import Foundation

// MARK: - 碎片热身（⑦-B②）
//
// 留存那条链是「想起 → 打开 → 张口 → 再来」，其中**唯一没有落点的是「张口」**：
// 开了应用、看了一眼、不知道从哪儿开始，于是关掉。这一层把三件真有依据的小事
// 串成一轮一分钟上下的微流程 —— 到期词 → 跟读一句 → 开口一句 ——
// 跑完给一张结算卡（「记得 2/3 · 用时 1 分 12 秒」）。
//
// 三条规矩：
//
// 1. **每一步都得是真的**。到期词来自 `ReviewScheduler`（间隔规则唯一一把尺子，
//    本层不碰也不改），跟读句是今日/随包素材里真实存在的句子，开口提示是预设提问里
//    的真句子。凑不出依据的步骤就不排 —— 一轮只有两步也是合法的一轮，
//    硬凑三步才是骗人。
// 2. **本层只编排，不碰 IO**。录音 / 判分 / 发消息全在调用方；
//    这里只回答「现在第几步、这一步能不能推进、结算怎么说」。
// 3. **数字不许写死**。入口那句「约 1 分 29 秒」按步骤构成算，
//    结算的「记得 2/3」「1 分 12 秒」全部来自真数据。
//
// 纯值类型、零 IO、不 import UI。

/// 热身流程里的一步。
///
/// 用枚举而不是「带 kind 字段的结构体」：三种步各自带的字段根本不同
/// （词带词条 id，跟读带句子，开口带提示）。塞进一个结构体里就会出现
/// 「跟读步上那个 entryID 到底填什么」这种永远对不上号的可选字段 ——
/// 而可选字段一旦填错，症状是判分记到别人头上（静默的）。
public enum WarmUpStep: Sendable, Equatable {

    /// 认一个到期词（带词条 id：判分要落到那一条上）。
    case word(entryID: UUID, word: String)
    /// 跟读一句。
    case shadow(sentence: String)
    /// 开口说一句。提示句是**照着说的那句**，发出去的是**你实际说出来的那句**。
    case speak(prompt: String)

    public enum Kind: String, Sendable, Equatable {
        case word
        case shadow
        case speak
    }

    public var kind: Kind {
        switch self {
        case .word: return .word
        case .shadow: return .shadow
        case .speak: return .speak
        }
    }

    /// 这一步要展示的那句话（词 / 跟读句 / 开口提示）。
    public var text: String {
        switch self {
        case .word(_, let word): return word
        case .shadow(let sentence): return sentence
        case .speak(let prompt): return prompt
        }
    }

    /// 步骤小标题（界面语言）。
    public var title: String {
        switch self {
        case .word: return "这个词还记得吗"
        case .shadow: return "跟读这一句"
        case .speak: return "开口说这一句"
        }
    }

    /// 每一步的预计秒数。
    ///
    /// ⚠️ 按步算而不是整轮写死「90 秒」：一轮只有两个词时还写着 90 秒，
    /// 就是在替用户编一个数。入口那句「约 X」由它累加得出。
    public var estimatedSeconds: Int {
        switch self {
        case .word: return 12
        case .shadow: return 25
        case .speak: return 28
        }
    }

    /// 同一轮里不会重复，够 `ForEach` / 比较用。
    public var id: String { "\(kind.rawValue)#\(text)" }
}

/// 一轮热身的**步骤编排**（建好就不再改）。
public struct WarmUpPlan: Sendable, Equatable {

    /// 一轮最多带几个到期词。
    ///
    /// 取 3 的理由是「碎片」：到期词再多也只走三个，剩下的留给正式复习
    /// （`VocabularyReviewSession` 那一轮上限 20）。热身的目的是**动起来**，
    /// 不是把待复习清干净。
    public static let defaultWordCount = 3

    public let steps: [WarmUpStep]

    public init(steps: [WarmUpStep]) {
        self.steps = steps
    }

    /// 排一轮：到期词 → 跟读 → 开口。**凑不出依据的步骤不排**。
    ///
    /// - Parameters:
    ///   - dueEntries: 真的到期的词（调用方传 `VocabularyReviewSession.queue` 的结果）。
    ///   - shadowSentence: 跟读句（nil / 空白 = 这一步不排）。
    ///   - speakPrompt: 开口提示（nil / 空白 = 这一步不排）。
    ///   - maxWords: 最多几个词。
    public static func plan(
        dueEntries: [VocabularyEntry],
        shadowSentence: String?,
        speakPrompt: String?,
        maxWords: Int = defaultWordCount
    ) -> WarmUpPlan {
        var steps: [WarmUpStep] = []

        let words = dueEntries
            .map { (id: $0.id, word: $0.word.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.word.isEmpty }
        for entry in words.prefix(max(maxWords, 0)) {
            steps.append(.word(entryID: entry.id, word: entry.word))
        }

        if let sentence = Self.meaningful(shadowSentence) {
            steps.append(.shadow(sentence: sentence))
        }
        if let prompt = Self.meaningful(speakPrompt) {
            steps.append(.speak(prompt: prompt))
        }

        return WarmUpPlan(steps: steps)
    }

    /// 一步都排不出来（UI 此时**整块不画**，不留空壳）。
    public var isEmpty: Bool { steps.isEmpty }

    public var total: Int { steps.count }
    public var wordCount: Int { steps.filter { $0.kind == .word }.count }
    public var hasShadow: Bool { steps.contains { $0.kind == .shadow } }
    public var hasSpeak: Bool { steps.contains { $0.kind == .speak } }

    /// 「3 个到期词 · 1 句跟读 · 1 句开口」—— 每个数字都来自真数据。
    public var compositionText: String {
        var parts: [String] = []
        let words = wordCount
        if words > 0 { parts.append("\(words) 个到期词") }
        if hasShadow { parts.append("1 句跟读") }
        if hasSpeak { parts.append("1 句开口") }
        return parts.joined(separator: " · ")
    }

    /// 预计用时（秒）：按步骤构成累加。
    public var estimatedSeconds: Int {
        steps.reduce(0) { $0 + $1.estimatedSeconds }
    }

    /// 入口那句「约 1 分 29 秒」。由构成算出，不拍脑袋写 90 秒。
    public var estimateText: String {
        ProgressAggregator.durationText(TimeInterval(estimatedSeconds))
    }

    // MARK: - 按天抽句子（同一天同一句）

    /// 从跟读素材里按天抽一句。
    ///
    /// 同一天固定同一句：用户看中了没点，隔一会儿回来还是它 ——
    /// 「那句挺好的怎么没了」比换一句更让人不想再点。
    public static func pickSentence(from pool: [String], dayKey: String, language: String) -> String? {
        pick(from: pool, dayKey: dayKey, language: language, slot: "sentence")
    }

    /// 从预设提问里按天抽一句开口提示。
    public static func pickPrompt(from pool: [String], dayKey: String, language: String) -> String? {
        pick(from: pool, dayKey: dayKey, language: language, slot: "prompt")
    }

    // MARK: - 内部

    /// 两个抽取各走各的种子：否则「今天跟读第 N 句」和「开口第 N 句」
    /// 会永远同步轮转，看起来像同一步在做两件事。
    private static func pick(
        from pool: [String],
        dayKey: String,
        language: String,
        slot: String
    ) -> String? {
        let candidates = pool
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return nil }
        var rng = SeededRandomGenerator(seed: DailySeed.seed(
            dayKey: dayKey,
            language: language,
            purpose: "warmup-\(slot)"
        ))
        return candidates.shuffled(using: &rng).first ?? candidates.first
    }

    private static func meaningful(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

/// 一轮热身的**进行状态**：走到第几步、认得几个、读了多少分。
public struct WarmUpProgress: Sendable, Equatable {

    public let plan: WarmUpPlan
    public private(set) var index: Int = 0
    /// 判「记得」的词数。
    public private(set) var remembered: Int = 0
    /// 判「忘了」的词数（**跳过的不算**：没判就是没判）。
    public private(set) var forgotten: Int = 0
    /// 跟读那一步的发音分（没读 / 没量到音频 = nil）。
    public private(set) var shadowScore: Double? = nil
    /// 开口那一步**听到的**原话（不是提示句本身）。
    public private(set) var spokenText: String? = nil
    public let startedAt: Date
    /// 走完那一刻（nil = 还在走）。钉住它是为了结算上的用时不再往后长。
    public private(set) var finishedAt: Date? = nil

    public init(plan: WarmUpPlan, now: Date = Date()) {
        self.plan = plan
        self.startedAt = now
    }

    // MARK: - 读到哪了

    public var currentStep: WarmUpStep? {
        plan.steps.indices.contains(index) ? plan.steps[index] : nil
    }

    /// 走完了（**最后一步做完**才算，不是「点开了」）。
    public var isFinished: Bool { index >= plan.steps.count }

    /// 已完成步数（界面上「第 2 / 5 步」的前半）。
    public var completedCount: Int { min(max(index, 0), plan.steps.count) }

    /// 当前第几步（1-based；走完时钉在总步数上，不显示「第 6 / 5 步」）。
    public var stepNumber: Int { min(index + 1, max(plan.steps.count, 1)) }

    /// 整轮用时（秒）：跑完就钉在结束那一刻，没跑完按传入时刻算。
    public func elapsedSeconds(now: Date) -> Int {
        Int(max((finishedAt ?? now).timeIntervalSince(startedAt), 0).rounded())
    }

    // MARK: - 推进（每步只认自己那一种，别的一步都推不动）

    /// 给当前这个词判分并前进。
    ///
    /// - Returns: 真的推进了没有（当前步不是词 = false）。
    ///   调用方据此决定要不要真的去落库 —— 界面与数据不许各走一半。
    @discardableResult
    public mutating func gradeCurrentWord(remembered: Bool) -> Bool {
        guard case .word = currentStep else { return false }
        if remembered {
            self.remembered += 1
        } else {
            self.forgotten += 1
        }
        index += 1
        return true
    }

    /// 记下跟读这一步的分数并前进（nil = 这次没量到，照实记成「没分」）。
    @discardableResult
    public mutating func markShadow(score: Double?) -> Bool {
        guard case .shadow = currentStep else { return false }
        shadowScore = score
        index += 1
        return true
    }

    /// 记下开口这一步听到的原话并前进（空白一律记成 nil，不许拿空串冒充「说过」）。
    @discardableResult
    public mutating func markSpoken(_ text: String?) -> Bool {
        guard case .speak = currentStep else { return false }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        spokenText = trimmed.isEmpty ? nil : trimmed
        index += 1
        return true
    }

    /// 跳过当前这一步。**不计成绩**：没判就是没判，不能算进「忘了」。
    @discardableResult
    public mutating func skipCurrent() -> Bool {
        guard currentStep != nil else { return false }
        index += 1
        return true
    }

    /// 收尾：钉住结束时刻。用时从此不再往后长。
    public mutating func finish(now: Date = Date()) {
        index = plan.steps.count
        finishedAt = finishedAt ?? now
    }

    // MARK: - 结算

    public func summary(now: Date = Date()) -> WarmUpSummary {
        WarmUpSummary(
            wordTotal: plan.wordCount,
            remembered: remembered,
            shadowScore: shadowScore.map { Int($0.rounded()) },
            spokenText: spokenText,
            elapsedSeconds: elapsedSeconds(now: now),
            completedSteps: completedCount,
            totalSteps: plan.total
        )
    }

    /// 结算摘要：**不现取时钟**。
    ///
    /// 跑完的轮次用时钉在 `finishedAt`（`finish()` 写下的那一刻）；
    /// 没跑完的那一档界面上本来也不显示结算脸 —— 真出现了就按当前时刻算，
    /// 绝不显示 0。给界面用：视图体里现取 `Date()` 是一次隐形的时钟依赖，
    /// `summary(now:)` 的语义哪天变了，结算卡上那行字就会自己往前走。
    public var settlement: WarmUpSummary {
        summary(now: finishedAt ?? Date())
    }
}

/// 一轮热身的结算。
public struct WarmUpSummary: Sendable, Equatable {

    /// 这一轮带了几个词。
    public var wordTotal: Int
    /// 判「记得」的几个。
    public var remembered: Int
    /// 跟读分（没读 / 没量到 = nil，界面就不写这一项）。
    public var shadowScore: Int?
    /// 开口那步听到的原话（nil = 没说 / 没听清）。
    public var spokenText: String?
    public var elapsedSeconds: Int
    public var completedSteps: Int
    public var totalSteps: Int

    public var durationText: String {
        ProgressAggregator.durationText(TimeInterval(elapsedSeconds))
    }

    /// 「记得 2/3」。一轮没带词时返回 nil —— 那时写「记得 0/0」是在编数字。
    public var scoreText: String? {
        guard wordTotal > 0 else { return nil }
        return "记得 \(remembered)/\(wordTotal)"
    }

    /// 「记得 2/3 · 用时 1 分 12 秒」。
    public var headline: String {
        guard let score = scoreText else { return "热身完成 · 用时 \(durationText)" }
        return "\(score) · 用时 \(durationText)"
    }

    /// 第二行：跟读分 / 开口一句如实补上；两样都没有就说走了几步。
    public var detail: String {
        var parts: [String] = []
        if let shadowScore { parts.append("跟读 \(shadowScore) 分") }
        if spokenText != nil { parts.append("开口 1 句") }
        if parts.isEmpty { parts.append("走完 \(completedSteps)/\(totalSteps) 步") }
        return parts.joined(separator: " · ")
    }
}
