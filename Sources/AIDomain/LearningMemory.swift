import Foundation

/// 跨会话的学习记忆摘要（Implementation Plan §19 Phase 15）。
///
/// 库里早就攒下了纠错 / 词汇 / 发音这些学习资产，但**对话时从来没被用上**——
/// 老师对学员的印象只剩下「当前这一段会话」，换个会话就失忆。这份摘要就是
/// 「长期记忆」的载体：由 `MemoryRetriever` 的纯函数从原始记录里算出来，
/// 可完整单测、不依赖任何模型；再经 `PromptBuilder` 折成一小段上下文交给老师。
///
/// 刻意做得**很小**：它是提示，不是报告。塞得越多，老师越容易照着念。
public struct LearningMemory: Sendable, Equatable {

    /// 反复犯的错（按次数降序，次数相同看最近一次）。
    public var recurringErrors: [RecurringError]
    /// 该复习的词（到期待复习，掌握度低的靠前）。
    public var focusWords: [String]
    /// 偏弱的发音维度（跨多次跟读求平均后仍低于阈值）。
    public var weakDimensions: [WeakDimension]
    /// 累计练习过的会话数。
    public var sessionsPracticed: Int
    /// 累计纠错条数（本轮检索窗口内）。
    public var totalCorrections: Int

    public init(
        recurringErrors: [RecurringError] = [],
        focusWords: [String] = [],
        weakDimensions: [WeakDimension] = [],
        sessionsPracticed: Int = 0,
        totalCorrections: Int = 0
    ) {
        self.recurringErrors = recurringErrors
        self.focusWords = focusWords
        self.weakDimensions = weakDimensions
        self.sessionsPracticed = sessionsPracticed
        self.totalCorrections = totalCorrections
    }

    /// 空记忆：没有任何历史时，老师就像面对新学员。
    public static let empty = LearningMemory()

    /// 没有任何**可用内容**（练习次数之类的计数不算内容）。
    public var isEmpty: Bool {
        recurringErrors.isEmpty && focusWords.isEmpty && weakDimensions.isEmpty
    }
}

/// 一条反复出现的错误：同一处「原句 → 改正」进入过多少次。
public struct RecurringError: Sendable, Equatable, Identifiable {
    public var original: String
    public var corrected: String
    public var explanation: String
    /// 出现次数（≥ 1）。
    public var count: Int
    /// 最近一次出现的时间。
    public var lastSeen: Date

    public init(original: String, corrected: String, explanation: String, count: Int, lastSeen: Date) {
        self.original = original
        self.corrected = corrected
        self.explanation = explanation
        self.count = count
        self.lastSeen = lastSeen
    }

    public var id: String { original + "\u{1}" + corrected }
}

/// 一个偏弱的发音维度（跨多次跟读的平均分）。
public struct WeakDimension: Sendable, Equatable, Identifiable {
    public var dimension: PronunciationDimension
    /// 0...100 的跨记录平均分。
    public var averageScore: Double
    /// 参与平均的记录条数。
    public var sampleCount: Int

    public init(dimension: PronunciationDimension, averageScore: Double, sampleCount: Int) {
        self.dimension = dimension
        self.averageScore = averageScore
        self.sampleCount = sampleCount
    }

    public var id: String { dimension.rawValue }
    public var displayName: String { dimension.displayName }
}

// MARK: - 检索（纯函数）

/// 记忆检索：把散落的原始事实收敛成一份 `LearningMemory`。
///
/// **不碰数据库、不依赖任何模型**，因此可以拿构造出来的记录完整单测。
/// 数据库只负责「把原始事实取出来」，怎么排序、算多少，全在这里。
public enum MemoryRetriever {

    /// 默认「偏弱」阈值：低于这个分的维度才值得提醒老师。
    public static let weakScoreThreshold: Double = 75

    /// 反复错误：把同一处「原句 → 改正」归一后计数，次数多的排前面。
    ///
    /// 归一化要够狠（大小写、首尾与连续空白），否则 `"I go  to school"` 与
    /// `"i go to school"` 会被当成两件不同的错，重复次数就统计不出来 ——
    /// 而「重复」正是这个字段唯一的价值。
    ///
    /// - Parameter records: 纠错记录，**约定按时间新 → 旧传入**（与数据库查询一致）。
    public static func recurringErrors(from records: [CorrectionRecord], limit: Int = 5) -> [RecurringError] {
        guard limit > 0, !records.isEmpty else { return [] }

        struct Bucket {
            var original: String
            var corrected: String
            var explanation: String
            var count: Int
            var lastSeen: Date
            var index: Int
        }

        var buckets: [String: Bucket] = [:]
        for record in records {
            let correction = record.correction
            let original = correction.original.trimmingCharacters(in: .whitespacesAndNewlines)
            let corrected = correction.corrected.trimmingCharacters(in: .whitespacesAndNewlines)
            // 空原句 / 空改正没有教学信息，丢弃。
            guard !original.isEmpty, !corrected.isEmpty else { continue }
            // 指纹口径与 `GrammarAgent.pattern` 保持一致：忽略大小写 / 空白 / 标点，
            // 否则同一条错误在库里分桶、在分析层判重会得到两个不同的结论。
            let key = matchKey(original) + "\u{1}" + matchKey(corrected)
            if var existing = buckets[key] {
                existing.count += 1
                if record.createdAt > existing.lastSeen {
                    existing.lastSeen = record.createdAt
                    existing.original = original
                    existing.corrected = corrected
                    if !correction.explanation.isEmpty { existing.explanation = correction.explanation }
                }
                buckets[key] = existing
            } else {
                buckets[key] = Bucket(
                    original: original,
                    corrected: corrected,
                    explanation: correction.explanation,
                    count: 1,
                    lastSeen: record.createdAt,
                    index: buckets.count
                )
            }
        }

        return buckets.values
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                if lhs.lastSeen != rhs.lastSeen { return lhs.lastSeen > rhs.lastSeen }
                return lhs.index < rhs.index
            }
            .prefix(limit)
            .map {
                RecurringError(
                    original: $0.original,
                    corrected: $0.corrected,
                    explanation: $0.explanation,
                    count: $0.count,
                    lastSeen: $0.lastSeen
                )
            }
    }

    /// 该复习的词：先取「到期待复习」（**复用 `ReviewScheduler`**，别在这里重写一套间隔逻辑），
    /// 掌握度低的靠前；全都已掌握时退回「掌握度最低的几个」，避免记忆整块为空。
    public static func focusWords(from vocabulary: [VocabularyEntry], limit: Int = 6, now: Date = Date()) -> [String] {
        guard limit > 0, !vocabulary.isEmpty else { return [] }
        var candidates = ReviewScheduler.dueEntries(vocabulary, now: now)
        if candidates.isEmpty {
            candidates = vocabulary.filter { !$0.isMastered }
        }
        let ranked = candidates.sorted { lhs, rhs in
            if lhs.mastery != rhs.mastery { return lhs.mastery < rhs.mastery }
            return (lhs.lastReviewedAt ?? lhs.createdAt) < (rhs.lastReviewedAt ?? rhs.createdAt)
        }
        return ranked.prefix(limit).map(\.word)
    }

    /// 偏弱的发音维度：把每次跟读里各维度的得分按维度求平均，低于阈值的才算「弱」。
    ///
    /// 只出现一两次的维度也保留（`sampleCount` 一并带出去，让上层自行决定要不要弱化），
    /// 因为学员很可能就是刚练了两遍、正需要被提醒。
    public static func weakDimensions(
        from reports: [PronunciationReport],
        limit: Int = 3,
        threshold: Double = MemoryRetriever.weakScoreThreshold
    ) -> [WeakDimension] {
        guard limit > 0, !reports.isEmpty else { return [] }
        var result: [WeakDimension] = []
        for dimension in PronunciationDimension.allCases {
            let scores = reports.compactMap { $0.line(dimension)?.score }
            guard !scores.isEmpty else { continue }
            let average = scores.reduce(0, +) / Double(scores.count)
            guard average < threshold else { continue }
            result.append(WeakDimension(dimension: dimension, averageScore: average, sampleCount: scores.count))
        }
        return result.sorted { $0.averageScore < $1.averageScore }.prefix(limit).map { $0 }
    }

    /// 组装一份完整摘要。数据库侧只需把原始事实取出来，口径全在这里。
    public static func brief(
        corrections: [CorrectionRecord],
        vocabulary: [VocabularyEntry],
        reports: [PronunciationReport],
        sessionCount: Int,
        errorLimit: Int = 5,
        wordLimit: Int = 6,
        dimensionLimit: Int = 3,
        now: Date = Date()
    ) -> LearningMemory {
        LearningMemory(
            recurringErrors: recurringErrors(from: corrections, limit: errorLimit),
            focusWords: focusWords(from: vocabulary, limit: wordLimit, now: now),
            weakDimensions: weakDimensions(from: reports, limit: dimensionLimit),
            sessionsPracticed: sessionCount,
            totalCorrections: corrections.count
        )
    }

    /// 按「与当前话题的相关度」重排并裁剪记忆：相关的排前面，明显不相关的直接丢掉。
    ///
    /// 只在**真实**嵌入模型上启用（mock 的向量只是字符哈希，按它排序等于乱排）。
    /// 丢条目要克制：只丢低于 `floor` 的，避免把记忆清空、让老师又「失忆」。
    /// 缺相关度（key 不在字典里）的条目按 `floor` 处理 —— 保留、排在最后，而不是被误删。
    public static func reranked(
        _ memory: LearningMemory,
        relevance: [String: Double],
        floor: Double = 0.05,
        errorLimit: Int = 5,
        wordLimit: Int = 6
    ) -> LearningMemory {
        guard !relevance.isEmpty else { return memory }
        var result = memory

        result.recurringErrors = memory.recurringErrors.enumerated()
            .map { (index: $0.offset, error: $0.element, score: relevance[$0.element.id] ?? floor) }
            .filter { $0.score >= floor }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.index < rhs.index
            }
            .prefix(errorLimit)
            .map(\.error)

        result.focusWords = memory.focusWords.enumerated()
            .map { (index: $0.offset, word: $0.element, score: relevance[$0.element] ?? floor) }
            .filter { $0.score >= floor }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.index < rhs.index
            }
            .prefix(wordLimit)
            .map(\.word)

        return result
    }

    /// 归一键：小写 + 首尾去空白 + 连续空白压成一个空格。
    ///
    /// 公开出来的理由：界面上「同一个错误」的去重口径也必须跟这里一致
    /// （否则同一个错会因为大小写差异显示成两行），各处各写一套必然漂移。
    public static func normalize(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// 判重键：`normalize` 之后**再去掉标点**。
    ///
    /// 专门用于「是不是同一处错误」的指纹与去重（`GrammarAgent.pattern`、
    /// `recurringErrors` 分桶、已知错误列表）。老师把同一处标成 `He go home.`
    /// 还是 `he go home` 说的是同一处，标点差异不该算成两处。
    ///
    /// ⚠️ **不要拿它判断「有没有发生变化」**——那必须保留标点，否则
    /// `Hello world → Hello, world.` 这种标点纠错会被当成「没变」丢掉。
    /// 那个场景继续用 `normalize`。
    public static func matchKey(_ text: String) -> String {
        normalize(text.components(separatedBy: CharacterSet.punctuationCharacters).joined(separator: " "))
    }
}
