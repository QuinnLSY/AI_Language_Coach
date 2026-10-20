import Foundation

// MARK: - 快捷键：动作与绑定
//
// 这一层是**纯数据 + 纯逻辑**：不 import AppKit，也不认识 `AppState`。
// 理由与 `AppSection` 同款 —— 「有哪些动作可以绑键」「一个绑定长什么样」
// 「两个动作撞了没有」都是可以脱机单测的事实，不该被事件分发与界面细节绑住。
// 真正的按键监听在 `AppUI.ShortcutMonitor`，执行在 `AppState.perform(shortcut:)`。

/// 快捷键动作的**分组**（设置页「快捷键中心」按这个分节）。
public enum ShortcutGroup: String, CaseIterable, Sendable, Identifiable {
    /// 复习卡：只在复习进行时生效。
    case review
    /// 页面跳转：任何时候都生效。
    case navigation
    /// 全局动作（#599）：打开搜索 / 设置 / 说明这类「不挑当前在哪一页」的入口。
    case global
    /// 对话页（#617）：发送。挑页面、还挑「此刻发得出去吗」。
    case chat

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .review: return "复习卡"
        case .navigation: return "页面跳转"
        case .global: return "全局"
        case .chat: return "对话"
        }
    }

    /// 这个分组在什么前提下生效 —— 设置页要拿它提醒用户，别让人以为设了却没反应。
    public var scopeNote: String {
        switch self {
        case .review: return "仅在复习卡进行时生效"
        case .navigation: return "任何时候都生效"
        case .global: return "任何时候都生效（有浮层盖着时不响应）"
        case .chat: return "在对话页、未在生成时生效"
        }
    }
}

/// 一次按键的**规范化**表示。
///
/// `key` 用文本而不是 `keyCode`：keyCode 是键盘布局相关的（同一个物理键在
/// 不同布局上是不同字符），而用户想绑的是**字符**（「我要 R」而不是「我要第 15 号键」）。
/// 单字符一律小写；空格 / 回车这类没有可打印字符的键用固定名字。
public struct ShortcutBinding: Codable, Equatable, Hashable, Sendable {

    /// 规范化的键名：单字符（`"a"` / `"1"`）或特殊名（`"space"` / `"return"` …）。
    public var key: String
    public var command: Bool
    public var shift: Bool
    public var option: Bool
    public var control: Bool

    public init(
        key: String,
        command: Bool = false,
        shift: Bool = false,
        option: Bool = false,
        control: Bool = false
    ) {
        self.key = Self.normalize(key)
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    /// 特殊键的名字 → 它们在界面上怎么写。
    ///
    /// 只收「没有可打印字符、但确实想绑」的那几个：方向键 / 功能键暂不开放，
    /// 它们在不同键盘上差异大，绑上去容易变成一个用户自己都按不出来的组合。
    public static let specialKeyDisplayNames: [String: String] = [
        "space": "空格",
        "return": "回车",
        "escape": "Esc",
        "tab": "Tab",
        "delete": "删除"
    ]

    /// 规范化键名：单字符一律小写（`Shift+R` 的 shift 走修饰键，不靠大小写）。
    public static func normalize(_ raw: String) -> String {
        raw.lowercased()
    }

    /// 一个修饰键都没有 —— 也就是「按这个键本身」。
    ///
    /// ⚠️ 这类绑定和文本输入**天然打架**（在输入框里按 `r` 就是打一个 r）。
    /// 事件分发靠它决定要不要放行，所以这里的判断必须准。
    public var isPlainKey: Bool { !command && !shift && !option && !control }

    /// 给人看的写法：`⌘⇧R` / `空格` / `1`。
    ///
    /// ⚠️ 修饰键的顺序固定为 ⌃⌥⇧⌘（Apple 惯例），别按声明顺序拼 ——
    /// 用户会照着系统菜单的样子读它。
    public var displayString: String {
        var text = ""
        if control { text += "⌃" }
        if option { text += "⌥" }
        if shift { text += "⇧" }
        if command { text += "⌘" }
        if let special = Self.specialKeyDisplayNames[key] {
            return text + special
        }
        return text + key.uppercased()
    }

    /// 两个绑定是不是同一个键（冲突判据）。
    public func collides(with other: ShortcutBinding) -> Bool {
        key == other.key
            && command == other.command
            && shift == other.shift
            && option == other.option
            && control == other.control
    }
}

/// 可以被绑定的动作。
///
/// ⚠️ 加动作时的三件事：① 给 `title`（设置页读它）；② 给 `defaultBinding`；
/// ③ 在 `AppState.perform(shortcut:)` 里接上真实行为 —— 漏掉 ③ 的话，
/// 这个动作会在设置页里好好躺着、按下去毫无反应。
public enum ShortcutAction: String, CaseIterable, Codable, Sendable, Identifiable {

    // 复习卡（需要「复习正在进行」这一上下文）
    case reviewReveal
    case reviewRemembered
    case reviewForgotten
    case reviewSpeak
    /// #599：开口跟读这个词（录音）。原来只有鼠标点麦克风一条路。
    case reviewToggleRecording
    /// #599：回放自己刚才录的那一遍。
    case reviewReplay

    // 全局（#599：不挑当前在哪一页的入口）
    /// 跨页搜索（原来只有侧栏那颗放大镜能开）。
    case openSearch
    /// 设置浮层。
    case openSettings
    /// 应用内帮助中心。
    case openHelp

    // 对话页（#617）
    /// 发送当前输入（原来是写死在发送按钮上的 `keyboardShortcut`，用户改不了）。
    case sendMessage

    // 页面跳转（数字与侧栏位置一致，由 `AppSection.shortcutDigit` 推出来）
    case openPractice
    case openShadowing
    case openWriting
    case openReading
    case openListening
    case openDictionary
    case openVocabulary
    case openScenarios
    case openProgress
    case openRecords

    public var id: String { rawValue }

    public var group: ShortcutGroup {
        switch self {
        case .reviewReveal, .reviewRemembered, .reviewForgotten, .reviewSpeak,
             .reviewToggleRecording, .reviewReplay:
            return .review
        case .openSearch, .openSettings, .openHelp:
            return .global
        case .sendMessage:
            return .chat
        default:
            return .navigation
        }
    }

    public var title: String {
        switch self {
        case .reviewReveal: return "翻面看释义"
        case .reviewRemembered: return "记得（认识）"
        case .reviewForgotten: return "忘了"
        case .reviewSpeak: return "朗读这个词"
        case .reviewToggleRecording: return "跟读这个词"
        case .reviewReplay: return "回放我的录音"
        case .openSearch: return "全局搜索"
        case .openSettings: return "打开设置"
        case .openHelp: return "使用说明"
        case .sendMessage: return "发送"
        case .openPractice: return "去「练习」"
        case .openShadowing: return "去「跟读」"
        case .openWriting: return "去「写作」"
        case .openReading: return "去「阅读」"
        case .openListening: return "去「听力」"
        case .openDictionary: return "去「词典」"
        case .openVocabulary: return "去「词汇本」"
        case .openScenarios: return "去「情景对话」"
        case .openProgress: return "去「学习进度」"
        case .openRecords: return "去「学习记录」"
        }
    }

    /// 页面跳转动作对应的页面；复习类动作为 nil。
    public var section: AppSection? {
        switch self {
        case .openPractice: return .practice
        case .openShadowing: return .shadowing
        case .openWriting: return .writing
        case .openReading: return .reading
        case .openListening: return .listening
        case .openDictionary: return .dictionary
        case .openVocabulary: return .vocabulary
        case .openScenarios: return .scenarios
        case .openProgress: return .progress
        case .openRecords: return .records
        default: return nil
        }
    }

    /// 某个页面对应的跳转动作（「前往」菜单与设置页共用这条反查）。
    public static func navigationAction(for section: AppSection) -> ShortcutAction? {
        allCases.first { $0.section == section }
    }

    /// 出厂绑定。
    public var defaultBinding: ShortcutBinding {
        switch self {
        case .reviewReveal: return ShortcutBinding(key: "space")
        case .reviewRemembered: return ShortcutBinding(key: "1")
        case .reviewForgotten: return ShortcutBinding(key: "2")
        case .reviewSpeak: return ShortcutBinding(key: "r")
        // #599：m = 麦克风（录音跟读），p = play（回放自己的那一遍）。
        // 与既有四个复习键同在无修饰键那一档 —— 复习页没有文本输入框，
        // 不会因为「打字时抢键」被打断（`isTextInputFocused` 这道护栏仍然在）。
        case .reviewToggleRecording: return ShortcutBinding(key: "m")
        case .reviewReplay: return ShortcutBinding(key: "p")
        // 全局三个都带 ⌘：既避开复习那档无修饰键，也避开「跳转 ⌘1…⌘9」。
        case .openSearch: return ShortcutBinding(key: "k", command: true)
        case .openSettings: return ShortcutBinding(key: ",", command: true)
        case .openHelp: return ShortcutBinding(key: "/", command: true)
        // 发送沿用按钮上那颗写死多年的 ⌘↩（macOS 聊天工具的惯例）。
        // 带 ⌘ 所以不撞「无修饰键 + 打字」那道护栏 —— 正打着字也能发。
        case .sendMessage: return ShortcutBinding(key: "return", command: true)
        default:
            // 页面跳转统一走 ⌘ + 侧栏序号：顺序从 `AppSection.allCases` 推，
            // 加一页时编号自动跟着走（这也是 `shortcutDigit` 存在的理由）。
            let digit = section?.shortcutDigit ?? 1
            return ShortcutBinding(key: "\(digit)", command: true)
        }
    }
}

// MARK: - 冲突检测

/// 「同一个按键被两个动作占了」这种事的判据。
///
/// 为什么非要专门判一次：两个动作绑同一个键时，按下只会命中**先查到的那一个**
/// （顺序由字典遍历决定），另一个从设置的界面上看却好端端地配着键 ——
/// 用户会以为「这个快捷键坏了」。所以宁可当场把冲突报出来。
public enum ShortcutConflict {

    /// 找出所有撞车的绑定 → 撞在它上面的动作列表。
    ///
    /// 只报**同一分组**内的冲突：复习用无修饰键、跳转用 ⌘+数字，两组天然错开；
    /// 而「复习的 1」与「跳转的 ⌘1」是两个不同的键，不算撞。
    public static func detect(
        _ bindings: [ShortcutAction: ShortcutBinding]
    ) -> [ShortcutBinding: [ShortcutAction]] {
        var byBinding: [ShortcutBinding: [ShortcutAction]] = [:]
        for (action, binding) in bindings {
            byBinding[binding, default: []].append(action)
        }
        return byBinding.filter { $0.value.count > 1 }
    }

    /// 某个动作当前是否处在冲突里（设置页给那一行标红用）。
    public static func conflicts(
        for action: ShortcutAction,
        in bindings: [ShortcutAction: ShortcutBinding]
    ) -> [ShortcutAction] {
        guard let binding = bindings[action] else { return [] }
        return (detect(bindings)[binding] ?? []).filter { $0 != action }
    }
}

// MARK: - 一次真实按键

/// 一次按键的**原始**描述：从 `NSEvent` 里抽出来的那点信息，仅此而已。
///
/// 为什么不直接拿 `NSEvent`：那一层是 AppKit 的，进不了 AIDomain，
/// 而「按下的键配不配得上某个动作」这件事本身不需要 AppKit。
public struct ShortcutEventKey: Equatable, Hashable, Sendable {

    public var key: String
    public var command: Bool
    public var shift: Bool
    public var option: Bool
    public var control: Bool

    public init(
        key: String,
        command: Bool = false,
        shift: Bool = false,
        option: Bool = false,
        control: Bool = false
    ) {
        self.key = ShortcutBinding.normalize(key)
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    /// 当作绑定来看（冲突判据与存储格式共用一份）。
    public var binding: ShortcutBinding {
        ShortcutBinding(
            key: key,
            command: command,
            shift: shift,
            option: option,
            control: control
        )
    }
}

/// 按下的键 → 该跑哪个动作。
///
/// 这里是**唯一**的分发判据，写在这层是为了能被单测直接打：
/// 「在输入框里打字时不许抢键」「没在复习时复习键不许响」都是纯规则。
public enum ShortcutResolver {

    /// 判定所需的**上下文**（全部是界面当前的事实，由 AppState 现取现给）。
    public struct Context: Sendable {
        /// 光标现在在一个文本输入框里（聊天框 / 设置里的各种文本框）。
        public var isTextInputFocused: Bool
        /// 复习卡正在进行（决定复习类动作要不要响应）。
        public var isReviewActive: Bool
        /// 设置页正在录制新按键（这时一切按键都归录制器）。
        public var isCapturing: Bool
        /// 有整块浮层盖着（设置 / 情景 / 材料上传 / 考试报告）——
        /// 底下那一页此刻看不见，快捷键再切页只会让人莫名其妙。
        public var isOverlayPresented: Bool
        /// 对话页的输入区在场，且此刻发得出去（#617：决定「发送」要不要响应）。
        public var isChatActive: Bool

        public init(
            isTextInputFocused: Bool = false,
            isReviewActive: Bool = false,
            isCapturing: Bool = false,
            isOverlayPresented: Bool = false,
            isChatActive: Bool = false
        ) {
            self.isTextInputFocused = isTextInputFocused
            self.isReviewActive = isReviewActive
            self.isCapturing = isCapturing
            self.isOverlayPresented = isOverlayPresented
            self.isChatActive = isChatActive
        }
    }

    /// 这一次按键该触发哪个动作（nil = 不归快捷键管，事件照常往下走）。
    ///
    /// 命中顺序按 `ShortcutAction.allCases`（复习在前、跳转在后），是**确定的**：
    /// 万一两个动作绑了同一个键，永远是同一个赢，不会这次这个下次那个。
    public static func action(
        for event: ShortcutEventKey,
        bindings: [ShortcutAction: ShortcutBinding],
        context: Context
    ) -> ShortcutAction? {
        if context.isCapturing { return nil }
        let pressed = event.binding
        guard let action = ShortcutAction.allCases.first(where: {
            bindings[$0]?.collides(with: pressed) == true
        }) else { return nil }
        // ⚠️ 无修饰键 + 正在打字 = 抢别人的字母。宁可这个键此刻不灵，
        // 也不能让用户在聊天框里打不出「r」。
        if pressed.isPlainKey, context.isTextInputFocused { return nil }
        if action.group == .review, !context.isReviewActive { return nil }
        if action.group == .chat, !context.isChatActive { return nil }
        if context.isOverlayPresented { return nil }
        return action
    }
}

// MARK: - 落盘

/// `[ShortcutAction: ShortcutBinding]` 与 `Data` 之间的转换。
///
/// 为什么要手写而不直接 `JSONEncoder` 编字典：Swift 对「键是枚举」的字典并不保证
/// 编成 `{"openPractice": …}` 这种对象（可能是 `[key, value]` 的数组），
/// 换了表示法就是一次静默的配置丢失。手写一遍，格式锁死。
public enum ShortcutBindingArchive {

    public static func encode(_ bindings: [ShortcutAction: ShortcutBinding]) -> Data? {
        var raw: [String: ShortcutBinding] = [:]
        for (action, binding) in bindings { raw[action.rawValue] = binding }
        return try? JSONEncoder().encode(raw)
    }

    /// 解出来的字典**补齐缺省动作**：以后加了新动作，老用户那份配置里没有它，
    /// 读出来就得用出厂键补上 —— 否则那个动作会一直是个「按了没反应」的死键。
    public static func decode(_ data: Data) -> [ShortcutAction: ShortcutBinding] {
        guard let raw = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data)
        else { return Self.defaults() }
        var result = Self.defaults()
        for (key, binding) in raw {
            guard let action = ShortcutAction(rawValue: key) else { continue }
            result[action] = binding
        }
        return result
    }

    /// 出厂绑定全表。
    public static func defaults() -> [ShortcutAction: ShortcutBinding] {
        var result: [ShortcutAction: ShortcutBinding] = [:]
        for action in ShortcutAction.allCases { result[action] = action.defaultBinding }
        return result
    }
}

// MARK: - 复习卡上的按键提示

/// 复习卡底部那行提示用的是**当前**绑定，不是写死的「空格 / 1 / 2 / R」。
///
/// 用户在设置里把「记得」改成别的手指位以后，卡上却还写着旧键 —— 那就是界面在撒谎。
public struct ReviewShortcutHints: Sendable, Equatable {

    public var reveal: String
    public var remembered: String
    public var forgotten: String
    public var speak: String

    public init(
        reveal: String,
        remembered: String,
        forgotten: String,
        speak: String
    ) {
        self.reveal = reveal
        self.remembered = remembered
        self.forgotten = forgotten
        self.speak = speak
    }

    public init(bindings: [ShortcutAction: ShortcutBinding]) {
        self.init(
            reveal: (bindings[.reviewReveal] ?? ShortcutAction.reviewReveal.defaultBinding).displayString,
            remembered: (bindings[.reviewRemembered] ?? ShortcutAction.reviewRemembered.defaultBinding).displayString,
            forgotten: (bindings[.reviewForgotten] ?? ShortcutAction.reviewForgotten.defaultBinding).displayString,
            speak: (bindings[.reviewSpeak] ?? ShortcutAction.reviewSpeak.defaultBinding).displayString
        )
    }
}
