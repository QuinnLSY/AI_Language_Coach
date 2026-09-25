import XCTest

@testable import AppCore
@testable import AppUI

/// 应用内动效开关（MotionMode 三态）+ 第二批微交互的接线哨兵（2026-09-25）。
///
/// 覆盖档有**两条**生效路径（环境注入 / 非 View 的 `Animation.app`），合成逻辑必须
/// 同一份真相 —— 所以纯函数在 `MotionMode.reducesMotion` 上，两处都调它，这里钉住真值表。
/// 接线哨兵管的是「线还在不在」：这类线一断不报错、只会静默回到旧行为，只能靠扫源码。
/// ⚠️ 哨兵扫描的字符串**不能出现在被扫文件的注释里**（注释里有同款字符串会假绿）。
final class MotionModeWiringTests: XCTestCase {

    // MARK: - MotionMode 真值表（纯函数）

    func testReducedModeForcesMotionOffRegardlessOfSystem() {
        XCTAssertTrue(MotionMode.reduced.reducesMotion(systemPrefers: false))
        XCTAssertTrue(MotionMode.reduced.reducesMotion(systemPrefers: true))
    }

    func testFullModeForcesMotionOnRegardlessOfSystem() {
        XCTAssertFalse(MotionMode.full.reducesMotion(systemPrefers: false))
        XCTAssertFalse(MotionMode.full.reducesMotion(systemPrefers: true))
    }

    func testFollowSystemDefersToTheSystemPreference() {
        XCTAssertEqual(
            MotionMode.followSystem.reducesMotion(systemPrefers: true),
            true
        )
        XCTAssertEqual(
            MotionMode.followSystem.reducesMotion(systemPrefers: false),
            false
        )
    }

    // MARK: - 非 View 链路（Animation.app 走的静态覆盖档）

    override func tearDown() {
        // 覆盖档是进程级静态：测完必须还原，否则串到同进程后续用例。
        AppMotionDescriptor.appOverride = nil
        super.tearDown()
    }

    func testOverrideReducedWinsOverSystemPreference() {
        AppMotionDescriptor.appOverride = .reduced
        XCTAssertTrue(AppMotionDescriptor.current().reduceMotion)
    }

    func testOverrideFullWinsOverSystemPreference() {
        AppMotionDescriptor.appOverride = .full
        XCTAssertFalse(AppMotionDescriptor.current().reduceMotion)
    }

    func testNilOverrideFallsBackToTheSystemWorkspaceFlag() {
        AppMotionDescriptor.appOverride = nil
        // 本机没开「减弱动态效果」→ 应为 false。若哪天测试机开了偏好，
        // 这条断言要跟着改成读 NSWorkspace 的实时值，而不是钉死 false。
        let systemPrefers = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        XCTAssertEqual(AppMotionDescriptor.current().reduceMotion, systemPrefers)
    }

    // MARK: - 接线哨兵（线断了不报错，只能扫源码）

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: "Sources/\(relativePath)", encoding: .utf8)
    }

    /// 应用根必须把**设置里的档位**传给注入器 —— 漏传的话 UI 上切了档也只影响
    /// `Animation.app` 那条路，View 树永远是「跟随系统」。
    func testRootInjectionPassesTheSettingsOverride() throws {
        let main = try source("AppUI/Views/MainView.swift")
        XCTAssertTrue(
            main.contains(".appMotionRoot(override: state.motionMode)"),
            "MainView 根注入要带上 state.motionMode"
        )
    }

    /// `AppState.start()` 必须从配置加载档位并写进静态覆盖档。
    /// 这是「手写 init / 启动加载漏赋值静默归零」那类事故的守卫：漏一行编译不报错，
    /// 用户设置永远不生效。
    func testStartLoadsMotionModeAndWritesTheOverride() throws {
        let appState = try source("AppUI/AppState.swift")
        XCTAssertTrue(
            appState.contains("motionMode = configuration.product.motionMode"),
            "start() 里漏了从配置加载 motionMode —— 用户上次的选择会被静默丢掉"
        )
        XCTAssertTrue(
            appState.contains("AppMotionDescriptor.appOverride = motionMode"),
            "start() 里漏了写静态覆盖档 —— withAnimation(.app(...)) 那条链路不跟档位走"
        )
        XCTAssertTrue(
            appState.contains("AppMotionDescriptor.appOverride = mode"),
            "setMotionMode 里漏了同步静态覆盖档 —— 设置页看着切了、实际没生效"
        )
    }

    /// 设置页必须有那张「动画效果」卡（用户明确要的应用内开关）。
    func testSettingsShowTheMotionCard() throws {
        let settings = try source("AppUI/Views/SettingsView.swift")
        XCTAssertTrue(settings.contains("motionCard"), "设置页要挂 motionCard")
        XCTAssertTrue(settings.contains("state.setMotionMode"), "卡片要接 setMotionMode")
    }

    /// 侧栏导航高亮条必须走 matched geometry（滑动而不是原地重画）。
    func testSidebarSelectionHighlightIsAMatchedGeometryEffect() throws {
        let sidebar = try source("AppUI/Components/AppSidebar.swift")
        XCTAssertTrue(sidebar.contains("@Namespace"), "侧栏缺 @Namespace")
        XCTAssertTrue(
            sidebar.contains("matchedGeometryEffect(id: \"nav-selection\""),
            "导航高亮条要挂 matchedGeometryEffect"
        )
        XCTAssertTrue(
            sidebar.contains(".animation(motion.animation(.panel), value: state.activeSection)"),
            "高亮滑动的事务要挂在 navList 容器上（activeSection 变化驱动）"
        )
    }

    /// 连续天数要数字滚动。
    func testStreakNumberUsesNumericTextTransition() throws {
        let badge = try source("AppUI/Components/StreakBadgeView.swift")
        XCTAssertTrue(badge.contains(".contentTransition(.numericText())"))
        XCTAssertTrue(
            badge.contains(".animation(motion.animation(.reveal), value: badge.days)"),
            "数字滚动要有动画事务驱动，否则 transition 不生效"
        )
    }

    /// 聊天气泡插入：过渡与动画事务必须**成对**出现 —— 只有 transition 没有事务
    /// 是这个项目里真实存在过的静默失效（transition 从不带动画 = 瞬间出现）。
    func testChatBubbleInsertionHasBothTransitionAndTransaction() throws {
        let chat = try source("AppUI/Views/ChatView.swift")
        XCTAssertTrue(
            chat.contains(".move(edge: .bottom).combined(with: .opacity)"),
            "新消息要从底部推入"
        )
        XCTAssertTrue(
            chat.contains(".appAnimation(.reveal, value: chat.visibleMessages.count)"),
            "消息容器要挂插入动画事务（count 变化驱动）"
        )
    }

    /// 结果反馈：结算成功要有触觉；挂载点必须在常驻容器（挂进 if let 等不到变化）。
    func testRewardSuccessHapticIsOnAPersistentContainer() throws {
        let main = try source("AppUI/Views/MainView.swift")
        XCTAssertTrue(
            main.contains(".sensoryFeedback(.success, trigger: state.lastReward)"),
            "结算成功要有触觉反馈"
        )
    }
}
