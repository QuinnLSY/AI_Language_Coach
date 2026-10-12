import AppKit
import SwiftUI

// MARK: - 状态栏那枚叶子 + 弹出的小面板
//
// 为什么不用 SwiftUI 的 `MenuBarExtra`：
// ① 它的面板尺寸与位置由系统掌管，自绘控件（本项目里的胶囊按钮、分区底卡）在里面的排版
//    不可预测，而项目在菜单这类控件上一贯是自绘（`MenuPopUpHitArea` 那条铁律同源）；
// ② 这里要能让 SwiftUI 面板动态高度、每次打开都是最新数据 —— 自管 `NSPopover` 才做得到。
//
// ⚠️ 只在真的 `.app` 里装（`AppKitHost.isPackedApp`）：测试进程里往系统状态栏塞一枚图标，
// 是「看不见但真实存在」的副作用，跑完一批测试整条菜单栏多了几个东西。
@MainActor
public final class MenuBarController: NSObject, NSPopoverDelegate {

    public static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private weak var state: AppState?

    private override init() { super.init() }

    /// 装上状态栏图标。重复调用无害（第二次直接返回）。
    public func install(state: AppState) {
        guard AppKitHost.isPackedApp, statusItem == nil else { return }
        self.state = state
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: "语林")
            // SF Symbol 默认是模板图，跟着菜单栏深浅自动变色 —— 不要自己着色。
            button.image?.isTemplate = true
            button.toolTip = "语林 · 今天练什么"
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        statusItem = item
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if let popover, popover.isShown {
            popover.performClose(sender)
            return
        }
        guard let state else { return }
        let root = NSHostingController(rootView: MenuBarPanelHost(state: state))
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = root
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // ⚠️ SwiftUI 那一侧的 fitting size 要等第一遍 layout 才算得出来，
        // 而这一遍是在 popover 已经铺上去之后发生的 —— 不补这一下，面板会按
        // `NSPopover` 的默认高度显示（内容被裁一段，看着像没画完）。
        DispatchQueue.main.async {
            root.preferredContentSize = root.view.fittingSize
        }
    }

    public func popoverDidClose(_ notification: Notification) {
        // 每次打开都重建： panel 的内容必须是**当下**的今日进度，不该留着上一份快照。
        popover?.contentViewController = nil
        popover = nil
    }
}

// MARK: - 面板与状态源的那一层薄薄的桥

/// 把 `AppState` 翻译成 `MenuBarPanel` 认的四个回调。
///
/// ⚠️ 这一层存在的唯一理由是让 `MenuBarPanel` 保持**纯渲染**（入参全是值或闭包），
/// 这样它才能进离屏渲染回归；而涌进讲的是 AppKit 生命周期，本来就不该混进那张卡里。
struct MenuBarPanelHost: View {

    let state: AppState

    var body: some View {
        MenuBarPanel(
            snapshot: state.menuBarSnapshot,
            dockIconHidden: state.dockIconHidden,
            onGo: { section in
                Task { @MainActor in await state.openFromMenuBar(section) }
            },
            onOpenMainWindow: { AppKitHost.bringFront() },
            onToggleDockIcon: { state.setDockIconHidden(!state.dockIconHidden) },
            onQuit: { AppKitHost.terminate() }
        )
        // ⚠️ popover 不在 MainView 的视图树里，收不到那一处的 `.appPressable` 注入 ——
        // 缺了它，面板上的按钮会退回系统默认外观（蓝色高亮块），与全应用不一致。
        .buttonStyle(.appPressable)
        .forestTheme(state.theme)
    }
}
