import AIDomain
import AIInfrastructure
import AIServices
import AppCore
@testable import AppUI
import XCTest

/// ⑦-A 菜单栏与深链的**接线**。
///
/// 纯函数全绿不代表这一屏读的是真数据：
/// 菜单栏要是写死一句「今日 0/3」，单测照样通过，而用户看着的是一句假的进度。
/// 这一层钉的就是「派生那一步」。
///
/// ⚠️ 另外三条是**源码哨兵**：`alc://` 的 scheme 注册在打包脚本里、
/// 委派回调落在 `AppMain` 里 —— 这两处删一行都不会有任何编译错误，只会在
/// 装好了的应用上表现为「敲 open alc://review 没反应」，最难查。
@MainActor
final class MenuBarWiringTests: XCTestCase {

    // MARK: - 菜单栏那屏读的是真快照

    func testSnapshotReadsTheRealStreak() {
        let state = makeState()
        XCTAssertFalse(
            state.menuBarSnapshot.detail.contains("连续"),
            "快照里连续天数还是 0 的时候不该提连续"
        )

        state.progressSnapshot.streakDays = 5
        XCTAssertTrue(
            state.menuBarSnapshot.detail.contains("连续 5 天"),
            "连续天数变了面板得跟着变 —— 写死一句的假派生会在这里红"
        )
    }

    func testSnapshotReadsTheRealDuration() {
        let state = makeState()
        state.progressSnapshot.today.seconds = 754
        XCTAssertTrue(
            state.menuBarSnapshot.detail.contains(ProgressAggregator.durationText(754)),
            "今天练了多久必须取自真快照"
        )
    }

    /// 「现在该按」的那颗必须是**真的**还没做完的那一项。
    func testPrimaryFollowsTheRealPlan() {
        let state = makeState()
        // 空快照 → 三项里 conversation / shadowing 会排出来（review 要今天起初有到期词才排），
        // 全都没做完。主按钮该落在排在最前的那一件上。
        guard let next = state.dailyPlan.nextTask else { return XCTFail("空快照也该排出今日任务") }
        XCTAssertEqual(state.menuBarSnapshot.primary?.section, AppSection(next.kind))
        XCTAssertEqual(state.menuBarSnapshot.primary?.title, next.title)
    }

    // MARK: - 深链：没准备好之前不许动页面

    /// 冷启动那条路径：AppState 还在 start 的前半段就收到了地址。
    /// 这时跳页 = 落在一页还没加载的空页面上。
    func testEarlyLinkIsQueuedNotApplied() {
        let state = makeState()
        XCTAssertFalse(state.isDeepLinkReady, "没 start 过就叫没准备好")

        state.receiveDeepLink(Self.url("alc://vocabulary"))

        XCTAssertEqual(state.pendingDeepLinks.count, 1, "收进来先排队")
        XCTAssertEqual(state.activeSection, .practice, "没准备好时不许动页面")
    }

    func testQueuedLinkAppliesAfterDrain() async throws {
        let state = makeState()
        state.receiveDeepLink(Self.url("alc://vocabulary"))

        await state.drainPendingDeepLinks()

        XCTAssertEqual(state.activeSection, .vocabulary, "排队的地址在处理时要把人送到那一页")
        XCTAssertTrue(state.pendingDeepLinks.isEmpty, "处理完要清干净，不能反复执行")
    }

    /// 准备好了之后进来的是**立刻执行**，不该还要谁再敲一下。
    func testReadyLinkAppliesRightAway() async throws {
        let state = makeState()
        state.isDeepLinkReady = true

        state.receiveDeepLink(Self.url("alc://writing"))
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(state.pendingDeepLinks.isEmpty, "就绪时不再排队")
        XCTAssertEqual(state.activeSection, .writing)
    }

    /// 认不出来的地址悄悄丢掉 —— 系统不会把别人的 scheme 发到这里来。
    func testUnrecognizedLinkIsDropped() {
        let state = makeState()
        state.receiveDeepLink(Self.url("https://example.com/x"))
        state.receiveDeepLink(Self.url("alc://definitely-not-a-page"))
        XCTAssertTrue(state.pendingDeepLinks.isEmpty)
    }

    // MARK: - 菜单栏跳页

    func testOpenFromMenuBarSwitchesSection() async {
        let state = makeState()
        await state.openFromMenuBar(.shadowing)
        XCTAssertEqual(state.activeSection, .shadowing)
    }

    /// Dock 图标开关要落盘：这是「恢复得回来」的唯一依据 ——
    /// 一旦收起图标，菜单栏是唯一入口，抽奖不到上次的选择就等于把用户锁在外面。
    func testDockIconPreferencePersists() {
        let before = UserDefaults.standard.bool(forKey: AppState.dockIconHiddenKey)
        addTeardownBlock { UserDefaults.standard.set(before, forKey: AppState.dockIconHiddenKey) }

        let state = makeState()
        state.setDockIconHidden(true)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: AppState.dockIconHiddenKey))
        state.setDockIconHidden(false)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: AppState.dockIconHiddenKey))
    }

    // MARK: - 源码哨兵（删一行也不会编译报错的那几处）

    func testAppMainHandsStateToTheDelegate() throws {
        let raw = try Self.code("Sources/AppMain/AppMain.swift")
        XCTAssertTrue(raw.contains("@NSApplicationDelegateAdaptor(AppURLDelegate.self)"),
                      "委派不挂上去，冷启动的 alc:// 没人接")
        XCTAssertTrue(raw.contains("appDelegate.state = created"),
                      "state 必须在 App init 里递过去 —— 回调到达时拿不到 @State 里的那份")
    }

    /// `.ask` 那条分支最容易被人改成「只跳页不说话」：
    /// 那时用户点进来看到的是一个空输入框，而不是已经发出去的那句话。
    ///
    /// ⚠️ 顺序必须钉**区间**：`openPractice()` 与 `sendChat(text)` 互换之后，
    /// 两条各自 `contains` 照样全绿，而用户看到的是消息落在别的页面上。
    func testAskRouteStillSendsTheSentence() throws {
        let raw = try Self.code("Sources/AppUI/AppState+DeepLink.swift")
        XCTAssertTrue(raw.contains("case let .ask(text):"), "ask 分支要还在")
        guard let openRange = raw.range(of: "await openPractice()"),
              let sendRange = raw.range(of: "_ = sendChat(text)")
        else {
            return XCTFail("ask 分支必须「先到练习页、再把这句话发出去」—— 两行都得在")
        }
        XCTAssertTrue(
            openRange.lowerBound < sendRange.lowerBound,
            "顺序反了：消息会发在当前页面的会话里，用户看不到自己那句去了哪儿"
        )
    }

    /// scheme 注册只写在打包脚本里：不注册，`open alc://…` 会说「找不到能打开的应用程序」。
    func testPackagingRegistersTheScheme() throws {
        let raw = try Self.code("Scripts/make_app.sh")
        XCTAssertTrue(raw.contains("CFBundleURLSchemes"), "Info.plist 里要注册 URL scheme")
        XCTAssertTrue(raw.contains("<string>alc</string>"), "scheme 名与 AppDeepLink.scheme 必须一致")
    }

    /// 状态栏图标不许在测试进程里装上（`AppKitHost.isPackedApp` 那道闸）。
    func testMenuBarInstallGuardsUnpackedProcesses() throws {
        let raw = try Self.code("Sources/AppUI/MenuBarController.swift")
        XCTAssertTrue(raw.contains("guard AppKitHost.isPackedApp, statusItem == nil else { return }"))
    }

    // MARK: - 工装

    private static func url(_ raw: String) -> URL {
        URL(string: raw) ?? URL(fileURLWithPath: "/")
    }

    private func makeState() -> AppState {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("alc-menubar-\(UUID().uuidString).json")
        )
        // ⚠️ 必须 `:memory:`：裸 `CoachServices()` 的库路径是 nil，会落到真实学习库上。
        return AppState(services: CoachServices(config: store, databasePath: ":memory:"))
    }

    /// 读源码并剥掉注释行 —— 注释里为了说明反例写的旧写法不该把判据自己骗过去。
    private static func code(_ path: String) throws -> String {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
