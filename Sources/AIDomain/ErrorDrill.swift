import Foundation

// MARK: - 改错练习（把「记住的错」变成「练过的错」）

/// 一轮改错练习：把反复犯的错排成队列 → 逐张改 → 判定 → 结算。
///
/// **为什么要有它**：学习记忆此前一直是**单向**的 —— `RecurringError` 算出来之后只做了两件事
/// （摊在记忆卡上给学员看、折进 Prompt 让老师知道），唯独没有「让你真的把它改过来」。
/// 知道错了和改过来之间，差的就是这一步。
///
/// 与 `VocabularyReviewSession` 同款：纯值类型、不 import UI / IO，
/// 队列与结算全在这里，状态由上层持有。
///
/// ⚠️ **判定不发起任何模型请求**：`RecurringError` 自带 `corrected`，
/// 学员的答案只需与它归一比对 —— 既省一次请求，也让「判得对不对」能完整单测。
/// 拿模型去判一道自己早知道答案的题，是花成本买不确定。
public struct ErrorDrillSession: Sendable, Equatable {

    /// 一轮最多练几处（错再多也是这一批，一次全推过去只会让人放弃）。
    public static let maxCards = 5

    /// 连对几次算「攻克」（攻克后不再出现在队列里）。
    ///
    /// 取 2 而不是 1：答对一次很可能是刚看完正确答案的短时记忆，
    /// 隔一轮还能答对，才说明真的改过来了。
    public static let masteryStreak = 2

    // MARK: - 判分结果

    public struct Outcome: Sendable, Equatable, Identifiable {
        /// 对应 `RecurringError.id`（`original + 分隔符 + corrected`）。
        public var errorID: String
        /// 学员交上来的答案（原样保留，结算与展示都要用）。
        public var answer: String
        public var isCorrect: Bool

        public init(errorID: String, answer: String, isCorrect: Bool) {
            self.errorID = errorID
            self.answer = answer
            self.isCorrect = isCorrect
        }

        public var id: String { errorID }
    }

    // MARK: - 结算

    public struct Summary: Sendable, Equatable {
        public var total: Int
        public var correct: Int
        /// 这一轮新攻克的处数（连对次数刚好到门槛的那些）。
        public var conquered: Int

        public var wrong: Int { total - correct }
        public var accuracy: Double { total == 0 ? 0 : Double(correct) / Double(total) }
        public var accuracyPercent: Int { Int((accuracy * 100).rounded()) }

        public var headline: String {
            guard total > 0 else { return "这一轮没有可练的错" }
            if wrong == 0 { return "\(total) 处全改对了" }
            return "这一轮练了 \(total) 处：改对 \(correct) 处、还差 \(wrong) 处"
        }

        /// 补充说明。**攻克了才提攻克**，没攻克时不说那句空话。
        public var detail: String {
            var parts: [String] = []
            if conquered > 0 {
                parts.append("其中 \(conquered) 处连对两次，之后不再出现在练习里")
            }
            if wrong > 0 {
                parts.append("没改对的还会留在记忆里，下次接着练")
            }
            return parts.joined(separator: "。")
        }
    }

    // MARK: - 状态

    /// 本轮队列（建好就不再改顺序）。
    public private(set) var queue: [RecurringError]
    /// 当前第几处（0 起）。
    public private(set) var index: Int = 0
    /// 已判分的结果（与队列前若干处一一对应）。
    public private(set) var outcomes: [Outcome] = []
    public let startedAt: Date

    /// 建一轮练习。`errors` 传 `LearningMemory.recurringErrors`（已按次数排好），本类型自己筛、自己截断。
    ///
    /// - Parameter mastered: 已攻克的错（`id` 集合），不再进队列。
    public init(
        errors: [RecurringError],
        mastered: Set<String> = [],
        limit: Int = maxCards,
        now: Date = Date()
    ) {
        self.queue = Self.queue(from: errors, mastered: mastered, limit: limit)
        self.startedAt = now
    }

    // MARK: - 队列

    /// 待练队列：**沿用 `MemoryRetriever` 已经排好的顺序**（次数多 → 最近发生），
    /// 这里只做「剔除已攻克 + 截断」。
    ///
    /// 为什么不在这里重排：排序口径已经在检索层定过一次，再排一遍就是第二把尺子，
    /// 两边迟早分叉成「记忆卡上排第一的、练习里排第三」。
    public static func queue(
        from errors: [RecurringError],
        mastered: Set<String> = [],
        limit: Int = maxCards
    ) -> [RecurringError] {
        guard limit > 0 else { return [] }
        return Array(errors.filter { !mastered.contains($0.id) }.prefix(limit))
    }

    // MARK: - 推进

    /// 当前这一处（走完了为 nil）。
    public var current: RecurringError? {
        guard index < queue.count else { return nil }
        return queue[index]
    }

    /// 上一处（刚判过的那一处；还没判过为 nil）。
    ///
    /// 判分后要停在原地回一句「改对了 / 正确答案是……」再让用户点下一处，
    /// 而 `submit` 已经把 `index` 推进了 —— 这里是拿回刚判那一张的唯一路径。
    public var previous: RecurringError? {
        let previousIndex = index - 1
        guard previousIndex >= 0, previousIndex < queue.count else { return nil }
        return queue[previousIndex]
    }

    /// 已走完没有。
    public var isFinished: Bool { index >= queue.count }

    /// 进度（第几处 / 共几处），供 UI 显示。空队列时为 (0, 0)。
    public var progress: (done: Int, total: Int) { (outcomes.count, queue.count) }

    /// 交答案并推进到下一处。返回这次的判分结果（已走完时返回 nil）。
    ///
    /// 答案**原样存进** `outcomes`：结算要能回看「他当时写的是什么」，
    /// 只存一个 bool 等于把证据扔掉。
    @discardableResult
    public mutating func submit(_ answer: String) -> Outcome? {
        guard let error = current else { return nil }
        let outcome = Outcome(
            errorID: error.id,
            answer: answer,
            isCorrect: ErrorDrillMatcher.isCorrect(answer: answer, expected: error.corrected)
        )
        outcomes.append(outcome)
        index += 1
        return outcome
    }

    /// 本轮结算。
    ///
    /// - Parameter conquered: 判分后**新**达到攻克门槛的处数（由上层按连对次数算，
    ///   因为「连对几次」是跨轮的历史，不归本轮所有）。
    public func summary(conquered: Int = 0) -> Summary {
        Summary(
            total: outcomes.count,
            correct: outcomes.filter(\.isCorrect).count,
            conquered: conquered
        )
    }
}

// MARK: - 判定（纯函数）

/// 改错练习的判定。**不碰模型，只做归一比对**。
public enum ErrorDrillMatcher {

    /// 这处改对了没有。
    ///
    /// 用 `MemoryRetriever.matchKey`（小写 + 压空白 + 去标点）而不是逐字相等：
    /// 判的是「语法改对了没有」，尾随句号、多余空格、大小写差异都不该算错 ——
    /// 而 `matchKey` 正是库里判「是不是同一处错误」用的那一把尺子，
    /// 口径一致才不会出现「同一处在记忆里算一个、在练习里算两个」。
    ///
    /// ⚠️ 反过来，拿它判断「内容有没有变化」是错的（会吞掉纯标点的纠错），
    /// 那个场景必须保留标点 —— 继续用 `MemoryRetriever.normalize`。
    ///
    /// ⚠️ 空答案一律判错：什么都不写不算「改对了」。
    public static func isCorrect(answer: String, expected: String) -> Bool {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return MemoryRetriever.matchKey(trimmed) == MemoryRetriever.matchKey(expected)
    }
}

// MARK: - 攻克进度（跨轮，纯函数）

/// 「这一处练到什么程度」的账本：**连对次数**。
///
/// 单独抽出来的理由：它是**跨轮**的状态（这轮答对一次、下轮再答对一次才算攻克），
/// 而 `ErrorDrillSession` 只管一轮 —— 混进去会让 session 既不是纯一轮、也不好单测。
///
/// ⚠️ 答错**清零**而不是减一：既然标准是「连对两次」，中间错一次就得从头来，
/// 否则「对、错、对」也能毕业，门槛就形同虚设。
public enum ErrorDrillProgress {

    /// 把一次判分记进账本，返回更新后的连对次数。
    ///
    /// - Parameter streak: 这一处此前连对了几次。
    public static func streak(after isCorrect: Bool, previous streak: Int) -> Int {
        isCorrect ? streak + 1 : 0
    }

    /// 这一处算不算攻克了。
    public static func isMastered(streak: Int, threshold: Int = ErrorDrillSession.masteryStreak) -> Bool {
        streak >= threshold
    }

    /// 结算这一轮的判分，返回（新账本, 本轮新攻克了几处）。
    ///
    /// 一次算完而不是让上层循环调用：账本与「新攻克数」必须**同一次遍历**得出，
    /// 分开算会出现「同一处被计了两次攻克」（这一轮提交两次同一处时）。
    public static func applied(
        _ outcomes: [ErrorDrillSession.Outcome],
        to ledger: [String: Int],
        threshold: Int = ErrorDrillSession.masteryStreak
    ) -> (ledger: [String: Int], conquered: Int) {
        var next = ledger
        var conquered = 0
        for outcome in outcomes {
            let before = next[outcome.errorID] ?? 0
            let after = streak(after: outcome.isCorrect, previous: before)
            next[outcome.errorID] = after
            if isMastered(streak: after, threshold: threshold),
               !isMastered(streak: before, threshold: threshold) {
                conquered += 1
            }
        }
        return (next, conquered)
    }
}
