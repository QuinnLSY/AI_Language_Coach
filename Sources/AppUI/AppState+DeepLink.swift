import AIDomain
import Foundation

// MARK: - AppState · alc:// 深链（⑦-A）
//
// 解析在 `AppDeepLink`（纯函数），这里管的是**点了之后发生什么**：
// 叫起窗口 → 跳页 / 发一句话。
//
// ⚠️ 冷启动那条路径容易漏：`AppState` 还在 `start()` 前半段时 macOS 已经把 URL 交给
// `AppURLDelegate` 了。那时直接跳页会落在一页空页面上（数据一条都没加载），
// 所以收进来先排队，`start()` 走完再统一处理。
extension AppState {

    /// 收到一条深链：能处理就立刻处理，不能就排队。
    ///
    /// 认不出来的地址**悄悄丢掉**：系统不会把别人的 scheme 发到这里来，
    /// 真收到了也多半是拼错的 —— 弹一个警告框不如什么都不做。
    public func receiveDeepLink(_ url: URL) {
        guard AppDeepLink.parse(url) != nil else { return }
        guard isDeepLinkReady else {
            pendingDeepLinks.append(url)
            return
        }
        Task { await applyDeepLink(url) }
    }

    /// 把排队的那几条处理掉（`start()` 末尾与 `AppURLDelegate` 各调一次，重复调用无害）。
    public func drainPendingDeepLinks() async {
        let queued = pendingDeepLinks
        pendingDeepLinks = []
        for url in queued {
            await applyDeepLink(url)
        }
    }

    // MARK: - 执行

    /// 执行一条已经认出来的地址。
    private func applyDeepLink(_ url: URL) async {
        guard let route = AppDeepLink.parse(url) else { return }
        // 先叫起来：用户点了链接，窗口却还在别的桌面背后 —— 跳了也等于没跳。
        AppKitHost.bringFront()
        switch route {
        case let .section(section):
            await go(to: section)
        case let .ask(text):
            // 带一句话进来：**跳到练习页再发出去**。顺序反过来（`sendChat` 在前）
            // 会把它发在别的页面的会话里，用户看不到自己的消息出现在哪。
            await openPractice()
            _ = sendChat(text)
        }
    }
}
