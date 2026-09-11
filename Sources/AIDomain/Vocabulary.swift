import Foundation

// MARK: - 词汇本（Implementation Plan §24 Phase 20 — Vocabulary System）
//
// 硬要求：**复习逻辑与 UI 分离** —— 调度、判分全部是纯函数，本文件不 import 任何 UI/IO。

/// 一条词汇（落库 + UI 展示）。
public struct VocabularyEntry: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    /// 单词 / 表达（唯一键，去重依据）。
    public var word: String
    /// 中文释义（按需由 LLM 补，导入时可能为空）。
    public var meaning: String
    /// 例句（按需由 LLM 补）。
    public var example: String
    /// 难度 1–5（1 最易）。
    public var difficulty: Int
    /// 掌握度 0–5，5 = 已掌握。
    public var mastery: Int
    /// 复习次数。
    public var reviewCount: Int
    /// 最近一次复习时间（没复习过为 nil）。
    public var lastReviewedAt: Date?
    /// 来源。
    public enum Source: String, Codable, Sendable {
        /// 会话复盘提取（第 20 步 new_words）。
        case review
        /// 情景对话目标词表。
        case scenario
        /// 手动添加。
        case manual
    }

    public var source: Source
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        word: String,
        meaning: String = "",
        example: String = "",
        difficulty: Int = 3,
        mastery: Int = 0,
        reviewCount: Int = 0,
        lastReviewedAt: Date? = nil,
        source: Source = .manual,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        self.meaning = meaning
        self.example = example
        self.difficulty = min(max(difficulty, 1), 5)
        self.mastery = min(max(mastery, 0), 5)
        self.reviewCount = max(reviewCount, 0)
        self.lastReviewedAt = lastReviewedAt
        self.source = source
        self.createdAt = createdAt
    }

    /// 是否已掌握（mastery 封顶）。
    public var isMastered: Bool { mastery >= ReviewScheduler.masteredMastery }
}

// MARK: - 复习调度（简化间隔重复）

/// 复习调度器：**纯函数**，间隔重复的简化版。
///
/// 规则（刻意简单，先可用再谈科学）：
/// - 掌握度 0–5，对应复习间隔 `[当天, 1, 2, 4, 7, 14]` 天；
/// - 复习答对 → 掌握度 +1（封顶 5）；答错 → −1（保底 0），且**当天重新到期**；
/// - 没复习过的新词永远当天到期（不加间隔就见不到第二面）。
public enum ReviewScheduler {
    /// 掌握度上限。
    public static let maxMastery = 5
    /// 视为「已掌握」的最低档。
    public static let masteredMastery = 5

    /// 各掌握度对应的复习间隔（天）。
    public static let intervalDays: [Int] = [0, 1, 2, 4, 7, 14]

    /// 该词是否到期应复习。
    public static func isDue(_ entry: VocabularyEntry, now: Date = Date()) -> Bool {
        guard entry.mastery < masteredMastery else { return false }
        guard let last = entry.lastReviewedAt else { return true }
        let days = intervalDays[min(entry.mastery, intervalDays.count - 1)]
        return now.timeIntervalSince(last) >= Double(days) * 86_400
    }

    /// 待复习的词（保持传入顺序）。
    public static func dueEntries(_ entries: [VocabularyEntry], now: Date = Date()) -> [VocabularyEntry] {
        entries.filter { isDue($0, now: now) }
    }

    /// 一次复习的结果。
    public enum Grade: Sendable, Equatable {
        case remembered
        case forgotten
    }

    /// 判分后的新状态（不改传入值）。
    public static func graded(_ entry: VocabularyEntry, _ grade: Grade, now: Date = Date()) -> VocabularyEntry {
        var next = entry
        switch grade {
        case .remembered:
            next.mastery = min(entry.mastery + 1, maxMastery)
        case .forgotten:
            next.mastery = max(entry.mastery - 1, 0)
        }
        next.reviewCount = entry.reviewCount + 1
        next.lastReviewedAt = now
        return next
    }
}

// MARK: - 每日推荐（Daily Recommendation）

/// 每日推荐的一个单词（来自本地雅思词库，不落库、默认不进复习列表）。
public struct DailyWord: Sendable, Equatable, Identifiable, Codable {
    public var word: String
    /// 难度档：1 简单 / 2 中等 / 3 困难（雅思标准）。
    public var difficulty: Int

    public var id: String { word }

    public init(word: String, difficulty: Int) {
        self.word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        self.difficulty = min(max(difficulty, 1), 3)
    }

    /// 难度标签（UI 展示）。
    public var difficultyLabel: String { Self.difficultyLabel(for: difficulty) }

    /// 难度标签（静态版，给没有词实例的 UI 用）。
    public static func difficultyLabel(for difficulty: Int) -> String {
        switch difficulty {
        case 1: "简单"
        case 2: "中等"
        default: "困难"
        }
    }
}

/// 每日推荐的释义结果（按需由 LLM 补，不落库）。
public struct DailyDefinition: Sendable, Equatable {
    public var pos: String
    public var meaning: String
    public var example: String
    public var exampleTranslation: String
    public var synonyms: [String]
    public var antonyms: [String]

    public init(
        pos: String,
        meaning: String,
        example: String,
        exampleTranslation: String,
        synonyms: [String],
        antonyms: [String]
    ) {
        self.pos = pos
        self.meaning = meaning
        self.example = example
        self.exampleTranslation = exampleTranslation
        self.synonyms = synonyms
        self.antonyms = antonyms
    }
}

/// 每日推荐选词器：**纯函数**。
///
/// 规则：每次 10 个 —— 3 简单 / 5 中等 / 2 困难（雅思标准）；
/// 从词库对应档位里随机抽，排除指定集合（刷新时排除当前展示的 10 个）。
/// 某档位词不够时有多少给多少，不凑数。
public enum DailyWordPicker {
    /// 每次推荐的配额（难度 1/2/3 → 个数）。
    public static let quota: [Int: Int] = [1: 3, 2: 5, 3: 2]

    /// 从词库抽一组每日推荐（可注入随机源，便于单测）。
    public static func pick<R: RandomNumberGenerator>(
        from bank: [DailyWord],
        excluding: Set<String> = [],
        using generator: inout R
    ) -> [DailyWord] {
        let available = bank.filter { !excluding.contains($0.word.lowercased()) }
        var picked: [DailyWord] = []
        for difficulty in [1, 2, 3] {
            let count = quota[difficulty] ?? 0
            let candidates = available.filter { $0.difficulty == difficulty }.shuffled(using: &generator)
            picked.append(contentsOf: candidates.prefix(count))
        }
        return picked
    }

    /// 便捷入口（系统随机源）。
    public static func pick(from bank: [DailyWord], excluding: Set<String> = []) -> [DailyWord] {
        var rng = SystemRandomNumberGenerator()
        return pick(from: bank, excluding: excluding, using: &rng)
    }
}

// MARK: - 统计

/// 词汇统计（页面头部 / 学习记录）。
public struct VocabularyStats: Sendable, Equatable {
    public var total: Int
    public var due: Int
    public var mastered: Int
    /// 有中文释义的词数（释义是按需补的，这里让用户知道还剩多少没配）。
    public var defined: Int

    public init(total: Int, due: Int, mastered: Int, defined: Int) {
        self.total = total
        self.due = due
        self.mastered = mastered
        self.defined = defined
    }

    public static let empty = VocabularyStats(total: 0, due: 0, mastered: 0, defined: 0)

    public static func from(_ entries: [VocabularyEntry], now: Date = Date()) -> VocabularyStats {
        VocabularyStats(
            total: entries.count,
            due: ReviewScheduler.dueEntries(entries, now: now).count,
            mastered: entries.filter(\.isMastered).count,
            defined: entries.filter { !$0.meaning.isEmpty }.count
        )
    }
}
