import AIInfrastructure
import AIInterfaces
import AppCore
import Foundation

/// 模型输出译文的清理规则（纯函数，便于单测）。
///
/// 翻译是给学员看的，模型的「顺手加一句说明」在这里比没翻译更糟（会被当成译文的一部分）。
/// 规则与拼写纠正同源：**只保留译文本体**。
public enum TranslationRule {

    /// 清理模型输出：去围栏、去包裹引号、去常见前缀（「译文：」「Translation:」）。
    public static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 去掉整体包裹的引号（成对才算）
        let quotePairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("“", "”"), ("「", "」"), ("『", "』")]
        for (open, close) in quotePairs where text.count >= 2 && text.first == open && text.last == close {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        // 模型偶尔先复述一句「译文如下 / Translation:」，丢掉那一行的前半截
        let prefixes = ["译文：", "译文:", "翻译：", "翻译:", "translation:", "Translation:"]
        for prefix in prefixes where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 对话气泡的按需翻译。
///
/// **为什么是「点开才翻译」而不是「生成时一并产出」**：
/// 1. 一并产出 = 每条回复都要多译一遍，token 与首字延迟直接翻倍，而绝大多数气泡学员根本不会点开；
/// 2. 一并产出会把译文塞进对话历史与上下文（越聊越贵），按需翻译则完全不进历史；
/// 3. 按需 + 有界缓存后，重复点开是零成本，缓存只占几十 KB 且随进程回收。
///
/// 缓存策略：FIFO，超出 `cacheLimit` 丢最早的一条（一条译文通常几百字节）。
public actor TranslationService {

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

    /// 缓存条数上限。
    public static let cacheLimit = 120

    private let llm: LLMManager
    private var cache: [String: String] = [:]
    private var insertionOrder: [String] = []

    public init(llm: LLMManager) {
        self.llm = llm
    }

    /// 命中缓存的译文（无则 nil）。供调用方跳过请求。
    public func cached(text: String, targetLanguage: String) -> String? {
        cache[key(text: text, targetLanguage: targetLanguage)]
    }

    /// 当前缓存条数（单测用）。
    public var cachedCount: Int { cache.count }

    /// 把一段文本翻译成目标语言。命中缓存直接返回，不产生任何请求。
    public func translate(_ text: String, targetLanguage: String, options: Options) async throws -> String {
        let source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return "" }
        let cacheKey = key(text: source, targetLanguage: targetLanguage)
        if let hit = cache[cacheKey] { return hit }

        let request = LLMRequest(
            messages: [
                LLMMessage(role: .system,
                           content: PromptBuilder.translationPrompt(text: source, targetLanguage: targetLanguage))
            ],
            model: options.model,
            temperature: options.temperature ?? 0,
            maxTokens: options.maxTokens ?? 512,
            streaming: false,
            // 翻译是确定性短任务，思考段纯属浪费：实测同一句 24.8s → 1.4s，译文一致。
            reasoningEffort: LLMRequest.noThinkingEffort
        )
        let response = try await llm.generate(request)
        let cleaned = TranslationRule.clean(response.text)
        guard !cleaned.isEmpty else { return "" }
        remember(cacheKey, cleaned)
        return cleaned
    }

    // MARK: - 内部

    private func key(text: String, targetLanguage: String) -> String {
        "\(targetLanguage)\u{1F}\(text)"
    }

    private func remember(_ cacheKey: String, _ value: String) {
        if cache[cacheKey] == nil {
            insertionOrder.append(cacheKey)
            cache[cacheKey] = value
        }
        while insertionOrder.count > Self.cacheLimit {
            let oldest = insertionOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }
}
