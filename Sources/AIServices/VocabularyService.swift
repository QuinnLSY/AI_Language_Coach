import AIDomain
import AIInfrastructure
import AIInterfaces
import AppCore
import Foundation

/// 释义解析规则（纯函数，便于单测）。**词汇本与每日推荐共用同一套解析**。
///
/// 模型被要求按「键值行」回复：
/// ```
/// phonetic: /səbˈstænʃl/
/// pos: adj.
/// meaning: 大量的；实质性的；重要的
/// explanation: 强调数量或程度超出一般，多用于正式书面语境。
/// example: The government made substantial changes to the education policy.
/// translation: 政府对教育政策做出了重大调整。
/// synonyms: considerable、significant
/// antonyms: slight、minor
/// keywords: -
/// ```
/// 键值格式相比位置格式的好处：**缺字段只是少一行**（位置格式一缺就整体错位），
/// 允许值里出现换行与冒号，也天然支持「中文义项 / 中文解释分行」。
///
/// 健壮性处理（都是实测踩过的坑）：
/// - 剥围栏、去空行、容忍模型先客气一句；
/// - 键名归一化（大小写、下划线、中英文冒号、`-`/`*` 前缀、中文键名都能认）；
/// - **字段名回显防御**：值是字段名本身（`meaning: MEANING`）时视为缺席，
///   而不是把 "MEANING" 当成释义落库（qwen3:8b 实测出现过）；
/// - 认不出键值时回退旧格式（`||` 分段、整段纯文本），历史数据照旧能看。
public enum VocabularyDefinitionRule {

    /// 字段（与 `VocabularyDefinition` 一一对应）。
    enum Field: Hashable {
        case phonetic, pos, meaning, explanation, example
        case translation, synonyms, antonyms, keywords
    }

    // MARK: - 键名

    /// 键名归一化：去装饰前缀 / 下划线 / 空格，统一小写。
    static func normalizeKey(_ raw: String) -> String {
        var key = raw.trimmingCharacters(in: .whitespaces)
        while let first = key.first, "-*•#·>".contains(first) {
            key = String(key.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return key
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }

    /// 键名 → 字段（认英文键、旧版大写键与常见中文键）。
    static func field(forKey raw: String) -> Field? {
        switch normalizeKey(raw) {
        case "phonetic", "ipa", "pronunciation", "音标": .phonetic
        case "pos", "partofspeech", "词性": .pos
        case "meaning", "meanings", "sense", "senses", "definition", "释义", "词义", "中文释义", "中文翻译", "意思", "含义":
            .meaning
        case "explanation", "usage", "note", "notes", "解释", "说明", "用法", "辨析": .explanation
        case "example", "sentence", "例句": .example
        case "translation", "exampletranslation", "extranslation", "例句翻译", "译文", "翻译": .translation
        case "synonyms", "synonym", "syn", "近义词", "同义词": .synonyms
        case "antonyms", "antonym", "ant", "反义词": .antonyms
        case "keywords", "keyword", "keys", "重点单词", "关键词": .keywords
        default: nil
        }
    }

    /// 该文本是否只是字段名（回显防御）。
    static func isPlaceholder(_ value: String) -> Bool {
        field(forKey: value) != nil
    }

    // MARK: - 音标（模型偶尔缺 / 只回一个「/」）

    /// 音标是否可用。模型实测出现过两种坏输出：整个字段空缺，以及**只回一个斜杠** `"/"`。
    /// 判据刻意宽松：至少 3 个字符且含字母（`/ˈhɒbi/`、`[ˈhɒbi]` 都算可用）。
    public static func isUsablePhonetic(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard value.count >= 3 else { return false }
        return value.contains(where: { $0.isLetter })
    }

    /// 从任意文本里捞出第一个像样的音标片段（`/…/`）。
    ///
    /// 用途：模型有时把音标写到别的行（或写成没带键的裸行），此时按「键值行」解析会丢掉它；
    /// 这里做一次兜底搜捕，救回来的音标胜过没有音标。
    public static func phoneticCandidate(in text: String) -> String? {
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            guard characters[index] == "/" else { index += 1; continue }
            var end = index + 1
            while end < characters.count, characters[end] != "/", end - index <= 40 {
                end += 1
            }
            if end < characters.count, characters[end] == "/", end > index + 1 {
                let candidate = String(characters[index...end])
                let inner = String(characters[(index + 1)..<end])
                // 音标里不会有空格与中文；靠这两条把「A/B」「and/or」这类斜杠写法挡掉。
                let hasCJK = inner.contains { $0.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }
                if isUsablePhonetic(candidate), !hasCJK,
                   !inner.contains(where: { $0.isWhitespace }), inner.count <= 24 {
                    return candidate
                }
            }
            index = end + 1
        }
        return nil
    }

    /// 拆「键: 值」。键必须短且只由字母 / 中文 / 下划线组成（允许 `-`/`*` 装饰前缀），
    /// 免得把英文例句里的冒号误当分隔符（那行会落到「自由文本」里，不丢内容）。
    static func splitKeyed(_ line: String) -> (key: String, value: String)? {
        guard let index = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return nil }
        let rawKey = String(line[line.startIndex..<index]).trimmingCharacters(in: .whitespaces)
        guard !rawKey.isEmpty, rawKey.count <= 26 else { return nil }
        let key = normalizeKey(rawKey)
        guard !key.isEmpty, key.count <= 24,
              key.allSatisfy({ $0.isLetter || $0 == "_" })
        else { return nil }
        let value = String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    // MARK: - 解析

    /// 解析模型输出（也用于落库文本，落库文本请先过 `sanitizedStoredMeaning`）。
    ///
    /// 认不出任何结构时整段文字进 `legacyText`（UI 按一段释义展示，不会丢内容）。
    public static func parse(_ raw: String) -> VocabularyDefinition {
        var definition = VocabularyDefinition()
        let lines = raw
            .replacingOccurrences(of: "```", with: "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var unlabeled: [String] = []
        var foundKeyed = false
        for line in lines {
            guard let (key, value) = splitKeyed(line), let field = field(forKey: key) else {
                unlabeled.append(line)
                continue
            }
            foundKeyed = true
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            // 空值 / `-` / 字段名回显 → 该字段视为缺席。
            guard !trimmed.isEmpty, trimmed != "-", !isPlaceholder(trimmed) else { continue }
            switch field {
            case .phonetic:
                // 只回一个「/」或其它没有字母的垃圾值时视为缺席（否则卡片上会显示一个孤零零的斜杠）。
                if isUsablePhonetic(trimmed) { definition.phonetic = trimmed }
            case .pos: definition.pos = trimmed
            case .meaning: definition.senses = trimmed
            case .explanation: definition.explanation = trimmed
            case .example: definition.example = trimmed
            case .translation: definition.exampleTranslation = trimmed
            case .synonyms: definition.synonyms = list(trimmed)
            case .antonyms: definition.antonyms = list(trimmed)
            case .keywords: definition.keywords = strippedKeywordLabel(trimmed)
            }
        }

        guard foundKeyed else { return legacyDefinition(from: lines) }

        // 音标兜底搜捕：模型把音标写到了没带键的行里（或干脆忘了键名），这里救回来。
        if definition.phonetic.isEmpty,
           let rescued = phoneticCandidate(in: lines.joined(separator: " ")) {
            definition.phonetic = rescued
        }

        // 键值行之外还剩的**自由文本**（旧版落库的整段释义、模型没按格式回的段落）：
        // 结构里没有义项与解释时，整段落到 `legacyText` —— UI 原样展示那段文字，
        // 并给出「重新释义」入口升级格式（这样老词条的音标 / 词性 / 例句翻译才补得上）。
        let freeText = unlabeled.filter { !isPlaceholder($0) }.joined(separator: "\n")
        if definition.senses.isEmpty, definition.explanation.isEmpty, !freeText.isEmpty {
            definition.legacyText = freeText
        }
        return definition
    }

    /// 落库文本 → 结构；认不出结构时整段进 `legacyText`。
    public static func decodeStored(_ raw: String) -> VocabularyDefinition {
        parse(sanitizedStoredMeaning(raw))
    }

    /// 认不出键值时的旧格式回退：`||` 分段（v2 三段 / v1 六段），否则整段文字。
    private static func legacyDefinition(from lines: [String]) -> VocabularyDefinition {
        var definition = VocabularyDefinition()
        if let body = lines.first(where: { $0.contains("||") }) {
            let real = body
                .components(separatedBy: "||")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !isPlaceholder($0) }
            func segment(_ index: Int) -> String {
                guard index < real.count else { return "" }
                return real[index] == "-" ? "" : real[index]
            }
            if real.count >= 6 {
                // 每日推荐 v1：词性||释义||例句||例句翻译||近义词||反义词。
                definition.pos = segment(0)
                definition.senses = segment(1)
                definition.example = segment(2)
                definition.exampleTranslation = segment(3)
                definition.synonyms = list(segment(4))
                definition.antonyms = list(segment(5))
            } else {
                // 词汇本 v2：释义||例句||重点单词。
                definition.senses = segment(0)
                definition.example = segment(1)
                definition.keywords = segment(2)
            }
            if !definition.isEmpty {
                if definition.phonetic.isEmpty,
                   let rescued = phoneticCandidate(in: body) {
                    definition.phonetic = rescued
                }
                return definition
            }
        }
        definition.legacyText = lines.joined(separator: "\n")
        if let rescued = phoneticCandidate(in: definition.legacyText) {
            definition.phonetic = rescued
        }
        return definition
    }

    /// `keywords: 重点单词：xxx` 这种「值自带标签前缀」的坏值要去掉前缀，
    /// 否则 UI 会渲染成「重点单词 重点单词：xxx」重复两遍（qwen3:8b 实测出现过）。
    static func strippedKeywordLabel(_ raw: String) -> String {
        guard let index = raw.firstIndex(where: { $0 == ":" || $0 == "：" }), index > raw.startIndex else {
            return raw
        }
        let head = String(raw[raw.startIndex..<index]).trimmingCharacters(in: .whitespaces)
        guard field(forKey: head) == .keywords else { return raw }
        let rest = String(raw[raw.index(after: index)...]).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? raw : rest
    }

    /// 「considerable、significant」「-, minor」→ 有效词列表。
    ///
    /// ⚠️ **不按 `/` 拆**：近反义与重点单词现在带词性（`significant (adj./n.) 显著的`），
    /// 按 `/` 拆会把词性劈成两半。
    static func list(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "-" else { return [] }
        var chunks: [String] = []
        var current = ""
        var depth = 0
        for character in trimmed {
            if character == "(" || character == "（" {
                depth += 1
            } else if character == ")" || character == "）" {
                depth = max(depth - 1, 0)
            }
            if depth == 0, "、，,;；|".contains(character) {
                chunks.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        chunks.append(current)
        return chunks
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "-" }
    }

    // MARK: - 历史坏数据清洗

    /// 清洗历史坏数据：老版本解析器曾把字段名回显落库（释义=「MEANING」、
    /// 重点单词=「EXAMPLE」）。逐行剔除纯字段名行与值是字段名的键值行；
    /// 剔完为空 → 返回空串（UI 退回「还没有释义」，可重新查释义覆盖）。
    public static func sanitizedStoredMeaning(_ raw: String) -> String {
        let kept = raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard !line.isEmpty else { return false }
                if isPlaceholder(line) { return false }
                if let (key, value) = splitKeyed(line), field(forKey: key) != nil {
                    let trimmed = value.trimmingCharacters(in: .whitespaces)
                    // 「meaning: -」「example: EXAMPLE」这类空壳行整行剔除。
                    return !(trimmed.isEmpty || trimmed == "-" || isPlaceholder(trimmed))
                }
                return true
            }
        return kept.joined(separator: "\n")
    }
}

/// 按需释义的请求参数（与翻译 / 拼写纠正同风格：模型名与 token 上限由装配层决定）。
public struct VocabularyDefineOptions: Sendable {
    public var model: String?
    public var maxTokens: Int?

    public init(model: String? = nil, maxTokens: Int? = nil) {
        self.model = model
        self.maxTokens = maxTokens
    }
}

/// 词汇本（第 24 步 Vocabulary）：生词提取入库 / 复习调度 / 按需释义。
///
/// 职责切分（Plan §24 硬要求：复习逻辑与 UI 分离）：
/// - **调度与判分**在 `AIDomain.ReviewScheduler`（纯函数）；
/// - 本服务只做编排：读库、导入去重、判分落库、按需调 LLM 补释义。
public actor VocabularyService {

    private let llm: LLMManager
    private let learning: LearningDatabase?

    public init(llm: LLMManager, learning: LearningDatabase?) {
        self.llm = llm
        self.learning = learning
    }

    // MARK: - 读取

    /// 全部词汇（新 → 旧）。没有数据库时为空（UI 呈现可操作提示，不崩）。
    /// 读出时顺手清洗历史坏数据（字段名回显行），清完为空的词退回「还没有释义」，
    /// 可重新查释义覆盖。
    public func entries() async -> [VocabularyEntry] {
        guard let learning else { return [] }
        let loaded = (try? await learning.allVocabulary()) ?? []
        return loaded.map { entry in
            var cleaned = entry
            cleaned.meaning = VocabularyDefinitionRule.sanitizedStoredMeaning(entry.meaning)
            return cleaned
        }
    }

    /// 从复盘的 new_words 导入生词（按 word 去重，已有词的进度不动）。返回新词数。
    @discardableResult
    public func importFromReviews(limit: Int = 20) async -> Int {
        guard let learning else { return 0 }
        let reviews = (try? await learning.recentReviews(limit: limit)) ?? []
        var imported = 0
        for review in reviews {
            for word in review.newWords {
                let clean = Self.normalize(word)
                guard !clean.isEmpty else { continue }
                let entry = VocabularyEntry(word: clean, source: .review)
                if (try? await learning.upsertVocabulary(entry)) == true {
                    imported += 1
                }
            }
        }
        return imported
    }

    /// 手动添加一个词。已存在时返回已有的那条（UI 提示「已在词表里」）。
    public func add(word: String, meaning: String = "", source: VocabularyEntry.Source = .manual) async -> VocabularyEntry? {
        guard let learning else { return nil }
        let clean = Self.normalize(word)
        guard !clean.isEmpty else { return nil }
        let entry = VocabularyEntry(word: clean, meaning: meaning, source: source)
        _ = try? await learning.upsertVocabulary(entry)
        return await entries().first { $0.word.caseInsensitiveCompare(clean) == .orderedSame }
    }

    /// 记一次复习（调度与判分规则见 `ReviewScheduler`）。
    public func grade(id: UUID, remembered: Bool) async -> VocabularyEntry? {
        guard let learning,
              let current = await entries().first(where: { $0.id == id })
        else { return nil }
        let graded = ReviewScheduler.graded(current, remembered ? .remembered : .forgotten)
        try? await learning.recordVocabularyReview(graded, remembered: remembered)
        return graded
    }

    /// 删除一个词。
    public func remove(id: UUID) async {
        try? await learning?.deleteVocabulary(id: id)
    }

    // MARK: - 按需释义（LLM）

    /// 给生词补「音标 / 词性 / 中文义项 / 解释 / 例句及翻译 / 近反义 / 重点单词」。
    /// 模型不可用 / 解析不出内容时抛错，由 UI 给可操作提示。
    public func define(
        _ entry: VocabularyEntry,
        learningLanguage: String,
        nativeLanguage: String,
        options: VocabularyDefineOptions
    ) async throws -> VocabularyEntry {
        let request = LLMRequest(
            messages: [
                LLMMessage(
                    role: .system,
                    content: PromptBuilder.vocabularyDefinePrompt(
                        word: entry.word,
                        learningLanguage: learningLanguage,
                        nativeLanguage: nativeLanguage
                    )
                )
            ],
            model: options.model,
            temperature: 0,
            maxTokens: options.maxTokens ?? 512,
            streaming: false,
            // 确定性短任务关思考：与翻译同理由（24.8s → 1.4s）。
            reasoningEffort: LLMRequest.noThinkingEffort
        )
        let response = try await llm.generate(request)
        var parsed = VocabularyDefinitionRule.parse(response.text)
        // 单词必须有音标：模型漏了 / 只回一个「/」时补一次极短的定向请求。
        if parsed.phonetic.isEmpty,
           let rescued = await phoneticFallback(word: entry.word, learningLanguage: learningLanguage, options: options) {
            parsed.phonetic = rescued
        }
        guard !parsed.isEmpty else {
            throw AppError.unknown("模型没有给出可解析的释义，请再试一次")
        }
        var defined = entry
        defined.meaning = parsed.encoded
        defined.example = parsed.example
        try? await learning?.updateVocabularyDefinition(id: entry.id, meaning: parsed.encoded, example: parsed.example)
        return defined
    }

    // MARK: - 每日推荐（本地选词 + 按需 LLM 释义）

    /// 抽一组每日推荐：3 简单 / 5 中等 / 2 困难 / 2 词组（雅思标准），排除指定词。
    /// 某档学完（该档词全被排除）时缺口由未学完的最低档补（见 `DailyWordPicker.pick`）。
    /// 词库资源缺失时返回空（UI 隐藏板块，不崩）。
    public func dailyRecommendation(excluding: Set<String> = []) -> [DailyWord] {
        DailyWordPicker.pick(from: VocabularyWordBank.load(), excluding: excluding)
    }

    /// 词库全部词（设置页展示「已学 / 总词数」、每日推荐选词都用它）。
    public func wordBank() -> [DailyWord] {
        VocabularyWordBank.load()
    }

    /// 词库的词性 / 中文速查（词汇本添加框联想）。
    public func wordBankEntries() -> [WordBankEntry] {
        VocabularyWordBank.entries()
    }

    /// 给每日推荐的词补「音标 / 词性 / 中文义项 / 解释 / 例句及翻译 / 近反义 / 重点单词」。
    /// 与词汇本走**同一套字段**；只做展示，不落库 —— 推荐词默认不进复习列表。
    public func defineDaily(
        _ word: String,
        learningLanguage: String,
        nativeLanguage: String,
        options: VocabularyDefineOptions
    ) async throws -> VocabularyDefinition {
        let request = LLMRequest(
            messages: [
                LLMMessage(
                    role: .system,
                    content: PromptBuilder.vocabularyDailyPrompt(
                        word: word,
                        learningLanguage: learningLanguage,
                        nativeLanguage: nativeLanguage
                    )
                )
            ],
            model: options.model,
            temperature: 0,
            maxTokens: options.maxTokens ?? 512,
            streaming: false,
            // 确定性短任务关思考：与翻译同理由（24.8s → 1.4s）。
            reasoningEffort: LLMRequest.noThinkingEffort
        )
        let response = try await llm.generate(request)
        var parsed = VocabularyDefinitionRule.parse(response.text)
        if parsed.phonetic.isEmpty,
           let rescued = await phoneticFallback(word: word, learningLanguage: learningLanguage, options: options) {
            parsed.phonetic = rescued
        }
        guard !parsed.isEmpty else {
            throw AppError.unknown("模型没有给出可解析的释义，请再试一次")
        }
        return parsed
    }

    // MARK: - 音标兜底

    /// 只有**单个单词**才需要音标（词组 / 短句本来就没有）。
    public static func needsPhonetic(_ word: String) -> Bool {
        !word.contains(" ") && word.count <= 24
    }

    /// 定向补一次音标：一次极短的请求（只问 IPA），失败就认了（返回 nil，不阻塞主流程）。
    private func phoneticFallback(
        word: String,
        learningLanguage: String,
        options: VocabularyDefineOptions
    ) async -> String? {
        guard Self.needsPhonetic(word) else { return nil }
        let request = LLMRequest(
            messages: [
                LLMMessage(
                    role: .system,
                    content: PromptBuilder.vocabularyPhoneticPrompt(
                        word: word,
                        learningLanguage: learningLanguage
                    )
                )
            ],
            model: options.model,
            temperature: 0,
            maxTokens: 64,
            streaming: false,
            reasoningEffort: LLMRequest.noThinkingEffort
        )
        guard let response = try? await llm.generate(request) else { return nil }
        guard let candidate = VocabularyDefinitionRule.phoneticCandidate(in: response.text),
              VocabularyDefinitionRule.isUsablePhonetic(candidate)
        else { return nil }
        return candidate
    }

    // MARK: - 内部

    /// 生词清洗：去首尾空白与两端常见引号，过滤空串 / 过长（> 48 字符多半不是「一个词」）。
    public static func normalize(_ raw: String) -> String {
        var word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotePairs: [(String, String)] = [("\"", "\""), ("“", "”"), ("'", "'"), ("「", "」")]
        for (open, close) in quotePairs where word.count >= 2 && word.hasPrefix(open) && word.hasSuffix(close) {
            word = String(word.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        guard word.count <= 48 else { return "" }
        return word
    }
}
