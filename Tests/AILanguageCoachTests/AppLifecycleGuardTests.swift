import XCTest

/// 应用生命周期两处接线哨兵（2026-10-02 止血批）。
///
/// 这两件事都**测不到运行时行为**（SwiftUI 的 Scene 命令、视图里的定时器），
/// 只能钉在源码上：谁哪天把那一行删了，这里的用例立刻变红。
final class AppLifecycleGuardTests: XCTestCase {

    // MARK: - ⌘N 不许开出第二个 AppState

    /// `AppState` 是每个窗口各建一份，不是共享单例 —— 开第二个窗口就是第二套
    /// `CoachServices`：第二条数据库连接、第二个录音器、第二个按键监听器（两个一起吃
    /// 同一次按键）、两个资源巡检互相挂起对方刚拉起的模型。
    /// 而 macOS 默认给每个 App 都挂了「新建窗口 ⌘N」，用户随手一按就中招。
    func testAppMainRemovesTheNewWindowCommand() throws {
        let raw = try Self.code("Sources/AppMain/AppMain.swift")
        XCTAssertTrue(raw.contains("CommandGroup(replacing: .newItem)"),
                      "必须把「新建窗口」这个菜单项整个拿掉：本应用只有一个窗口的份")
    }

    // MARK: - 打字点不许泄漏定时器

    /// 旧写法是 `Timer.scheduledTimer(...)` 写在 `onAppear` 里：既没保存引用，
    /// 也没有 `onDisappear` 去 invalidate —— 每出现一次「正在输入」就永久多一个
    /// 0.35 秒定时器（闭包还捕获着视图），应用久开后闲着也在周期性叫醒主线程。
    func testTypingDotsUsesALifecycleBoundTimer() throws {
        let raw = try Self.code("Sources/AppUI/Views/ChatView.swift")
        XCTAssertFalse(raw.contains("Timer.scheduledTimer"),
                       "定时器必须随视图生命周期自动断开，不能靠谁记得去 invalidate")
        XCTAssertTrue(raw.contains("Timer.publish(every: 0.35"),
                      "三点动画本身要保留（它是「正在等待」的唯一提示），只是换一种接法")
    }

    /// 读源码，剥掉注释行 —— 注释里为了说明反例而写的旧写法不该把判据自己骗过去。
    private static func code(_ path: String) throws -> String {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
