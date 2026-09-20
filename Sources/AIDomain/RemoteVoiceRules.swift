import Foundation

/// 云端音色目录的解析（纯函数，脱机可测）。
///
/// 各家语音服务的音色列表长得**完全不一样**，而它们都不是 OpenAI 的 `/models` 形态：
/// - `{"count":19,"voices":[{"id":"zh-CN-XiaoxiaoNeural","name":"晓晓（女，温柔）"}]}`（Edge TTS 代理）
/// - `{"data":[{"id":"alloy","name":"Alloy"}]}`（OpenAI 兼容的 `/models` 形态）
/// - `["voice-a","voice-b"]` / `{"voices":["voice-a"]}`（极简清单）
///
/// 规则：**宽容解析**。认得出来就用，认不出来返回空数组（`[]`）而**不抛错**——
/// 音色清单拿不到不该让能力不可用，用户仍能靠配置里的静态 `voices` 正常朗读。
public enum RemoteVoiceCatalog {

    /// 一个可用的音色：`id` 是发给服务端的真名，`name` 是给人看的名字。
    public struct Voice: Sendable, Equatable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// 常见的「列表容器」字段名（按优先级）。
    private static let containerKeys = ["voices", "data", "items", "list", "results"]

    /// 常见的「音色 id」字段名。`name` 放最后：极简清单里只有它可用。
    private static let idKeys = ["id", "voice_id", "voiceId", "short_name", "shortName", "name"]

    /// 解析音色列表。返回顺序与服务端一致（`.first` 才是服务端的默认音色）。
    public static func decode(_ data: Data) -> [Voice] {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) else { return [] }

        let rawItems: [Any]
        if let array = object as? [Any] {
            rawItems = array
        } else if let dictionary = object as? [String: Any] {
            rawItems = containerKeys.lazy.compactMap { dictionary[$0] as? [Any] }.first ?? []
        } else {
            return []
        }

        var seen = Set<String>()
        var voices: [Voice] = []
        for item in rawItems {
            guard let voice = voice(from: item) else { continue }
            guard seen.insert(voice.id.lowercased()).inserted else { continue }
            voices.append(voice)
        }
        return voices
    }

    private static func voice(from item: Any) -> Voice? {
        if let text = item as? String {
            let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return id.isEmpty ? nil : Voice(id: id, name: id)
        }
        guard let dictionary = item as? [String: Any] else { return nil }
        for key in idKeys {
            guard let value = dictionary[key] as? String else { continue }
            let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            let trimmedName = (dictionary["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmedName, !trimmedName.isEmpty { return Voice(id: id, name: trimmedName) }
            return Voice(id: id, name: id)
        }
        return nil
    }
}

/// 「用哪个音色朗读」（纯函数，脱机可测）。
///
/// 存在的理由（真实缺陷）：本地音色名（`serena`）在云端音色服务里**根本不存在**，
/// 而语音服务的音色清单是按语言分的（`en-US-AriaNeural` / `zh-CN-XiaoxiaoNeural` …）。
/// 旧实现遇到「音色不在清单里」就盲取第一个——中文音色列表的第一个恰好是中文音色，
/// 于是英文老师的每一句都用中文音色朗读。所以退回时必须**按语言挑**，而不是按顺序挑。
public enum RemoteVoiceResolver {

    /// 语言名 → 主语言标签：`en-US` → `en`、`English` → `en`、`zh-CN-XiaoxiaoNeural` → `zh`。
    /// 认不出来返回 nil（**不做过滤**，免得把用户的选择挡掉）。
    public static func languageTag(_ text: String?) -> String? {
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let lowered = raw.lowercased().replacingOccurrences(of: "_", with: "-")
        if let head = lowered.split(separator: "-").first, lowered.contains("-") {
            let tag = String(head)
            if isLanguageCode(tag) { return tag }
            return languageNames[tag]
        }
        if isLanguageCode(lowered) { return lowered }
        return languageNames[lowered]
    }

    /// 实际使用的音色。
    ///
    /// 优先级：
    /// 1. **用户选定的音色**在清单里 → 用它（选了谁就读谁，不偷偷改）；
    /// 2. 否则按**请求语言**挑第一个同语言的音色（`English` → `en-US-AriaNeural`）；
    /// 3. 再否则用清单第一个（服务端默认）；
    /// 4. 清单为空 → 原样返回请求的音色（没有清单就没有可挑的依据）。
    public static func pick(requested: String?, language: String?, voices: [String]) -> String? {
        let catalog = cleaned(voices)
        let wanted = requested?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !catalog.isEmpty else {
            return (wanted?.isEmpty == false) ? wanted : nil
        }
        if let wanted, !wanted.isEmpty,
           let hit = catalog.first(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) {
            return hit
        }
        if let tag = languageTag(language),
           let hit = catalog.first(where: { languageTag($0) == tag }) {
            return hit
        }
        return catalog.first ?? wanted
    }

    // MARK: - 内部

    /// 去空白、去空项、去重（保持服务端顺序）。
    private static func cleaned(_ voices: [String]) -> [String] {
        var seen = Set<String>()
        return voices.compactMap { voice in
            let trimmed = voice.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return nil }
            return trimmed
        }
    }

    private static func isLanguageCode(_ text: String) -> Bool {
        text.count == 2 && text.allSatisfy { $0.isLetter && $0.isASCII }
    }

    /// 语言**全名** → 标签（调用方传进来的常常是 `English` 这样的名字）。
    private static let languageNames: [String: String] = [
        "english": "en", "chinese": "zh", "mandarin": "zh", "cantonese": "zh",
        "japanese": "ja", "korean": "ko", "spanish": "es", "french": "fr",
        "german": "de", "italian": "it", "portuguese": "pt", "russian": "ru",
        "arabic": "ar", "hindi": "hi", "thai": "th", "vietnamese": "vi",
        "dutch": "nl", "polish": "pl", "turkish": "tr", "indonesian": "id"
    ]
}
