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
        /// 上传材料自动出题拆出来的生词表（#208）。
        case material
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

    /// 这个词在**那一天**复习过没有（`lastReviewedAt` 落在同一天）。
    public static func isReviewed(
        _ entry: VocabularyEntry,
        on day: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard let last = entry.lastReviewedAt else { return false }
        return calendar.startOfDay(for: last) == calendar.startOfDay(for: day)
    }

    /// 指定那**一天**复习过几个词（`lastReviewedAt` 落在同一天）。
    ///
    /// 用来回答「今天复习完了没有」—— 判分时落的是 `lastReviewedAt`，
    /// 所以这一项只能由真实记录算出来，不能让用户自己打勾。
    public static func reviewedCount(
        _ entries: [VocabularyEntry],
        on day: Date = Date(),
        calendar: Calendar = .current
    ) -> Int {
        entries.filter { isReviewed($0, on: day, calendar: calendar) }.count
    }

    // MARK: 当天起初的到期盘子（每日任务的固定指标）

    /// 指定那天**开始时**（0 点）到期的词。**每日任务那一项的指标只认它。**
    ///
    /// ⚠️ 为什么不能拿「此刻到期」（`dueEntries`）当每日任务的指标：
    /// 复习答对会把间隔拉长（`intervalDays`），于是「此刻到期」**随复习进行不断变小** ——
    /// 今天从「8 个」缩到 5 个、做完还整项消失。每日任务的指标是**当天定住**的量：
    /// 完成后显示 8/8，多复习的词不再计入口径，也不许回头改指标。
    ///
    /// 逐词判定「那一刻它到底在不在盘子里」：
    /// - **今天才入本的词不计**。今天 0 点时它还不在词汇本里，算进来只会让指标
    ///   随着「今天加了多少词」往上涨 —— 那是新增，不是今天的复习任务。
    /// - 今天之前就在本里、且**今天复习过**的词 → 计入。复习队列**只取到期词**
    ///   （`VocabularyReview.queue(from:)` 走的就是 `dueEntries`），
    ///   所以「今天碰过它」本身就证明它今天开始时到期 —— `lastReviewedAt`
    ///   被这次复习覆盖了，光看它反而会漏算。
    /// - 今天之前就在本里、今天没碰过的 → 用**今天 0 点**这个时刻判 `isDue`，
    ///   而不是用此刻：用此刻会让「今天刚满间隔的词」提前算进来、
    ///   也会让「昨天就该复习但拖到今天」的词时算时不算。
    public static func dueAtStartOfDayEntries(
        _ entries: [VocabularyEntry],
        day: Date = Date(),
        calendar: Calendar = .current
    ) -> [VocabularyEntry] {
        let midnight = calendar.startOfDay(for: day)
        return entries.filter { entry in
            guard entry.createdAt < midnight else { return false }
            if isReviewed(entry, on: day, calendar: calendar) { return true }
            return isDue(entry, now: midnight)
        }
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

    /// 近义词词条（英文 + 词性 + 中文），与重点单词共用同一条目结构。
    public var synonymTerms: [VocabularyTerm] {
        VocabularyTermParser.parseList(synonyms.joined(separator: "；"))
    }

    /// 反义词词条。
    public var antonymTerms: [VocabularyTerm] {
        VocabularyTermParser.parseList(antonyms.joined(separator: "；"))
    }

    /// 重点单词词条（词组 / 短句才有）。
    public var keywordTerms: [VocabularyTerm] {
        VocabularyTermParser.parseList(keywords)
    }

    /// 重点单词**展示**词条：必须是英文（用户口径：重点单词里出现纯中文一律不认）。
    /// 模型偶尔把中文释义塞进 keywords（实测：「你好、打招呼」），这类条目直接丢弃；
    /// 一个英文词都没有时整行不显示 —— 而不是渲染一行没有单词的「重点单词」。
    public var displayKeywordTerms: [VocabularyTerm] {
        keywordTerms.filter { !$0.word.isEmpty }
    }

    /// 需要补「词性 / 中文」的英文词条（近义词 / 反义词 / 重点单词三类合并去重）。
    ///
    /// 判定标准：**有英文但缺词性或缺中文** —— 这正是模型常见的残缺输出
    /// （实测重点单词回成 `precipitation, rainfall, drizzle`，三个词都没有词性和中文）。
    /// 只有中文没英文的条目**不进补全队列**：它连该补哪个词都不知道，直接不展示。
    public var termsNeedingCompletion: [VocabularyTerm] {
        var seen = Set<String>()
        return (synonymTerms + antonymTerms + keywordTerms).filter { term in
            guard !term.word.isEmpty else { return false }
            guard term.pos.isEmpty || term.translation.isEmpty else { return false }
            return seen.insert(term.word.lowercased()).inserted
        }
    }

    /// 用补全结果重写三类词条（顺序不变，已补到的字段覆盖，其余保持原样）。
    /// 重点单词顺带走 `displayKeywordTerms`（纯中文条目就此清除）。
    public func patched(with completed: [String: VocabularyTerm]) -> VocabularyDefinition {
        func patch(_ terms: [VocabularyTerm]) -> [VocabularyTerm] {
            terms.map { term in
                guard let filled = completed[term.word.lowercased()] else { return term }
                return VocabularyTerm(
                    word: term.word.isEmpty ? filled.word : term.word,
                    pos: term.pos.isEmpty ? filled.pos : term.pos,
                    translation: term.translation.isEmpty ? filled.translation : term.translation
                )
            }
        }
        var copy = self
        copy.synonyms = patch(synonymTerms).map(\.displayText)
        copy.antonyms = patch(antonymTerms).map(\.displayText)
        copy.keywords = patch(displayKeywordTerms).map(\.displayText).joined(separator: "、")
        return copy
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

// MARK: - 词条（近义词 / 反义词 / 重点单词的展示单元）

/// 一条「英文 + 词性 + 中文」词条。**近义词 / 反义词 / 重点单词共用同一结构**，
/// 三处排版因此完全一致。
///
/// 模型输出并不总是完整，实测出现过两种残缺：
/// ① 只有英文（+ 词性）没有中文 —— 卡片上就是个光秃秃的 `cycle (n.)`；
/// ② 只有中文没有英文 —— 出现孤零零的「（n.）循环」。
/// 解析器把能认出来的部分各归各位，UI 只渲染**存在**的部分，
/// 因此不会再出现半截括号或只有一个词性的怪模样。
public struct VocabularyTerm: Sendable, Equatable, Identifiable {
    /// 英文词（可能为空）。
    public var word: String
    /// 词性，如 `n.` / `adj.`（可空）。
    public var pos: String
    /// 中文翻译（可能为空）。
    public var translation: String

    public init(word: String = "", pos: String = "", translation: String = "") {
        self.word = word.trimmingCharacters(in: .whitespaces)
        self.pos = pos.trimmingCharacters(in: .whitespaces)
        self.translation = translation.trimmingCharacters(in: .whitespaces)
    }

    public var id: String { "\(word)|\(pos)|\(translation)" }

    /// 三个字段全空。
    public var isEmpty: Bool { word.isEmpty && pos.isEmpty && translation.isEmpty }

    /// 英文与中文都在（完整词条）；只有一个的属于残缺输出。
    public var isComplete: Bool { !word.isEmpty && !translation.isEmpty }

    /// 纯文本形态（无障碍标签 / 日志 / 测试断言用）。
    public var displayText: String {
        var parts: [String] = []
        if !word.isEmpty {
            parts.append(pos.isEmpty ? word : "\(word) (\(pos))")
        } else if !pos.isEmpty {
            parts.append("(\(pos))")
        }
        if !translation.isEmpty { parts.append(translation) }
        return parts.joined(separator: " ")
    }
}

/// 词条解析（**纯函数**）：把模型给的「word (pos) 中文」半结构化文本拆成词条。
///
/// 认得的写法（混排、缺项都行）：
/// - `take (v.) 拿`（完整）
/// - `take 拿`（没有词性）
/// - `take (v.)`（缺中文 —— 只保留英文与词性，不再拼出空括号）
/// - `拿`（缺英文 —— 只渲染中文，不凭空造词性）
public enum VocabularyTermParser {

    /// 条目分隔符：中文顿号 / 分号、英文分号、竖线、换行。
    /// （半角 / 全角逗号另算：只有后面紧跟新的英文词时才当分隔符，见 `startsNewEnglishWord`。）
    public static let separators: Set<Character> = ["；", ";", "、", "|", "\n"]

    /// 一整段文本 → 词条列表（空条目自动丢弃）。
    /// 括号内的分隔符不算分隔符（挡住 `(adj./n.)` 这类词性被劈开）。
    public static func parseList(_ raw: String) -> [VocabularyTerm] {
        let characters = Array(raw)
        var chunks: [String] = []
        var current = ""
        var depth = 0
        for (index, character) in characters.enumerated() {
            if character == "(" || character == "（" {
                depth += 1
            } else if character == ")" || character == "）" {
                depth = max(depth - 1, 0)
            }
            let isSeparator = depth == 0 && (
                separators.contains(character)
                    || (isComma(character) && startsNewEnglishWord(characters, after: index))
            )
            if isSeparator {
                chunks.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        chunks.append(current)
        return chunks
            .map { parse($0) }
            .filter { !$0.isEmpty }
    }

    /// 半角 / 全角逗号。
    static func isComma(_ character: Character) -> Bool {
        character == "," || character == "，"
    }

    /// 逗号后面（跳过空格）是不是一个新的**英文词**开头。
    ///
    /// 实测模型会把重点单词写成 `precipitation, rainfall, drizzle, drought` —— 用逗号分隔，
    /// 旧解析器整段当成一个词条的翻译，于是四个词只剩一个「单词 + 一串英文翻译」。
    /// 反过来，中文翻译内部的「，」（如 `拿，拿住`）后面不是英文，因此不会被误切。
    static func startsNewEnglishWord(_ characters: [Character], after index: Int) -> Bool {
        var cursor = index + 1
        while cursor < characters.count, characters[cursor] == " " { cursor += 1 }
        guard cursor < characters.count else { return false }
        let next = characters[cursor]
        return next.isASCII && next.isLetter
    }

    /// 单条文本 → 词条。
    public static func parse(_ raw: String) -> VocabularyTerm {
        var text = stripLeadingNumbering(raw.trimmingCharacters(in: .whitespaces))
        var pos = ""

        // 先抠词性：半角 (…) 与全角（…）都认。
        for (open, close) in [("(", ")"), ("（", "）")] {
            guard let openIndex = text.firstIndex(of: Character(open)),
                  let closeIndex = text[openIndex...].firstIndex(of: Character(close)),
                  closeIndex > openIndex
            else { continue }
            let inner = String(text[text.index(after: openIndex)..<closeIndex])
                .trimmingCharacters(in: .whitespaces)
            // 「(n.)」「( n. )」都认；空括号不算词性。
            if !inner.isEmpty { pos = inner }
            text.removeSubrange(openIndex...closeIndex)
            break
        }
        text = text.trimmingCharacters(in: .whitespaces)

        // 英文段 = 开头连续的一串「英文词字符」（词组里的空格算同一段）。
        let characters = Array(text)
        var index = 0
        while index < characters.count, isEnglishCharacter(characters[index]) { index += 1 }
        let word = String(characters[0..<index]).trimmingCharacters(in: .whitespaces)
        let rest = String(characters[index...]).trimmingCharacters(in: .whitespaces)
        // 剩下的整段当作中文翻译（可能为空，也可能还夹着标点）。
        return VocabularyTerm(word: word, pos: pos, translation: rest)
    }

    /// 英文词字符：ASCII 字母 / 数字 / 空格 / 连字符 / 撇号 / 斜杠。
    /// 故意**不含中文**，这样中文开头（只有翻译的残缺条目）会落进 translation。
    static func isEnglishCharacter(_ character: Character) -> Bool {
        guard character.isASCII else { return false }
        return character.isLetter || character.isNumber
            || character == " " || character == "-" || character == "'" || character == "/"
    }

    /// 去掉「1. 」「2、」「3)」这类序号前缀（模型偶尔会加上）。
    static func stripLeadingNumbering(_ raw: String) -> String {
        let characters = Array(raw)
        var index = 0
        while index < characters.count, characters[index].isNumber { index += 1 }
        guard index > 0, index < characters.count,
              [".", "、", ")", "）", ":", "："].contains(String(characters[index]))
        else { return raw }
        return String(characters[(index + 1)...]).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - 词条补全（缺词性 / 中文时定向问模型）

/// 「给这几个英文词补词性 + 中文」请求的解析（**纯函数**）。
///
/// 提示词要求每行一条 `word||pos||中文`（`||` 是唯一分隔符，字段里不会再出现）。
/// 模型偶尔不听话，因此容错：
/// - 分隔符认 `||` / `|` / 全角 `｜`；
/// - 行首项目符号（`- ` / `* ` / `1. `）与两端空格先剥掉；
/// - 没有分隔符的行退回按 `word (pos) 中文` 解析；
/// - 字段名回显（`word|pos|translation` 这种标签行）直接丢弃。
public enum VocabularyTermCompletion {

    /// 行内字段分隔符（长的优先）。
    public static let fieldSeparators = ["||", "|", "｜"]

    /// 模型输出 → [小写英文词: 词条]。
    public static func parse(_ raw: String) -> [String: VocabularyTerm] {
        var result: [String: VocabularyTerm] = [:]
        for line in raw.split(whereSeparator: \.isNewline) {
            guard let term = parseLine(String(line)), !term.word.isEmpty else { continue }
            result[term.word.lowercased()] = term
        }
        return result
    }

    /// 单行 → 词条（认不出返回 nil）。
    static func parseLine(_ raw: String) -> VocabularyTerm? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        text = VocabularyTermParser.stripLeadingNumbering(text)
        text = stripBullet(text)
        guard !text.isEmpty else { return nil }

        if let parts = splitFields(text) {
            let word = parts[0].trimmingCharacters(in: .whitespaces)
            let pos = parts.count > 1 ? normalizing(parts[1]) : ""
            let translation = parts.count > 2 ? normalizing(parts[2]) : ""
            guard !isFieldName(word) else { return nil }
            return VocabularyTerm(word: word, pos: pos, translation: translation)
        }

        // 没有分隔符：退回半结构化解析（`rainfall (n.) 降雨`）。
        let term = VocabularyTermParser.parse(text)
        guard !term.word.isEmpty else { return nil }
        return term
    }

    /// 按 `||` / `|` / `｜` 切成至多 3 段（没有分隔符返回 nil）。
    static func splitFields(_ text: String) -> [String]? {
        for separator in fieldSeparators {
            let parts = text.components(separatedBy: separator)
            if parts.count >= 2 {
                // `word || pos || 中文` 这种带空格的写法照样切对。
                return parts.count > 3 ? Array(parts[0...1] + [parts[2...].joined(separator: separator)]) : parts
            }
        }
        return nil
    }

    /// 去掉行首项目符号。
    static func stripBullet(_ text: String) -> String {
        var result = text
        while let first = result.first, "-*•—–".contains(first) {
            result.removeFirst()
            result = result.trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    /// 字段值清洗：去空白、去掉模型多写的引号。
    static func normalizing(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
            .trimmingCharacters(in: .whitespaces)
    }

    /// 字段名回显防御（`word` / `pos` / `translation` 这些标签不能当内容）。
    static func isFieldName(_ raw: String) -> Bool {
        let key = raw.lowercased().trimmingCharacters(in: .whitespaces)
        return ["word", "pos", "translation", "meaning", "chinese", "中文", "词性"].contains(key)
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
/// 规则：每次最多 12 个 —— 3 简单 / 5 中等 / 2 困难 / 2 词组（雅思标准）；
/// 从词库对应档位里随机抽，排除指定集合（刷新时排除当前展示的一批 + 已认熟的词）。
///
/// **等级补齐**：某档的词全被认熟（`excluding` 里已无该档可用词）时该档不再出词，
/// 它的配额空缺由**还没学完的最低档**顶上（中/困学完 → 简单补；简单学完 → 中等补；
/// 简 + 中完 → 只剩困难）。词库整体不够时有多少给多少，不凑数。
public enum DailyWordPicker {
    /// 词组档难度值。
    public static let phraseDifficulty = 4
    /// 每次推荐的配额（难度 1/2/3/4 → 个数）。
    public static let quota: [Int: Int] = [1: 3, 2: 5, 3: 2, 4: 2]

    /// 难度档顺序（补齐时按「最低档优先」遍历）。
    public static let levelOrder: [Int] = [1, 2, 3, phraseDifficulty]

    /// 每次推荐的总数。
    public static var total: Int { quota.values.reduce(0, +) }

    /// 从词库抽一组每日推荐（可注入随机源，便于单测）。
    public static func pick<R: RandomNumberGenerator>(
        from bank: [DailyWord],
        excluding: Set<String> = [],
        using generator: inout R
    ) -> [DailyWord] {
        pick(fromSources: [bank], excluding: excluding, using: &generator)
    }

    /// 从**多本词典**抽一组（按优先级给定顺序，词典库选定的词源用这个入口）。
    ///
    /// 优先级的体现：每本词典先各自按档位打乱，再按传入顺序首尾相接成「同一档的大池子」——
    /// 同一档里排在前面的是优先级高的词典，配额自然先被它满足，不够才轮到下一本。
    /// 一本词典里的词不会挤掉另一本的同名词（最后统一按词去重）。
    public static func pick<R: RandomNumberGenerator>(
        fromSources sources: [[DailyWord]],
        excluding: Set<String> = [],
        using generator: inout R
    ) -> [DailyWord] {
        var pools: [Int: [DailyWord]] = [:]
        for source in sources {
            let available = source.filter { !excluding.contains($0.word.lowercased()) }
            for level in levelOrder {
                pools[level, default: []].append(
                    contentsOf: available.filter { $0.difficulty == level }.shuffled(using: &generator)
                )
            }
        }
        return select(from: pools)
    }

    // MARK: 按天恒定（种子派生）

    /// 按**种子**抽一组：同一个种子必定抽出同一批词。
    ///
    /// 每日推荐「同一天打开很多次都看到同一批」靠的就是它 ——
    /// 种子由 `DailySeed.seed(dayKey:language:)` 从日期派生，纯函数、不落盘。
    public static func pick(
        fromSources sources: [[DailyWord]],
        excluding: Set<String> = [],
        seed: UInt64
    ) -> [DailyWord] {
        var rng = SeededRandomGenerator(seed: seed)
        return pick(fromSources: sources, excluding: excluding, using: &rng)
    }

    /// 单本词库的按种子入口（与上面多本入口同一套配额 / 补齐 / 去重规则）。
    public static func pick(from bank: [DailyWord], excluding: Set<String> = [], seed: UInt64) -> [DailyWord] {
        var rng = SeededRandomGenerator(seed: seed)
        return pick(from: bank, excluding: excluding, using: &rng)
    }

    /// 按配额抽词 + 缺口补齐（抽词规则见本类型文档）。
    static func select(from pools: [Int: [DailyWord]]) -> [DailyWord] {
        var picked: [Int: [DailyWord]] = [:]
        var deficit = 0
        for level in levelOrder {
            let pool = pools[level] ?? []
            let want = quota[level] ?? 0
            picked[level] = Array(pool.prefix(min(want, pool.count)))
            // 这一档学完了（可用词不足配额）→ 缺多少记下来给别人补。
            deficit += max(want - pool.count, 0)
        }

        // 缺口由**还没学完的最低档**依次顶上（低档先补，补不动再轮到下一档）。
        for level in levelOrder where deficit > 0 {
            let pool = pools[level] ?? []
            let used = picked[level]?.count ?? 0
            let spare = pool.count - used
            guard spare > 0 else { continue }
            let extra = min(spare, deficit)
            picked[level, default: []].append(contentsOf: pool[used..<(used + extra)])
            deficit -= extra
        }

        // 同名词可能同时长在多本词典里 —— 出结果前按词去重，不让它占两个名额。
        var seen = Set<String>()
        var result: [DailyWord] = []
        for level in levelOrder {
            for word in picked[level] ?? [] where !seen.contains(word.word.lowercased()) {
                seen.insert(word.word.lowercased())
                result.append(word)
            }
        }
        return result
    }

    /// 便捷入口（系统随机源）。
    public static func pick(from bank: [DailyWord], excluding: Set<String> = []) -> [DailyWord] {
        var rng = SystemRandomNumberGenerator()
        return pick(from: bank, excluding: excluding, using: &rng)
    }

    /// 便捷入口（多本词典，系统随机源）。
    public static func pick(fromSources sources: [[DailyWord]], excluding: Set<String> = []) -> [DailyWord] {
        var rng = SystemRandomNumberGenerator()
        return pick(fromSources: sources, excluding: excluding, using: &rng)
    }
}

/// 收起态的翻页（**纯函数**）。
///
/// 产品口径：每日推荐收起时**完整展示 4 张卡**（2 行 × 2 列），右侧用上下按钮翻页；
/// 早先用「固定高度 + 滚动条」，第二排只露一半，所以改成整页翻。
public enum DailyWordPager {
    /// 每页卡片数。
    public static let pageSize = 4

    /// 总页数（不足一页也算一页）。
    public static func pageCount(_ words: [DailyWord], pageSize: Int = pageSize) -> Int {
        max((words.count + pageSize - 1) / pageSize, 1)
    }

    /// 第 `index` 页的词（越界页码夹到最后一页，不崩不空屏）。
    public static func page(_ words: [DailyWord], index: Int, pageSize: Int = pageSize) -> [DailyWord] {
        guard !words.isEmpty else { return [] }
        let lastPage = pageCount(words, pageSize: pageSize) - 1
        let start = min(max(index, 0), lastPage) * pageSize
        return Array(words[start..<min(start + pageSize, words.count)])
    }

    /// 把一页的词切成若干行（每行 `perRow` 个）—— 收起态 2×2 布局用。
    ///
    /// 用普通行列而不是 `LazyVGrid` 的理由见 `VocabularyView.dailyGrid`：
    /// 懒容器的子视图不参与过渡动画，卡片滑走了按钮却留在原地。
    public static func rows(_ words: [DailyWord], perRow: Int = 2) -> [[DailyWord]] {
        guard perRow > 0 else { return words.isEmpty ? [] : [words] }
        return stride(from: 0, to: words.count, by: perRow).map {
            Array(words[$0..<min($0 + perRow, words.count)])
        }
    }
}

// MARK: - 统计

/// 词汇统计（页面头部 / 学习记录）。
public struct VocabularyStats: Sendable, Equatable {
    public var total: Int
    /// **此刻**到期的词数（词汇页头部那个「待复习 N」就是这个）。
    ///
    /// ⚠️ 每日任务那一项**不许**用它：复习答对会把间隔拉长，它会随复习变小。
    public var due: Int
    public var mastered: Int
    /// 有中文释义的词数（释义是按需补的，这里让用户知道还剩多少没配）。
    public var defined: Int

    /// **今天起初**（0 点）到期的词数 —— 每日任务那一项用的**固定指标**。
    ///
    /// 与 `due`（此刻到期）是两回事：后者会随复习变小，拿它当每日任务的指标
    /// 就会出现「今天原本 8 个，做完变成 5/5，全做完整项消失」。
    /// 口径见 `ReviewScheduler.dueAtStartOfDayEntries(_:day:calendar:)`。
    public var dueAtDayStart: Int
    /// `dueAtDayStart` 那批词里**今天已经复习过**的个数 —— 今日任务的完成度。
    ///
    /// 单独算，而不是直接用全局的「今天复习了几个不同词」（`vocabularyReviewedToday`）：
    /// 今天新加的词被复习了也**不算**这个指标的进度。
    /// 用户口径原话：「完成了表示今天已经达标，多完成的不应该再计入」。
    public var dueAtDayStartReviewed: Int

    public init(
        total: Int,
        due: Int,
        mastered: Int,
        defined: Int,
        dueAtDayStart: Int,
        dueAtDayStartReviewed: Int
    ) {
        self.total = total
        self.due = due
        self.mastered = mastered
        self.defined = defined
        self.dueAtDayStart = dueAtDayStart
        self.dueAtDayStartReviewed = dueAtDayStartReviewed
    }

    public static let empty = VocabularyStats(
        total: 0, due: 0, mastered: 0, defined: 0,
        dueAtDayStart: 0, dueAtDayStartReviewed: 0
    )

    public static func from(
        _ entries: [VocabularyEntry],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> VocabularyStats {
        // 今日指标那一批先取出来：完成度要在**同一批词**里数，
        // 不能拿全局的「今天复习了几个」顶替（那会把今天新加的词也算进来）。
        let dayStartDue = ReviewScheduler.dueAtStartOfDayEntries(entries, day: now, calendar: calendar)
        return VocabularyStats(
            total: entries.count,
            due: ReviewScheduler.dueEntries(entries, now: now).count,
            mastered: entries.filter(\.isMastered).count,
            defined: entries.filter { !$0.meaning.isEmpty }.count,
            dueAtDayStart: dayStartDue.count,
            dueAtDayStartReviewed: dayStartDue.filter {
                ReviewScheduler.isReviewed($0, on: now, calendar: calendar)
            }.count
        )
    }
}
