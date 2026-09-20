import AIDomain
import AppKit

/// 全局按键监听：把「按下的键」翻译成「该跑哪个动作」。
///
/// 为什么不用 SwiftUI 的 `.keyboardShortcut`：那个写法只能挂在某个具体视图上，
/// 而这里要的是**跨页面**的键（在词典页按 ⌘1 也要回练习页），并且要能让用户在
/// 设置里改掉它 —— 改完还得立刻生效。所以统一由这一个本地事件监视器分发。
///
/// ⚠️ **与菜单的关系**：「前往」菜单上的等价键只负责**显示**，
/// 真正分发的是这里 —— 这里命中就返回 nil 把事件吃掉，菜单因此不会同一次按键跑两遍。
/// （放给菜单自己处理的话，用户在设置里改过的键和菜单上写死的键会各说各的。）
@MainActor
public final class ShortcutMonitor {

    private var monitor: Any?
    private let handle: (ShortcutEventKey) -> Bool

    /// - Parameter handle: 返回「这个键是不是归快捷键管」；true 就把事件吃掉。
    public init(handle: @escaping (ShortcutEventKey) -> Bool) {
        self.handle = handle
    }

    public var isInstalled: Bool { monitor != nil }

    public func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, let key = Self.eventKey(event), self.handle(key) else { return event }
            // 吃掉：否则同一个键还会被菜单的等价键再处理一次。
            return nil
        }
    }

    public func remove() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    // MARK: - AppKit 侧的事实（纯函数层拿不到，只有这里能问）

    /// 光标此刻是不是在一个文本输入框里。
    ///
    /// ⚠️ 判据是**第一响应者的类型**：输入框获得焦点后，真正持有第一响应者的是
    /// 字段编辑器（`NSTextView`），而不是 `NSTextField` 本身 —— 只认 `NSTextField`
    /// 会在聊天框里彻底失灵（那正是最需要保住打字的地方）。
    public static func isTextInputFocused() -> Bool {
        // ⚠️ `NSApp` 是**隐式解包**的 Optional：在没有 NSApplication 的进程里它就是 nil，
        // 直接读会当场崩（单测进程就是这么崩的）。没有 App 就等于没有窗口，也就没有输入框。
        guard let app = NSApp else { return false }
        guard let responder = app.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
    }

    /// 一次按键 → 规范化描述（拿不到字符的键返回 nil，交给系统照常处理）。
    static func eventKey(_ event: NSEvent) -> ShortcutEventKey? {
        // 这几个键没有可打印字符（`characters` 是空格 / 换行 / 空），
        // 只能靠 keyCode 认 —— 它们的 keyCode 在所有键盘布局上都是固定的。
        let key: String
        switch event.keyCode {
        case 49: key = "space"
        case 36: key = "return"
        case 53: key = "escape"
        case 48: key = "tab"
        case 51: key = "delete"
        default:
            // 用「忽略修饰键的字符」：⌘R 拿到的是 "r" 而不是 "®"，
            // ⇧R 拿到 "R"（`ShortcutEventKey` 会统一压成小写，修饰键另记）。
            guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return nil }
            key = chars
        }
        let flags = event.modifierFlags
        return ShortcutEventKey(
            key: key,
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control)
        )
    }
}
