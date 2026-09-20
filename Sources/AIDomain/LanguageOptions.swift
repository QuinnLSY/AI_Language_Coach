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
