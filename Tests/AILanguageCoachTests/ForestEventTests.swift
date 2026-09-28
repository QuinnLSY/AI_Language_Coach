import AIDomain
import AppCore
@testable import AppUI
import XCTest

/// 森林地基（批次一）的纯函数与映射测试：
/// 事件总线语义、事件→脉冲翻译表、轮换节奏的错落感参数、树冠成长与果位表。
@MainActor
final class ForestEventTests: XCTestCase {

    // MARK: - ① 事件总线

    /// 线程安全的订阅计数器（emit 从任意上下文来）。
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        func bump() { lock.lock(); value += 1; lock.unlock() }
    }

    func testEmittedEventReachesEverySubscriber() {
        let bus = LearningEventBus()
        let a = Counter(), b = Counter()
        // ⚠️ 凭证必须持住：丢弃（deinit）即退订——这正是防泄漏设计
        var subscriptions: [LearningEventBus.Subscription] = []
        subscriptions.append(bus.subscribe { _ in a.bump() })
        subscriptions.append(bus.subscribe { _ in b.bump() })
        bus.emit(.wordCollected(word: "substantial"))
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(b.count, 1)
        _ = subscriptions
    }

    /// 退订之后不再收（AppState 生命周期凭证的语义基础）。
    func testCancelledSubscriptionStopsReceiving() {
        let bus = LearningEventBus()
        let counter = Counter()
        let subscription = bus.subscribe { _ in counter.bump() }
        bus.emit(.practiceCompleted(rounds: 3))
        XCTAssertEqual(counter.count, 1)
        subscription.cancel()
        bus.emit(.practiceCompleted(rounds: 3))
        XCTAssertEqual(counter.count, 1, "cancel 后不应再收到事件")
    }

    /// 订阅凭证释放即退订（deinit 兜底，忘了 cancel 也不泄漏回调）。
    func testReleasedSubscriptionDetachesItself() {
        let bus = LearningEventBus()
        let counter = Counter()
        do {
            _ = bus.subscribe { _ in counter.bump() }
        }
        bus.emit(.starsEarned(levelID: "L1", total: 2, delta: 1))
        XCTAssertEqual(counter.count, 0, "凭证释放后回调不应再被持有与调用")
    }

    // MARK: - ② 事件 → 脉冲翻译表

    func testStageTranslatesEachEventToItsOwnPulse() {
        let stage = ForestStage()
        XCTAssertEqual(stage.wordTick, 0)
        XCTAssertEqual(stage.practiceTick, 0)
        XCTAssertEqual(stage.fruitPulseTick, 0)
        XCTAssertEqual(stage.ceremonyTick, 0)

        stage.ingest(.wordCollected(word: "substantial"))
        XCTAssertEqual(stage.wordTick, 1)
        XCTAssertEqual(stage.practiceTick, 0, "收词不该惊动别的通道")

        stage.ingest(.practiceCompleted(rounds: 4))
        XCTAssertEqual(stage.practiceTick, 1)

        stage.ingest(.starsEarned(levelID: "L1", total: 2, delta: 1))
        XCTAssertEqual(stage.fruitPulseTick, 1)
        XCTAssertEqual(stage.ceremonyTick, 0, "攒星是小回应，全套仪式留给通关")

        stage.ingest(.levelCompleted(levelID: "L1"))
        XCTAssertEqual(stage.ceremonyTick, 1)
        XCTAssertEqual(stage.lastCompletedLevelID, "L1")
    }

    /// 纠错事件进得了总线、舞台先按住不表（批次二地面的「歪头安慰」接这里）——
    /// 占位本身钉死：纠错不该误触发树上的任何通道。
    func testCorrectionsRecordedDoesNotTouchTreeChannels() {
        let stage = ForestStage()
        stage.ingest(.correctionsRecorded(count: 3))
        XCTAssertEqual(stage.wordTick, 0)
        XCTAssertEqual(stage.practiceTick, 0)
        XCTAssertEqual(stage.fruitPulseTick, 0)
        XCTAssertEqual(stage.ceremonyTick, 0)
    }

    /// 端到端：舞台挂上总线后，emit 的事件要能穿过线程跳回主 actor 变成脉冲。
    func testAttachedStageReceivesBusEvents() async throws {
        let stage = ForestStage()
        let subscription = stage.attach(to: LearningEventBus.testBus)
        LearningEventBus.testBus.emit(.wordCollected(word: "dawn"))
        // handler 里 Task { @MainActor } 是异步跳转：轮转等待到脉冲出现为止
        for _ in 0..<100 where stage.wordTick == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(stage.wordTick, 1, "挂上总线后 emit 的事件必须变成脉冲")
        subscription.cancel()
    }

    // MARK: - ③ 轮换节奏（错落感）

    /// 下一批告别前的静默期：平时 0.5–1.5 个基准周期；一成概率长歇 2.2–3.2 个周期。
    func testNextDepartureDelaySpreadsAroundBase() {
        // frequency 0 → base 55；frequency 1 → base 25；越界钳到 0…1
        let normal = (0...20).map {
            ForestRotationPacing.nextDepartureDelay(frequency: 0.5, roll: 0.5, spread: Double($0) / 20)
        }
        XCTAssertEqual(normal.first ?? -1, 20.0, accuracy: 0.001, "spread=0 → 0.5×base(40)")
        XCTAssertEqual(normal.last ?? -1, 60.0, accuracy: 0.001, "spread=1 → 1.5×base(40)")

        let longSpell = ForestRotationPacing.nextDepartureDelay(frequency: 0.5, roll: 0.05, spread: 0)
        XCTAssertEqual(longSpell, 88.0, accuracy: 0.001, "roll<0.1 → 长歇 2.2×base")
        let longSpellTop = ForestRotationPacing.nextDepartureDelay(frequency: 0.5, roll: 0.05, spread: 1)
        XCTAssertEqual(longSpellTop, 128.0, accuracy: 0.001, "长歇上界 3.2×base")

        XCTAssertEqual(
            ForestRotationPacing.nextDepartureDelay(frequency: 2, roll: 0.5, spread: 0),
            ForestRotationPacing.nextDepartureDelay(frequency: 1, roll: 0.5, spread: 0),
            "frequency 越界要钳回 1（频率拉满就是拉满，不该出现负周期）"
        )
    }

    /// 一批走几只：够两只时约三成结伴，否则一只；不足两只永远只走一只。
    func testGroupSizeCanPairUpButNeverExceedsPresent() {
        XCTAssertEqual(ForestRotationPacing.groupSize(present: 3, roll: 0.29), 2, "三成概率结伴")
        XCTAssertEqual(ForestRotationPacing.groupSize(present: 3, roll: 0.30), 1, "概率线外不结伴")
        XCTAssertEqual(ForestRotationPacing.groupSize(present: 1, roll: 0.0), 1, "只剩一只不许凭空结伴")
        XCTAssertEqual(ForestRotationPacing.groupSize(present: 0, roll: 0.0), 1, "0 只时返回 1，调用方负责不挑空集")
    }

    /// 归期 4–45s：有「提前来」的快、也有大半天不见影的慢（错落感的主体）。
    func testReturnDelayBounds() {
        XCTAssertEqual(ForestRotationPacing.returnDelay(roll: 0), 4.0, accuracy: 0.001)
        XCTAssertEqual(ForestRotationPacing.returnDelay(roll: 1), 45.0, accuracy: 0.001)
        // 随机端到端：大量抽样必须全部落在界内
        for _ in 0..<200 {
            let delay = ForestRotationPacing.returnDelay(roll: Double.random(in: 0..<1))
            XCTAssertTrue((4.0...45.0).contains(delay), "归期越界：\(delay)")
        }
    }

    /// 结伴离场的错落间隔 0.9–1.8s：第二只前后脚动身，不齐步走。
    func testStaggerDelayBounds() {
        XCTAssertEqual(ForestRotationPacing.staggerDelay(roll: 0), 0.9, accuracy: 0.001)
        XCTAssertEqual(ForestRotationPacing.staggerDelay(roll: 1), 1.8, accuracy: 0.001)
    }

    // MARK: - ④ 树冠成长与果实

    /// 茂密度 = 已得星 / 需求星，钳到 0…1；没有需求星时恒 0。
    func testCanopyDensityClampsAndHandlesEmpty() {
        XCTAssertEqual(TreeCanvas.canopyDensity(earned: 0, required: 0), 0, "没有关卡时树冠保持疏朗")
        XCTAssertEqual(TreeCanvas.canopyDensity(earned: 3, required: 6), 0.5)
        XCTAssertEqual(TreeCanvas.canopyDensity(earned: 9, required: 6), 1, "超采不许把树撑爆")
        XCTAssertEqual(TreeCanvas.canopyDensity(earned: -1, required: 6), 0, "负数钳到 0")
    }

    /// 果位表：16 个位置、互不重叠（两两距离足够）、全部落在树冠轮廓内。
    func testFruitPlacementsAreStableAndInsideCanopy() {
        let placements = FruitLayer.placements
        XCTAssertEqual(placements.count, 16, "果位表就是成果上限——树冠不该被挤爆")
        for (x, y) in placements {
            XCTAssertTrue((-170.0...170.0).contains(x), "果实横向出界：\(x)")
            XCTAssertTrue((-45.0...160.0).contains(y), "果实纵向出界：\(y)")
        }
        for i in 0..<placements.count {
            for j in (i + 1)..<placements.count {
                let dx = placements[i].0 - placements[j].0
                let dy = placements[i].1 - placements[j].1
                XCTAssertGreaterThan((dx * dx + dy * dy).squareRoot(), 24,
                                     "果位 \(i) 与 \(j) 距离过近（<24pt），会挤成一坨")
            }
        }
    }
}

/// 测试专用：一条独立总线（不碰 `CoachServices.events` 单例语义）。
private extension LearningEventBus {
    static let testBus = LearningEventBus()
}
