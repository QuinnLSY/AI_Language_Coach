import CoreGraphics

/// 窗口布局档位（#417 窄窗降级）——**纯函数，唯一真相**。
///
/// 为什么收进来一个 enum：窗口最小尺寸此前在 `AppMain` 与 `MainView`
/// **各写一遍**（1080×720），改一处漏一处就是「设置说能缩到 880、窗口卡在 1080」
/// 这种两边对不上的静默 bug；窄窗要降级的判据（侧栏何时收成图标栏）同理。
/// 所有「多小算窄、窄了怎么办」的数字只住在这里。
public enum AppLayoutMetrics {

    // MARK: - 窗口约束（AppMain 与 MainView 共用一份）

    /// 窗口最小宽。1080 → 880：窄窗时侧栏自动收成图标栏（省 144pt），
    /// 三栏在这个宽度下依然摆得开（树 ≥300、聊天 ≥400，见 `treeWidth`）。
    public static let minWindowWidth: CGFloat = 880
    /// 窗口最小高。720 → 640：矮窗时侧栏导航列表自己滚（不再压扁头部）。
    public static let minWindowHeight: CGFloat = 640

    // MARK: - 侧栏

    /// 窗口宽低于这条线，侧栏**临时**收成图标栏（76pt）。
    ///
    /// 为什么是 1000：新下限（树 260 / 聊天 340）下 880 宽**摆得开**三栏，
    /// 但展开侧栏时树被压到 ~305 —— 880–999 这个区间「能摆下」和「好看」是两回事，
    /// 树画布在 300 上下时关卡节点挤成一团。窄窗宁可让导航收成图标，把宽度还给
    /// 聊天与树。这是「窗口说了算」的派生值，**不写回**用户偏好 ——
    /// 窗口拉宽自动还原，用户手动收起/展开的偏好原样保留。
    public static let sidebarCollapseBelow: CGFloat = 1000

    /// 侧栏此刻是否展开 = 用户偏好 ∧ 窗口允许。
    public static func sidebarExpanded(userPrefers: Bool, windowWidth: CGFloat) -> Bool {
        userPrefers && windowWidth >= sidebarCollapseBelow
    }

    // MARK: - 宽度分配

    /// 聊天区最小宽。窄窗档下让位：400 → 340（880 宽也摆得下三栏）。
    public static let chatMinWidth: CGFloat = 340
    /// 成长之树最小宽。300 → 260：树画布在 <336 时本来就会退化（ForestGroundPlan）。
    public static let treeMinWidth: CGFloat = 260

    /// 树宽夹取：[树下限, 可用宽 − 聊天下限]。
    ///
    /// 从 `MainView.treeWidth` 挪来：夹取公式与两个下限必须同源，
    /// 否则「Metrics 说 880 摆得开、MainView 的旧下限说摆不开」各执一词。
    public static func treeWidth(preferred: CGFloat, available: CGFloat) -> CGFloat {
        let upper = max(treeMinWidth, available - chatMinWidth)
        return min(max(preferred, treeMinWidth), upper)
    }

    // MARK: - 浮层高度

    /// 考后结算卡的高度：设计高 660，**矮窗下必须夹到可用高以内**。
    ///
    /// 为什么非夹不可：#417 把窗口最小高从 720 降到 640 之后，660 的卡片在最小窗口里
    /// 上下各被切掉 10pt。这张卡的出口**只有**底部「再来一次 / 完成」两个按钮
    /// （点遮罩不关，注释里写明了），底部被切就等于「考完出不来」。
    /// 卡内正文区本来就是 ScrollView，压矮只是多滚一点。
    public static func examReportHeight(available: CGFloat) -> CGFloat {
        min(660, max(420, available - 40))
    }
}
