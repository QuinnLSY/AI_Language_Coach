import AppCore

/// 设置页「朗读语气」要渲染的控制项（风格 / 情感）。
///
/// 为什么做成纯函数而不是直接写在视图里：**候选值是供应商给的**，而今天四条语音链路
/// （本地 Qwen3 / 本机 Edge 代理 / OpenAI 兼容云端 / mock）没有一条有风格或情感的字段位 ——
/// 真机上这段逻辑永远走「一个都不显示」那条分支。只有纯函数用例才能把
/// 「供应商一支持就亮」这条路真正走通，视图里写死的话它就是个永远没人验证的分支。
///
/// 判定只认「候选值非空」这一件事：能拿到候选值 = 供应商声明了该能力 **且** 请求形态载得动
/// 它（这两层判定在 `ProviderConfig.toneOptions(for:)` 里做完，这里不重复判）。
public enum TeacherVoiceTone {

    /// 「不指定」在下拉里的取值。空串与 `ProductConfig.speechStyle` 的「没选」语义同源，
    /// 所以它就是同一个值，不需要另造一个哨兵。
    public static let unspecified = ""

    /// 顺序固定为「风格 → 情感」。
    ///
    /// ⚠️ 不能直接遍历传入的字典：字典的遍历顺序不稳定，同一份配置两次打开设置
    /// 可能排出不同的次序，看起来像「设置页自己在动」。
    public static let displayOrder: [VoiceCapability] = [.style, .emotion]

    public struct Control: Sendable, Equatable, Identifiable {
        public var capability: VoiceCapability
        /// 控件标题（如「朗读风格」）。
        public var title: String
        /// 供应商给出的候选值（保证非空 —— 空的不该出现在这里）。
        public var options: [String]
        /// 当前选中的值；nil = 还没选（下拉显示「不指定」）。
        public var selected: String?
        /// 悬停说明。
        public var help: String

        public var id: String { capability.rawValue }
    }

    /// 悬停提示：讲清「取值表由供应商定义」，免得用户把它当成应用功能缺失。
    public static let optionHelp = "取值由当前语音供应商定义，应用只负责原样传给合成器；"
        + "选「不指定」即回到默认语气。"

    public static func controls(
        options: [VoiceCapability: [String]],
        selectedStyle: String,
        selectedEmotion: String
    ) -> [Control] {
        displayOrder.compactMap { capability in
            let values = (options[capability] ?? [])
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !values.isEmpty else { return nil }
            let selected = selectedValue(for: capability, style: selectedStyle, emotion: selectedEmotion)
            return Control(
                capability: capability,
                title: title(for: capability),
                options: values,
                // ⚠️ 选中的值必须**真的在候选表里**：换了供应商之后旧取值可能已经不存在，
                // 这时要当作「没选」。否则下拉会显示一个候选表里根本没有的值，
                // 用户看到的选项列表与控件显示的值对不上，怎么点都「选不回去」。
                selected: selected.flatMap { values.contains($0) ? $0 : nil },
                help: optionHelp
            )
        }
    }

    private static func title(for capability: VoiceCapability) -> String {
        switch capability {
        case .style: "朗读风格"
        case .emotion: "朗读情感"
        case .voiceCloning: "音色克隆"
        case .pitchControl: "音高控制"
        }
    }

    private static func selectedValue(
        for capability: VoiceCapability,
        style: String,
        emotion: String
    ) -> String? {
        switch capability {
        case .style: style.isEmpty ? nil : style
        case .emotion: emotion.isEmpty ? nil : emotion
        default: nil
        }
    }
}
