import Foundation

// MARK: - 开屏话题卡（今天聊什么）
//
// 为什么要有这一层：首屏空态原本只有「和老师打个招呼」一句问候，加输入框里
// 轮换的预设提问（`starterQuestions`）。轮换的那串是**输入框占位提示** ——
// 想用得自己照着打一遍，而且每次看都不一样（同一天反复开屏看到的也不同）。
// 它装饰了空框，却没有回答用户真正卡住的那一问：**今天第一句说什么**。
//
// 本文件产出「能点一下就开口」的几张卡，三条规矩：
//
// 1. **每张卡都得有依据**。没有练过的情景就不给「接着练」；今天没词就不给「用词开口」。
//    宁可只给一张，也不凑三张空壳 —— 卡片比数据好看，但落成装饰就骗人。
// 2. **同一天同一张**。句子由 `DailySeed` 从池里确定性抽出：用户看中了没点、
//    隔一会儿回来还是同一句，不会出现「那句挺好的怎么没了」。
// 3. **发出去的那句由调用方给模板**。词条 prompt 是**学习语言**的句子，
//    而本层不认识「当前在学哪门语言」，模板由 AppState 按 `LearningLanguage` 注入，
//    本文件只做替换。
//
// 纯函数、零 IO、不 import UI。

/// 上次练过的情景（用来决定要不要给「接着练」）。
public struct PriorPractice: Sendable, Equatable {

    public var scenarioID: String
    /// 情景名（卡片上原样展示，不许缩写）。
    public var scenarioTitle: String
    /// 主线已完成的步数。
    public var doneSteps: Int
    /// 主线总步数。
    public var totalSteps: Int
    /// 距上次练它多久（小时）。
    public var hoursAgo: Int
    /// 主线已全部完成 —— 再催「接着练」就是催他重做一遍。
    public var isComplete: Bool

    public init(
        scenarioID: String,
        scenarioTitle: String,
        doneSteps: Int = 0,
        totalSteps: Int = 0,
        hoursAgo: Int = 0,
        isComplete: Bool = false
    ) {
        self.scenarioID = scenarioID
        self.scenarioTitle = scenarioTitle
        self.doneSteps = doneSteps
        self.totalSteps = totalSteps
        self.hoursAgo = hoursAgo
        self.isComplete = isComplete
    }
}

/// 一张话题卡。
public struct KickoffSuggestion: Sendable, Equatable, Identifiable {

    public enum Kind: String, Sendable, Equatable {
        /// 回到上次没练完的情景。
        case resume
        /// 用今天的一个词开口。
        case todayWord
        /// 随便聊两句（句库里的句子）。
        case smallTalk
    }

    public enum Action: Sendable, Equatable {
        /// 直接把这句发给老师（**句子本身是学习语言**）。
        case send(text: String)
        /// 打开上次那个情景接着练。
        case openScenario(id: String)
    }

    public var kind: Kind
    /// 卡上的主标（界面语言的短句）。
    public var title: String
    /// 卡上的副标（**必须是可核对的数据**：情景名 / 词 / 步数），空串表示不显示。
    public var detail: String
    public var action: Action

    public init(kind: Kind, title: String, detail: String, action: Action) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.action = action
    }

    /// 同一屏里每种卡最多一张 —— 用种类当 id，SwiftUI 的 diff 才不会错位。
    public var id: String { kind.rawValue }
}

public enum TopicKickoff {

    /// 排一次话题卡的入参。
    ///
    /// ⚠️ `wordPromptTemplate` **不给默认值**：它是「请用 xx 造个句」这句怎么说，
    /// 随学习语言变。给了默认值就会有人不传，于是学日语的用户收到一句英文。
    public struct Context: Sendable {

        /// 上次练过的情景（没练过就 nil）。
        public var priorPractice: PriorPractice?
        /// 今天推荐 / 今天练过的词（**已按调用方的优先级排好**，去重由调用方做）。
        public var todayWords: [String]
        /// 「随便聊聊」的句子池（学习语言），来自资源文件。
        public var smallTalkPool: [String]
        /// 日期键（同一天抽到同一句）。
        public var dayKey: String
        /// 学习语言标识（参与种子：换语言就换一批句子）。
        public var language: String
        /// 带 `%@` 的句型模板（学习语言），本文件把词替换进去。
        public var wordPromptTemplate: String

        public init(
            priorPractice: PriorPractice? = nil,
            todayWords: [String] = [],
            smallTalkPool: [String] = [],
            dayKey: String = "",
            language: String = "",
            wordPromptTemplate: String
        ) {
            self.priorPractice = priorPractice
            self.todayWords = todayWords
            self.smallTalkPool = smallTalkPool
            self.dayKey = dayKey
            self.language = language
            self.wordPromptTemplate = wordPromptTemplate
        }
    }

    /// 最多给几张卡（屏幕就那么宽，多出来的是噪音不是推荐）。
    public static let maximumSuggestions = 3

    /// 排话题卡：按「断点续练 → 今天的词 → 随便聊聊」的顺序，**没依据的种类不出卡**。
    ///
    /// ⚠️ 零张卡是合法的返回值：用户第一次打开、什么都没有时，
    /// UI 应该只画那句问候，而不是硬凑三张点下去没反应的卡。
    public static func plan(_ context: Context) -> [KickoffSuggestion] {
        var cards: [KickoffSuggestion] = []

        if let resume = resumeCard(context.priorPractice) {
            cards.append(resume)
        }
        if let word = wordCard(context) {
            cards.append(word)
        }
        if let talk = smallTalkCard(context) {
            cards.append(talk)
        }

        return Array(cards.prefix(maximumSuggestions))
    }

    // MARK: - 三种卡的各自判据

    /// 「接着练」：必须真的练过、且没练完、且知道练到哪一步。
    ///
    /// `doneSteps == 0` 不算练过 —— 点开一次就退出的情景，
    /// 催「接着练」等于把人送回他刚走出去的地方；那时候该给的是别的入口。
    public static func resumeCard(_ prior: PriorPractice?) -> KickoffSuggestion? {
        guard let prior,
              !prior.isComplete,
              prior.doneSteps > 0,
              !prior.scenarioID.isEmpty,
              !prior.scenarioTitle.isEmpty
        else { return nil }

        var parts: [String] = []
        parts.append("上次练到 \(prior.doneSteps)/\(prior.totalSteps) 步")
        parts.append(elapsedText(hoursAgo: prior.hoursAgo))

        return KickoffSuggestion(
            kind: .resume,
            title: "接着练《\(prior.scenarioTitle)》",
            detail: parts.joined(separator: " · "),
            action: .openScenario(id: prior.scenarioID)
        )
    }

    /// 「用今天这个词开口」：词取自今日推荐，同一天固定同一个词。
    public static func wordCard(_ context: Context) -> KickoffSuggestion? {
        let candidates = context.todayWords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return nil }

        var rng = SeededRandomGenerator(seed: DailySeed.seed(
            dayKey: context.dayKey,
            language: context.language,
            purpose: Self.purpose(for: "word")
        ))
        guard let word = candidates.shuffled(using: &rng).first ?? candidates.first else { return nil }

        return KickoffSuggestion(
            kind: .todayWord,
            title: "用今天这个词开口",
            detail: word,
            action: .send(text: Self.filled(context.wordPromptTemplate, with: word))
        )
    }

    /// 「随便聊两句」：从句子池里抽一句，同一天同一句。
    public static func smallTalkCard(_ context: Context) -> KickoffSuggestion? {
        let pool = context.smallTalkPool
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !pool.isEmpty else { return nil }

        var rng = SeededRandomGenerator(seed: DailySeed.seed(
            dayKey: context.dayKey,
            language: context.language,
            purpose: Self.purpose(for: "smalltalk")
        ))
        guard let line = pool.shuffled(using: &rng).first ?? pool.first else { return nil }

        return KickoffSuggestion(
            kind: .smallTalk,
            title: "不知道说什么？来这句",
            detail: line,
            action: .send(text: line)
        )
    }

    // MARK: - 内部

    /// 把 `%@` 换成词。
    ///
    /// ⚠️ **模板里没写 `%@` 时返回原句，模板为空时才用兜底句** ——
    /// 决不许返空串：空串会在 `sendChat` 的 `guard !trimmed.isEmpty` 那里静默失败，
    /// 表面症状是「点了卡片，屏幕上什么都没有」，而日志一行都不会有。
    private static func filled(_ template: String, with word: String) -> String {
        guard !template.isEmpty else { return fallbackPrompt(word) }
        guard template.contains("%@") else { return template }
        return String(format: template, word)
    }

    /// 兜底句型（模板为空时用）：至少保证发出去的是一句能接得住的话。
    private static func fallbackPrompt(_ word: String) -> String {
        "Can you help me use the word \"\(word)\" in a sentence?"
    }

    /// 两个筛选各走各的种子：否则「今天的第 N 个词」和「句库第 N 句」
    /// 会永远同步轮转，看起来像同一张卡在做两件事。
    private static func purpose(for slot: String) -> String {
        "topic-kickoff-\(slot)"
    }

    /// 多久以前：**不美化**。超过一天就说「天前」，让用户自己判断还接不接得上。
    public static func elapsedText(hoursAgo: Int) -> String {
        guard hoursAgo > 0 else { return "刚刚练过" }
        if hoursAgo < 24 { return "\(hoursAgo) 小时前" }
        let days = hoursAgo / 24
        return days == 1 ? "昨天" : "\(days) 天前"
    }
}
