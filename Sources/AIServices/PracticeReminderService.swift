import Foundation
import UserNotifications

// MARK: - 本地定时练习提醒（#226）
//
// 分层说明：这是**本机系统能力的薄封装**，与 `ModelLifecycleManager` 同层（AIServices）。
// 它只做三件事：
// 1. 把产品配置（开关 + 时刻）同步成一条**每日重复**的系统通知；
// 2. 管授权（未授权时请求一次；被拒绝时如实上报，绝不崩）；
// 3. 用户点通知 → 回调 `onOpenToday`（AppState 接走：激活窗口 + 展开今日黑板）。
//
// 纯逻辑（文案、时刻合法性）都在领域层 / 配置层 —— 本类**没有可单测的分支**，
// 且 `UNUserNotificationCenter` 在无签名单测进程里不可用，所以测试只覆盖纯函数。

/// 本地定时练习提醒调度器。
///
/// ⚠️ 实例必须被长期持有（AppState 持有）：`UNUserNotificationCenter.delegate`
/// 是**弱引用**，实例被释放后点通知的回调就静默失效了。
public final class PracticeReminderService: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {

    /// 每日提醒的通知标识前缀（重排前先按前缀清掉旧的，避免堆积）。
    private static let identifierPrefix = "practice-reminder.daily"

    /// 用户点了通知（要求「点击直接进今天」）。AppState 在主线程接手后续。
    public var onOpenToday: (@Sendable () -> Void)?

    /// 最近一次同步后的授权状态（设置页如实展示；只在主线程读写）。
    public private(set) var authorizationDenied = false
    /// 授权还没问过（开关刚打开时要去请求，设置页提示「将弹出系统授权框」）。
    public private(set) var authorizationNotDetermined = true

    /// 通知中心**惰性获取**。
    ///
    /// ⚠️ 绝不能在 init / 存储属性里调 `UNUserNotificationCenter.current()`：
    /// 无 bundle 的进程（单测 / CLI）里它直接崩（`bundleProxyForCurrentProcess is nil`）。
    /// 拖到第一次 `sync` 才触达 —— 只有真实 app 会走到那里。
    private var _center: UNUserNotificationCenter?
    private var center: UNUserNotificationCenter {
        if let _center { return _center }
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        _center = c
        return c
    }

    // MARK: 同步（设置改动 / 启动都走这里）

    /// 通知能力是否可用：只有**打包成 .app** 的真实应用才有通知中心。
    /// 无 bundle 的进程（单测 / CLI）里 `UNUserNotificationCenter.current()`
    /// 直接崩（`bundleProxyForCurrentProcess is nil`）—— 先探测再触达。
    private static var notificationsAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// 把配置同步成实际的系统通知。
    ///
    /// - 关：清掉所有待发提醒（不再发），不动授权。
    /// - 开：按需请求授权 → 成功才排每日通知；被拒绝只记状态。
    ///
    /// - Parameters:
    ///   - enabled: 提醒开关。
    ///   - requestIfNeeded: 授权未定时是否弹系统授权框。**只有用户主动打开开关时才弹**
    ///     （启动时静默同步配置传 false，别一开应用就糊一张系统框）。
    ///   - hour/minute: 每日提醒时刻（24 小时制）。
    ///   - title/body: 通知文案（领域层 `TodayPanel.practiceReminderCopy` 产出）。
    /// - Returns: 授权是否被拒绝（设置页用来给一句指引；false = 正常或未开启）。
    @discardableResult
    public func sync(
        enabled: Bool,
        requestIfNeeded: Bool = true,
        hour: Int,
        minute: Int,
        title: String,
        body: String
    ) async -> Bool {
        guard Self.notificationsAvailable else { return false }

        guard enabled else {
            await cancelPending()
            authorizationDenied = false
            return false
        }

        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            authorizationDenied = false
            authorizationNotDetermined = false
        case .notDetermined:
            guard requestIfNeeded else { return false }
            // 用户主动打开开关：替用户问一次系统授权框。
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            authorizationNotDetermined = false
            authorizationDenied = !granted
            guard granted else { await cancelPending(); return true }
        default:
            // .denied（含临时异常）：如实记录，不弹框、不崩、不再骚扰。
            authorizationDenied = true
            authorizationNotDetermined = false
            await cancelPending()
            return true
        }

        await schedule(hour: hour, minute: minute, title: title, body: body)
        return false
    }

    // MARK: 排 / 清

    private func schedule(hour: Int, minute: Int, title: String, body: String) async {
        let clampedHour = min(max(hour, 0), 23)
        let clampedMinute = min(max(minute, 0), 59)

        // 先清旧的再排新的：改时刻不会残留两条（标识固定只有一条，双保险）。
        await cancelPending()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        var components = DateComponents()
        components.hour = clampedHour
        components.minute = clampedMinute
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(
            identifier: Self.identifierPrefix + ".default", content: content, trigger: trigger
        )
        try? await center.add(request)
    }

    private func cancelPending() async {
        // async 版拉取（回调版会触发 Swift 6 告警）。
        let requests = await center.pendingNotificationRequests()
        let ids = requests
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) }
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    // MARK: UNUserNotificationCenterDelegate（点通知 → 进「今天」）

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard response.notification.request.identifier.hasPrefix(Self.identifierPrefix) else {
            completionHandler()
            return
        }
        // Swift 6：`completionHandler` 不能被 actor 隔离的闭包捕获 —— 所以先收尾、
        // 业务回调丢到主线程队列（跳转「今天」不阻塞系统收尾）。
        let callback = onOpenToday
        DispatchQueue.main.async { callback?() }
        completionHandler()
    }

    /// 应用在前台时通知也照常弹（默认会被系统吞掉；前台提醒恰恰是学习场景最常用的）。
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        guard notification.request.identifier.hasPrefix(Self.identifierPrefix) else {
            completionHandler([])
            return
        }
        completionHandler([.banner, .sound])
    }
}
