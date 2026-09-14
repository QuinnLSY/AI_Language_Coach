import AIDomain
import AIInfrastructure
import AIInterfaces
import AppCore
import Foundation
import Observation

/// 面向 UI 的对话服务。**UI 只依赖本类型，禁止直连 Provider / HTTP。**
@MainActor
@Observable
public final class ChatService {

    public private(set) var messages: [ChatMessage] = []
    public private(set) var streamingText: String = ""
    public private(set) var isGenerating = false
    /// 模型正在「思考」：已有推理增量但还没有正文（推理模型常见）。
    public private(set) var isThinking = false
    /// 流式思考过程（实时增长；UI 折叠面板展示最新若干行）。
    public private(set) var streamingReasoning: String = ""
    public private(set) var errorMessage: String?

    public var profile: LearnerProfile = LearnerProfile()
    /// 当前练习会话（持久化用）。
    public private(set) var sessionID: UUID
    /// 进行中的情景对话（nil = 普通练习）。场景数据来自资源文件，UI 不内置。
    public private(set) var scenarioProgress: ScenarioProgress?
    /// 本会话按消息记录的纠错（UI 在气泡下方展示「改一改」卡片）。
    public private(set) var correctionsByMessage: [UUID: [GrammarCorrection]] = [:]
    /// 已取回的译文（messageID → 译文）。**默认不展示**，点翻译按钮才出现。
    public private(set) var translationsByMessage: [UUID: String] = [:]
    /// 正在取译文的消息（按钮转圈）。
    public private(set) var translatingMessageIDs: Set<UUID> = []
    /// 翻译失败提示（可关闭）。
    public private(set) var translationError: String?
    /// 本会话累计纠错条数。
    public var correctionCount: Int { correctionsByMessage.values.reduce(0) { $0 + $1.count } }
    /// 上下文占用估算（token）：流式响应通常不回传 usage，用字符数近似
    /// （中英混合约 3 字符/token，每条消息附加 ~8 token 结构开销）。
    public var estimatedContextTokens: Int {
        var chars = 0
        for message in messages { chars += message.content.count + 24 }
        return (chars * 10 + 29) / 30
    }

    private let services: CoachServices

    /// 对话引擎（第 6–10 步）：状态机 + 上下文 + 各 Agent 的编排点。
    ///
    /// 只装纯逻辑，**不发任何模型请求**：UI 可直接读 `engine.state` 来显示
    /// 「正在听 / 正在想 / 正在说」，而不是靠几个布尔量拼凑。
    public let engine: ConversationEngine
    /// 本轮教学计划（生成前算出）。UI / 调试可读；它不参与持久化。
    public private(set) var lastTurnPlan: TurnPlan?

    private var generationTask: Task<Void, Never>?
    /// 会话是否已落库。**启动时不建空会话**——否则「最近会话」永远是新会话，
    /// 上次的练习记录与情景就再也恢复不回来了；首条消息 / 首次进情景时才建行。
    private var didPersistSession = false
    /// 本次运行是否已经由老师打过招呼（每次打开应用只开一次场）。
    private var didGreetThisLaunch = false
    /// 当前正在生成的是开场招呼（学员抢话时可以直接撤掉）。
    private var isGreeting = false

    public init(services: CoachServices) {
        self.services = services
        self.sessionID = UUID()
        self.engine = ConversationEngine()
    }

    public func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 老师正在打招呼时学员抢话：先把招呼撤掉，绝不能让这句话石沉大海。
        if isGreeting { cancel() }
        guard !isGenerating else { return }
        let message = ChatMessage(role: .user, content: trimmed)
        messages.append(message)
        persist(message)
        // 情景对话：学员每发一次言记一轮，用于给老师「还剩几轮」的收尾提示。
        if scenarioProgress != nil { scenarioProgress?.turnsUsed += 1 }
        // 状态机 + 上下文：这一轮学员说了什么，是后续决策的输入。
        engine.recordLearner(trimmed, at: message.createdAt)
        engine.send(.learnerSpoke)
        streamingText = ""
        errorMessage = nil
        isGenerating = true
        generationTask = Task { [weak self] in
            await self?.generate()
        }
    }

    // MARK: - 情景对话（Role Play，Implementation Plan §21）

    /// 进入一个情景：老师先以角色身份开场，之后每次回复都带着场景指令。
    /// 场景本体来自 `ScenarioCatalog`（资源文件），本层不做任何场景判断。
    /// 同时把会话标记为「在练该情景」落库 —— 重启后能接着练。
    public func startScenario(_ scenario: Scenario) {
        cancel()
        streamingText = ""
        streamingReasoning = ""
        isThinking = false
        errorMessage = nil
        scenarioProgress = ScenarioProgress(scenario: scenario)
        syncEngineScenario()
        persistScenarioBinding(scenario.id)
        let opening = scenario.opening.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !opening.isEmpty else { return }
        let message = ChatMessage(role: .assistant, content: opening)
        messages.append(message)
        persist(message)
    }

    /// 退出情景，回到普通练习（已产生的对话保留）。
    public func endScenario() {
        scenarioProgress = nil
        syncEngineScenario()
    }

    /// 把情景进度同步给对话引擎（决策要知道「还剩几轮 / 目标词是什么」）。
    private func syncEngineScenario() {
        engine.syncScenario(
            scenarioProgress.map { ScenarioFocus(scenario: $0.scenario, turnsRemaining: $0.turnsRemaining) }
        )
    }

    private func persistScenarioBinding(_ scenarioID: String?) {
        let sessionID = sessionID
        let services = services
        Task {
            await services.attachScenario(scenarioID, to: sessionID, mode: .conversation)
        }
    }

    private func persist(_ message: ChatMessage) {
        let sessionID = sessionID
        let services = services
        let needsSession = !didPersistSession
        didPersistSession = true
        let scenarioID = scenarioProgress?.scenario.id
        // 建行与写消息放在同一个 Task 里，保证顺序（消息带外键）。
        Task {
            if needsSession {
                await services.persistSession(
                    ChatSession(id: sessionID, startedAt: Date(), scenarioID: scenarioID)
                )
            }
            await services.persistMessage(message, sessionID: sessionID)
        }
    }

    public func cancel() {
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
        // 取消后回到「可以再次开口」的状态。上下文**保留** ——
        // 学员画像、跨会话记忆、已练到第几轮都不该因为一次取消而清空。
        engine.send(.reset)
    }

    /// 启动时恢复上次会话：消息回流 + 继续往同一会话里追加。
    /// 若上次在练情景，则把情景一并接回来（老师继续扮演，轮次按已发言数还原）。
    public func restoreLastSessionIfNeeded() async {
        guard messages.isEmpty, !isGenerating else { return }
        guard let restored = await services.latestChatSession(), !restored.messages.isEmpty else { return }
        sessionID = restored.session.id
        didPersistSession = true
        messages = restored.messages
        // 把恢复出来的历史灌进引擎上下文：老师要知道「刚才聊到哪」，
        // 决策（难度 / 学员答得长短）也才有依据。
        engine.replaceTurns(restored.messages)
        if let scenarioID = restored.session.scenarioID,
           let scenario = await services.scenario(id: scenarioID) {
            scenarioProgress = ScenarioProgress(
                scenario: scenario,
                turnsUsed: messages.filter { $0.role == .user }.count
            )
            syncEngineScenario()
        }
    }

    public func clear() {
        cancel()
        messages.removeAll()
        streamingText = ""
        streamingReasoning = ""
        scenarioProgress = nil
        persistScenarioBinding(nil)
        errorMessage = nil
        translationsByMessage.removeAll()
        translatingMessageIDs.removeAll()
        translationError = nil
        lastTurnPlan = nil
        // 开一段全新的练习：状态复位、上下文里的对话轨迹清空。
        // 学员画像与跨会话记忆**不动** —— 那是「这个人」的属性，不是「这段会话」的。
        engine.reset()
        engine.updateContext { context in
            context.recentTurns.removeAll()
            context.scenario = nil
            context.currentTopic = nil
        }
    }

    // MARK: - 内部

    /// 一次生成所需的上下文（Provider 名 / 模型 / 产品配置）。
    private struct TeacherContext {
        let configuration: AppConfiguration
        let providerName: String?
        let model: String?
    }

    /// 生成前的统一就绪检查：模型没被关闭 + Provider 已装配（用户手速快于启动时自己补上）。
    /// 不就绪时已经把可读的错误写进 `errorMessage` 并返回 nil。
    private func resolveTeacherContext() async -> TeacherContext? {
        let configuration = await services.configuration
        let providerName = configuration.resolvedProvider(for: .llm)?.userFacingName
        let model = await services.currentLLMModel()

        // ① 模型不在运行 → 先判断是不是资源管理自动挂起的：是就静默恢复，不打扰用户；
        //    只有用户显式关闭（恢复不了）才明确告诉他怎么办，而不是假装在生成。
        if !(await services.isModelRunning(.llm)) {
            _ = (try? await services.resumeIfSuspended(.llm)) ?? false
            if !(await services.isModelRunning(.llm)) {
                errorMessage = ModelDiagnostics.stoppedHint(providerName: providerName, model: model)
                return nil
            }
        }

        // ② 应用还没装配好 Provider 就收到了消息（用户手速快于启动）：
        //    以前这里直接以「尚未初始化」失败，表现就是「老师永远不回第一句」。
        //    现在自己把装配补上再继续。
        do {
            try await services.ensureLLMReady()
        } catch {
            errorMessage = ModelDiagnostics.describe(providerName: providerName, model: model, error: error)
            return nil
        }
        return TeacherContext(configuration: configuration, providerName: providerName, model: model)
    }

    /// 老师的人设提示词（含跨会话学习记忆 + 情景角色叠加 + 本轮教学计划）。
    ///
    /// 顺序即优先级：人设 → 长期记忆 → 情景角色 → 本轮计划。
    /// 计划放最后是有意的——离生成最近的指令权重最高，而它正是「这一轮该怎么教」。
    private func systemPrompt(
        for configuration: AppConfiguration,
        memory: LearningMemory,
        plan: TurnPlan?
    ) -> String {
        var systemPrompt = PromptBuilder.teacherSystemPrompt(
            learningLanguage: profile.learningLanguage,
            nativeLanguage: profile.nativeLanguage,
            proficiency: profile.proficiency.displayName,
            practiceMode: configuration.product.practiceMode
        )
        let memoryBlock = PromptBuilder.learningMemoryBlock(
            memory,
            learningLanguage: profile.learningLanguage,
            nativeLanguage: profile.nativeLanguage
        )
        if !memoryBlock.isEmpty {
            systemPrompt += "\n\n" + memoryBlock
        }
        // 情景对话：在老师人设之后再叠一层角色扮演指令（场景数据驱动，不写死在业务里）。
        if let progress = scenarioProgress {
            let block = PromptBuilder.scenarioBlock(
                scenario: progress.scenario,
                turnsRemaining: progress.turnsRemaining,
                learningLanguage: profile.learningLanguage,
                nativeLanguage: profile.nativeLanguage
            )
            systemPrompt += "\n\n" + block
        }
        // 本轮教学计划：教学逻辑在 Agent 层算好，这里只是它的渲染目标。
        if let plan, plan.hasAnythingToTeach {
            let block = PromptBuilder.responsePlanBlock(
                plan.plan,
                decision: plan.decision,
                direction: plan.direction,
                learningLanguage: profile.learningLanguage,
                nativeLanguage: profile.nativeLanguage
            )
            if !block.isEmpty { systemPrompt += "\n\n" + block }
        }
        return systemPrompt
    }

    /// 学员最近说的一句，作为学习记忆检索的查询串（没有则 nil = 只走结构化记忆）。
    private func latestUserMessage() -> String? {
        messages.last(where: { $0.role == .user })?.content
    }

    private func request(context: TeacherContext, systemPrompt: String, history: [LLMMessage]) -> LLMRequest {
        let providerConfig = context.configuration.resolvedProvider(for: .llm)
        var llmMessages = [LLMMessage(role: .system, content: systemPrompt)]
        llmMessages.append(contentsOf: history)
        return LLMRequest(
            messages: llmMessages,
            model: context.model,
            temperature: providerConfig?.temperature,
            topP: providerConfig?.topP,
            maxTokens: providerConfig?.maxTokens,
            streaming: true
        )
    }

    private func generate() async {
        // 被取消时**不要**顺手清掉 isGenerating：见 generateGreeting() 的同款注释。
        defer { if !Task.isCancelled { isGenerating = false } }

        guard let context = await resolveTeacherContext() else {
            engine.send(.generationFailed)
            return
        }
        let configuration = context.configuration
        let providerName = context.providerName
        let model = context.model

        // 本轮教学计划：状态/记忆/情景 → 决策 → 方向 → 响应计划。
        // **纯函数、零模型请求**，因此每轮都算也不会有额外开销或计费。
        engine.send(.generationStarted)
        syncEngineScenario()
        let memory = await services.learningMemory(query: latestUserMessage())
        let learnerText = latestUserMessage() ?? ""
        let plan = engine.planTurn(learnerText: learnerText, memory: memory, profile: profile)
        lastTurnPlan = plan

        let request = self.request(
            context: context,
            systemPrompt: systemPrompt(for: configuration, memory: memory, plan: plan),
            history: messages.map { LLMMessage(role: $0.role, content: $0.content) }
        )
        let tokensBefore = estimatedContextTokens
        var accumulated = ""
        var reasoning = ""
        var failure: Error?
        do {
            let stream = await services.llm.stream(request)
            for try await chunk in stream {
                if Task.isCancelled { break }
                if let delta = chunk.reasoningDelta, !delta.isEmpty {
                    reasoning += delta
                    streamingReasoning = reasoning
                }
                if !chunk.textDelta.isEmpty {
                    // 首个正文增量的时刻 = 「正在说」的开始。
                    if accumulated.isEmpty { engine.send(.firstToken) }
                    accumulated += chunk.textDelta
                    streamingText = accumulated
                }
                isThinking = accumulated.isEmpty && !reasoning.isEmpty
            }
        } catch {
            failure = error
        }

        streamingText = ""
        streamingReasoning = ""
        isThinking = false

        var finalText = Self.stripThinking(accumulated).trimmingCharacters(in: .whitespacesAndNewlines)

        // ③ 流式一个字都没拿到（部分 runtime 的 SSE 会失败）→ 退回一次性请求再试一次。
        //    宁可多花一次请求，也不要让学员的话石沉大海。
        if finalText.isEmpty, failure == nil, !Task.isCancelled {
            if let fallback = await nonStreamingFallback(request) {
                finalText = fallback
                reasoning = ""
            }
        }

        if !finalText.isEmpty {
            // 抽取老师标注的纠错块（[[FIX]] ...），不进聊天正文。
            let parsed = Self.extractCorrections(finalText)
            let trimmedReasoning = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = ChatMessage(
                role: .assistant,
                content: parsed.cleanText,
                reasoning: trimmedReasoning.isEmpty ? nil : trimmedReasoning
            )
            messages.append(message)
            persist(message)
            engine.recordTeacher(parsed.cleanText, at: message.createdAt)
            engine.send(.generationFinished)
            if !parsed.corrections.isEmpty {
                correctionsByMessage[message.id] = parsed.corrections
                persistCorrections(parsed.corrections)
                // 结构化分析（分类 / 定级 / 判重）——同样零请求：
                // 结果进「已知错误」，成为**下一轮**决策的依据（「反复错误 → 集中练」由此生效）。
                _ = engine.analyzeReply(parsed.corrections, history: await services.recentCorrectionRecords())
            }
            // 今日全局 token 用量（上下文增量估算，供黑板/督促气泡）。
            DailyTokenCounter.add(max(estimatedContextTokens - tokensBefore, 0))
            return
        }

        // ④ 调用出错 → 明确说出是哪个模型出的问题。
        if let failure {
            if !(failure is CancellationError) {
                errorMessage = ModelDiagnostics.describe(providerName: providerName, model: model, error: failure)
            }
            if !(failure is CancellationError) { engine.send(.generationFailed) }
            return
        }
        // ⑤ 请求成功但正文为空：绝大多数是推理模型把输出预算全用在思考上了。
        if Task.isCancelled { return }
        engine.send(.generationFinished)
        errorMessage = ModelDiagnostics.label(providerName: providerName, model: model)
            + " 这次没有给出回复（可能把输出额度都用在思考上了）。请再发一次，或换个模型试试。"
    }

    // MARK: - 开场招呼（打开应用时老师先开口）

    /// 应用打开、服务就绪后由**老师先打招呼**，开启本次学习。
    ///
    /// 存在的理由：以前「打开应用 → 学员立刻发第一句」，而此时 LLM Provider 可能还没装配完，
    /// 那一句就石沉大海了。现在改成老师先开口，学员看到老师说话就知道可以开口了。
    ///
    /// 每次打开应用只开场一次；已在生成 / 已在情景中（情景有自己的开场白）则不插话。
    public func greetIfNeeded() {
        guard !didGreetThisLaunch, !isGenerating, scenarioProgress == nil else { return }
        didGreetThisLaunch = true
        isGreeting = true
        isGenerating = true
        errorMessage = nil
        engine.send(.generationStarted)
        generationTask = Task { [weak self] in
            await self?.generateGreeting()
        }
    }

    private func generateGreeting() async {
        defer {
            isGreeting = false
            // 被取消时不抢状态：「学员抢话」这条路径是 send() 先 cancel() 再起新的生成，
            // 这里若顺手清掉 isGenerating，新消息刚点亮的「生成中」会立刻被抹掉。
            if !Task.isCancelled { isGenerating = false }
        }
        guard let context = await resolveTeacherContext() else {
            engine.send(.generationFailed)
            return
        }
        let memory = await services.learningMemory(query: latestUserMessage())
        var request = self.request(
            context: context,
            // 开场招呼**不带教学计划**：此刻还没有学员发言可依据，
            // 硬套一份「本轮该纠错」的计划会让老师一开口就找错。
            systemPrompt: systemPrompt(for: context.configuration, memory: memory, plan: nil),
            // 带上已有历史：恢复的会话里老师会自然地说「欢迎回来」，而不是重复自我介绍。
            history: messages.map { LLMMessage(role: $0.role, content: $0.content) }
                + [LLMMessage(role: .user,
                              content: PromptBuilder.greetingPrompt(
                                learningLanguage: profile.learningLanguage,
                                nativeLanguage: profile.nativeLanguage))]
        )
        // 招呼很短，不需要逐 token 上屏；一次性拿回来即可。
        request.streaming = false

        let tokensBefore = estimatedContextTokens
        guard let response = try? await services.llm.generate(request) else {
            engine.send(.generationFailed)
            return
        }
        let text = Self.stripThinking(response.text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !Task.isCancelled else {
            if !Task.isCancelled { engine.send(.generationFailed) }
            return
        }
        let parsed = Self.extractCorrections(text)
        guard !parsed.cleanText.isEmpty else {
            engine.send(.generationFailed)
            return
        }
        let message = ChatMessage(role: .assistant, content: parsed.cleanText)
        messages.append(message)
        persist(message)
        engine.recordTeacher(parsed.cleanText, at: message.createdAt)
        engine.send(.generationFinished)
        if !parsed.corrections.isEmpty {
            correctionsByMessage[message.id] = parsed.corrections
            persistCorrections(parsed.corrections)
        }
        DailyTokenCounter.add(max(estimatedContextTokens - tokensBefore, 0))
    }

    // MARK: - 气泡翻译（按需）

    /// 取某条消息的译文；**再点一次收起**（译文默认不展示）。
    ///
    /// 译文不进对话历史，也不进上下文窗口 —— 翻译只在 UI 上按需展示。
    public func translate(messageID: UUID) async {
        guard messages.contains(where: { $0.id == messageID }) else { return }
        if translationsByMessage[messageID] != nil {
            translationsByMessage.removeValue(forKey: messageID)
            return
        }
        guard !translatingMessageIDs.contains(messageID) else { return }
        translatingMessageIDs.insert(messageID)
        defer { translatingMessageIDs.remove(messageID) }
        translationError = nil
        let source = messages.first(where: { $0.id == messageID })?.content ?? ""
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // 模型不在运行时与对话生成同一套口径：资源管理挂起的静默恢复，
        // 用户显式关闭的给「去哪打开」的提示，而不是笼统的「未就绪」。
        if !(await services.isModelRunning(.llm)) {
            _ = (try? await services.resumeIfSuspended(.llm)) ?? false
            if !(await services.isModelRunning(.llm)) {
                let configuration = await services.configuration
                translationError = ModelDiagnostics.stoppedHint(
                    providerName: configuration.resolvedProvider(for: .llm)?.userFacingName,
                    model: await services.currentLLMModel()
                )
                return
            }
        }
        do {
            let result = try await services.translate(source, targetLanguage: profile.nativeLanguage)
            guard !Task.isCancelled else { return }
            guard !result.isEmpty else {
                translationError = "没有拿到翻译结果，请再点一次翻译。"
                return
            }
            translationsByMessage[messageID] = result
        } catch {
            guard !Task.isCancelled else { return }
            let configuration = await services.configuration
            translationError = ModelDiagnostics.describe(
                providerName: configuration.resolvedProvider(for: .llm)?.userFacingName,
                model: await services.currentLLMModel(),
                error: error
            )
        }
    }

    /// 关闭翻译失败提示。
    public func clearTranslationError() { translationError = nil }

    /// 无流式兜底：同样请求再走一次非流式通道，返回可用的正文（失败返回 nil）。
    private func nonStreamingFallback(_ request: LLMRequest) async -> String? {
        var plain = request
        plain.streaming = false
        do {
            let response = try await services.llm.generate(plain)
            let text = Self.stripThinking(response.text).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }

    /// 解析并剥离 `[[FIX]] 原句 => 改正 => 简短说明` 行。
    /// 返回净化后的正文与纠错列表（纯函数，便于单测）。
    nonisolated static func extractCorrections(_ text: String) -> (cleanText: String, corrections: [GrammarCorrection]) {
        var corrections: [GrammarCorrection] = []
        var keptLines: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[[FIX]]") else {
                keptLines.append(line)
                continue
            }
            let body = trimmed.dropFirst("[[FIX]]".count).trimmingCharacters(in: .whitespaces)
            let parts = body.components(separatedBy: "=>").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { continue }
            let explanation = parts.count >= 3 ? parts[2] : ""
            corrections.append(GrammarCorrection(original: parts[0], corrected: parts[1], explanation: explanation))
        }
        let clean = keptLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (clean, corrections)
    }

    private func persistCorrections(_ corrections: [GrammarCorrection]) {
        let sessionID = sessionID
        let services = services
        Task {
            for correction in corrections {
                await services.persistCorrection(correction, sessionID: sessionID)
            }
        }
    }

    /// deepseek-r1 会输出 `<think>...推理...</think>`，产品层不展示推理段。
    private static func stripThinking(_ text: String) -> String {
        guard let start = text.range(of: "<think>") else { return text }
        if let end = text.range(of: "</think>", range: start.upperBound..<text.endIndex) {
            return String(text[..<start.lowerBound]) + String(text[end.upperBound...])
        }
        return String(text[..<start.lowerBound])
    }
}
