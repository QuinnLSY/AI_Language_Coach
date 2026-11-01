import AIDomain
import AIInfrastructure
import AIInterfaces
import AppCore
import Foundation

/// 应用服务装配中心：根据配置创建并持有 Provider，UI / Agent 只依赖本类型。
public actor CoachServices {

    // MARK: - 存储属性
    //
    // ⚠️ 存储属性只能留在类体（extension 不能加存储属性），而它们被
    // `CoachServices+*.swift` 各扩展按域共用 —— private 只在本文件可见，
    // 每个扩展都会取不到 → 一律 internal（模块内可见，跨模块零影响）。

    public let llm: LLMManager
    /// 语音识别（ASR）统一入口。
    public let asr: ASRManager
    /// 语音合成（TTS）统一入口。
    public let tts: TTSManager
    /// 语音能力（录音/识别/朗读）——UI 只认它。
    public let voice: VoiceService
    /// 练习复盘（学习记忆：一次练习 → 一份结构化总结）。
    internal let reviewer: SessionReviewService
    /// 语音输入专用的拼写纠正（只作用于语音识别结果，手打不改）。
    internal let spellingCorrector: SpellingCorrectionService
    /// 气泡翻译（按需 + 有界缓存）。
    internal let translator: TranslationService
    /// 跟读（Shadowing，第 22 步）：示范 / 录音 / 回放 / 评测 / 落库。
    public let shadowing: ShadowingService
    /// 入学定级（进阶 ⑤）：题库读入 + 出卷。判分与定级是纯函数，不在这里。
    public let placement: PlacementService
    /// 今日跟读句子的落盘缓存（每天一份，按日期 + 学习语言作废）。
    internal let shadowingDailyStore: ShadowingDailyStore
    /// 发音评测（Pronunciation，第 23 步）：从录音量语速 / 停顿 / 音高 / 音量起伏。
    public let pronunciation: PronunciationService
    /// 词汇本（Vocabulary，第 24 步）：生词导入 / 复习 / 按需释义。
    public let vocabulary: VocabularyService
    /// 词典（新功能）：词典库（内置三本 + 导入）、模糊匹配、按词查完整条目。
    public let dictionary: DictionaryService
    /// 学习进度（Dashboard，第 25 步）：会话 / 纠错 / 跟读 / 词汇按天汇总。
    public let progress: ProgressService
    /// 写作批改（#230）：题目走内置题库，批改一次请求出全部分数 / 批改 / 改写。
    public let writing: WritingService
    /// 每日短文阅读（#231）：一次请求出文章 + 题目 + 答案 + 解析；判分在本地零请求。
    public let reading: ReadingService
    /// 语义索引（Embedding，第 15 步）：把历史学习记忆按「与当前话题的相关度」取回来。
    /// 默认配置下装配的是 mock（不具语义），此时 `supportsSemanticRanking == false`，
    /// 记忆退回结构化路径 —— 不引入任何额外开销。
    public let embedding: EmbeddingManager

    /// 学习事件总线：服务层在**既有落库点**顺手发出「刚刚发生了什么」，
    /// 森林舞台（AppUI `ForestStage`）订阅它做视觉回应。唯一的实例在这里，
    /// UI 与测试都从 `services.events` 订阅——不要另开第二条总线。
    public nonisolated let events = LearningEventBus()
    /// 落库失败记账（唯一实例，注入给所有会写库的子服务 —— 见 `PersistenceFailureRecorder`）。
    ///
    /// 与 `events` 同一套路：子服务不再自己 `try?` 吞掉失败，而是往这同一份账上记一笔，
    /// 「学习记录有 N 次没保存成功」那条横幅才可能真的亮起来。
    public nonisolated let persistenceFailures = PersistenceFailureRecorder()

    /// 学习数据库。打开失败时为 nil（功能降级为不持久化，不影响对话）。
    public private(set) var learning: LearningDatabase?
    /// 学习库被**隔离重建**时给用户看的说明（nil = 一切正常）。
    ///
    /// 沉默重建是发布级事故：用户会以为旧记录还在。这里必须如实说出来。
    /// 本轮启动应用备份恢复的说明（nil = 没有待恢复内容）。
    public private(set) var pendingRestoreNote: String?
    /// 本轮启动学习库的恢复说明（坏库隔离重建时给出）。
    public private(set) var databaseRecoveryNote: String?
    /// 本轮启动撞上「另一个实例正持有学习数据」时的说明（nil = 没撞）。
    ///
    /// 与 `databaseRecoveryNote` **互斥**：撞锁时根本不打开库，所以不会有隔离说明。
    /// 这两句混在一起说会出人命 —— 「库坏了已重建」和「有人正在用，这轮先别动」
    /// 是两种完全不同的处置，用户在其中一个情形下会去翻 backup，另一个情形下只要退出就好。
    public private(set) var databaseLockedNote: String?
    /// 跨进程写锁（nil = 本轮没取锁：内存库 / 测试进程 / 锁文件建不出来）。
    ///
    /// 必须活在 `CoachServices` 上：锁的生命周期要覆盖整个连接期，
    /// 提前释放等于给别人开门，而连接还开着。
    internal let dataLock: DataDirectoryLock?
    /// 学习记录**存不住**的次数（库不可用 / 写入抛错各算一次）。
    ///
    /// ⚠️ 这个数必须被 UI 看见：此前所有落库点都是 `try?`，写不进去时用户这边
    /// 一点动静都没有 —— 练一整天，退出重进历史是空的，还以为是自己记错了。
    /// 静默丢数据比崩溃更糟：崩溃有声音，这个没有。
    public var persistenceFailureCount: Int { get async { await persistenceFailures.count } }
    /// 最近一次落库失败的一句话原因（nil = 还没失败过）。UI 取它做横幅文案。
    public var lastPersistenceFailure: String? { get async { await persistenceFailures.lastDescription } }
    /// 数据备份开关第 30 步）：导出 / 清单都在项目空间 `.workbuddy/backups/`。
    internal let backup: DataBackup
    /// 克隆音色档案（第 24 步）：独立持久化，与 config.json 分开存放（见 `VoiceProfileStore`）。
    internal let voiceProfileStore: VoiceProfileStore
    /// 聊天附件仓库（图片 / 视频 / 文件）：文件本体与 config.json 分开存放。
    internal let attachmentStore: AttachmentStore
    /// 上传材料的落盘仓库（材料 → 情景 + 跟读句 + 生词表，#208）。
    internal let materialStore: MaterialStore
    /// 用户自建情景的落盘仓库（一句话生成，⑦）。
    internal let customScenarioStore: CustomScenarioStore
    /// AI 排的课的落盘仓库（③，一条课一个 JSON）。
    internal let courseStore: CourseStore
    internal let config: ConfigStore
    internal var llmProvider: (any LLMProvider)?
    /// 场景目录缓存（资源文件，进程内读一次即可）。
    internal var scenarioCache: [Scenario]?
    /// 用户自建情景（进程内缓存，由 `reloadCustomScenarios()` 刷）。
    ///
    /// ⚠️ 与 `scenarioCache` 分开存：内置那份读一次就永不变化，
    /// 这一份会随「生成 / 删除」变 —— 合在一起就得每次生成都重读一遍资源包。
    internal var customScenarioCache: [Scenario] = []
    /// 已排好的 AI 课程（进程内缓存，由 `reloadCourses()` 刷）。UI 拿它渲染「AI 排的课」。
    internal var courseCache: [CourseBlueprint] = []
    /// 课内情景（`courseCache` 摊平后的那一份）。
    ///
    /// ⚠️ 与 `courseCache` **必须一起刷**：只刷课不刷它，情景面板会少那几节
    /// （点进去练习也找不到）；只刷它不刷课，卡片上又会少一条课。见 `reloadCourses()`。
    internal var courseScenarioCache: [Scenario] = []
    /// 考卷目录缓存（同上）。
    internal var examCache: [ExamBlueprint]?
    /// 进行中的 LLM 装配任务：并发调用只装配一次（见 `ensureLLMReady`）。
    internal var llmReadyTask: Task<Void, Error>?
    /// 被用户显式「关闭」的模型能力。**仅进程内有效**：应用打开时全部为启动态。
    internal var stoppedKinds: Set<AIProviderKind> = []
    /// 被资源管理**自动挂起**的能力（第 27 步）：与用户关闭语义不同——
    /// 挂起是省内存的临时状态，下次被使用时自动恢复（`resumeIfSuspended`）；
    /// 用户关闭是明确意图，绝不自动拉起。两者都让 `isModelRunning` 变 false。
    internal var suspendedKinds: Set<AIProviderKind> = []
    /// 语义索引是否已尝试装配过（每进程只试一次，避免 runtime 没起时每轮重试）。
    internal var embeddingBootstrapAttempted = false

    public init(
        config: ConfigStore = .shared,
        llm: LLMManager = LLMManager(),
        databasePath: String? = nil,
        backupDirectory: URL? = nil,
        voiceProfileStore: VoiceProfileStore = .shared,
        attachmentStore: AttachmentStore = .shared,
        dictionaryStore: DictionaryBookStore = .shared,
        shadowingDailyStore: ShadowingDailyStore = .shared,
        materialStore: MaterialStore = MaterialStore(),
        customScenarioStore: CustomScenarioStore = CustomScenarioStore(),
        courseStore: CourseStore = CourseStore()
    ) {
        self.config = config
        self.llm = llm
        self.voiceProfileStore = voiceProfileStore
        self.attachmentStore = attachmentStore
        self.asr = ASRManager()
        self.tts = TTSManager()
        self.embedding = EmbeddingManager()
        self.voice = VoiceService(asr: self.asr, tts: self.tts)
        let path = databasePath ?? LearningDatabase.defaultURL().path
        let restoreDataDirectory = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent, isDirectory: true)
        // 跨进程写锁必须早于本目录的**任何一步写盘**：`applyPendingRestoreIfNeeded` 会改文件，
        // `openLearningDatabase` 会跑迁移。第二个实例做这两步时遇到的"打不开"其实是
        // 别人正当地占着 —— 分不清就会把用户正在用的库当坏库隔离掉。
        let lock = Self.acquireDataLock(directory: restoreDataDirectory, path: path)
        self.dataLock = lock.lock
        self.databaseLockedNote = lock.note
        // 备份恢复（#209）：待恢复内容必须在**打开学习库之前**应用——
        // 活连接底下换库文件轻则损坏、重则连当前库一起搭进去。
        // 撞锁时连这一步也不做：恢复要覆盖库文件，而另一个实例正连着它。
        self.pendingRestoreNote = lock.blocked
            ? nil
            : DataBackup.applyPendingRestoreIfNeeded(dataDirectory: restoreDataDirectory)
        if let note = self.pendingRestoreNote {
            AppLog.info("备份恢复：\(note)", category: "database")
        }
        // 坏库不等于「不能用」：先把可疑文件隔离保住证据，再重建空库继续服务，
        // 并通过 `databaseRecoveryNote` 把这件事如实告诉用户（沉默降级比崩溃更糟）。
        //
        // ⚠️ 撞锁时**压根不打开库**：打开后紧接着的迁移写入会撞 SQLITE_BUSY，
        // 而那条路径把失败读成「库坏了」→ 隔离重建 → 用户正在用的库被改名挪走。
        // 宁可这一轮完全不读写，也不能让第二个实例动别人的库。
        let opened: (database: LearningDatabase?, note: String?) = lock.blocked
            ? (database: nil, note: nil)
            : Self.openLearningDatabase(at: path)
        let database = opened.database
        self.learning = database
        self.databaseRecoveryNote = opened.note
        self.reviewer = SessionReviewService(llm: self.llm, learning: database, events: self.events,
                                             failures: self.persistenceFailures)
        self.spellingCorrector = SpellingCorrectionService(llm: self.llm)
        self.translator = TranslationService(llm: self.llm)
        // 发音评测（第 23 步）：首版纯声学 + 文本对齐，不依赖任何发音模型；
        // 将来接入音素模型时，把 provider 从工厂装进 PronunciationService 即可。
        self.pronunciation = PronunciationService()
        self.shadowing = ShadowingService(voice: self.voice, pronunciation: self.pronunciation,
                                           learning: database, failures: self.persistenceFailures)
        self.shadowingDailyStore = shadowingDailyStore
        // 入学定级（进阶 ⑤）：题库随包发布，出卷 / 判分全在本地（零请求）。
        self.placement = PlacementService()
        self.materialStore = materialStore
        self.customScenarioStore = customScenarioStore
        self.courseStore = courseStore
        self.vocabulary = VocabularyService(llm: self.llm, learning: database, events: self.events,
                                             failures: self.persistenceFailures)
        self.dictionary = DictionaryService(llm: self.llm, store: dictionaryStore)
        self.progress = ProgressService(learning: database)
        self.writing = WritingService(llm: self.llm)
        self.reading = ReadingService(llm: self.llm)
        // ⚠️ 备份目录必须**跟随库所在目录**（2026-10-02 修）：不能写死 `DataBackup()`
        // 的默认位置 —— 否则测试用临时库时，「清除前留底」会落进用户真实备份目录。
        // 生产路径下两者等价（库就在 `.workbuddy/app-config/`，备份到 `.workbuddy/backups/`）；
        // 显式传入 `backupDirectory` 时以传入值为准（测试隔离用）。
        self.backup = DataBackup(
            dataDirectory: restoreDataDirectory,
            backupDirectory: backupDirectory,
            // 备份前把 WAL 落回主库，否则可能拷出「旧库 + 新 WAL」的错配组合。
            // 失败不阻断备份，但必须留痕 —— 静默跳过的 checkpoint 等于没做。
            checkpoint: { [database] in
                guard let database else { return }
                do {
                    try await database.checkpoint()
                } catch {
                    AppLog.warning(
                        "备份前 checkpoint 失败（备份包可能含未落盘的 WAL）：\(error.localizedDescription)",
                        category: "database"
                    )
                }
            }
        )
        if self.learning == nil {
            AppLog.warning("学习数据库不可用（已尝试隔离重建）: \(path)", category: "database")
        }
    }

    /// 取跨进程写锁。返回锁本体、给用户看的说明、以及是否要**跳过开库**。
    ///
    /// 只在「用户真实数据目录 + 非测试进程」时取锁，另两种情形直接放行：
    /// - 内存库 / 临时库：没有共享面，锁了纯属误伤；
    /// - 测试进程：RenderTests 是 10 workers 并行，每个用例都构造 `CoachServices`，
    ///   取锁会让它们互相阻塞 —— 而它们指向的根本不是同一个文件。
    private static func acquireDataLock(
        directory: URL,
        path: String
    ) -> (lock: DataDirectoryLock?, note: String?, blocked: Bool) {
        guard path != ":memory:" else { return (nil, nil, false) }
        guard !ProcessIdentity.isRunningTests else { return (nil, nil, false) }
        guard directory.standardizedFileURL == AppPaths.userDataDirectory().standardizedFileURL else {
            return (nil, nil, false)
        }
        switch DataDirectoryLock.acquire(directory: directory) {
        case .acquired(let lock):
            AppLog.info("已取得学习数据写锁：\(directory.path)", category: "database")
            return (lock, nil, false)
        case .busy:
            AppLog.warning("学习数据已被另一个实例占用，本轮不打开学习库：\(directory.path)", category: "database")
            return (nil, Self.lockedNote(), true)
        case .unavailable(let reason):
            // 锁建不出来 ≠ 有人占用。别因此拒绝启动：按无锁继续，撞了还有 busy_timeout 兜。
            AppLog.warning("数据目录写锁不可用（\(reason)），本次按无锁运行", category: "database")
            return (nil, nil, false)
        }
    }

    private static func lockedNote() -> String {
        """
        另一个语林窗口正在使用学习数据，这一轮不会读取也不会保存你的进度。

        请先退出另一个窗口，再重新打开本应用。
        """
    }

    /// 打开学习库；坏库先隔离再重建，并返回要给用户看的说明。
    private static func openLearningDatabase(at path: String) -> (database: LearningDatabase?, note: String?) {
        do {
            let result = try DataResilience.openLearningDatabase(path: path)
            let note = result.recovered
                ? Self.recoveryNote(path: path, quarantined: result.quarantined)
                : nil
            return (result.database, note)
        } catch {
            AppLog.error("学习数据库隔离重建失败: \(path) — \(error.localizedDescription)", category: "database")
            return (nil, Self.unavailableNote(path: path))
        }
    }

    private static func recoveryNote(path: String, quarantined: Bool) -> String {
        let directory = DataResilience.quarantineDirectory(
            base: URL(fileURLWithPath: path).deletingLastPathComponent()
        ).lastPathComponent
        // ⚠️ 隔离失败时**不能**再说「文件保留在 corrupt 目录里、没有被删除」：
        // 挪不动的文件留在原处，紧接着重建的空库就把主库覆盖了 —— 那句话是假的，
        // 用户会以为还有得捞，实际已经没了。
        let preservation = quarantined
            ? "损坏的文件保留在 corrupt 目录里（\(directory)/），没有被删除；这段时间之外的历史记录需要从那里找回。"
            : "损坏的文件没能完整隔离（可能已被新建的空库覆盖），这段时间之外的历史记录很可能找不回来了。"
        return """
        学习数据库损坏，已自动隔离并重建。

        \(preservation)新的学习记录会正常保存。
        """
    }

    private static func unavailableNote(path: String) -> String {
        "学习数据库无法打开，本轮的进度与复盘不会保存：\(URL(fileURLWithPath: path).lastPathComponent)"
    }

    public var configuration: AppConfiguration {
        get async { await config.current }
    }
    public var configStore: ConfigStore { config }

    // MARK: - 共享内部助手（被各扩展文件调用，故为 internal）

    /// 提示词里该写的「学习语言」。
    ///
    /// 配置里存的是 BCP-47 标识（`en-US`），而提示词里写的是**语言全名**（`English`）——
    /// 直接灌配置值进去，模型收到的就是 `practise en-US`（能猜到，但不该让它猜）。
    /// 每个喂提示词的调用点都从这里取值：这样「配置的写法」和「提示词的写法」的换算
    /// 只有这一处知道答案，将来加语言不会漏掉某个调用点。
    internal func promptLanguage(_ configuration: AppConfiguration) -> String {
        LearningLanguage(bcp47: configuration.product.learningLanguage).serviceName
    }

    /// 记一次落库失败：计数 + 日志 + 留一句给用户看的原因。
    ///
    /// 动作名由**调用点**给（只有它知道自己在干什么），这里只拼装与留痕；
    /// 错误文案取 `LocalizedError.errorDescription`（`AppError` 六档都实现了），
    /// 系统错误退到 `localizedDescription` —— 一律不加品类前缀（前缀让消息看着像片段，
    /// 还会和动作名叠成三冒号，见 `AppErrorTextTests`）。
    internal func recordPersistenceFailure(_ action: String, _ error: Error?) async {
        await persistenceFailures.record(action, error)
    }

}
