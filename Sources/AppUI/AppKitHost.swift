import AIServices
import AppKit
import Foundation

// MARK: - AppKit 侧那几个「只有真 .app 才能做」的动作
//
// 收在一处的理由：`NSApp` 在非 bundle 进程（`swift test` / xctest runner / 命令行可执行）
// 里虽然**存在**，但它的每一个动作都是施加在**宿主进程**上的：
//   - `activate(ignoringOtherApps:)` 会把 Xcode 或 Terminal 顶到前台，抢走正在打字的焦点；
//   - `setActivationPolicy(.accessory)` 会把测试宿主的 Dock 图标收起来；
//   - `terminate` 就更不用说了。
// 这些都是「代码没错、环境不对」的坑，散落各处迟早有人漏判据，所以判据只在这里写一遍。
@MainActor
public enum AppKitHost {

    /// 当前是不是被打成 `.app` 在跑（而不是测试 / 命令行进程）。
    ///
    /// ⚠️ 判据用 **bundlePath 后缀**：打包脚本产出的永远是 `.../AI_Language_Coach.app`；
    /// 测试宿主是 `.xctest`（或压根没有 bundle），命令行也没有 `.app`。
    /// 别改用 `bundleIdentifier != nil` —— SwiftPM 的产物也有 identifier，那条判不出来。
    public static var isPackedApp: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    /// 把主窗口叫到前面来（深链、“打开主窗口”都靠它）。
    public static func bringFront() {
        guard isPackedApp, let app = NSApp else { return }
        app.activate(ignoringOtherApps: true)
        // ⚠️ 收起 Dock 图标（accessory）时 `activate` 不会自动把主窗口浮出来 ——
        // 那一档下菜单栏是唯一的入口，不显式 orderFront 就等于按钮没反应。
        guard app.activationPolicy() == .accessory else { return }
        app.windows.filter(\.canBecomeMain).forEach { $0.makeKeyAndOrderFront(nil) }
    }

    /// 收起 / 恢复 Dock 图标。
    ///
    /// ⚠️ 调用方只有一处：菜单栏面板里的那行开关（理由写在 `MenuBarPanel` 的注释里）——
    /// Dock 图标一收，**菜单栏就是唯一还能找到这个应用的地方**，
    /// 把开关放在别处（比如设置页）等于留了一条把自己锁在外面的路。
    public static func setDockIconHidden(_ hidden: Bool) {
        guard isPackedApp, let app = NSApp else { return }
        app.setActivationPolicy(hidden ? .accessory : .regular)
    }

    /// 退出（面板上那颗「退出」）。
    ///
    /// 先做退出收尾 —— 停掉**本应用亲手拉起**的本地服务（Edge-TTS 代理、whisper 等），
    /// 见 `AppServiceShutdown`：收尾有界等待，超时也放行，退出不会被卡死。
    /// `services` 为 nil（拿不到状态源）时跳过收尾直接退。
    public static func terminate(services: CoachServices? = nil) {
        guard isPackedApp else { return }
        if let services { AppServiceShutdown.run(services: services) }
        NSApp?.terminate(nil)
    }
}

// MARK: - 应用级委派：冷启动那一下由 UNSNotification 之外这条路进来
//
// 为什么不用 SwiftUI 的 `.onOpenURL`：**冷启动**那一下（应用没在跑，用户敲 `open alc://…`）
// 文档从不保证何时回调，实测也不总是能收到。而 `NSApplicationDelegate.application(_:open:)`
// 是 LaunchServices 的原始落点，冷启动与运行时都从这里进。
@MainActor
public final class AppURLDelegate: NSObject, NSApplicationDelegate {

    public static let shared = AppURLDelegate()

    /// UI 状态源（`weak`：应用进程里它活得比谁都久，这里是借用不是拥有）。
    public weak var state: AppState?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        guard let state else { return }
        MenuBarController.shared.install(state: state)
        // 上次退出前收起了 Dock 图标：这一次的 activation policy 要跟着摆回同一档，
        // 否则会「开关显示已收起，Dock 上图标还在」。
        AppKitHost.setDockIconHidden(state.dockIconHidden)
        Task { @MainActor in await state.drainPendingDeepLinks() }
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { state?.receiveDeepLink(url) }
    }

    /// 退出兜底：⌘Q / App 菜单「退出」/ Dock 右键退出都会落到这里
    /// （`AppKitHost.terminate(services:)` 里的收尾在前，这里再跑一遍是幂等的 ——
    /// 登记簿「停成功即注销」，在册为空时直接返回，不会双停）。
    ///
    /// 单独要它的理由：Dock 右键退出、系统关机等路径**不经过**我们的菜单项，
    /// 没有这一条，那些路径退出后本地服务照样残留。
    public func applicationWillTerminate(_ notification: Notification) {
        if let state { AppServiceShutdown.run(services: state.services) }
    }
}
