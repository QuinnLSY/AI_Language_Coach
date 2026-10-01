import AIDomain
import AppUI
import SwiftUI

@main
@MainActor
struct AILanguageCoachApp: App {

    @State private var state = AppState()

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
            // 设置：SwiftUI 只会为独立的 `Settings` 场景自动提供 ⌘,，
            // 而本应用的设置是**浮在内容之上的浮层**（打开它不关掉底下那一页），
            // 所以这一项要自己接管 —— 否则 ⌘, 会静默失效。
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { state.showingSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
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
