import AIDomain
import AIInfrastructure
import AIInterfaces
import AppCore
import Foundation

/// 词汇本定义输出的解析规则（纯函数，便于单测）。
///
/// 模型被要求回一行「释义||例句||重点单词」；实际偶尔会围栏、多余行、缺分隔符，
/// 甚至把格式行里的字段名（MEANING/EXAMPLE/KEYWORDS）原样回显、只在中间填内容
/// （qwen3:8b 实测出现过）。规则：
/// - 取**含 `||` 的第一行**拆开；
/// - **等于字段名的段直接剔除**（回显防御），剩下的段按 释义→例句→重点单词 依次取用；
/// - 重点单词为 `-` 视为「没有」；没有 `||` 时整行按释义处理。
public enum VocabularyDefineRule {

    /// 模型可能原样回显的字段名（小写）。
    static let placeholderTokens: Set<String> = ["meaning", "example", "keywords", "pos", "释义", "例句", "重点单词"]

    public struct Definition: Sendable, Equatable {
        public var meaning: String
        public var example: String
        /// 重点单词（「boost (v.) 提升；encourage (v.) 鼓励」这样的整段文本）。
        public var keywords: String

        public init(meaning: String, example: String, keywords: String = "") {
            self.meaning = meaning
            self.example = example
            self.keywords = keywords
        }

        /// 落库的释义全文：详细释义 + 重点单词行（有重点单词时另起一行）。
        public var storedMeaning: String {
            keywords.isEmpty ? meaning : "\(meaning)\n重点单词：\(keywords)"
        }
    }

    /// 该段是否是字段名的原样回显。
    static func isPlaceholder(_ segment: String) -> Bool {
        placeholderTokens.contains(segment.trimmingCharacters(in: .whitespaces).lowercased())
    }

    public static func parse(_ raw: String) -> Definition? {
        let lines = raw
            .replacingOccurrences(of: "```", with: "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // 含分隔符的行才是正文（模型偶尔先客气一句）。
        if let body = lines.first(where: { $0.contains("||") }) {
            let real = body
                .components(separatedBy: "||")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !isPlaceholder($0) }
            // 整行都是字段名回显（没有真实内容）：按无正文处理。
            guard let meaning = real.first, !meaning.isEmpty else { return nil }
            let example = real.count > 1 ? real[1] : ""
            var keywords = real.count > 2 ? real[2] : ""
            if keywords == "-" { keywords = "" }
            return Definition(meaning: meaning, example: example, keywords: keywords)
        }
        guard let single = lines.first, !single.isEmpty, !isPlaceholder(single) else { return nil }
        return Definition(meaning: single, example: "")
    }

    /// 清洗历史坏数据：老版本解析器曾把字段名回显落库（释义=「MEANING」、
    /// 重点单词=「EXAMPLE」）。逐行剔除字段名行与「重点单词：<字段名>」行；
    /// 剔完为空 → 返回空串（UI 退回「还没有释义」，可重新查释义覆盖）。
    public static func sanitizedStoredMeaning(_ raw: String) -> String {
        let kept = raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                if isPlaceholder(line) { return false }
                // 「重点单词：EXAMPLE」这类坏行：冒号后是字段名 → 整行剔除。
                if line.hasPrefix("重点单词"),
                   let value = line.split(whereSeparator: { ":：".contains($0) }).last,
                   isPlaceholder(String(value)) {
                    return false
                }
                return true
            }
        return kept.joined(separator: "\n")
    }
}

/// 每日推荐释义输出的解析规则（纯函数）。
///
/// 一行六段：`词性||释义||例句||例句翻译||近义词||反义词`；
/// 近/反义词以「、」分隔，`-` 表示没有；字段名回显段（POS/MEANING/…）直接剔除。
public enum VocabularyDailyRule {

    static let placeholderTokens: Set<String> = [
        "pos", "meaning", "example", "example_translation", "example translation",
        "exampletranslation", "synonyms", "antonyms", "词性", "释义", "例句", "例句翻译", "近义词", "反义词",
    ]

    static func isPlaceholder(_ segment: String) -> Bool {
        placeholderTokens.contains(segment.trimmingCharacters(in: .whitespaces).lowercased())
    }

    public static func parse(_ raw: String) -> DailyDefinition? {
        let lines = raw
            .replacingOccurrences(of: "```", with: "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let body = lines.first(where: { $0.contains("||") }) else { return nil }
        // 按原始位置取段；等于字段名的段（模型回显格式行）逐个中和为「缺席」，
        // 不能整体重排 —— 回显场景下剔除后位置有歧义。
        let parts = body.components(separatedBy: "||").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        func field(_ index: Int) -> String {
            guard index < parts.count else { return "" }
            let value = parts[index]
            return (value == "-" || isPlaceholder(value)) ? "" : value
        }
        let meaning = field(1)
        guard !meaning.isEmpty else { return nil }
        return DailyDefinition(
            pos: field(0),
            meaning: meaning,
            example: field(2),
            exampleTranslation: field(3),
            synonyms: parseList(field(4)),
            antonyms: parseList(field(5))
        )
    }

    /// 「wonderful、excellent」「-, excellent」→ 有效词列表。
    private static func parseList(_ raw: String) -> [String] {
        guard raw != "-" else { return [] }
        return raw
            .split(whereSeparator: { "、，,;；".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "-" }
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
            cleaned.meaning = VocabularyDefineRule.sanitizedStoredMeaning(entry.meaning)
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

    /// 给生词补「中文释义 + 例句」。模型不可用 / 解析失败时抛错，由 UI 给可操作提示。
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
        guard let parsed = VocabularyDefineRule.parse(response.text) else {
            throw AppError.unknown("模型没有给出可解析的释义，请再试一次")
        }
        var defined = entry
        defined.meaning = parsed.storedMeaning
        defined.example = parsed.example
        try? await learning?.updateVocabularyDefinition(id: entry.id, meaning: parsed.storedMeaning, example: parsed.example)
        return defined
    }

    // MARK: - 每日推荐（本地选词 + 按需 LLM 释义）

    /// 抽一组每日推荐：3 简单 / 5 中等 / 2 困难（雅思标准），排除指定词。
    /// 词库资源缺失时返回空（UI 隐藏板块，不崩）。
    public func dailyRecommendation(excluding: Set<String> = []) -> [DailyWord] {
        DailyWordPicker.pick(from: VocabularyWordBank.load(), excluding: excluding)
    }

    /// 给每日推荐的词补「词性 + 详细中文释义 + 例句及翻译 + 近/反义词」。
    /// 只做展示，不落库 —— 推荐词默认不进复习列表。
    public func defineDaily(
        _ word: String,
        learningLanguage: String,
        nativeLanguage: String,
        options: VocabularyDefineOptions
    ) async throws -> DailyDefinition {
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
        guard let parsed = VocabularyDailyRule.parse(response.text) else {
            throw AppError.unknown("模型没有给出可解析的释义，请再试一次")
        }
        return parsed
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
