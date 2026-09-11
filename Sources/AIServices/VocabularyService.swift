import AIDomain
import AIInfrastructure
import AIInterfaces
import AppCore
import Foundation

/// 词汇本定义输出的解析规则（纯函数，便于单测）。
///
/// 模型被要求回一行「释义||例句」；实际偶尔会围栏、多余行、缺分隔符。
/// 规则：取**含 `||` 的第一行**拆开，两侧各留第一段；没有 `||` 时整行按释义处理（例句为空）。
public enum VocabularyDefineRule {

    public struct Definition: Sendable, Equatable {
        public var meaning: String
        public var example: String

        public init(meaning: String, example: String) {
            self.meaning = meaning
            self.example = example
        }
    }

    public static func parse(_ raw: String) -> Definition? {
        var lines = raw
            .replacingOccurrences(of: "```", with: "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // 含分隔符的行才是正文（模型偶尔先客气一句）。
        if let body = lines.first(where: { $0.contains("||") }) {
            let parts = body.components(separatedBy: "||")
            let meaning = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
            let example = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            guard !meaning.isEmpty else { return nil }
            return Definition(meaning: meaning, example: example)
        }
        guard let single = lines.first, !single.isEmpty else { return nil }
        lines = [single]
        return Definition(meaning: single, example: "")
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
    public func entries() async -> [VocabularyEntry] {
        guard let learning else { return [] }
        return (try? await learning.allVocabulary()) ?? []
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
        defined.meaning = parsed.meaning
        defined.example = parsed.example
        try? await learning?.updateVocabularyDefinition(id: entry.id, meaning: parsed.meaning, example: parsed.example)
        return defined
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
