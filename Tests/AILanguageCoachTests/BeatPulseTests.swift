@testable import AppUI
import XCTest

// MARK: - 慢节拍脉冲（#669）

/// 动物慢节拍回归：眨眼 / 哈气 / 教棍挥动从「每实例一个 `Timer`」改成读全局氛围钟的相位。
///
/// 改造的性质决定了测试的形状：`Timer → 相位` 是**纯移动**，编译照过、渲染照绿，
/// 唯一守得住的是 ① 相位算式本身（纯函数，直接钉）② 三条路的接线形态（源码哨兵）。
/// 少了任何一组，「每只动物又各起一个定时器」都能静悄悄地回来。
@MainActor
final class BeatPulseTests: XCTestCase {

    // MARK: 工具（源码哨兵：只扫代码，注释里为了说明反例写的旧写法不算）

    private nonisolated static func code(_ path: String) throws -> String {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private nonisolated static func declBody(matching marker: String, in source: String) throws -> String {
        guard let signature = source.range(of: marker) else {
            throw NSError(domain: "sentinel", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "找不到声明 \(marker)"])
        }
        guard let open = source.range(of: "{", range: signature.upperBound..<source.endIndex) else {
            throw NSError(domain: "sentinel", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "找不到 \(marker) 的声明体开头"])
        }
        var depth = 0
        var index = open.lowerBound
        while index < source.endIndex {
            let character = source[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return String(source[open.lowerBound..<index]) }
            }
            index = source.index(after: index)
        }
        throw NSError(domain: "sentinel", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "\(marker) 的声明体没有闭合"])
    }

    // MARK: 相位算式（纯函数）

    /// 第 k 拍落在 `k × period`（无初相时）—— 拍号就是「过了几个整周期」。
    func testBeatCountsWholePeriodsFromZero() {
        XCTAssertEqual(BeatPulse.beatIndex(elapsed: 0, period: 3.2, lead: 0), 0)
        XCTAssertEqual(BeatPulse.beatIndex(elapsed: 3.199, period: 3.2, lead: 0), 0,
                       "差 1ms 没到一个周期就翻拍 → 每帧都可能多打一拍")
        XCTAssertEqual(BeatPulse.beatIndex(elapsed: 3.2, period: 3.2, lead: 0), 1)
        XCTAssertEqual(BeatPulse.beatIndex(elapsed: 6.4, period: 3.2, lead: 0), 2)
        XCTAssertEqual(BeatPulse.beatIndex(elapsed: 12.8, period: 3.2, lead: 0), 4)
    }

    /// 初相只平移序列、不改间距：第 k 拍落在 `k × period − lead`。
    ///
    /// ⚠️ 取样**躲开整周期边界**：二进制下 8.6 + 1.0 = 9.5999…，除 3.2 得
    /// 2.9999…，`Int` 截断成 2。真实时钟是帧间隔累加出来的，永远不会正落
    /// 边界上（差一帧也就 50ms，肉眼无感）—— 是测试不该在边界上取样。
    func testLeadShiftsTheWholeSequenceWithoutChangingItsSpacing() {
        let period = 3.2, lead = 1.0
        // 第一拍从 3.2 提前到 2.2
        XCTAssertEqual(BeatPulse.beatIndex(elapsed: 2.19, period: period, lead: lead), 0)
        XCTAssertEqual(BeatPulse.beatIndex(elapsed: 2.21, period: period, lead: lead), 1)
        // 间距仍是整周期：2.2 / 5.4 / 8.6（不是 3.2 / 6.4，也不是忽快忽慢）
        XCTAssertEqual(BeatPulse.beatIndex(elapsed: 5.39, period: period, lead: lead), 1)
        XCTAssertEqual(BeatPulse.beatIndex(elapsed: 5.41, period: period, lead: lead), 2)
        XCTAssertEqual(BeatPulse.beatIndex(elapsed: 8.59, period: period, lead: lead), 2)
        XCTAssertEqual(BeatPulse.beatIndex(elapsed: 8.61, period: period, lead: lead), 3)
    }

    /// 初相长于一个周期时只是换个相位（等价 `lead mod period`），不会漏拍 / 连拍。
    ///
    /// lead 4.0、period 3.2 → 拍点落在 k×3.2 − 4.0 = … 2.4 / 5.6 / 8.8 …
    func testLeadLongerThanOnePeriodStillOnlyShiftsPhase() {
        let period = 3.2, lead = 4.0
        XCTAssertEqual(BeatPulse.beatIndex(elapsed: 2.39, period: period, lead: lead), 1)
        XCTAssertEqual(BeatPulse.beatIndex(elapsed: 2.41, period: period, lead: lead), 2)
        XCTAssertEqual(BeatPulse.beatIndex(elapsed: 5.59, period: period, lead: lead), 2)
        XCTAssertEqual(BeatPulse.beatIndex(elapsed: 5.61, period: period, lead: lead), 3)
    }

    /// 非正周期恒不拍：`10 / 0 = +∞`，而 `Int(+∞)` 是**陷阱**（直接把进程崩掉），
    /// 比「拍号算不出来」危险得多。负周期同理（时钟回拨 / 传错单位）。
    func testNonPositivePeriodNeverBeatsInsteadOfDividingByZero() {
        XCTAssertEqual(BeatPulse.beatIndex(elapsed: 10, period: 0, lead: 0), 0)
        XCTAssertEqual(BeatPulse.beatIndex(elapsed: 0, period: 0, lead: 0), 0)
        XCTAssertEqual(BeatPulse.beatIndex(elapsed: 10, period: -3.2, lead: 0), 0)
    }

    /// 拍号单调不回退：`onChange` 只在**变化**时回调，回退一次那一拍就永远丢了。
    func testBeatNumberNeverGoesBackwards() {
        var previous = -1
        var elapsed = 0.0
        while elapsed <= 30 {
            let beat = BeatPulse.beatIndex(elapsed: elapsed, period: 2.6, lead: 1.3)
            XCTAssertGreaterThanOrEqual(beat, previous, "elapsed=\(elapsed) 拍号回退 → 有一拍被吞")
            previous = beat
            elapsed += 0.05
        }
        // 30 秒整 / 2.6 秒一拍：floor((30 + 1.3) / 2.6)
        XCTAssertEqual(previous, Int((30 + 1.3) / 2.6))
    }

    /// 共享一颗钟之后，**初相是唯一的错峰手段**：八个种子的初相必须两两不同，
    /// 且在同一时刻不能落在同一个拍号上 —— 否则就是 #628 修掉的「一起眨」回来了。
    func testEveryAnimalKeepsItsOwnPhaseUnderTheSharedClock() {
        let period = CuteAnimalView.blinkPeriod
        let leads = (0..<8).map { CuteAnimalView.blinkLead(seed: $0) }
        XCTAssertEqual(Set(leads).count, 8, "八个种子的初相有重复 → 黄金比例低差异序列失效")

        let sampled = 2.0
        let beats = leads.map { BeatPulse.beatIndex(elapsed: sampled, period: period, lead: $0) }
        XCTAssertGreaterThan(Set(beats).count, 1,
                             "同一时刻所有个体拍号相同 → 共享钟把它们变成了齐步眨")
    }

    // MARK: 三条路的接线形态（这类改动编译照过、渲染照绿，只能扫源码）

    /// 动物文件里不许再有「每实例一个 Timer」；三个动作都还在，只是换了节拍来源。
    ///
    /// ⚠️ 负面断言必须配正面断言：只钉「不许有 Timer.publish」的话，
    /// 文件被删空 / 动作被摘掉都恒绿。三条调用形态（含 `.overlay {` 前缀）
    /// 同时钉住「动作还在」与「相位读在独立透明层里」。
    func testAnimalsNoLongerOwnOneTimerPerAnimal() throws {
        let file = try Self.code("Sources/AppUI/Theme/Animals.swift")
        XCTAssertFalse(file.contains("Timer.publish"),
                       "Animals.swift 又出现 Timer.publish → 每只动物各起一个定时器回来了")
        XCTAssertFalse(file.contains(".onReceive("),
                       "onReceive 的定时器接回来了 → 改造被回退")

        let animal = try Self.declBody(matching: "struct CuteAnimalView", in: file)
        XCTAssertTrue(
            animal.contains(".overlay {\n            BeatPulse(period: Self.blinkPeriod,"),
            "眨眼节拍不在独立透明层里，或没读 Self.blinkPeriod → 要么整只动物每帧重绘，要么周期漂移"
        )
        XCTAssertTrue(
            animal.contains("BeatPulse(period: Self.breathPeriod,"),
            "哈气节拍没有并入共享钟（或周期没走 Self.breathPeriod）"
        )

        let pointer = try Self.declBody(matching: "struct TeacherPointer", in: file)
        XCTAssertTrue(
            pointer.contains(".overlay {\n            BeatPulse(period: 4.2) {"),
            "教棍挥动没有并入共享钟，或没挂成独立透明层"
        )
    }

    /// `BeatPulse` 自己必须保留三条路：暂停 / 读钟 / 自起表。
    ///
    /// 少任何一条都有具体后果：没有暂停 → 渲染夹具与睡着的动物白烧调度；
    /// 没有读钟 → 主窗口里又回到每实例一颗表；没有自起表 → 离屏夹具里
    /// 压根不眨（那是既有渲染回归的输入）。
    func testBeatPulseKeepsAllThreeRoutes() throws {
        let file = try Self.code("Sources/AppUI/Components/ForestAmbientClock.swift")
        let body = try Self.declBody(matching: "struct BeatPulse", in: file)
        XCTAssertTrue(body.contains("if paused {"),
                      "没有暂停分支 → 夹具闸门 / 睡意闸门关不住节拍")
        XCTAssertTrue(body.contains("else if let ambient {") && body.contains("beat(elapsed: ambient.elapsed)"),
                      "没有「读全局氛围钟」这条路 → 主窗口里回到每实例一颗表")
        XCTAssertTrue(body.contains("TimelineView(.periodic(from: .now, by: interval))"),
                      "没有自起表这条路 → 离屏夹具里节拍根本不响；且必须用 .periodic（.animation 不保证按间隔醒）")
        XCTAssertTrue(body.contains("@Environment(\\.forestAmbientClock) private var ambient"),
                      "没有从环境读钟 → 三条路少了一半")
    }

    // MARK: 反证（判据自身要能证明自己抓得到那个 bug）

    /// 反证：把 `+ lead` 抹掉（共享钟之后最常见的退化写法），
    /// `testEveryAnimalKeepsItsOwnPhaseUnderTheSharedClock` 当场红。
    func testPhaseAssertionWouldCatchADroppedLead() {
        let period = CuteAnimalView.blinkPeriod
        let sampled = 2.0
        let withoutLead = (0..<8).map { _ in
            BeatPulse.beatIndex(elapsed: sampled, period: period, lead: 0)
        }
        XCTAssertEqual(Set(withoutLead).count, 1,
                       "抹掉初相后八个个体竟然还不同相 → 相位算式里还有别的错峰来源，那条断言是假的")
    }

    /// 反证：guard 去掉之后，负周期会安安静静返回 -3（拍号乱翻），
    /// 除零则会以陷阱收场（`Int(Double.infinity)`）。这里用负周期演示杀伤力
    /// —— 反证要红在该红的断言上，不引陷阱。
    func testGuardAssertionWouldCatchAnUnguardedDivision() {
        let unguarded = Int((10.0 + 0.0) / -3.2)
        XCTAssertEqual(unguarded, -3)
        XCTAssertNotEqual(BeatPulse.beatIndex(elapsed: 10, period: -3.2, lead: 0), unguarded,
                          "实现与无保护版本结果相同 → 那条非正周期断言是假的")
    }

    /// 反证：把埋点换回旧写法时，源码哨兵钉的**负面模式真的匹配得上**它。
    /// （负面断言最怕的是「模式写错，永远匹配不到任何东西」。）
    func testSentinelPatternReallyMatchesTheOldTimerForm() {
        let regressed = """
            .onReceive(Timer.publish(every: Self.blinkPeriod, on: .main, in: .common).autoconnect()) { _ in
                blink()
            }
            """
        XCTAssertTrue(regressed.contains("Timer.publish"),
                      "反证样本里没有 Timer.publish → 哨兵的负面模式匹配不到旧写法，那条断言是空的")
        XCTAssertFalse(regressed.contains(".overlay {\n            BeatPulse(period: Self.blinkPeriod,"),
                      "反证样本竟然含新调用形态 → 样本写错了")
    }
}
