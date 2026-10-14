import AIDomain
import AppCore
import Foundation

// MARK: - AppState · 菜单栏常驻助手（⑦-A）
//
// 菜单栏解决的是留存链上漏得最凶的一环：**想起之后还得打开**。
// 平时用户在别的应用里，要打开语林是「切空间 → 找图标 → 双击」三步；
// 有了状态栏那枚叶子，一步点开就能看见今天还剩什么，点一颗按钮直接到那一页。
//
// ⚠️ 这一层**不自己算**：语录、排序、文案全在 `MenuBarAssistant` 的纯函数里，
// 这里只负责把真数据喂进去（同一条规矩：`WarmUpCard` 与 `WarmUp` 也是这个分工）。
extension AppState {

    /// 菜单栏那一屏的内容。
    ///
    /// 全部取自已有的派生量：`dailyPlan` 是快照的纯函数、`progressSnapshot` 是唯一统计口径 ——
    /// 所以菜单栏报的数字与首屏今日卷轴**逐字同源**（一致性由
    /// `MenuBarAssistantTests.testHeadlineMatchesTodayPanel` 钉着）。
    public var menuBarSnapshot: MenuBarAssistant.Snapshot {
        MenuBarAssistant.snapshot(
            plan: dailyPlan,
            streakDays: progressSnapshot.streakDays,
            todaySeconds: progressSnapshot.today.seconds,
            hasPracticeToday: progressSnapshot.today.hasPractice
        )
    }

    /// 从菜单栏跳到某一页。
    ///
    /// ⚠️ **先叫起窗口，再跳页**：反过来做的话，窗口在别的桌面 / 被别的应用挡着时，
    /// 用户看到的是「什么都没发生」—— 而数据其实已经切过去了。
    public func openFromMenuBar(_ section: AppSection) async {
        AppKitHost.bringFront()
        await go(to: section)
    }

    /// 收起 / 恢复 Dock 图标。
    ///
    /// ⚠️ 面板上的入口文案里写着「收起之后到这里来恢复」，所以这一行不能藏在设置里 ——
    /// Dock 图标一收，菜单栏就是唯一入口，用户得永远找得到这个开关。
    public func setDockIconHidden(_ hidden: Bool) {
        dockIconHidden = hidden
    }

    /// 显示 / 收起状态栏那枚叶子（设置页「显示」卡里的开关）。
    ///
    /// 与 Dock 图标的分工：那个收起了菜单栏就是唯一入口，开关必须永远够得着；
    /// 这个收起了应用照样从 Dock / 聚焦打开，所以开关放在设置里正合适。
    public func setStatusBarIconHidden(_ hidden: Bool) {
        statusBarIconHidden = hidden
    }
}
