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
                .frame(minWidth: 1080, minHeight: 720)
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

            // 「前往」菜单：与侧栏读同一份 `AppSection`，
            // 编号就是它在侧栏里的位置（加页面只改枚举，编号自动跟着变）。
            CommandMenu("前往") {
                ForEach(AppSection.allCases) { section in
                    Button(section.title) {
                        Task { await state.go(to: section) }
                    }
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(section.shortcutDigit)")),
                        modifiers: .command
                    )
                }
            }
        }
    }
}
