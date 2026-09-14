import AppCore
import Foundation

/// 云端模型的「按能力归类」规则（纯函数，脱机可测）。
///
/// 背景：云端厂商（OpenAI / Groq / SiliconFlow …）的模型列表是**混在一起**的
/// —— `GET /v1/models` 一次返回聊天、语音识别、语音合成、向量模型。
/// 用户在「语音识别」区块里不该看到 `gpt-4o`，在「AI 大脑」里也不该看到 `tts-1`。
///
/// 这里只做**命名归类**（属于领域规则），不持有任何端点 / 密钥 / 具体模型清单。
///
/// 铁律：**筛不出来就别筛**。某厂商命名完全不命中关键词时原样返回，
/// 绝不因为规则不认识就把用户已经付费的模型挡在门外。
public enum RemoteModelFilter {

    /// 各能力的命名关键词（小写匹配，命中即计一分）。
    private static let keywords: [AIProviderKind: [String]] = [
        .asr: ["whisper", "transcribe", "speech-to-text", "stt", "asr", "sensevoice", "paraformer", "fun-asr"],
        .tts: ["tts", "text-to-speech", "speech", "voice", "kokoro", "cosyvoice", "fish-speech", "chattts"],
        .embedding: ["embed", "bge", "gte", "jina", "text-similarity"],
        .llm: ["gpt", "chat", "instruct", "qwen", "deepseek", "llama", "claude", "gemini", "glm", "mistral", "yi", "nemotron", "agnes"]
    ]

    /// 明确**不是**语言模型的命名特征（图像 / 视频生成、重排、3D）。
    ///
    /// 为什么需要**反向**排除，而不是只靠正向加分：
    /// 有些厂商的模型前缀会同时出现在文本与生成模型上（如 `agnes-3.0-flash` 与
    /// `agnes-image-2.5-flash`）。正向加分把两个都算成「像语言模型」，
    /// 用户在「AI 大脑」里选中一个图像模型后，对话必然失败 —— 那是生成端点，不是 chat。
    /// 这里只列**几乎不可能出现在对话模型名里**的词，避免把正常模型误伤。
    private static let generativeMarkers = ["image", "video", "diffusion", "rerank", "-3d", "tts", "whisper"]

    /// 同分时谁优先（语音类模型名里常常既有 speech 又有 voice）。
    private static let priority: [AIProviderKind: Int] = [
        .embedding: 4, .asr: 3, .tts: 2, .llm: 1
    ]

    /// 一个模型 id 最像哪类能力；认不出来返回 nil。
    public static func classify(_ modelID: String) -> AIProviderKind? {
        let id = modelID.lowercased()
        var best: (kind: AIProviderKind, score: Int)?
        for (kind, words) in keywords {
            let score = words.reduce(0) { $0 + (id.contains($1) ? 1 : 0) }
            guard score > 0 else { continue }
            let rank = priority[kind] ?? 0
            let bestRank = best.flatMap { priority[$0.kind] } ?? 0
            if best == nil || score > best!.score || (score == best!.score && rank > bestRank) {
                best = (kind, score)
            }
        }
        return best?.kind
    }

    /// 是不是明确的生成类模型（图像 / 视频 / 重排…）——对话模型列表要排掉它们。
    public static func isGenerative(_ modelID: String) -> Bool {
        let id = modelID.lowercased()
        return generativeMarkers.contains { id.contains($0) }
    }

    /// 按能力筛选模型 id。命中为空时原样返回（见文件头铁律）。
    ///
    /// `.llm` 额外排掉生成类模型：那是另一类端点，选中后对话必然失败，
    /// 而报错（404 / 400）看不出是「选错了模型类别」。其它能力不受这条影响。
    public static func filterIDs(_ ids: [String], for kind: AIProviderKind) -> [String] {
        var matched = ids.filter { classify($0) == kind }
        if kind == .llm {
            let chat = matched.filter { !isGenerative($0) }
            // 全是生成类模型（说明这家把前缀也用在了生成模型上）→ 保持原样，别把列表清空。
            matched = chat.isEmpty ? matched : chat
        }
        return matched.isEmpty ? ids : matched
    }
}

/// 云端端点拼接规则（纯函数）：端点由配置文件给出，各家前缀不同，这里只做安全拼接。
public enum RemoteEndpoint {

    /// 去掉结尾斜杠并要求带 scheme；非法返回 nil。
    public static func base(_ endpoint: String) -> URL? {
        var text = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.scheme != nil else { return nil }
        return url
    }

    /// 语音接口的语言参数：应用内部用 BCP-47（`en-US` / `zh-CN`），
    /// 而 OpenAI 兼容的云端接口只认主语言标签（`en` / `zh`）。
    /// 不归一化就会稳定 400，且错误信息很难看出是语言字段的问题。
    public static func primaryLanguageTag(_ language: String?) -> String? {
        guard let language else { return nil }
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(separator: "-").first.map { $0.lowercased() }
    }

    /// 拼接相对路径。
    ///
    /// 两个坑都要躲：① 路径开头的 `/`；② **端点本身已带版本前缀**——
    /// OpenAI 的端点是 `https://api.openai.com/v1`，再拼 `v1/models` 就成了
    /// `/v1/v1/models`（404）。规则：端点最后一段与相对路径首段相同则去重。
    public static func url(base: URL, path: String) -> URL {
        var relative = path
        while relative.hasPrefix("/") { relative.removeFirst() }
        if let head = relative.split(separator: "/").first,
           base.lastPathComponent == String(head) {
            relative = relative.dropFirst(head.count).trimmingPrefix("/").description
        }
        return base.appendingPathComponent(relative)
    }

    /// OpenAI 兼容的模型列表地址。
    ///
    /// ⚠️ 之所以要有这两个具名入口：适配器里曾各自写 `base.appendingPathComponent("v1/models")`，
    /// 端点自带 `/v1` 的厂商（AgnesAI 国内/国际站、OpenAI）会被拼成 `/v1/v1/models`，
    /// 服务端回 `Invalid URL`，用户看到的是「模型不可用 / 密钥无效」这类**指错方向**的提示。
    /// 所有云端适配器一律走这里，把「有没有版本前缀」的判断收敛到一处。
    public static func modelsURL(base: URL) -> URL {
        url(base: base, path: "v1/models")
    }

    /// OpenAI 兼容的对话补全地址。
    public static func chatURL(base: URL) -> URL {
        url(base: base, path: "v1/chat/completions")
    }
}
