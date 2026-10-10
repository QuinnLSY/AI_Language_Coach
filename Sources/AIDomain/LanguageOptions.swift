import Foundation

// MARK: - 语言候选清单（学习语言 / 母语）
//
// 为什么需要这一层：设置页原来是三个**裸文本框**，让用户手填 `en-US`、`zh-CN`，
// 甚至音色名 —— 终端用户不可能知道该填什么格式，填错的代价是识别、翻译、
// 释义全走偏，而界面上看不出来任何异常。
// 把「有哪些可选」从 UI 里挪到一个纯函数能算出来的清单，下拉才有东西可画。
//
// ⚠️ 当前版本**只做英语**（用户已明确：先把英语板块的交互做扎实，其他语言后续再开）。
// 所以 `learning` 只列英语变体。将来加语言时**只改这里** ——
// `SettingsView` 直接映射这份清单，不要在界面层另写一份字面量，
// 否则「配置里存的值」和「下拉里能选的值」迟早对不上。

/// 学习语言 / 母语的候选清单。纯数据 + 纯函数，不 import UI。
public enum LanguageOptions {

    /// 一个语言选项。
    ///
    /// `tag` 是配置里真正存的 BCP-47 标识（`en-US`），`title` 是给人看的名字（`英语（美国）`）。
    /// 两者必须分开：把显示名存进配置，将来改文案就等于改了用户的数据。
    public struct Option: Sendable, Hashable, Identifiable {
        public let tag: String
        public let title: String

        public var id: String { tag }

        /// 由 `tag` 派生的「学习语言」值（语言全名 / 主语言标签 / 素材 key）。
        ///
        /// 纯计算、不缓存：`tag` 是不可变的，多算几次没有代价，
        /// 而存一份副本就等于多一处可能跟 `tag` 对不上的状态。
        public var language: LearningLanguage { LearningLanguage(bcp47: tag) }

        public init(tag: String, title: String) {
            self.tag = tag
            self.title = title
        }
    }

    /// 学员正在学的语言。
    ///
    /// 变体不是装饰：它决定语音识别与发音评测采用哪一套英语模型，
    /// 也影响老师朗读时挑哪个音色的口音。所以「美音 / 英音」是要让学员自己选的。
    public static let learning: [Option] = [
        Option(tag: "en-US", title: "英语（美国）"),
        Option(tag: "en-GB", title: "英语（英国）"),
        Option(tag: "en-AU", title: "英语（澳大利亚）")
    ]

    /// 母语：释义、翻译与讲解的落点语言。
    public static let native: [Option] = [
        Option(tag: "zh-CN", title: "简体中文"),
        Option(tag: "zh-TW", title: "繁體中文"),
        Option(tag: "en-US", title: "English")
    ]

    /// 把配置里的当前值补进候选清单（若它不在清单里）。
    ///
    /// ⚠️ 必须补，且必须补在**首位**：老配置里可能存着清单外的值（比如早期手填过的别的标识）。
    /// 不补的表现是下拉显示「未选择」，而用户真正配的值还静静躺在配置里 ——
    /// 看起来就像「设置丢了」，而且下次点一下下拉就会被无声改掉。
    public static func includingCurrent(_ tag: String, in options: [Option]) -> [Option] {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return options }
        guard !options.contains(where: { $0.tag.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return options }
        return [Option(tag: trimmed, title: displayName(for: trimmed))] + options
    }

    /// 清单外的标识符给一个还能看懂的名字：先问系统要本地化名，要不到就原样显示标识符。
    public static func displayName(for tag: String) -> String {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return tag }
        if let name = Locale(identifier: "zh-Hans").localizedString(forIdentifier: trimmed),
           !name.isEmpty {
            return name
        }
        return trimmed
    }
}

// MARK: - 学习语言的唯一表示（值类型）
//
// 为什么值得单独立一个类型：同一个「学员在学什么语言」全仓被表达了三次，
// 而且三处的更新时机完全独立 ——
//   `en-US`（配置里存的 BCP-47，设置页下拉的 tag）
//   `English`（本地 ASR / TTS / 跟读示范要的语言全名）
//   `en`（云端 OpenAI 兼容接口要的主语言标签，也是素材目录的 key）
// 加一种语言要同时改好几处字面量 + 两张映射表，而改动时**不会有任何编译错误提醒你漏了哪处**：
// 漏掉的那处只会在运行时悄悄用错语言（最典型的就是 prompt 里渲染出 `practise en-US`）。
// 收成一个类型之后，「英语有几种写法」只有这一个地方知道答案。

/// 「学员正在学什么语言」的唯一表示。纯数据 + 纯函数，不 import UI。
public struct LearningLanguage: Sendable, Hashable {

    /// 配置里存的 BCP-47 标识（`en-US`），也是设置页下拉选项的 `tag`。
    /// 空输入退化成 `en-US`（配置里的值一定是有效标签，这里只是兜住手改坏的库）。
    public let bcp47: String

    /// 主语言标签（`en`）：云端 OpenAI 兼容接口用。
    public let primaryTag: String

    /// 语言全名（`English`）：本地 ASR / TTS / Qwen3 / 跟读示范用。
    public let serviceName: String

    /// 素材目录 / 词典书的 key（`en`）。
    ///
    /// 与 `primaryTag` 同值但**语义不同**，所以单独命名：
    /// `primaryTag` 是「协议要什么」，`contentKey` 是「资源放在哪」——
    /// 将来素材目录改成按 `en-US` 分文件夹时，只需要改这一个属性，不必碰协议层。
    public var contentKey: String { primaryTag }

    /// 当前版本唯一的学习语言：英语（美国）。
    public static let english = LearningLanguage(bcp47: "en-US")

    /// 从配置里的标签构造。**不失败** —— 传进来的应当是 `LanguageOptions` 产出的有效标签。
    public init(bcp47: String) {
        let trimmed = bcp47.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.isEmpty ? "en-US" : trimmed
        self.bcp47 = normalized
        let primary = LearningLanguage.derivePrimaryTag(from: normalized)
        self.primaryTag = primary
        self.serviceName = LearningLanguage.deriveServiceName(for: primary)
    }

    /// 宽容解析任意语言标识，用于收编历史遗留的自由文本：
    /// BCP-47（`en-US`）、裸主标签（`en`）、语言全名（`English`）、
    /// 音色 id（`zh-CN-XiaoxiaoNeural`）、下划线写法（`zh_HK`）都认。
    /// **认不出来返回 nil**（不猜、也不过滤 —— 过滤会把用户的选择挡掉）。
    ///
    /// ⚠️ 这里**只认出「是哪种语言」，不保留地区变体**：结果里的 `bcp47 == primaryTag`
    /// （`en-US` 与 `en-GB` 都归成 `en`）。地区变体只有配置里那个值才重要，
    /// 而那条路径走 `init(bcp47:)`，是保真的。两者分工不同，别混用：
    /// 「我手上是配置标签」用 `init`，「我从一段文本里认语言」用 `resolving`。
    ///
    /// ⚠️ 判定顺序是「先当语言代码原样试，再试语言全名」：反过来的话，
    /// `xx` 这种未知的两字母代码会被当成语言名去查表，悄悄别名成 `en`。
    public static func resolving(_ raw: String?) -> LearningLanguage? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased().replacingOccurrences(of: "_", with: "-")
        // 带地区 / 带后缀（`en-US`、`zh-CN-XiaoxiaoNeural`）只看 `-` 前那一段。
        let head = String(lowered.split(separator: "-").first ?? "")

        let tag: String
        if isLanguageCode(head) {
            tag = head
        } else if let mapped = languageNames[head] {
            tag = mapped
        } else if isLanguageCode(lowered) {
            tag = lowered
        } else if let mapped = languageNames[lowered] {
            tag = mapped
        } else {
            return nil
        }
        return LearningLanguage(bcp47: tag)
    }

    // MARK: - 内部

    /// 从任意标签取主语言标签：`en-US`→`en`、`zh-CN-XiaoxiaoNeural`→`zh`、`English`→`en`。
    /// 认不出就原样小写返回，**不**退化成 `en` —— 把未知语言悄悄改成英语才是最难查的那类错。
    private static func derivePrimaryTag(from tag: String) -> String {
        let lowered = tag.lowercased().replacingOccurrences(of: "_", with: "-")
        let head = String(lowered.split(separator: "-").first ?? "")
        if isLanguageCode(head) { return head }
        if let mapped = languageNames[head] { return mapped }
        if isLanguageCode(lowered) { return lowered }
        if let mapped = languageNames[lowered] { return mapped }
        return head.isEmpty ? "en" : head
    }

    /// 主语言标签 → 语言全名（`en`→`English`）。
    /// 先问系统（覆盖的语种全），系统不认识再查内置兜底表，最后才原样返回标签。
    private static func deriveServiceName(for primaryTag: String) -> String {
        if let name = Locale(identifier: "en-US").localizedString(forLanguageCode: primaryTag),
           !name.isEmpty {
            return name
        }
        return fallbackServiceNames[primaryTag] ?? primaryTag
    }

    /// Foundation 在个别标签上会返回 nil（实测 `xx` / 空串都是 nil）。
    /// 英语必须**铁定**给得出 `English`：它是当前唯一的语言，一旦这里退化成 `en-US`，
    /// 我们想修的那个瑕疵（prompt 里渲染成 `practise en-US`）就会原样复活。
    private static let fallbackServiceNames: [String: String] = ["en": "English"]

    /// 两字母 ASCII 语言代码（`en`、`zh`；`en-US` 取头之后也走这里）。
    private static func isLanguageCode(_ text: String) -> Bool {
        text.count == 2 && text.allSatisfy { $0.isLetter && $0.isASCII }
    }

    /// 语言**全名** → 主语言标签。调用方（音色清单、历史配置）常常传的是 `English` 这种名字。
    /// 多个名字可指向同一标签：`mandarin` / `cantonese` 都归到 `zh`。
    private static let languageNames: [String: String] = [
        "english": "en", "chinese": "zh", "mandarin": "zh", "cantonese": "zh",
        "japanese": "ja", "korean": "ko", "spanish": "es", "french": "fr",
        "german": "de", "italian": "it", "portuguese": "pt", "russian": "ru",
        "arabic": "ar", "hindi": "hi", "thai": "th", "vietnamese": "vi",
        "dutch": "nl", "polish": "pl", "turkish": "tr", "indonesian": "id"
    ]
}
