import AIDomain
import AppUI
import SwiftUI

@main
@MainActor
struct AILanguageCoachApp: App {

    @State private var state = AppState()

    /// 应用级委派：冷启动的 `alc://` 落在它那里（`AppURLDelegate` 里有说明），
    /// 菜单栏图标也在它 `applicationDidFinishLaunching` 时才装。
    @NSApplicationDelegateAdaptor(AppURLDelegate.self) var appDelegate

    init() {
        // ⚠️ 这里刻意自己建好 `AppState` 再交给 delegate：
        // delegate 的 `applicationDidFinishLaunching` 要用它装菜单栏、处理排队的深链，
        // 而那一次回调发生在 App 之外，拿不到 SwiftUI 内部的 `@State` 值。
        let created = AppState()
        _state = State(initialValue: created)
        appDelegate.state = created
    }

    var body: some Scene {
        WindowGroup {
            MainView(state: state)
                // ⚠️ 与 MainView 里那份是**同一个常量**（AppLayoutMetrics）——
                // 此前两处各写一遍 1080×720，改一处漏一处就是两边对不上的静默 bug。
                .frame(minWidth: AppLayoutMetrics.minWindowWidth,
                       minHeight: AppLayoutMetrics.minWindowHeight)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 820)
        .commands {
            // ⚠️ 关掉「新建窗口 ⌘N」：本应用只有一个窗口的份。
            //
            // `AppState` 是**每个窗口各建一份**（`@State private var state` 在 App 上），
            // 不是共享单例 —— 开第二个窗口就会同时跑起第二套 `CoachServices`：
            // 第二条数据库连接、第二个 `MicrophoneRecorder`、第二个 `installShortcutMonitor()`
            // （两个监听抢同一批按键）、两个 `ModelLifecycleManager` 互相挂起对方刚拉起的模型。
            // 表现出来就是「两个窗口数据不同步、点一下跳两页、录音打架」，
            // 而 macOS 默认会给每个 App 挂上 ⌘N —— 用户随手一按就中招。
            // 空 `CommandGroup(replacing:)` = 把这个菜单项整个拿掉（不是禁用，是不存在）。
            CommandGroup(replacing: .newItem) { }

            // 设置：SwiftUI 只会为独立的 `Settings` 场景自动提供 ⌘,，
            // 而本应用的设置是**浮在内容之上的浮层**（打开它不关掉底下那一页），
            // 所以这一项要自己接管 —— 否则 ⌘, 会静默失效。
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { state.showingSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }

            // 退出（自停）：接管 ⌘Q，退出前先停掉**本应用亲手拉起**的本地服务
            // （Edge-TTS 代理、whisper 等）—— 见 `AppServiceShutdown`。
            // 不接管的话，⌘Q 走系统默认项直接退出，那些服务会残留成孤儿进程。
            // ⚠️ 与全局快捷键系统不冲突：`ShortcutAction` 里没有 quit 动作，
            // `ShortcutMonitor` 不会同吃这一次按键。
            CommandGroup(replacing: .appTermination) {
                Button("退出语林") { AppKitHost.terminate(services: state.services) }
                    .keyboardShortcut("q")
            }

            // 帮助（#413）：系统那个「Help」菜单默认指向应用自己的帮助书册（本应用没有），
            // 换成直接开应用内帮助中心 —— 说明不该只有「先打开设置、再滚到第一张卡」这一条路。
            CommandGroup(replacing: .help) {
                Button("语林使用说明") { state.showingHelp = true }
                    .keyboardShortcut("/", modifiers: .command)
            }

            // 「前往」菜单：与侧栏读同一份 `AppSection`，
            // 编号就是它在侧栏里的位置（加页面只改枚举，编号自动跟着变）。
            //
            // ⚠️ 菜单上的等价键**只负责显示**：真正分发的是 `ShortcutMonitor`
            // （它在命中时会把事件吃掉，菜单不会同一次按键跑两遍）。
            // 所以这里必须读**用户改过的**绑定 —— 显示成出厂键就是在撒谎。
            CommandMenu("前往") {
                ForEach(AppSection.allCases) { section in
                    Button(section.title) {
                        Task { await state.go(to: section) }
                    }
                    .modifier(MenuKeyHint(binding: menuBinding(for: section)))
                }
            }
        }
    }

    /// 某一页当前绑的键（没配过就是出厂键）。
    private func menuBinding(for section: AppSection) -> ShortcutBinding {
        guard let action = ShortcutAction.navigationAction(for: section) else {
            return ShortcutBinding(key: "\(section.shortcutDigit)", command: true)
        }
        return state.shortcutBinding(for: action)
    }
}

/// 菜单项上的按键提示。
///
/// ⚠️ **无修饰键的绑定一律不挂**：菜单等价键在打字时也会命中，
/// 而真正分发处（`ShortcutMonitor`）已经按「光标是否在输入框里」放过行了 ——
/// 再挂上去等于绕过那道护栏，用户在聊天框里打 "p" 就会跳页。
private struct MenuKeyHint: ViewModifier {

    var binding: ShortcutBinding

    func body(content: Content) -> some View {
        if let equivalent = Self.equivalent(for: binding) {
            content.keyboardShortcut(equivalent, modifiers: Self.modifiers(for: binding))
        } else {
            content
        }
    }

    private static func equivalent(for binding: ShortcutBinding) -> KeyEquivalent? {
        guard !binding.isPlainKey else { return nil }
        switch binding.key {
        case "space": return .space
        case "return": return .return
        case "escape": return .escape
        case "tab": return .tab
        case "delete": return .delete
        default:
            guard let scalar = binding.key.first, binding.key.count == 1 else { return nil }
            return KeyEquivalent(scalar)
        }
    }

    private static func modifiers(for binding: ShortcutBinding) -> EventModifiers {
        var mods: EventModifiers = []
        if binding.command { mods.insert(.command) }
        if binding.shift { mods.insert(.shift) }
        if binding.option { mods.insert(.option) }
        if binding.control { mods.insert(.control) }
        return mods
    }
}
