import Foundation

// MARK: - 词汇本（Implementation Plan §24 Phase 20 — Vocabulary System）
//
// 硬要求：**复习逻辑与 UI 分离** —— 调度、判分全部是纯函数，本文件不 import 任何 UI/IO。

/// 一条词汇（落库 + UI 展示）。
public struct VocabularyEntry: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    /// 单词 / 表达（唯一键，去重依据）。
    public var word: String
    /// 落库的释义全文（LLM 生成的结构化键值行；历史数据可能是整段中文）。
    /// UI 用 `VocabularyDefinitionRule.decodeStored` 解析后按统一结构展示。
    public var meaning: String
    /// 例句（按需由 LLM 补；朗读卡片英文时用）。
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

// MARK: - 释义（统一模型）

/// 一条词的完整释义。**词汇本复习卡与每日推荐卡共用同一个结构**，
/// 因此两处的排版完全一致（区别只有复习卡多一行「重点单词」）。
///
/// 数据来源两种：
/// - LLM 按需生成：键值行格式（`phonetic: …` / `pos: …` …）；
/// - 历史落库数据：早先版本只存了「一段中文释义（+重点单词）」，
///   解析不出结构时整体落到 `legacyText`，UI 按整段文字展示。
public struct VocabularyDefinition: Sendable, Equatable {
    /// 音标（IPA）。**只有单个单词才有**；词组 / 短句一律为空。
    public var phonetic: String
    /// 词性，多词性用 `/` 连接（如 `n./v.`）。
    public var pos: String
    /// 中文义项：**多义词的义项全部列出**，用「；」分隔。
    public var senses: String
    /// 中文解释（用法 / 语境 / 搭配），与义项**分行**展示。
    public var explanation: String
    public var example: String
    public var exampleTranslation: String
    public var synonyms: [String]
    public var antonyms: [String]
    /// 词组 / 短句的重点单词（「word (n.) 中文；…」整段文本）；单词为空。
    public var keywords: String
    /// 无法结构化的历史数据原文（非空时 UI 按整段释义展示）。
    public var legacyText: String

    public init(
        phonetic: String = "",
        pos: String = "",
        senses: String = "",
        explanation: String = "",
        example: String = "",
        exampleTranslation: String = "",
        synonyms: [String] = [],
        antonyms: [String] = [],
        keywords: String = "",
        legacyText: String = ""
    ) {
        self.phonetic = phonetic
        self.pos = pos
        self.senses = senses
        self.explanation = explanation
        self.example = example
        self.exampleTranslation = exampleTranslation
        self.synonyms = synonyms
        self.antonyms = antonyms
        self.keywords = keywords
        self.legacyText = legacyText
    }

    /// 没有任何可展示内容。
    public var isEmpty: Bool {
        phonetic.isEmpty && pos.isEmpty && senses.isEmpty && explanation.isEmpty
            && example.isEmpty && exampleTranslation.isEmpty && synonyms.isEmpty
            && antonyms.isEmpty && keywords.isEmpty && legacyText.isEmpty
    }

    /// 是否来自历史非结构化数据（UI 可提示「重新释义」升级到新格式）。
    public var isLegacy: Bool { !legacyText.isEmpty }

    /// 中文义项列表（按「；」拆开）。
    public var senseList: [String] {
        senses
            .split(whereSeparator: { "；;".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 「重点单词」行文案（没有则 nil）。
    public var keywordsLine: String? {
        keywords.isEmpty ? nil : "重点单词：\(keywords)"
    }

    /// 落库编码。历史数据原样保留（重点单词行照旧拼回）；结构化数据写成键值行，
    /// 读回时同一套解析。
    public var encoded: String {
        guard legacyText.isEmpty else {
            return keywords.isEmpty ? legacyText : "\(legacyText)\n重点单词：\(keywords)"
        }
        var lines: [String] = []
        if !phonetic.isEmpty { lines.append("phonetic: \(phonetic)") }
        if !pos.isEmpty { lines.append("pos: \(pos)") }
        if !senses.isEmpty { lines.append("meaning: \(senses)") }
        if !explanation.isEmpty { lines.append("explanation: \(explanation)") }
        if !example.isEmpty { lines.append("example: \(example)") }
        if !exampleTranslation.isEmpty { lines.append("translation: \(exampleTranslation)") }
        if !synonyms.isEmpty { lines.append("synonyms: \(synonyms.joined(separator: "、"))") }
        if !antonyms.isEmpty { lines.append("antonyms: \(antonyms.joined(separator: "、"))") }
        if !keywords.isEmpty { lines.append("keywords: \(keywords)") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 每日推荐（Daily Recommendation）

/// 每日推荐的一个词 / 词组（来自本地雅思词库，不落库、默认不进复习列表）。
public struct DailyWord: Sendable, Equatable, Identifiable, Codable {
    /// 难度档上限：1 简单 / 2 中等 / 3 困难 / 4 词组（雅思标准）。
    public static let maxDifficulty = 4

    public var word: String
    /// 难度档：1 简单 / 2 中等 / 3 困难 / 4 词组。
    public var difficulty: Int

    public var id: String { word }

    /// 词组档（短语 / 固定搭配）。
    public var isPhrase: Bool { difficulty == DailyWordPicker.phraseDifficulty }

    public init(word: String, difficulty: Int) {
        self.word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        self.difficulty = min(max(difficulty, 1), Self.maxDifficulty)
    }

    /// 难度标签（UI 展示）。
    public var difficultyLabel: String { Self.difficultyLabel(for: difficulty) }

    /// 难度标签（静态版，给没有词实例的 UI 用）。
    public static func difficultyLabel(for difficulty: Int) -> String {
        switch difficulty {
        case 1: "简单"
        case 2: "中等"
        case 3: "困难"
        default: "词组"
        }
    }
}

/// 每日推荐选词器：**纯函数**。
///
/// 规则：每次 12 个 —— 3 简单 / 5 中等 / 2 困难 / 2 词组（雅思标准）；
/// 从词库对应档位里随机抽，排除指定集合（刷新时排除当前展示的一批）。
/// 某档位词不够时有多少给多少，不凑数。
public enum DailyWordPicker {
    /// 词组档难度值。
    public static let phraseDifficulty = 4
    /// 每次推荐的配额（难度 1/2/3/4 → 个数）。
    public static let quota: [Int: Int] = [1: 3, 2: 5, 3: 2, 4: 2]

    /// 每次推荐的总数。
    public static var total: Int { quota.values.reduce(0, +) }

    /// 从词库抽一组每日推荐（可注入随机源，便于单测）。
    public static func pick<R: RandomNumberGenerator>(
        from bank: [DailyWord],
        excluding: Set<String> = [],
        using generator: inout R
    ) -> [DailyWord] {
        let available = bank.filter { !excluding.contains($0.word.lowercased()) }
        var picked: [DailyWord] = []
        for difficulty in [1, 2, 3, phraseDifficulty] {
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
