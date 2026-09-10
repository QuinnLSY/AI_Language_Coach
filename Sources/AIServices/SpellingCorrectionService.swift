import AIDomain
import AIInterfaces
import AIInfrastructure
import AppCore
import Foundation

/// 拼写纠正的采纳规则（**纯函数，可单测**）。
///
/// 模型再小也会偶尔「顺手改写」句子。语音输入是用户马上要发出去的内容，
/// 一旦被改写就意味着「我说的和我发的不一样」——比不纠正糟糕得多。
/// 所以这里的原则是：**宁可保留原文，也不接受可疑的改写**。
public enum SpellingFixRule {

    /// 允许的最大改动比例（按词计的编辑距离 / 原文词数）。
    public static let maxChangeRatio = 0.34

    /// 采纳候选句；任何一项校验不过就原样返回输入。
    public static func accepted(original: String, candidate: String) -> String {
        let source = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = sanitize(candidate)
        guard !source.isEmpty, !cleaned.isEmpty else { return source }
        // 提示词泄漏 / 结构化输出混入 → 直接放弃
        guard !cleaned.contains("[["), !cleaned.contains("=>") else { return source }
        // 说明：模型在句子后面补解释时，`sanitize` 已经只保留首行，
        // 所以这里不必再单独「拒绝多行」——首行本身仍要过下面的改动比例校验。
        // 长度与词数都不能离谱（防止模型解释、翻译或截断）
        guard ratio(cleaned.count, source.count) >= 0.6, ratio(cleaned.count, source.count) <= 1.5 else { return source }
        let sourceWords = words(source)
        let candidateWords = words(cleaned)
        guard !sourceWords.isEmpty else { return source }
        guard ratio(candidateWords.count, sourceWords.count) >= 0.6,
              ratio(candidateWords.count, sourceWords.count) <= 1.5 else { return source }
        // 改动比例过大 → 不是"纠错"而是"重写"
        guard changeRatio(sourceWords, candidateWords) <= maxChangeRatio else { return source }
        return cleaned
    }

    /// 清理模型输出：去掉代码块围栏、包裹引号、多余空行与非句子的前后缀。
    public static func sanitize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉 ```...``` 围栏
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 只保留首个非空行组（模型偶尔在下面补一句解释）
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let first = lines.first { text = first }
        // 去掉整体包裹的引号（成对才算）
        let quotePairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("“", "”"), ("「", "」"), ("『", "』")]
        for (open, close) in quotePairs where text.count >= 2 && text.first == open && text.last == close {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            break
        }
        return text
    }

    // MARK: - 内部

    private static func ratio(_ value: Int, _ base: Int) -> Double {
        guard base > 0 else { return 0 }
        return Double(value) / Double(base)
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map(String.init)
    }

    /// 词级编辑距离 / 原文词数。公开以便单测钉住「改动比例」这一安全阈值。
    public static func changeRatio(_ lhs: [String], _ rhs: [String]) -> Double {
        guard !lhs.isEmpty else { return 1 }
        let distance = editDistance(lhs, rhs)
        return Double(distance) / Double(lhs.count)
    }

    private static func editDistance(_ lhs: [String], _ rhs: [String]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)
        for i in 1...lhs.count {
            current[0] = i
            for j in 1...rhs.count {
                let cost = lhs[i - 1] == rhs[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }
}

/// 语音输入专用的拼写纠正：把识别文本交给模型只修拼写，再用规则兜底。
///
/// **只对语音输入调用**（手打的字一个都不改）。任何失败都返回原文。
public actor SpellingCorrectionService {

    public struct Options: Sendable {
        public var model: String?
        public var temperature: Double?
        public var maxTokens: Int?

        public init(model: String? = nil, temperature: Double? = nil, maxTokens: Int? = nil) {
            self.model = model
            self.temperature = temperature
            self.maxTokens = maxTokens
        }
    }

    private let llm: LLMManager

    public init(llm: LLMManager) {
        self.llm = llm
    }

    /// 返回纠正后的句子；无法确定时返回原文（**永不抛错**，语音输入不能被它卡住）。
    public func correct(_ text: String, options: Options) async -> String {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source.count >= 2, source.count <= 400 else { return text }
        let request = LLMRequest(
            messages: [
                LLMMessage(role: .system, content: PromptBuilder.spellingFixPrompt(sentence: source))
            ],
            model: options.model,
            temperature: options.temperature ?? 0,
            maxTokens: options.maxTokens ?? 256,
            streaming: false
        )
        guard let response = try? await llm.generate(request) else { return text }
        return SpellingFixRule.accepted(original: text, candidate: response.text)
    }
}
