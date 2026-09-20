import Foundation

/// 提示条上挂的那一个动作（「重试」这类）。
@MainActor
public struct NoticeAction {

    public var title: String
    public var run: () -> Void

    public init(title: String, run: @escaping () -> Void) {
        self.title = title
        self.run = run
    }

    /// 「重试」：失败提示上最常见的那一个。
    public static func retry(_ run: @escaping () -> Void) -> NoticeAction {
        NoticeAction(title: "重试", run: run)
    }
}

/// 一条界面提示：**文案与动作绑成一个值**。
///
/// 为什么不拆成 `notice: String?` + `noticeAction: NoticeAction?` 两个属性：
/// 拆开就一定会出现「上一条失败留下的『重试』挂在下一条不相干的文案上」——
/// 点下去重试的是上一次那件事，界面上却写着这一次的错。绑成一个值以后，
/// 写文案那一刻必须顺带决定「这条有没有重试」，想漏也漏不掉（漏了就编译不过）。
@MainActor
public struct AppNotice {

    public var text: String
    /// nil = 这条只是告知，没有可重试的动作（比如「已经在词汇本里了」）。
    public var action: NoticeAction?

    public init(text: String, action: NoticeAction? = nil) {
        self.text = text
        self.action = action
    }
}
