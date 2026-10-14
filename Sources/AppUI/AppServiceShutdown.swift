import AIServices
import AppCore
import Foundation

/// 退出收尾：停掉**本应用亲手拉起**的本地服务（自停），有界等待后放行退出。
///
/// ## 为什么需要这一层
///
/// 退出路径（`AppKitHost.terminate(services:)` 与 `applicationWillTerminate`）都是
/// **同步**函数，而要等的 `stopServicesStartedByApp()` 是 actor 上的异步活。
/// 同步函数里 `await` 不了；若在主线程上阻塞等一个「稍后要回主 actor」的异步活，
/// 就是死锁 —— 主线程正被堵着，MainActor 永远排不进来。
///
/// 所以：detached task 里跑收尾（只碰 `CoachServices` 这个 actor，
/// 全程不碰 AppState / 主 actor），同步侧只做**有界**信号量等待。
/// 超时就放行退出 —— 退出永远不能被卡死，停不掉的服务留在台账里，下次退出重试。
///
/// 幂等：登记簿「停成功即注销」，在册为空时直接返回 —— 同一进程里
/// `terminate(services:)` 跑一遍、`applicationWillTerminate` 再兜底一遍，
/// 不会双停，也不会有第二次等待。
enum AppServiceShutdown {

    /// - Parameters:
    ///   - services: 服务装配中心（只用来调 `stopServicesStartedByApp()`）。
    ///   - timeout: 收尾的最长等待秒数。超时只留痕、不阻断退出。
    static func run(services: CoachServices, timeout: TimeInterval = 10) {
        let semaphore = SendableSemaphore()
        Task.detached {
            // 返回值（没能停掉的摘要）只用于测试与调用方判断；这里收尾自身已留痕。
            _ = await services.stopServicesStartedByApp()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: timeout) == .success else {
            AppLog.warning(
                "退出收尾超过 \(Int(timeout)) 秒未完成：本应用拉起的本地服务可能仍在运行（下次退出会重试）",
                category: "service"
            )
            return
        }
    }
}

/// `DispatchSemaphore` 的 Sendable 包装。
///
/// Swift 6 下 `DispatchSemaphore` 的 Sendable 判定历史上不稳，而退出收尾要把信号量
/// 从同步函数交给 detached task —— 用一个小包装把判定钉死在内，不外溢。
private final class SendableSemaphore: @unchecked Sendable {

    private let semaphore = DispatchSemaphore(value: 0)

    func signal() {
        semaphore.signal()
    }

    @discardableResult
    func wait(timeout: TimeInterval) -> DispatchTimeoutResult {
        semaphore.wait(timeout: .now() + timeout)
    }
}
