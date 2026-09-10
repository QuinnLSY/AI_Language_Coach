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
    private var generationTask: Task<Void, Never>?
    /// 会话是否已落库。**启动时不建空会话**——否则「最近会话」永远是新会话，
    /// 上次的练习记录与情景就再也恢复不回来了；首条消息 / 首次进情景时才建行。
    private var didPersistSession = false

    public init(services: CoachServices) {
        self.services = services
        self.sessionID = UUID()
    }

    public func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isGenerating else { return }
        let message = ChatMessage(role: .user, content: trimmed)
        messages.append(message)
        persist(message)
        // 情景对话：学员每发一次言记一轮，用于给老师「还剩几轮」的收尾提示。
        if scenarioProgress != nil { scenarioProgress?.turnsUsed += 1 }
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
    }

    /// 启动时恢复上次会话：消息回流 + 继续往同一会话里追加。
    /// 若上次在练情景，则把情景一并接回来（老师继续扮演，轮次按已发言数还原）。
    public func restoreLastSessionIfNeeded() async {
        guard messages.isEmpty, !isGenerating else { return }
        guard let restored = await services.latestChatSession(), !restored.messages.isEmpty else { return }
        sessionID = restored.session.id
        didPersistSession = true
        messages = restored.messages
        if let scenarioID = restored.session.scenarioID,
           let scenario = await services.scenario(id: scenarioID) {
            scenarioProgress = ScenarioProgress(
                scenario: scenario,
                turnsUsed: messages.filter { $0.role == .user }.count
            )
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
    }

    // MARK: - 内部

    private func generate() async {
        defer { isGenerating = false }

        let configuration = await services.configuration
        let providerConfig = configuration.resolvedProvider(for: .llm)
        let providerName = providerConfig?.userFacingName
        let model = await services.currentLLMModel()

        // ① 模型被用户显式关闭 → 立刻明确告诉他怎么办，而不是假装在生成。
        if !(await services.isModelRunning(.llm)) {
            errorMessage = ModelDiagnostics.stoppedHint(providerName: providerName, model: model)
            return
        }

        // ② 应用还没装配好 Provider 就收到了消息（用户手速快于启动）：
        //    以前这里直接以「尚未初始化」失败，表现就是「老师永远不回第一句」。
        //    现在自己把装配补上再继续。
        do {
            try await services.ensureLLMReady()
        } catch {
            errorMessage = ModelDiagnostics.describe(providerName: providerName, model: model, error: error)
            return
        }

        var systemPrompt = PromptBuilder.teacherSystemPrompt(
            learningLanguage: profile.learningLanguage,
            nativeLanguage: profile.nativeLanguage,
            proficiency: profile.proficiency.displayName,
            practiceMode: configuration.product.practiceMode
        )
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

        var llmMessages = [LLMMessage(role: .system, content: systemPrompt)]
        llmMessages.append(contentsOf: messages.map { LLMMessage(role: $0.role, content: $0.content) })

        let request = LLMRequest(
            messages: llmMessages,
            model: model,
            temperature: providerConfig?.temperature,
            topP: providerConfig?.topP,
            maxTokens: providerConfig?.maxTokens,
            streaming: true
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
            if !parsed.corrections.isEmpty {
                correctionsByMessage[message.id] = parsed.corrections
                persistCorrections(parsed.corrections)
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
            return
        }
        // ⑤ 请求成功但正文为空：绝大多数是推理模型把输出预算全用在思考上了。
        if Task.isCancelled { return }
        errorMessage = ModelDiagnostics.label(providerName: providerName, model: model)
            + " 这次没有给出回复（可能把输出额度都用在思考上了）。请再发一次，或换个模型试试。"
    }

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
