import Foundation

/// 学习事实事件：服务层在**既有落库点**顺手发出（零新增模型请求），
/// UI 层的森林舞台（`ForestStage`）订阅后分派给树 / 地面 / 天空各订阅者。
///
/// 设计灵魂「事事有回应」的地基：森林对学习不再聋——收词、纠错、练完、
/// 攒星、通关，每一件都有对应的视觉回应。事件只描述**事实**，不描述
/// 「该怎么演」：演法（果实挂枝 / 落叶 / 烟花）是订阅者自己的事，
/// 这样批次二 / 三给地面与天空接戏时不用动这里的任何东西。
public enum LearningEvent: Equatable, Sendable {

    /// 收进一个生词（词汇本真正落了一条；重复导入也会再发一次，森林只当「又捡到词」）。
    case wordCollected(word: String)
    /// 一轮对话后落了 N 条纠错（N > 0 才发）。
    case correctionsRecorded(count: Int)
    /// 一段练习完成并已生成复盘。
    case practiceCompleted(rounds: Int)
    /// 某一关攒了星（还没通关；通关走 `levelCompleted`，两条不并发）。
    case starsEarned(levelID: String, total: Int, delta: Int)
    /// 通关一个关卡（星星累加 + 解锁下一关已落库）。
    case levelCompleted(levelID: String)
}

/// 学习事件的进程内总线：服务层（actor 上下文）同步 `emit`，
/// 订阅方自己在 handler 里跳回主 actor——总线不预设任何线程。
///
/// 线程安全：`NSLock` 保护 handler 表；发射时取快照再逐个调用，
/// 回调里再订阅 / 退订也不会重入死锁。
///
/// ⚠️ 所有权：唯一的实例由 `CoachServices` 持有（`services.events`），
/// UI 与测试都从它订阅。不要另开第二条总线，否则「森林对谁聋了」会变成
/// 查两处才能回答的问题。
public final class LearningEventBus: @unchecked Sendable {

    private let lock = NSLock()
    private var handlers: [UUID: @Sendable (LearningEvent) -> Void] = [:]

    public init() {}

    /// 广播一条事件（同步、扇出快照；handler 的执行线程 = 调用线程）。
    public func emit(_ event: LearningEvent) {
        lock.lock()
        let handlers = Array(self.handlers.values)
        lock.unlock()
        for handler in handlers { handler(event) }
    }

    /// 订阅。持有的 `Subscription` 释放（或手动 `cancel`）即退订。
    @discardableResult
    public func subscribe(
        _ handler: @escaping @Sendable (LearningEvent) -> Void
    ) -> Subscription {
        let id = UUID()
        lock.lock()
        handlers[id] = handler
        lock.unlock()
        return Subscription(bus: self, id: id)
    }

    private func remove(_ id: UUID) {
        lock.lock()
        handlers[id] = nil
        lock.unlock()
    }

    /// 一份订阅的生命周期凭证：`cancel()` 或释放实例都会退订。
    /// AppState 把它存成属性，订阅随 AppState 活、随 AppState 走。
    public final class Subscription: @unchecked Sendable {

        private weak var bus: LearningEventBus?
        private let id: UUID

        fileprivate init(bus: LearningEventBus, id: UUID) {
            self.bus = bus
            self.id = id
        }

        deinit { cancel() }

        public func cancel() {
            bus?.remove(id)
        }
    }
}
