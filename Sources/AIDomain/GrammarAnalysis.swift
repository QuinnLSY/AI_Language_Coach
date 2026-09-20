import Foundation

// MARK: - 语法分析（Implementation Plan §12 Phase 8 — Grammar Agent）
//
// 验收点：**不依赖任何具体 LLM 也能测**。所以这里全是确定性规则，没有模型调用。
//
// 与现有链路的关系：老师（LLM）在回复里用 `[[FIX]] 原句 => 改正 => 说明` 标出错误，
// `ChatService.extractCorrections` 把它解析成 `GrammarCorrection`。本层接在那之后，
// 负责**分类 / 定级 / 判重**——把这些从「prompt 里的一句叮嘱」变成可断言的结构化数据。

/// 错误类型。取值用 snake_case 字符串，与计划文档给出的 JSON 契约一致
/// （`"error_type": "verb_tense"`），将来直接作为结构化输出契约也不冲突。
public enum GrammarErrorCategory: String, Codable, Sendable, Equatable, CaseIterable {
    case verbTense = "verb_tense"
    case verbAgreement = "verb_agreement"
    case article
    case preposition
    case pluralNumber = "plural_number"
    case wordOrder = "word_order"
    case pronoun
    case spelling
    case punctuation
    case wordChoice = "word_choice"
    case other

    /// 中文展示名（UI / 复盘）。
    public var displayName: String {
        switch self {
        case .verbTense: "时态"
        case .verbAgreement: "主谓一致"
        case .article: "冠词"
        case .preposition: "介词"
        case .pluralNumber: "单复数"
        case .wordOrder: "语序"
        case .pronoun: "代词"
        case .spelling: "拼写"
        case .punctuation: "标点"
        case .wordChoice: "用词"
        case .other: "其他"
        }
    }

    /// 默认严重度（可在单条上被长度规则覆盖）。
    var defaultSeverity: GrammarErrorSeverity {
        switch self {
        case .punctuation, .spelling, .article: .minor
        case .verbTense, .verbAgreement, .wordOrder, .other: .moderate
        case .preposition, .pluralNumber, .pronoun, .wordChoice: .moderate
        }
    }
}

/// 严重程度：老师据此决定「要不要打断正题专门讲这一处」。
public enum GrammarErrorSeverity: String, Codable, Sendable, Equatable, CaseIterable, Comparable {
    case minor
    case moderate
    case major

    var rank: Int {
        switch self {
        case .minor: 0
        case .moderate: 1
        case .major: 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    public var displayName: String {
        switch self {
        case .minor: "小问题"
        case .moderate: "要留意"
        case .major: "影响理解"
        }
    }
}

/// 一处被识别出的语法错误（结构化）。
public struct GrammarError: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var original: String
    public var corrected: String
    public var category: GrammarErrorCategory
    public var severity: GrammarErrorSeverity
    public var explanation: String
    /// 错误模式指纹（归一后的「原句\x01改正」）。同一处错误反复出现时指纹相同。
    public var pattern: String
    /// 是不是**反复**出现的同一个错（命中历史或本批重复）。
    public var isRepeated: Bool

    public init(
        id: UUID = UUID(),
        original: String,
        corrected: String,
        category: GrammarErrorCategory,
        severity: GrammarErrorSeverity,
        explanation: String,
        pattern: String,
        isRepeated: Bool = false
    ) {
        self.id = id
        self.original = original
        self.corrected = corrected
        self.category = category
        self.severity = severity
        self.explanation = explanation
        self.pattern = pattern
        self.isRepeated = isRepeated
    }
}

/// 一次分析的完整结果。
public struct GrammarAnalysis: Codable, Sendable, Equatable {
    public var errors: [GrammarError]

    public init(errors: [GrammarError] = []) {
        self.errors = errors
    }

    public static let clean = GrammarAnalysis()

    public var hasError: Bool { !errors.isEmpty }
    public var repeatedErrors: [GrammarError] { errors.filter(\.isRepeated) }
    public var hasRepeatedError: Bool { errors.contains { $0.isRepeated } }

    /// 老师优先要讲的那一处：**最严重的；同级取最先出现的**（先出现的通常是主句问题）。
    ///
    /// 只讲一处是刻意的：一次纠正五处，学员一处也记不住。
    public var primary: GrammarError? {
        errors.enumerated()
            .max { lhs, rhs in
                if lhs.element.severity != rhs.element.severity {
                    return lhs.element.severity < rhs.element.severity
                }
                return lhs.offset > rhs.offset
            }?
            .element
    }

    /// 出现次数最多的错误类型（用于「你最近总在时态上出错」这类提示）。
    public var dominantCategory: GrammarErrorCategory? {
        var counts: [GrammarErrorCategory: Int] = [:]
        for error in errors { counts[error.category, default: 0] += 1 }
        return counts.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            // 平票时按枚举声明顺序取靠前的，保证确定性。
            let order = GrammarErrorCategory.allCases
            return (order.firstIndex(of: lhs.key) ?? 0) > (order.firstIndex(of: rhs.key) ?? 0)
        }?.key
    }
}

// MARK: - Grammar Agent（纯函数）

/// 把老师标注的纠错转成结构化分析。
///
/// **不发任何模型请求**：分类靠规则表，判重靠历史指纹。
/// 规则是刻意「保守」的——拿不准的一律落到 `other`，而不是猜一个漂亮但错的类型；
/// 猜错的类型会污染「反复错误」统计，比不分类更糟。
public enum GrammarAgent {

    /// 判定「反复出现」的阈值：同一个错误模式累计达到这个次数才算。
    public static let repeatedThreshold = 2

    /// - Parameters:
    ///   - corrections: 本轮老师标注的纠错（来自 `[[FIX]]` 解析）。
    ///   - history: 历史纠错记录（**约定时间新 → 旧**，与数据库查询一致）。
    ///   - repeatedThreshold: 累计多少次算「反复」。
    public static func analyze(
        corrections: [GrammarCorrection],
        history: [CorrectionRecord] = [],
        repeatedThreshold: Int = GrammarAgent.repeatedThreshold
    ) -> GrammarAnalysis {
        guard !corrections.isEmpty else { return .clean }

        // 历史指纹计数：一条历史记录算一次。
        var seen: [String: Int] = [:]
        for record in history {
            let pattern = Self.pattern(original: record.correction.original, corrected: record.correction.corrected)
            guard !pattern.isEmpty else { continue }
            seen[pattern, default: 0] += 1
        }

        var errors: [GrammarError] = []
        for correction in corrections {
            let original = correction.original.trimmingCharacters(in: .whitespacesAndNewlines)
            let corrected = correction.corrected.trimmingCharacters(in: .whitespacesAndNewlines)
            // 空 / 无变化的一律不算错误：老师偶尔会标出一行「原句 => 同一句」，
            // 把它当错误会让「重复错误」统计被垃圾数据带偏。
            guard !original.isEmpty, !corrected.isEmpty,
                  MemoryRetriever.normalize(original) != MemoryRetriever.normalize(corrected) else { continue }

            let pattern = Self.pattern(original: original, corrected: corrected)
            let priorCount = seen[pattern, default: 0]
            seen[pattern] = priorCount + 1

            let category = classify(original: original, corrected: corrected)
            errors.append(
                GrammarError(
                    original: original,
                    corrected: corrected,
                    category: category,
                    severity: severity(category: category, original: original, corrected: corrected),
                    explanation: correction.explanation.trimmingCharacters(in: .whitespacesAndNewlines),
                    pattern: pattern,
                    // 历史里已经攒过一次以上，或本批里这是第二次出现 → 反复。
                    isRepeated: priorCount + 1 >= repeatedThreshold
                )
            )
        }
        return GrammarAnalysis(errors: errors)
    }

    /// 错误指纹：归一后的「原句\x01改正」。判重与历史统计共用同一个口径。
    ///
    /// 用 `matchKey`（忽略大小写 / 空白 / 标点）而不是 `normalize`：
    /// 同一处错误被老师标成 `He go home.` 还是 `he go home`，说的都是同一处，
    /// 标点差异不该被当成两处错误，否则「反复错误」永远攒不起来。
    static func pattern(original: String, corrected: String) -> String {
        let lhs = MemoryRetriever.matchKey(original)
        let rhs = MemoryRetriever.matchKey(corrected)
        guard !lhs.isEmpty, !rhs.isEmpty else { return "" }
        return lhs + "\u{1}" + rhs
    }

    // MARK: - 分类规则

    /// 分类：先看「是不是同词不同序」，再逐词比对替换，最后看增删词。
    ///
    /// 比对一律用**去掉标点**的词形：`"I to school go." → "I go to school."` 里
    /// `go.` 与 `go` 是同一个词，带着句点比会把语序问题误判成用词问题。
    static func classify(original: String, corrected: String) -> GrammarErrorCategory {
        let lhsBare = stripPunctuation(words(original))
        let rhsBare = stripPunctuation(words(corrected))
        guard !lhsBare.isEmpty, !rhsBare.isEmpty else { return .other }

        // ① 只差标点。
        if lhsBare == rhsBare { return .punctuation }

        // ② 词集合相同但顺序不同 → 语序。
        if lhsBare.count == rhsBare.count, Set(lhsBare) == Set(rhsBare), lhsBare != rhsBare {
            return .wordOrder
        }

        // ③ 词数相同：逐位比对，按**第一处**替换定类型（老师一次标一处，第一位最有代表性）。
        if lhsBare.count == rhsBare.count {
            for (lhs, rhs) in zip(lhsBare, rhsBare) where lhs != rhs {
                if let category = replacementCategory(from: lhs, to: rhs) { return category }
            }
            return .other
        }

        // ④ 词数不同 → 增删。按「删了什么 / 加了什么」判。
        let removed = multisetDifference(lhsBare, rhsBare)
        let added = multisetDifference(rhsBare, lhsBare)
        if let category = insertionCategory(removed: removed, added: added) {
            return category
        }
        return .other
    }

    /// 单词替换的类型判定。表都很小，只覆盖教学中高频的那几类。
    ///
    /// ⚠️ **顺序有讲究**：先判动词变位，再判单复数。
    /// `go → goes` 既是「加了个 s」也是第三人称单数 —— 如果先按「加 s = 复数」判，
    /// 就会把动词变位标成单复数，学员看到的解释会完全跑偏。
    private static func replacementCategory(from lhs: String, to rhs: String) -> GrammarErrorCategory? {
        let lhsLower = lhs.lowercased()
        let rhsLower = rhs.lowercased()

        if irregularVerbs.contains(where: { $0.pair(lhsLower, rhsLower) }) { return .verbTense }
        if thirdPerson(of: lhsLower) == rhsLower || thirdPerson(of: rhsLower) == lhsLower { return .verbAgreement }
        if pluralForm(of: lhsLower) == rhsLower || pluralForm(of: rhsLower) == lhsLower { return .pluralNumber }
        if prepositions.contains(lhsLower), prepositions.contains(rhsLower) { return .preposition }
        if pronouns.contains(lhsLower), pronouns.contains(rhsLower) { return .pronoun }
        if articles.contains(lhsLower), articles.contains(rhsLower) { return .article }
        // 形近词（长度 >= 4 且编辑距离 <= 2）→ 拼写。
        if lhsLower.count >= 4, rhsLower.count >= 4, editDistance(lhsLower, rhsLower) <= 2 { return .spelling }
        return .wordChoice
    }

    /// 常见动词的第三人称单数形式（不在表里的词返回 nil = 不做这个判断）。
    ///
    /// 只覆盖高频动词：与其用「以 s 结尾就是三单」这种宽泛启发式把名词复数全误判掉，
    /// 不如老实说「这个词我不认识」。
    static func thirdPerson(of word: String) -> String? {
        guard commonVerbs.contains(word) else { return nil }
        if word == "have" { return "has" }
        if word == "be" { return "is" }
        // go / do 的拼写变化没有规律可循（不是 +s 也不是 +es），单独列出。
        if word == "go" { return "goes" }
        if word == "do" { return "does" }
        if word.hasSuffix("y"), word.count > 1 { return String(word.dropLast()) + "ies" }
        if word.hasSuffix("ch") || word.hasSuffix("sh") || word.hasSuffix("ss") || word.hasSuffix("x") {
            return word + "es"
        }
        return word + "s"
    }

    /// 增删词的类型判定。
    private static func insertionCategory(
        removed: [String],
        added: [String]
    ) -> GrammarErrorCategory? {
        let removedLower = removed.map { $0.lowercased() }
        let addedLower = added.map { $0.lowercased() }

        // 只加了冠词 → 冠词缺失。
        if !addedLower.isEmpty, addedLower.allSatisfy({ articles.contains($0) }), removedLower.isEmpty {
            return .article
        }
        // 只去掉了冠词 → 多余冠词，同属冠词类。
        if !removedLower.isEmpty, removedLower.allSatisfy({ articles.contains($0) }), addedLower.isEmpty {
            return .article
        }
        // 多出 / 少了词尾复数：原文里的某个词与改正里的某个词是同源单复数。
        for lhs in removedLower {
            if addedLower.contains(where: { pluralForm(of: lhs) == $0 || pluralForm(of: $0) == lhs }) {
                return .pluralNumber
            }
        }
        // 补齐 / 删掉了 be / have / do / will 这类助动词 → 时态。
        // 删掉助动词同样是时态问题（`I have went` → `I went`），不能只盯「加了什么」。
        let auxiliaries: Set<String> = ["am", "is", "are", "was", "were", "be", "been", "being",
                                        "have", "has", "had", "do", "does", "did", "will", "would"]
        if addedLower.contains(where: { auxiliaries.contains($0) }) { return .verbTense }
        if removedLower.contains(where: { auxiliaries.contains($0) }) { return .verbTense }
        if addedLower.contains(where: { prepositions.contains($0) }) { return .preposition }
        if addedLower.contains(where: { pronouns.contains($0) }) { return .pronoun }
        // 词数差得很多 → 漏了一整截，归为「其他」但严重度会上去（见 severity）。
        return nil
    }

    static func severity(
        category: GrammarErrorCategory,
        original: String,
        corrected: String
    ) -> GrammarErrorSeverity {
        let base = category.defaultSeverity
        let lengthDelta = abs(words(corrected).count - words(original).count)
        // 补/删 3 个词以上：已经影响理解。
        if lengthDelta >= 3 { return .major }
        // 语序错到 6 词以上的句子，读起来会跑偏。
        if category == .wordOrder, words(original).count >= 6 { return .major }
        return base
    }

    // MARK: - 小工具

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func stripPunctuation(_ words: [String]) -> [String] {
        words.map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters) }.filter { !$0.isEmpty }
    }

    /// `lhs` 里有而 `rhs` 里没有的（保持 lhs 顺序；重复词按次数扣减）。
    static func multisetDifference(_ lhs: [String], _ rhs: [String]) -> [String] {
        var pool: [String: Int] = [:]
        for word in rhs { pool[word, default: 0] += 1 }
        var result: [String] = []
        for word in lhs {
            if let count = pool[word], count > 0 {
                pool[word] = count - 1
            } else {
                result.append(word)
            }
        }
        return result
    }

    /// 规则的复数形式（只处理 s / es / ies / ves 这几种教学高频形态）。
    ///
    /// ⚠️ `es` 结尾**不能一律砍两个字母**：`apples` 砍掉 `es` 得到 `appl`，
    /// 于是 `apple → apples` 这条最普通的复数就被漏掉（转而被拼写规则捡走）。
    /// 只有词干真正以 s / x / z / ch / sh 收尾时（box→boxes、watch→watches），
    /// `es` 才是后缀；否则 `e` 属于词干本身，只掉末尾的 `s`。
    static func pluralForm(of word: String) -> String? {
        if word.hasSuffix("ies"), word.count > 3 { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("ves"), word.count > 3 { return String(word.dropLast(3)) + "f" }
        if word.hasSuffix("es"), word.count > 2 {
            let stem = String(word.dropLast(2))
            let takesEs = stem.hasSuffix("s") || stem.hasSuffix("x") || stem.hasSuffix("z")
                || stem.hasSuffix("ch") || stem.hasSuffix("sh")
            return takesEs ? stem : String(word.dropLast(1))
        }
        if word.hasSuffix("s"), !word.hasSuffix("ss"), word.count > 1 { return String(word.dropLast(1)) }
        return nil
    }

    /// Levenshtein 距离（带提前退出：超过 `limit` 直接返回 limit + 1）。
    static func editDistance(_ lhs: String, _ rhs: String, limit: Int = 3) -> Int {
        let lhsChars = Array(lhs), rhsChars = Array(rhs)
        if abs(lhsChars.count - rhsChars.count) > limit { return limit + 1 }
        var previous = Array(0...rhsChars.count)
        var current = [Int](repeating: 0, count: rhsChars.count + 1)
        for i in 1...lhsChars.count {
            current[0] = i
            var rowMin = current[0]
            for j in 1...rhsChars.count {
                let cost = lhsChars[i - 1] == rhsChars[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowMin = min(rowMin, current[j])
            }
            if rowMin > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[rhsChars.count]
    }
}

// MARK: - 规则表（刻意小：只放教学中反复出现的那些）

private struct IrregularVerbPair {
    let forms: Set<String>
    /// 两个词是否同属一个不规则动词的不同形态（且确实不同）。
    func pair(_ lhs: String, _ rhs: String) -> Bool {
        lhs != rhs && forms.contains(lhs) && forms.contains(rhs)
    }
}

private let irregularVerbs: [IrregularVerbPair] = [
    IrregularVerbPair(forms: ["go", "went", "gone"]),
    IrregularVerbPair(forms: ["have", "has", "had"]),
    IrregularVerbPair(forms: ["do", "does", "did", "done"]),
    IrregularVerbPair(forms: ["be", "am", "is", "are", "was", "were", "been"]),
    IrregularVerbPair(forms: ["eat", "ate", "eaten"]),
    IrregularVerbPair(forms: ["see", "saw", "seen"]),
    IrregularVerbPair(forms: ["take", "took", "taken"]),
    IrregularVerbPair(forms: ["come", "came", "come"]),
    IrregularVerbPair(forms: ["make", "made"]),
    IrregularVerbPair(forms: ["get", "got", "gotten"]),
    IrregularVerbPair(forms: ["know", "knew", "known"]),
    IrregularVerbPair(forms: ["buy", "bought"]),
    IrregularVerbPair(forms: ["bring", "brought"]),
    IrregularVerbPair(forms: ["think", "thought"]),
    IrregularVerbPair(forms: ["teach", "taught"]),
    IrregularVerbPair(forms: ["speak", "spoke", "spoken"]),
    IrregularVerbPair(forms: ["write", "wrote", "written"]),
    IrregularVerbPair(forms: ["run", "ran", "run"]),
    IrregularVerbPair(forms: ["drink", "drank", "drunk"]),
]

private let prepositions: Set<String> = [
    "in", "on", "at", "to", "for", "with", "by", "from", "of", "about",
    "into", "onto", "over", "under", "between", "among", "during", "since",
    "until", "before", "after", "across", "through", "against", "beside", "near",
]

private let pronouns: Set<String> = [
    "i", "me", "my", "mine", "myself",
    "you", "your", "yours", "yourself",
    "he", "him", "his", "himself",
    "she", "her", "hers", "herself",
    "it", "its", "itself",
    "we", "us", "our", "ours", "ourselves",
    "they", "them", "their", "theirs", "themselves",
]

private let articles: Set<String> = ["a", "an", "the"]

/// 常见动词（原形）。用于把「加 s/es」正确地区分成**第三人称单数**而不是复数。
private let commonVerbs: Set<String> = [
    "go", "do", "have", "be", "say", "make", "take", "come", "get", "know",
    "think", "see", "want", "need", "use", "work", "live", "like", "play", "study",
    "watch", "speak", "teach", "learn", "read", "write", "eat", "drink", "run", "walk",
    "help", "call", "ask", "tell", "give", "find", "feel", "look", "try", "carry",
]
