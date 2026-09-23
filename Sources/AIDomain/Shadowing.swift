import Foundation

// MARK: - 跟读（Shadowing，第 22 步）
//
// 设计依据：Implementation Plan §22「Shadowing」。
//
// 链路：参考句 → 听示范（TTS 分句流水线）→ 学员跟读（录音 → **原始** ASR 结果）
//      → 逐词对齐 → 反馈 → 落库。
//
// 两条刻意的设计决定：
// 1. **跟读不用拼写纠正**。纠正会把「学员实际说了什么」改成「他本来想说什么」，
//    正好抹掉跟读要评估的东西（漏词、换词、串词）。所以这里吃 ASR 原始输出。
// 2. **单词语料数据驱动**：素材只来自 `Resources/Shadowing/drills.json`，代码零字面量。
//    本文件只描述「跟读是什么」与「怎么算匹配」，不含任何界面/资源内容。

/// 一条跟读素材（参考句）。
public struct ShadowingDrill: Codable, Sendable, Equatable, Identifiable {

    /// 稳定标识（如 `greet_01`）。
    public let id: String
    /// 参考句（学习语言）——学员要跟着说的那句。
    public var text: String
    /// 母语释义：跟读前先看懂在说什么，否则只是鹦鹉学舌。
    public var translation: String
    /// 主题分组（如「日常问候」），UI 只负责渲染。
    public var topic: String
    /// 难度 1...5（越界自动夹取）。
    public var difficulty: Int
    /// 这一句要留意的点（连读 / 语调 / 弱读…）。可为空。
    public var focus: String

    public init(
        id: String,
        text: String,
        translation: String = "",
        topic: String = "",
        difficulty: Int = 1,
        focus: String = ""
    ) {
        self.id = id
        self.text = text
        self.translation = translation
        self.topic = topic
        self.difficulty = Self.clamp(difficulty)
        self.focus = focus
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, translation, topic, difficulty, focus
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // id / text 缺失必须显式报错：没有参考句的素材是坏数据，不许静默兜底。
        id = try container.decode(String.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        translation = try container.decodeIfPresent(String.self, forKey: .translation) ?? ""
        topic = try container.decodeIfPresent(String.self, forKey: .topic) ?? ""
        focus = try container.decodeIfPresent(String.self, forKey: .focus) ?? ""
        difficulty = Self.clamp(try container.decodeIfPresent(Int.self, forKey: .difficulty) ?? 1)
    }

    /// 难度夹取到 1...5。
    public static func clamp(_ value: Int) -> Int { min(max(value, 1), 5) }
}

/// 一个跟读素材文件（`Resources/Shadowing/*.json`）。
public struct ShadowingDrillFile: Codable, Sendable, Equatable {
    public var version: Int
    public var drills: [ShadowingDrill]

    public init(version: Int = 1, drills: [ShadowingDrill] = []) {
        self.version = version
        self.drills = drills
    }
}

// MARK: - 每日跟读（按情景现生成）

/// 「今日跟读 20 句」的解析与轮转规则（**纯函数**，不碰模型、不碰 IO，可脱机单测）。
///
/// 素材来源从「包里写死的 drills.json」改成「每天按情景现生成」之后，稳定性的责任
/// 就从文件挪到了**日期**上：同一天必须拿到同一批句子（否则用户练到第 7 句去泡了杯茶，
/// 回来发现句子全换了），换一天才换一批。这条由 `dayKey` + 落盘缓存保证。
public enum ShadowingDailyRule {

    /// 每天的目标句数。
    public static let dailySentenceCount = 20

    /// 每天覆盖几个情景（20 句 ÷ 5 个情景 = 每情景 4 句）。
    public static let dailyScenarioCount = 5

    /// 日期键（`2026-09-16`）。缓存与「今天换没换」都以它为准 ——
    /// **不用时间戳**：同一天的任意时刻都必须算出同一个键。
    public static func dayKey(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 0
        let month = parts.month ?? 0
        let day = parts.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// 今天轮到哪几个情景：**按日期轮转**（`dayOfYear` 决定起点），
    /// 保证 ①同一天稳定 ②相邻两天不重样 ③一天之内不重复。
    public static func rotatedScenarios(
        from scenarios: [Scenario],
        date: Date = Date(),
        calendar: Calendar = .current,
        pick: Int = dailyScenarioCount
    ) -> [Scenario] {
        guard !scenarios.isEmpty else { return [] }
        let sorted = scenarios.sorted { $0.id < $1.id }
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        let start = ((dayOfYear - 1) % sorted.count + sorted.count) % sorted.count
        let take = min(max(pick, 1), sorted.count)
        return (0..<take).map { sorted[(start + $0) % sorted.count] }
    }

    /// 解析模型输出成跟读素材。
    ///
    /// 格式（一行一个键，`|` 分隔子字段，与词典那套同一把尺）：
    /// ```
    /// topic: 机场值机 | 3
    /// sentence: <学习语言例句> | <母语翻译> | <发音 / 连读要点>
    /// sentence: …
    /// topic: 酒店入住 | 4
    /// sentence: …
    /// ```
    ///
    /// `sentence` 归属于**它上面最近的那个 `topic`**；还没出现 `topic` 的句子直接丢弃
    /// （没有情景归属的句子在页面上无处安放）。单行坏了只丢那一行，不倒整份。
    public static func parse(_ raw: String, limit: Int = dailySentenceCount) -> [ShadowingDrill] {
        var drills: [ShadowingDrill] = []
        var topic = ""
        var difficulty = 1
        var topicIndex = -1
        var indexInTopic = 0

        let lines = raw
            .replacingOccurrences(of: "```", with: "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        for line in lines {
            guard let separator = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else { continue }
            let key = line[line.startIndex..<separator]
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: " ", with: "")
                .lowercased()
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            let fields = value
                .components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            switch key {
            case "topic", "scenario", "theme", "情景", "主题":
                guard let name = fields.first, !name.isEmpty else { continue }
                topic = name
                difficulty = ShadowingDrill.clamp(Int(fields.count > 1 ? fields[1] : "") ?? 1)
                topicIndex += 1
                indexInTopic = 0
            case "sentence", "drill", "line", "句子", "例句":
                guard !topic.isEmpty, let text = fields.first, !text.isEmpty else { continue }
                drills.append(
                    ShadowingDrill(
                        id: "daily-\(topicIndex)-\(indexInTopic)",
                        text: text,
                        translation: fields.count > 1 ? fields[1] : "",
                        topic: topic,
                        difficulty: difficulty,
                        focus: fields.count > 2 ? fields[2] : ""
                    )
                )
                indexInTopic += 1
            default:
                break
            }
            if drills.count >= limit { break }
        }
        return drills
    }
}

// MARK: - 历史记录能不能当「今天这一句」的分析

/// 判据：一条库里的跟读记录能不能被认成**今天这一句**的逐句分析（**纯函数**）。
///
/// 用户报障（2026-09-23）：「昨天读过的分析今天还在，匹配率还是昨天那个数」。
/// 根因是记录与素材之间**只有一个 `drill_id` 相连**，而这个 id 与内容无关 ——
/// 每日素材的 id 是 `daily-<主题序号>-<句内序号>`（见 `ShadowingDailyRule.parse`），
/// 换一天主题轮换，**同一批 id 换了一批全新的句子**。只按 id 取，
/// 就会把昨天的识别文本拿来对**今天**的参考句算匹配率，发音分也是昨天那次的。
///
/// 所以两个条件缺一不可：
/// 1. **同一天**（`dayKey`）：跨天一律不认。
/// 2. **参考文本一致**：同一天里用户点「换一批」会换掉整批句子，而 id 一个都不变。
///
/// 不满足就当作「这一句还没读过」——**宁可让用户重读一句，也不许把别人的成绩安在他头上**。
public enum ShadowingAnalysisAdoption {

    public static func adopts(
        _ attempt: ShadowingAttempt,
        for drill: ShadowingDrill,
        dayKey: String,
        calendar: Calendar = .current
    ) -> Bool {
        guard ShadowingDailyRule.dayKey(attempt.createdAt, calendar: calendar) == dayKey else {
            return false
        }
        return normalized(attempt.referenceText) == normalized(drill.text)
    }

    /// 参考文本的比较口径：压掉空白与大小写的差异。
    ///
    /// 只做这两样：漏一个多余空格不该让用户重读一遍；而**再往下归一**
    /// （去标点、词形还原）会把两句真正不同的话看成一个 —— 那正是这次要修的病。
    public static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }
}

// MARK: - 逐词对齐结果

/// 参考句里每个词的跟读结果。
public enum ShadowingTokenStatus: String, Sendable, Equatable, CaseIterable {
    /// 跟上了（词对词命中）。
    case matched
    /// 漏读了（参考句有、学员没说）。
    case missing
    /// 多说了（学员说了、参考句没有）。
    case extra
}

/// 对齐后的一个词。
public struct ShadowingToken: Sendable, Equatable {
    public var word: String
    public var status: ShadowingTokenStatus

    public init(word: String, status: ShadowingTokenStatus) {
        self.word = word
        self.status = status
    }
}

/// 跟读判定分档（纯数据，文案在此集中维护）。
public enum ShadowingVerdict: String, Sendable, Equatable, CaseIterable {
    /// 完全跟上。
    case perfect
    /// 很接近。
    case great
    /// 继续加油。
    case keepGoing
    /// 再来一次。
    case retry

    public var displayName: String {
        switch self {
        case .perfect: "完全跟上"
        case .great: "很接近了"
        case .keepGoing: "继续加油"
        case .retry: "再来一次"
        }
    }

    public var symbol: String {
        switch self {
        case .perfect: "checkmark.seal.fill"
        case .great: "hand.thumbsup.fill"
        case .keepGoing: "figure.walk.motion"
        case .retry: "arrow.counterclockwise"
        }
    }
}

/// 一次跟读的评测结果（参考句 vs 学员实际说的）。
public struct ShadowingComparison: Sendable, Equatable {
    public var referenceText: String
    public var recognizedText: String
    /// 逐词对齐（顺序与参考句一致，多说的词挂在对应位置之后）。
    public var tokens: [ShadowingToken]
    /// 命中的词数。
    public var matched: Int
    /// 参考句词数。
    public var referenceCount: Int
    /// 匹配率 0...1 = 命中词数 / 参考句词数。
    public var accuracy: Double
    public var verdict: ShadowingVerdict
    /// 漏读 / 读错的词（去重，保持出现顺序）。
    public var missedWords: [String]
    /// 一句话反馈。
    public var hint: String

    public init(
        referenceText: String,
        recognizedText: String,
        tokens: [ShadowingToken],
        matched: Int,
        referenceCount: Int,
        accuracy: Double,
        verdict: ShadowingVerdict,
        missedWords: [String],
        hint: String
    ) {
        self.referenceText = referenceText
        self.recognizedText = recognizedText
        self.tokens = tokens
        self.matched = matched
        self.referenceCount = referenceCount
        self.accuracy = accuracy
        self.verdict = verdict
        self.missedWords = missedWords
        self.hint = hint
    }

    /// 百分比整数（UI 直接显示，避免各处重复取整）。
    public var accuracyPercent: Int { Int((accuracy * 100).rounded()) }
}

/// 一次跟读记录（落库）。发音评测（第 23 步）录到音频时一并保存报告。
public struct ShadowingAttempt: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var drillID: String
    public var referenceText: String
    public var recognizedText: String
    public var accuracy: Double
    /// 发音评测报告（nil = 那次没有可用音频，比如纯文本预览）。
    public var pronunciation: PronunciationReport?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        drillID: String,
        referenceText: String,
        recognizedText: String,
        accuracy: Double,
        pronunciation: PronunciationReport? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.drillID = drillID
        self.referenceText = referenceText
        self.recognizedText = recognizedText
        self.accuracy = min(max(accuracy, 0), 1)
        self.pronunciation = pronunciation
        self.createdAt = createdAt
    }
}

/// 一次跟读的完整结果：文本对齐 +（录到音频时的）发音评测。
public struct ShadowingResult: Sendable, Equatable {
    public var comparison: ShadowingComparison
    public var pronunciation: PronunciationReport?

    public init(comparison: ShadowingComparison, pronunciation: PronunciationReport? = nil) {
        self.comparison = comparison
        self.pronunciation = pronunciation
    }
}

/// 跟读统计（学习记录 / 页面顶部的汇总）。
public struct ShadowingStats: Sendable, Equatable {
    public var attempts: Int
    public var bestAccuracy: Double
    public var averageAccuracy: Double
    /// 最近一次匹配率（无记录为 nil）。
    public var lastAccuracy: Double?
    /// 发音总分（0...100）：历史最佳 / 平均。只有带音频的记录才计入。
    public var bestPronunciation: Double?
    public var averagePronunciation: Double?

    public init(
        attempts: Int,
        bestAccuracy: Double,
        averageAccuracy: Double,
        lastAccuracy: Double?,
        bestPronunciation: Double? = nil,
        averagePronunciation: Double? = nil
    ) {
        self.attempts = attempts
        self.bestAccuracy = bestAccuracy
        self.averageAccuracy = averageAccuracy
        self.lastAccuracy = lastAccuracy
        self.bestPronunciation = bestPronunciation
        self.averagePronunciation = averagePronunciation
    }

    public static let empty = ShadowingStats(attempts: 0, bestAccuracy: 0, averageAccuracy: 0, lastAccuracy: nil)

    /// 从记录（约定为**新→旧**）汇总。
    public static func from(_ attempts: [ShadowingAttempt]) -> ShadowingStats {
        guard !attempts.isEmpty else { return .empty }
        let values = attempts.map(\.accuracy)
        let scores = attempts.compactMap(\.pronunciation).map(\.overall)
        return ShadowingStats(
            attempts: attempts.count,
            bestAccuracy: values.max() ?? 0,
            averageAccuracy: values.reduce(0, +) / Double(values.count),
            lastAccuracy: attempts.first?.accuracy,
            bestPronunciation: scores.max(),
            averagePronunciation: scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count)
        )
    }
}

// MARK: - 匹配算法（纯函数）

/// 逐词对齐与判定。**全部是纯函数**：不碰模型、不碰 IO，因此可以脱机单测。
public enum ShadowingScorer {

    /// 判定阈值（匹配率）。
    public static let perfectThreshold = 0.95
    public static let greatThreshold = 0.85
    public static let keepGoingThreshold = 0.6

    /// 归一化：小写、去掉标点、压缩空白，再切词。
    ///
    /// 保留 `'` 与 `-`：`don't` / `check-in` 应当是一个词，拆开会让匹配率凭空虚高。
    /// 数字保留（`gate 12` 也是跟读内容）。
    public static func words(_ text: String) -> [String] {
        var cleaned = ""
        cleaned.reserveCapacity(text.count)
        for character in text.lowercased() {
            if character.isLetter || character.isNumber || character == "'" || character == "-" {
                cleaned.append(character)
            } else {
                cleaned.append(" ")
            }
        }
        return cleaned.split(separator: " ").map(String.init)
    }

    /// 匹配率 → 分档。
    public static func verdict(for accuracy: Double) -> ShadowingVerdict {
        if accuracy >= perfectThreshold { return .perfect }
        if accuracy >= greatThreshold { return .great }
        if accuracy >= keepGoingThreshold { return .keepGoing }
        return .retry
    }

    /// 逐词对齐 + 判定 + 反馈。
    public static func compare(reference: String, recognized: String) -> ShadowingComparison {
        let refWords = words(reference)
        let hypWords = words(recognized)

        var tokens: [ShadowingToken] = []
        var matched = 0
        var missed: [String] = []

        if refWords.isEmpty {
            // 参考句为空 / 全是标点：没有可对齐的东西，直接判 0。
            return ShadowingComparison(
                referenceText: reference, recognizedText: recognized,
                tokens: [], matched: 0, referenceCount: 0, accuracy: 0,
                verdict: .retry, missedWords: [], hint: "这句素材没有可跟读的内容"
            )
        }

        // 最长公共子序列 → 骨架对齐；不在骨架上的参考词算漏读，学员多出来的算多说。
        let table = lcsTable(refWords, hypWords)
        var i = 0
        var j = 0
        while i < refWords.count || j < hypWords.count {
            if i < refWords.count, j < hypWords.count, refWords[i] == hypWords[j] {
                tokens.append(ShadowingToken(word: refWords[i], status: .matched))
                matched += 1
                i += 1
                j += 1
            } else if i < refWords.count,
                      j == hypWords.count || table[i + 1][j] >= table[i][j + 1] {
                tokens.append(ShadowingToken(word: refWords[i], status: .missing))
                if !missed.contains(refWords[i]) { missed.append(refWords[i]) }
                i += 1
            } else {
                // j < hypWords.count：学员多说了（不扣分，但要让用户看见）。
                tokens.append(ShadowingToken(word: hypWords[j], status: .extra))
                j += 1
            }
        }

        let accuracy = Double(matched) / Double(refWords.count)
        let verdict = verdict(for: accuracy)
        return ShadowingComparison(
            referenceText: reference, recognizedText: recognized,
            tokens: tokens, matched: matched, referenceCount: refWords.count,
            accuracy: accuracy, verdict: verdict, missedWords: missed,
            hint: hint(verdict: verdict, missed: missed, isSilent: hypWords.isEmpty)
        )
    }

    /// 一句话反馈。**点名漏掉的词**——「继续加油」这种空话对学习者没有信息量。
    public static func hint(verdict: ShadowingVerdict, missed: [String], isSilent: Bool) -> String {
        if isSilent { return "没有听到声音，凑近麦克风再说一次吧" }
        switch verdict {
        case .perfect:
            return "节奏和用词都跟上了，用这个状态再说下一句"
        case .great:
            return missed.isEmpty
                ? "很接近了，再听一遍示范，注意语速和重音"
                : "很接近了，留意这几个词：\(missed.prefix(4).joined(separator: "、"))"
        case .keepGoing:
            return missed.isEmpty
                ? "整体跟上了，个别词的发音再清楚一点"
                : "这几个词没跟上：\(missed.prefix(5).joined(separator: "、"))，再听一遍示范"
        case .retry:
            return missed.isEmpty
                ? "这次和示范差得有点多，先听两遍示范再开口"
                : "慢慢来，先听两遍示范，重点跟上：\(missed.prefix(4).joined(separator: "、"))"
        }
    }

    /// 两组词的**最长公共子序列长度**（骨架对齐最多能命中几个词）。
    ///
    /// 段落级跟读要反复问「第 i 句对上整段识别里的哪一段」，一次评测要问几千遍，
    /// 所以这里走**滚动两行**而不是 `lcsTable` 的全表：只要长度、不要回溯，
    /// 全表版本在这个量级下会把时间全花在分配二维数组上。
    public static func lcsMatchedCount(_ lhs: [String], _ rhs: [String]) -> Int {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        // 让 `previous` 对应较短的一侧，内存与内层循环都按它算。
        let (rows, columns) = lhs.count <= rhs.count ? (lhs, rhs) : (rhs, lhs)
        var previous = [Int](repeating: 0, count: columns.count + 1)
        var current = [Int](repeating: 0, count: columns.count + 1)
        for rowIndex in stride(from: rows.count - 1, through: 0, by: -1) {
            for columnIndex in stride(from: columns.count - 1, through: 0, by: -1) {
                current[columnIndex] = rows[rowIndex] == columns[columnIndex]
                    ? previous[columnIndex + 1] + 1
                    : max(previous[columnIndex], current[columnIndex + 1])
            }
            swap(&previous, &current)
        }
        return previous[0]
    }

    // MARK: - 私有

    /// LCS 长度表（(n+1) × (m+1)），用于回溯骨架对齐。
    private static func lcsTable(_ lhs: [String], _ rhs: [String]) -> [[Int]] {
        var table = [[Int]](repeating: [Int](repeating: 0, count: rhs.count + 1), count: lhs.count + 1)
        for i in stride(from: lhs.count - 1, through: 0, by: -1) {
            for j in stride(from: rhs.count - 1, through: 0, by: -1) {
                table[i][j] = lhs[i] == rhs[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }
        return table
    }
}
