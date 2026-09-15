import Foundation

// MARK: - 词汇复习会话（P1-3 复习闭环）
//
// 硬要求（与 `Vocabulary.swift` 同款）：**复习逻辑与 UI 分离**。
// 本文件只描述「一轮复习是什么」—— 到期队列怎么排、判分怎么推进、结算怎么算，
// 全是纯值类型，不 import UI / IO，间隔规则一律委托 `ReviewScheduler`（唯一一把尺子）。
//
// 三条刻意的设计决定：
//
// 1. **队列只取真的到期的词**。不做「凑数」（不足就把没到期的也拉进来）——
//    那会让「待复习 N 个」这个数字和用户点进去看到的张数对不上。
// 2. **一轮有上限**。到期词可能几十个，一次全推过去只会让人放弃；满了就走这一批，
//    剩下多少由结算如实说（`Summary.stillDue`）。
// 3. **朗读检查不自动判分**。音素评测是「把你说的话量出来」，不是「你记不记得这个词的意思」——
//    拿发音分去替用户点「认识 / 忘了」是两件事混成一件。
//    所以朗读只把证据摆出来（音量、音素、系统听成了什么），等级仍由学员自己按。

/// 一轮词汇复习：到期队列 → 逐张卡片判分 → 结算。
public struct VocabularyReviewSession: Sendable, Equatable {

    /// 一轮最多走几个词（到期的词再多也是这一批）。
    public static let maxCards = 20

    // MARK: - 判分结果

    /// 一张卡的判分结果。
    public struct Outcome: Sendable, Equatable, Identifiable {
        public var entryID: UUID
        public var word: String
        /// 学员自己给的等级（认识 = true）。
        public var remembered: Bool
        public var masteryBefore: Int
        public var masteryAfter: Int
        /// 这一轮判分之后**是否仍然到期**。
        ///
        /// 「忘了」会把掌握度 −1，而掌握度 0 的间隔是 0 天 —— 也就是**当天还是到期**。
        /// 这是间隔重复的本意（错的词就该今天再见一面），但必须让用户知道，
        /// 否则他会以为「复习完了待复习数字没变」是 bug。
        public var stillDue: Bool
        /// 这张卡朗读检查的总分（0...100）；没读 / 没量到音频为 nil。
        public var pronunciationScore: Double?
        /// 那次朗读走的是哪条通道。**推断 ≠ 实测**，必须随结果一路透出。
        public var phonemeSource: PhonemeSource?

        public var id: UUID { entryID }
        /// 掌握度变化（−1 / +1）。
        public var masteryDelta: Int { masteryAfter - masteryBefore }
    }

    // MARK: - 结算

    /// 一轮复习的结算。
    public struct Summary: Sendable, Equatable {
        public var total: Int
        public var remembered: Int
        public var forgotten: Int
        /// 本轮结束后仍然到期的词数（需要再来一遍的）。
        public var stillDue: Int
        /// 真读过音的卡数。
        public var spokenCount: Int
        /// 朗读平均分（只统计真读过的）。
        public var averagePronunciation: Double?
        /// 其中走**规则推断**通道的有几张（用来如实标注「不是声学实测」）。
        public var inferredCount: Int

        public var accuracy: Double { total == 0 ? 0 : Double(remembered) / Double(total) }
        public var accuracyPercent: Int { Int((accuracy * 100).rounded()) }
        /// 有没有可展示的朗读数据。
        public var hasSpokenData: Bool { spokenCount > 0 && averagePronunciation != nil }
        public var averagePronunciationPercent: Int? {
            averagePronunciation.map { Int($0.rounded()) }
        }

        /// 一行标题。
        public var headline: String {
            guard total > 0 else { return "今天没有到期的词" }
            if forgotten == 0 { return "这一轮全对，\(total) 个词都记住了" }
            return "这一轮复习了 \(total) 个词：\(remembered) 个认识、\(forgotten) 个忘了"
        }

        /// 补充说明（含朗读通道来源与「忘了的词今天还到期」两件事）。
        public var detail: String {
            var parts: [String] = []
            if let percent = averagePronunciationPercent {
                parts.append("朗读检查 \(spokenCount) 个，平均 \(percent) 分")
            }
            if inferredCount > 0 {
                parts.append("其中 \(inferredCount) 个是按发音部位推断的，不是声学实测，仅供参考")
            }
            if stillDue > 0 {
                parts.append("忘了的 \(stillDue) 个词今天仍留在待复习里，晚一点再过一轮就巩固住了")
            }
            if total == 0 {
                parts.append("可以去每日推荐里挑几个词加入复习列表")
            }
            return parts.joined(separator: "。")
        }
    }

    // MARK: - 状态

    /// 本轮队列（建好就不再改顺序）。
    public private(set) var queue: [VocabularyEntry]
    /// 当前卡在队列里的下标。
    public private(set) var index: Int = 0
    /// 已判分的卡（与队列前若干张一一对应）。
    public private(set) var outcomes: [Outcome] = []
    public let startedAt: Date

    /// 建一轮复习。`entries` 传词汇本全部词，本类型自己筛到期、自己排序。
    public init(entries: [VocabularyEntry], now: Date = Date(), limit: Int = maxCards) {
        self.queue = Self.queue(from: entries, now: now, limit: limit)
        self.startedAt = now
    }

    // MARK: - 队列

    /// 到期队列：按「**最不熟 → 最久没碰 → 字母序**」排。
    ///
    /// 掌握度低的先复习（这是复习最该花时间的地方）；同样不熟时先照顾最久没见的；
    /// 最后用字母序兜底，保证同一批词的顺序是确定的（不然测试与复现都无从谈起）。
    public static func queue(
        from entries: [VocabularyEntry],
        now: Date = Date(),
        limit: Int = maxCards
    ) -> [VocabularyEntry] {
        guard limit > 0 else { return [] }
        let due = ReviewScheduler.dueEntries(entries, now: now)
        let sorted = due.sorted { lhs, rhs in
            if lhs.mastery != rhs.mastery { return lhs.mastery < rhs.mastery }
            let left = lhs.lastReviewedAt ?? .distantPast
            let right = rhs.lastReviewedAt ?? .distantPast
            if left != right { return left < right }
            return lhs.word.lowercased() < rhs.word.lowercased()
        }
        return Array(sorted.prefix(limit))
    }

    /// 当前这张卡（走完为 nil）。
    public var current: VocabularyEntry? {
        queue.indices.contains(index) ? queue[index] : nil
    }

    /// 已判分的张数。
    public var reviewed: Int { outcomes.count }

    /// 本轮总张数。
    public var total: Int { queue.count }

    /// 进度 0...1。
    public var progress: Double {
        queue.isEmpty ? 1 : Double(reviewed) / Double(queue.count)
    }

    /// 这一轮是否走完了（含「本来就没有到期的词」）。
    public var isFinished: Bool { index >= queue.count }

    /// 队列里还剩几张没走。
    public var remaining: Int { max(queue.count - index, 0) }

    // MARK: - 判分推进

    /// 给当前这张卡判分并推到下一张。
    ///
    /// - Parameters:
    ///   - remembered: 学员自己给的等级。
    ///   - pronunciationScore: 这张卡的朗读总分（没读就传 nil）。**不影响等级**，
    ///     只是记进结算里让学员看到自己刚才读成什么样。
    ///   - phonemeSource: 那次朗读的通道来源。
    /// - Returns: 刚判完的那张卡的结果；走完了 / 没有当前卡时为 nil。
    @discardableResult
    public mutating func grade(
        remembered: Bool,
        pronunciationScore: Double? = nil,
        phonemeSource: PhonemeSource? = nil,
        now: Date = Date()
    ) -> Outcome? {
        guard let entry = current else { return nil }
        let graded = ReviewScheduler.graded(entry, remembered ? .remembered : .forgotten, now: now)
        let outcome = Outcome(
            entryID: entry.id,
            word: entry.word,
            remembered: remembered,
            masteryBefore: entry.mastery,
            masteryAfter: graded.mastery,
            // 「忘了」掌握度 −1：掌握度 0 的间隔是 0 天 → 今天仍然到期。
            stillDue: ReviewScheduler.isDue(graded, now: now),
            pronunciationScore: pronunciationScore,
            phonemeSource: phonemeSource
        )
        outcomes.append(outcome)
        index += 1
        return outcome
    }

    // MARK: - 就地更新当前这张

    /// 把**当前这张**卡换成最新版本（复习途中查到释义后同步显示）。
    ///
    /// ⚠️ 队列里存的是词条的值拷贝。查释义改的是词表那份数据，不回填这一张，
    /// 用户翻面看到的就还是「这个词还没有释义」—— 查了等于没查。
    ///
    /// 只换当前这一张，且要求 id 一致：队列顺序与已判分结果都不受影响
    /// （它是「换一份更完整的资料」，不是「重排这一轮」）。
    public mutating func updateCurrent(_ entry: VocabularyEntry) {
        guard queue.indices.contains(index), queue[index].id == entry.id else { return }
        queue[index] = entry
    }

    // MARK: - 结算

    public var summary: Summary {
        let forgotten = outcomes.filter { !$0.remembered }.count
        let scores = outcomes.compactMap(\.pronunciationScore)
        return Summary(
            total: outcomes.count,
            remembered: outcomes.count - forgotten,
            forgotten: forgotten,
            stillDue: outcomes.filter(\.stillDue).count,
            spokenCount: scores.count,
            averagePronunciation: scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count),
            inferredCount: outcomes.filter { $0.phonemeSource == .inference }.count
        )
    }
}
