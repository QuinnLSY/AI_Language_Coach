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

    /// **界面上要画的消息**。平时就是 `messages`，只有一种例外：
    /// 启动时把上一段会话接回内存、但马上要把它复盘掉换一段新的（见 `hideRestoredHistory()`）。
    ///
    /// ⚠️ 视图一律读这个，不要直接读 `messages` —— 否则那段「待会儿就没了的对话」
    /// 会在开屏时先画上屏、几秒后再被撤掉（用户实测：先闪一条学员问候，再变成老师的招呼）。
    public var visibleMessages: [ChatMessage] {
        suppressesRestoredHistory ? [] : messages
    }

    /// 恢复出来的历史**先不给界面看**（只留在内存里，复盘还要用它）。
    private var suppressesRestoredHistory = false

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
    /// 本局情景开始时的消息下标（开场白**之前**）。
    /// 课程覆盖度据此只数这一局说过的话，见 `scenarioLearnerUtterances`。
    public private(set) var scenarioStartIndex: Int = 0
    /// 当前任务的「前情提要」（情景模式下有值）。
    ///
    /// 它同时喂给两处：老师的 Prompt（引导的依据）与界面上的前情提要卡片。
    /// 单一来源，避免「老师说的」与「卡片写的」对不上。
    public private(set) var briefing: ScenarioBriefing?
    /// 上次随口练的复盘（随口练开场与引导的依据；没有历史时为 nil）。
    public private(set) var freeTalkReview: SessionReview?
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
    ///
    /// 图片按 `Self.imageTokenEstimate` 计 —— 视觉模型对一张普通截图普遍收几百到上千 token，
    /// 不把它算进来的话，用户会看到「上下文只用了 5%」却已经被服务端拒绝。
    public var estimatedContextTokens: Int {
        var chars = 0
        var images = 0
        for message in messages {
            chars += message.content.count + 24
            images += message.attachments.filter(\.isImage).count
        }
        return (chars * 10 + 29) / 30 + images * Self.imageTokenEstimate
    }

    /// 单张图片的粗略 token 开销（视觉模型普遍量级）。
    public static let imageTokenEstimate = 800

    /// 会把图片**真正内联发出**的历史轮数。
    ///
    /// 为什么不是「全部历史都带图」：图片会以 base64 内联进请求体，而对话每轮都要把
    /// 全部历史重发一次 —— 那样请求体会随图片数量近似平方增长（10 张图聊 10 轮 = 发 55 次），
    /// 用户看到的是「越聊越慢」和一张越来越长的账单。当前轮带图、更早的图片退化成文件名说明，
    /// 是这个权衡下最实用的折中。
    public static let inlineImageHistoryTurns = 1

    private let services: CoachServices
    /// 附件根目录：**取自 `AttachmentStore`**，与仓库自己的定位规则同源。
    ///
    /// 这里绝不再自己拼一次 `userDataDirectory()/attachments`：
    /// 两处各拼一次，只要有一处写错就会变成「图片预览显示正常、发给模型却是空的」——
    /// 两边都不报错，最难查。
    private let attachmentRoot: URL = AttachmentStore.defaultDirectory

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
    /// 本会话是随口练（开场与 Prompt 引导都走「学员主导」那一路）。
    private var isFreeTalkSession = false
    /// 本会话在考试（非 nil = 老师这一轮以**考官**身份说话）。
    ///
    /// 与情景对话一样是「角色叠加」，但价值取向相反：情景对话是陪练，
    /// 考试模式要按考卷流程一题一题走完，不聊天、不展开教学。
    public private(set) var examContext: ExamTurnContext?
    /// 学员每说完一句后的回调（AppState 用它**实时**保存主线任务进度，需求 5）。
    public var onLearnerTurn: (@MainActor () async -> Void)?
    /// **老师一轮结束**后的回调（成功给出了消息、失败什么都没说、被取消，都算一轮结束）。
    ///
    /// 存在的理由：考试模式下有两件事只能发生在生成**之后** ——
    /// ① 题目真正出现在学员面前的时刻（倒计时的起表点，见 `ExamRunner.arm`）；
    /// ② 老师这一轮标出的纠错条数（语法分的依据，事后补记到刚答完那一问上）。
    /// 让 AppState 去轮询 `isGenerating` 也能做到，但那是猜时刻；这里是真事件。
    ///
    /// - Parameters:
    ///   - message: 这一轮产出的老师消息；nil = 这一轮没有产出正文（模型没起 / 回空 / 被取消）。
    ///   - corrections: 这一轮老师标注的纠错。
    public var onTeacherTurnEnd: ((ChatMessage?, [GrammarCorrection]) -> Void)?
    /// 当前正在生成的是开场招呼（学员抢话时可以直接撤掉）。
    ///
    /// 公开给界面用：开场白是一次**真实模型调用**，冷启动实测 30–60s。
    /// 对话区要据此给出「老师正在准备…（已等待 N 秒）」的专门等待态
    /// （`TeacherPreparingCard`），而不是与普通回复共用那三个跳动的点。
    public private(set) var isGreeting = false

    public init(services: CoachServices) {
        self.services = services
        self.sessionID = UUID()
        self.engine = ConversationEngine()
    }

    public func send(_ text: String, attachments: [ChatAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 只发附件、不写字也是合法的一句（主流 Agent 都允许「丢张图 + 空白」）。
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        // 老师正在打招呼时学员抢话：先把招呼撤掉，绝不能让这句话石沉大海。
        if isGreeting { cancel() }
        guard !isGenerating else { return }
        let message = ChatMessage(role: .user, content: trimmed, attachments: attachments)
        messages.append(message)
        // 学员一开口，这段会话（可能是刚恢复出来、正待复盘的那一段）就是他要**接着用**的
        // 东西 —— 立刻揭开。
        // ⚠️ 少了这一句：启动那几秒里「隐藏待复盘」的标志还挂着，学员抢在老师前面说的话
        // 会被一起藏起来（表现为「我打了一句，屏幕上什么都没有」）。
        suppressesRestoredHistory = false
        persist(message)
        // 情景对话：学员每发一次言记一轮，用于给老师「还剩几轮」的收尾提示。
        if scenarioProgress != nil { scenarioProgress?.turnsUsed += 1 }
        // 主线任务的「当前节点」跟着这一句往前走（老师下一轮就知道该带学员做哪一步了）。
        if let current = briefing {
            briefing = current.refreshed(utterances: scenarioLearnerUtterances)
        }
        // 实时落库：学员一说到某个步骤，立刻记下来（中途退出也不丢）。
        if let hook = onLearnerTurn {
            Task { await hook() }
        }
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

    /// 附件在本机的位置。同步、无 I/O（除拼路径），可直接在视图渲染里用。
    ///
    /// 定位规则与 `AttachmentStore.fileURL(for:)` **共用同一个 `fileName(of:)`**，
    /// 因此「预览能显示」与「模型拿得到数据」不可能出现一半成立的情况。
    public func attachmentLocation(for attachment: ChatAttachment) -> URL {
        attachmentRoot.appendingPathComponent(AttachmentStore.fileName(of: attachment.storedPath))
    }

    // MARK: - 情景对话（Role Play，Implementation Plan §21）

    /// 进入一个情景：老师先以角色身份开场，之后每次回复都带着场景指令。
    /// 场景本体来自 `ScenarioCatalog`（资源文件），本层不做任何场景判断。
    /// 同时把会话标记为「在练该情景」落库 —— 重启后能接着练。
    ///
    /// ⚠️ **不再直接把素材里的 `opening` 贴上去**（需求 3/6）：
    /// 开场白改由老师生成，先交代「上次练到哪、这次先做什么」，再进入角色。
    /// 模型没起来时由 `briefing.fallbackOpeningMessage` 顶上（角色开场白 + 一句中文引导），
    /// 所以「老师一定有话说」这条不会因为模型没起而破。
    public func startScenario(_ scenario: Scenario, briefing: ScenarioBriefing? = nil) {
        cancel()
        streamingText = ""
        streamingReasoning = ""
        isThinking = false
        errorMessage = nil
        // 记下本局起点：之后算课程覆盖度时**只数这一局说过的话**，
        // 不把进入情景之前的闲聊算成「这一关说了几句」。
        scenarioStartIndex = messages.count
        scenarioProgress = ScenarioProgress(scenario: scenario)
        self.briefing = briefing
        freeTalkReview = nil
        // 进情景即离开随口练：两个模式是互斥的，靠别处调用 `clear()` 顺带复位不可靠。
        isFreeTalkSession = false
        syncEngineScenario()
        persistScenarioBinding(scenario.id)
    }

    /// 退出情景，回到普通练习（已产生的对话保留）。
    public func endScenario() {
        scenarioProgress = nil
        briefing = nil
        syncEngineScenario()
    }

    // MARK: - 考试模式（雅思口语 / 面试问答）

    /// 进入考试：老师从这一轮起以**考官**身份说话。
    ///
    /// 与 `startScenario` 的分工一样：这里只负责「老师是谁、问到哪」，
    /// 题目与流程全在 `ExamRunner` 里（纯值类型，可单测）。
    /// ⚠️ 考试与情景 / 随口练**互斥**，这里显式清掉另两个标记 ——
    /// 靠别处调用 `clear()` 顺带复位是不可靠的（老坑）。
    public func beginExam(_ context: ExamTurnContext) {
        cancel()
        streamingText = ""
        streamingReasoning = ""
        isThinking = false
        errorMessage = nil
        examContext = context
        scenarioProgress = nil
        briefing = nil
        freeTalkReview = nil
        isFreeTalkSession = false
        scenarioStartIndex = messages.count
        syncEngineScenario()
    }

    /// 更新考官这一轮的口径（答完一问 → 换成下一问；nil = 不再以考官身份说话）。
    ///
    /// 由 AppState 在**记录作答之后、发送之前**调用：老师这一轮拿到的
    /// 「现在该问哪一句」才是推进之后的那一题。
    public func updateExamContext(_ context: ExamTurnContext?) {
        examContext = context
    }

    /// 退出考试（回到普通练习，已产生的对话保留）。
    public func endExam() {
        examContext = nil
    }

    /// 由考卷直接宣布下一问：**本地消息，零模型请求**。
    ///
    /// 走这条路只有两种情况：学员超时/主动跳过（没人作答，也就没有话头递给老师），
    /// 或老师这一轮没产出正文（模型没起来）。两种情况下题目都必须照常出下去，
    /// 否则整场就卡在那一题上了。
    public func announceExamPrompt(_ context: ExamTurnContext, reason: String? = nil) {
        let head = reason.map { "（\($0)）" } ?? ""
        appendLocalTeacherMessage(
            "\(head)第 \(context.questionNumber)/\(context.totalQuestions) 问：\(context.prompt)"
        )
    }

    // MARK: - 课程体系取材（CEFR 覆盖度）

    /// 本局情景里学员说过的话（按时间顺序）。
    ///
    /// **必须在 `endScenario()` 之前取** —— 退出后 `scenarioProgress` 就没了，
    /// 这里就再也分不清「哪几句属于这一局」。
    ///
    /// 只数 `scenarioStartIndex` 之后的消息：进入情景前的闲聊不算这一关的产出。
    /// 端上恢复的历史会话把整段都算作这一局 —— 与 `restoreLastSessionIfNeeded`
    /// 里 `turnsUsed` 的口径保持一致，两处不能各说各的。
    public var scenarioLearnerUtterances: [String] {
        guard scenarioProgress != nil else { return [] }
        let start = min(max(scenarioStartIndex, 0), messages.count)
        return messages[start...]
            .filter { $0.role == .user }
            .map(\.content)
    }

    /// 把情景进度同步给对话引擎（决策要知道「还剩几轮 / 目标词是什么」）。
    private func syncEngineScenario() {
        engine.syncScenario(
            scenarioProgress.map { ScenarioFocus(scenario: $0.scenario, turnsRemaining: $0.turnsRemaining) }
        )
    }

    /// 产品配置里的老师人格档位（`ProductConfig` 存的是 rawValue 字符串，同 `teacherAnimal` 的约定）。
    ///
    /// 认不出的值落回 `.standard` —— 老配置或手改过的配置不该让老师行为失常。
    private func currentPersona(_ configuration: AppConfiguration) -> TeacherPersona {
        TeacherPersona(rawValue: configuration.product.teacherPersona) ?? .standard
    }

    /// 本会话该以什么模式入库。
    ///
    /// ⚠️ **唯一真源**，别在别处另传常量：`sessions.mode` 是「上次在练什么」的判据
    /// （`PracticeResumeRule.action(latestScenarioID:latestMode:)`）。随口练的会话被记成
    /// `conversation` 之后，`resumeOrOpenPractice` 里那条「上次随口练 → 带着复盘接着聊」
    /// **永远走不到**，只会退化成一句普通招呼 —— 而且不报任何错。
    private var sessionMode: PracticeMode { isFreeTalkSession ? .freeTalk : .conversation }

    private func persistScenarioBinding(_ scenarioID: String?) {
        let sessionID = sessionID
        let services = services
        let mode = sessionMode
        Task {
            await services.attachScenario(scenarioID, to: sessionID, mode: mode)
        }
    }

    private func persist(_ message: ChatMessage) {
        let sessionID = sessionID
        let services = services
        let needsSession = !didPersistSession
        didPersistSession = true
        let scenarioID = scenarioProgress?.scenario.id
        // ⚠️ 模式必须跟着走：`ChatSession.mode` 有默认值 `.conversation`，
        // 不显式传就等于「所有会话都是情景对话」。
        let mode = sessionMode
        // 建行与写消息放在同一个 Task 里，保证顺序（消息带外键）。
        Task {
            if needsSession {
                await services.persistSession(
                    ChatSession(id: sessionID, startedAt: Date(), mode: mode, scenarioID: scenarioID)
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
        // ⚠️ 恢复出来的历史**先按住不显示**：这一刻还不知道它是要接着用、还是马上要被复盘掉。
        // 直接上屏就有几百毫秒的闪窗（恢复 → 续做决策之间还夹着好几段 await），
        // 用户看到的就是「先闪一条学员问候，再变成老师的招呼」（实测报障）。
        // 由 `resumeOrOpenPractice()` 在决策完之后决定揭不揭开（`revealRestoredHistory()`）。
        suppressesRestoredHistory = true
        // 把恢复出来的历史灌进引擎上下文：老师要知道「刚才聊到哪」，
        // 决策（难度 / 学员答得长短）也才有依据。
        engine.replaceTurns(restored.messages)
        isFreeTalkSession = restored.session.mode == .freeTalk
        if let scenarioID = restored.session.scenarioID,
           let scenario = await services.scenario(id: scenarioID) {
            scenarioProgress = ScenarioProgress(
                scenario: scenario,
                turnsUsed: messages.filter { $0.role == .user }.count
            )
            // 恢复的历史会话没有「本局起点」可考，整段都算这一局 ——
            // 与上面 `turnsUsed` 数全部学员发言保持同一口径。
            scenarioStartIndex = 0
            syncEngineScenario()
        }
    }

    /// 把恢复出来的这段历史**从界面上撤掉**（数据仍留在内存里）。
    ///
    /// ⚠️ 恢复的那一刻就已经按住了（见 `restoreLastSessionIfNeeded`），所以这个方法现在是
    /// **幂等的保险**：真正决定「这段历史要不要接着用」的是 `resumeOrOpenPractice()`，
    /// 它若判定要换新的一段，就在复盘之前再按一次 —— 复盘要跑一次模型请求（好几秒），
    /// 那几秒里绝不能把上一段画在屏幕上。
    public func hideRestoredHistory() {
        guard !messages.isEmpty else { return }
        suppressesRestoredHistory = true
    }

    /// 揭开被按住的这段历史：**只有它确实还留在对话里**（情景续做 / 续聊 / 只是想接着看）时才调。
    ///
    /// 已经换了新一段的路径不用调 —— `clear()` 会把流水和这个标记一起复位。
    public func revealRestoredHistory() {
        guard !messages.isEmpty else { return }
        suppressesRestoredHistory = false
    }

    public func clear() {
        cancel()
        messages.removeAll()
        suppressesRestoredHistory = false
        streamingText = ""
        streamingReasoning = ""
        scenarioProgress = nil
        briefing = nil
        freeTalkReview = nil
        isFreeTalkSession = false
        examContext = nil
        scenarioStartIndex = 0
        // ⚠️ 这里**不写**会话绑定。`clear()` 的调用点全是「马上要开新的一段」：
        // `beginNewSession()` 会把 sessionID 换成新的，`beginFreeTalk()` 则在新 id 上重开。
        // 写一次 `attachScenario(nil, mode: .conversation)` 有两个坏处：
        //   ① 打到**上一段的 id** 上 → 把它刚留下的 `scenario_id` 抹成 NULL，
        //      而那是「上次练的是什么话题」的唯一记录（跨会话记忆的 `sessionFacts` 也读它）；
        //   ② 打在**新 id** 上（`beginFreeTalk` 那条路）→ 把随口练的会话抢先建成
        //      `conversation`，后面 `persist()` 的 `INSERT OR IGNORE` 就再也改不回来。
        // 新会话的绑定由真正建立它的人负责：`startScenario` / `persist()`。
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
        // 老师人格档位：紧跟人设 —— 它改的正是人设里那几条默认风格
        // （回复多长、纠不纠、什么时候用母语）。标准档返回空串，不注入。
        let personaBlock = PromptBuilder.teacherPersonaBlock(
            currentPersona(configuration),
            learningLanguage: profile.learningLanguage,
            nativeLanguage: profile.nativeLanguage
        )
        if !personaBlock.isEmpty {
            systemPrompt += "\n\n" + personaBlock
        }
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
            // 主线任务 / 教学重点 / 前情提要：**老师主动引导**的依据（需求 3）。
            // 与上面的角色指令分两块：一个说「你演谁」，一个说「把学员带到哪」。
            if let briefing {
                systemPrompt += "\n\n" + PromptBuilder.taskBlock(briefing: briefing)
            }
        }
        // 随口练（需求 4）：与情景对话相反 —— 学员主导，老师少引导、多建议与纠错。
        // ⚠️ 考试模式下**不注入**这一段：考场上没有「学员主导」这回事，
        // 两块同时注入会让老师一边念题一边问「你想聊点什么」。
        if configuration.product.practiceMode == .freeTalk,
           scenarioProgress == nil,
           examContext == nil {
            systemPrompt += "\n\n" + PromptBuilder.freeTalkBlock(review: freeTalkReview)
        }
        // 考试模式：把老师从「陪练」换成「考官」——排在人设与长期记忆之后，
        // 与情景角色同一层级（先是谁，再是这一轮干什么）。
        if let examContext {
            systemPrompt += "\n\n" + PromptBuilder.examExaminerBlock(
                examContext,
                learningLanguage: profile.learningLanguage,
                nativeLanguage: profile.nativeLanguage
            )
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

    /// 本地消息 → 传输消息：**只有最近 `inlineImageHistoryTurns` 轮学员消息里的图片会被内联**，
    /// 更早的图片与所有视频 / 文件退化成「附了 xxx.png」的说明。
    ///
    /// 图片读不出来（文件被清理）时也会退化成说明 —— 绝不能因为一张图丢了就让整轮对话失败。
    private func transportMessages() async -> [LLMMessage] {
        let userIndexes = messages.indices.filter { messages[$0].role == .user }
        let inlineFrom = userIndexes.suffix(Self.inlineImageHistoryTurns).first

        var result: [LLMMessage] = []
        for index in messages.indices {
            let message = messages[index]
            guard message.hasAttachments else {
                result.append(LLMMessage(role: message.role, content: message.content))
                continue
            }
            let inlineHere = message.role == .user && (inlineFrom.map { index >= $0 } ?? false)
            var images: [LLMInlineImage] = []
            var referenced: [String] = []
            for attachment in message.attachments {
                if inlineHere, attachment.isImage,
                   let data = await services.attachmentData(for: attachment) {
                    images.append(
                        LLMInlineImage(
                            mimeType: attachment.mimeType,
                            data: data,
                            fileName: attachment.fileName
                        )
                    )
                } else {
                    referenced.append(attachment.fileName)
                }
            }
            result.append(
                LLMMessage(
                    role: message.role,
                    content: message.content,
                    images: images,
                    referencedFileNames: referenced
                )
            )
        }
        return result
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
        // 这一轮的结果在这里攒着，由 `defer` 统一通知上层。
        // ⚠️ 不在四个 `return` 处各写一遍通知：漏掉任何一处，
        // 表现都是「考试模式下这一轮的倒计时永远不起表」——而且不报错。
        var turnResult: (message: ChatMessage, corrections: [GrammarCorrection])?
        // 被取消时**不要**顺手清掉 isGenerating：见 generateGreeting() 的同款注释。
        defer {
            if !Task.isCancelled { isGenerating = false }
            onTeacherTurnEnd?(turnResult?.message, turnResult?.corrections ?? [])
        }

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
        // 老师人格档位：在 `planTurn` 之前灌进去 —— 决策层读的 `teacherPreference`
        // 就是这里写的值，所以「设置里改档位」到「下一轮变口径」之间没有别的中间态。
        engine.syncPreference(currentPersona(configuration))
        let memory = await services.learningMemory(query: latestUserMessage())
        let learnerText = latestUserMessage() ?? ""
        let plan = engine.planTurn(learnerText: learnerText, memory: memory, profile: profile)
        lastTurnPlan = plan

        let request = self.request(
            context: context,
            systemPrompt: systemPrompt(for: configuration, memory: memory, plan: plan),
            history: await transportMessages()
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
            // 语言闸门（用户硬要求：学员可以用中文问，老师必须只能用英文答）：
            // 正文里混进中文就要一次「英文重说」。放在纠错块剥离之前，
            // 判据只看**剥离后的正文** —— 纠错行的说明本来就该用母语。
            if let rewritten = await englishOnlyRewriteIfNeeded(finalText, request: request) {
                // ⚠️ 重说**只重说正文**，纠错行必须原样留下：提示词里写了「keep the [[FIX]] line」，
                // 但那是靠模型自觉 —— 实测它有时顺手就把整块纠错删了（这一删，
                // 学员的错题本里就少一条，界面上也少一张卡片，而且不报错）。
                // 所以这里按「原来有、重说后没了」补回来，以原文为准。
                let original = Self.extractCorrections(finalText).corrections
                let kept = Self.extractCorrections(rewritten).corrections
                finalText = kept.isEmpty && !original.isEmpty
                    ? rewritten + "\n" + Self.correctionLines(original)
                    : rewritten
            }
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
            turnResult = (message, parsed.corrections)
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
        guard !didGreetThisLaunch, !isGenerating, scenarioProgress == nil, examContext == nil else { return }
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
        var turnResult: (message: ChatMessage, corrections: [GrammarCorrection])?
        defer {
            isGreeting = false
            // 被取消时不抢状态：「学员抢话」这条路径是 send() 先 cancel() 再起新的生成，
            // 这里若顺手清掉 isGenerating，新消息刚点亮的「生成中」会立刻被抹掉。
            if !Task.isCancelled { isGenerating = false }
            onTeacherTurnEnd?(turnResult?.message, turnResult?.corrections ?? [])
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
            history: await transportMessages()
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
        turnResult = (message, parsed.corrections)
    }

    // MARK: - 老师引导开场（需求 3 / 4 / 6）

    /// 挂上（或刷新）前情提要。恢复会话、切换任务时由上层调用。
    public func applyBriefing(_ briefing: ScenarioBriefing?) {
        self.briefing = briefing
    }

    /// 开始一段随口练：清空对话，记住上次的复盘（开场与引导要用）。
    public func beginFreeTalk(review: SessionReview?) {
        clear()
        freeTalkReview = review
        isFreeTalkSession = true
    }

    /// 开一段**全新的练习**：换一个新的会话 id。
    ///
    /// 每次练习 = 一个会话 = 一张记录卡片 + 一份复盘（需求 5 的「每次练习都要复盘」）。
    /// 复用同一个会话 id 会让两次练习共用一张卡片，复盘也会互相覆盖。
    ///
    /// ⚠️ **不建库行**：会话行仍然在第一条消息 / 首次进情景时才建，
    /// 否则「最近会话」会被空会话顶掉，上次的练习就恢复不回来了（老坑）。
    public func beginNewSession() {
        clear()
        sessionID = UUID()
        didPersistSession = false
    }

    /// 让老师说第一句（情景任务的引导 / 随口练的引子）。
    ///
    /// ⚠️ 与 `greetIfNeeded()` 的分工：那个是「应用刚打开、还没有任何任务」时的一般招呼，
    /// 这个带着**具体任务**开场（前情提要 + 现在该做什么）。两者都只由上层在合适时机触发一次。
    public func deliverOpener() {
        guard !isGenerating else { return }
        guard briefing != nil || isFreeTalkSession || examContext != nil else { return }
        didGreetThisLaunch = true
        isGreeting = true
        isGenerating = true
        errorMessage = nil
        engine.send(.generationStarted)
        generationTask = Task { [weak self] in
            await self?.generateOpener()
        }
    }

    private func generateOpener() async {
        var turnResult: (message: ChatMessage, corrections: [GrammarCorrection])?
        defer {
            isGreeting = false
            if !Task.isCancelled { isGenerating = false }
            onTeacherTurnEnd?(turnResult?.message, turnResult?.corrections ?? [])
        }
        let taskBriefing = briefing
        let review = freeTalkReview
        let exam = examContext
        let fallback = Self.fallbackOpenerText(
            briefing: taskBriefing, freeTalkReview: review, exam: exam
        )

        guard let context = await resolveTeacherContext() else {
            engine.send(.generationFailed)
            // 模型没起来也要有话说：引导句是本地拼的，不依赖模型。
            // 考试模式下这句兜底**就是考题本身**（第 1 问），不是一句客套 ——
            // 否则学员会盯着一句「我们开始吧」等一个永远不来的问题。
            if let local = appendLocalTeacherMessage(fallback) { turnResult = (local, []) }
            return
        }
        let memory = await services.learningMemory(query: latestUserMessage())
        // 开场不带教学计划：此刻还没有学员发言可依据（与 `generateGreeting` 同一条理由）。
        let systemPrompt = systemPrompt(for: context.configuration, memory: memory, plan: nil)
        let instruction: String
        if let exam {
            instruction = PromptBuilder.examOpenerPrompt(
                exam,
                learningLanguage: profile.learningLanguage,
                nativeLanguage: profile.nativeLanguage
            )
        } else if let taskBriefing {
            instruction = PromptBuilder.taskOpenerPrompt(briefing: taskBriefing)
        } else {
            instruction = PromptBuilder.freeTalkOpenerPrompt(review: review)
        }
        var request = self.request(
            context: context,
            systemPrompt: systemPrompt,
            history: await transportMessages() + [LLMMessage(role: .user, content: instruction)]
        )
        request.streaming = false

        let tokensBefore = estimatedContextTokens
        guard let response = try? await services.llm.generate(request) else {
            engine.send(.generationFailed)
            if let local = appendLocalTeacherMessage(fallback) { turnResult = (local, []) }
            return
        }
        let text = Self.stripThinking(response.text).trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = Self.extractCorrections(text)
        guard !Task.isCancelled else { return }
        guard !parsed.cleanText.isEmpty else {
            engine.send(.generationFailed)
            if let local = appendLocalTeacherMessage(fallback) { turnResult = (local, []) }
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
        turnResult = (message, parsed.corrections)
    }

    /// 本地兜底引导句：模型没起来 / 回空时用，保证老师一定有话说。
    private static func fallbackOpenerText(
        briefing: ScenarioBriefing?,
        freeTalkReview: SessionReview?,
        exam: ExamTurnContext? = nil
    ) -> String {
        // ⚠️ 考试模式排在最前：考场上最要紧的是**把题念出来**，
        // 一句「我们开始吧」在这里等于整场卡死（学员不知道要答什么）。
        if let exam {
            return "（考官）\(exam.examTitle) · \(exam.stageTitle)\n"
                + "第 \(exam.questionNumber)/\(exam.totalQuestions) 问：\(exam.prompt)\n"
                + "至少 \(exam.minimumWords) 词，限时 \(exam.timeLimitSeconds) 秒。"
        }
        if let briefing {
            return briefing.fallbackOpeningMessage(characterOpening: briefing.characterOpening)
        }
        if let headline = freeTalkReview?.headline, !headline.isEmpty {
            return "我们接着上次的随口练吧。上次复盘提到：\(headline) 想说点什么都可以。"
        }
        return "我们开始吧 —— 想聊点什么？"
    }

    /// 直接落一条本地老师消息（不经过模型）。返回落下的那一条（空文本时为 nil）。
    @discardableResult
    private func appendLocalTeacherMessage(_ text: String) -> ChatMessage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let message = ChatMessage(role: .assistant, content: trimmed)
        messages.append(message)
        persist(message)
        engine.recordTeacher(trimmed, at: message.createdAt)
        return message
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

    /// 老师回复跑出母语（中文）时的兜底：**多要一次**「只用英文重说」。
    ///
    /// 为什么值得多花这一次请求：语言口径是用户明确提的硬要求（学员可以中文问，
    /// 老师只能用英文答），而提示词不是硬保证 —— 实测模型会整句用中文回话
    /// （「那真是太好了！(That's great!) 不过…」）。判据是确定性的，命中才花钱。
    ///
    /// - 只看**剥离 `[[FIX]]` 之后**的正文：纠错行的说明本来就该是母语。
    /// - **一次为限**：重写拿不到、或在纠错块之外仍然带母语，就保留原文 ——
    ///   绝不能因为「语言不合规」把这一轮回复弄丢。
    /// - 返回 nil = 不需要重写。
    private func englishOnlyRewriteIfNeeded(_ text: String, request: LLMRequest) async -> String? {
        let clean = Self.extractCorrections(text).cleanText
        guard TeacherLanguageGuard.containsNativeScript(clean) else { return nil }
        // ⚠️ 这条请求**不带对话历史**，原文由提示词自带。
        // 带上历史时，弱模型（实测 agnes-3.0-flash）会去抄历史里那句英文 ——
        // 老师就会答非所问地复读开场白；只给它一段要重说的原文，它没有可抄错的东西。
        let rewrite = LLMRequest(
            messages: [
                LLMMessage(
                    role: .user,
                    content: PromptBuilder.englishOnlyRewritePrompt(
                        learningLanguage: profile.learningLanguage,
                        text: Self.extractCorrections(text).cleanText
                    )
                )
            ],
            model: request.model,
            temperature: request.temperature,
            topP: request.topP,
            maxTokens: request.maxTokens
        )
        guard let response = try? await services.llm.generate(rewrite) else { return nil }
        let candidate = Self.stripThinking(response.text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }
        let candidateClean = Self.extractCorrections(candidate).cleanText
        guard !candidateClean.isEmpty,
              !TeacherLanguageGuard.containsNativeScript(candidateClean)
        else { return nil }
        // ⚠️ 还要挡住「答非所问的复读」：实测弱模型会把历史里的开场白原样抄回来当重写结果。
        // 那种结果一旦上屏，用户看到的就是「学员问了话，老师不回答，却又打了个招呼」。
        let earlierReplies = messages.filter { $0.role == .assistant }.map(\.content)
        guard TeacherLanguageGuard.isCredibleRewrite(candidateClean, earlierReplies: earlierReplies)
        else { return nil }
        return candidate
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
    ///
    /// 标记的识别与容错全在 `GrammarCorrectionLine`（朗读那边也用它）：
    /// 这里只管「剥出来 → 解析 → 不进正文」。
    nonisolated static func extractCorrections(_ text: String) -> (cleanText: String, corrections: [GrammarCorrection]) {
        var corrections: [GrammarCorrection] = []
        var keptLines: [String] = []
        for line in text.components(separatedBy: "\n") {
            // ⚠️ 认不出标记的行**原样保留**：它可能只是一句普通的正文。
            // 但**认得出标记**、却切不出三段的，整行丢掉 —— 那是半个纠错块，
            // 留在正文里会以「[[FIX]] xxx」的样子给用户看见。
            guard let body = GrammarCorrectionLine.body(of: line) else {
                keptLines.append(line)
                continue
            }
            guard let fields = GrammarCorrectionLine.parts(of: body) else { continue }
            corrections.append(
                GrammarCorrection(
                    original: fields[0],
                    corrected: fields[1],
                    explanation: fields.count >= 3 ? fields[2] : ""
                )
            )
        }
        let clean = keptLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (clean, corrections)
    }

    /// 把纠错列表还原成 `[[FIX]]` 行（英文重说丢块时按这个补回去，见 `generate`）。
    nonisolated static func correctionLines(_ corrections: [GrammarCorrection]) -> String {
        corrections.map { correction -> String in
            let fields = [correction.original, correction.corrected, correction.explanation]
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return "[[FIX]] " + fields.joined(separator: " => ")
        }
        .joined(separator: "\n")
    }

    private func persistCorrections(_ corrections: [GrammarCorrection]) {        let sessionID = sessionID
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
