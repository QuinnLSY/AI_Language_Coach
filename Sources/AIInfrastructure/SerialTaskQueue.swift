import Foundation

/// 把若干次异步工作**按提交顺序**依次执行（前一个跑完才轮到下一个）。
///
/// 存在的理由（#S3-8）：`Task { await 写库() }` 这种 fire-and-forget 之间
/// **没有任何顺序保证** —— 先提交的不一定先落库。对「插入一条消息」与
/// 「删掉几条消息」这种必须讲先后的写入，症状就是「刚删掉的那条下次打开又回来了」。
///
/// 实现只用一条尾巴：每次提交都接在上一次的 `value` 后面。
/// - 不重试：失败由各调用方自己记账（落库失败有统一的横幅）。
/// - 不取消：已经排队的写入必须落完，返工比丢数据便宜。
///
/// ⚠️ `enqueue` **故意不是 `async`**：如果调用方要 `await queue.enqueue { … }`，
/// 它就得先把入队包进一个 `Task`，而那个 Task 什么时候跑到入队这一步又变成调度器说了算 ——
/// 顺序等于没保住。同步入队 + 调用方自己串行（UI 侧都在主 actor 上）才是真正的
/// 「调用顺序 = 执行顺序」。内部用锁而不是 actor，也是为了能同步入队。
public final class SerialTaskQueue: @unchecked Sendable {

    private let lock = NSLock()
    /// 当前链尾。nil = 还没有排过任何工作。
    private var tail: Task<Void, Never>?

    public init() {}

    /// 排一次工作到队尾（同步返回，顺序即调用顺序）。
    public func enqueue(_ work: @escaping @Sendable () async -> Void) {
        lock.lock()
        let previous = tail
        tail = Task {
            await previous?.value
            await work()
        }
        lock.unlock()
    }

    /// 等队里所有已排队的工作跑完（测试与「退出前收尾」用）。
    public func drain() async {
        await currentTail()?.value
    }

    /// 同步取链尾。`NSLock.lock()` 在 async 上下文里不可用（`noasync`），
    /// 所以取值这一步必须留在这个同步方法里。
    private func currentTail() -> Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        return tail
    }
}
