import XCTest
@testable import AppUI

/// 动物眨眼错峰（`CuteAnimalView.blinkLead`）。
///
/// 背景：森林地面带一屏最多 8 只动物，它们同时 appear、眨眼周期同为 3.2s
/// → **整排一起眨**，和「整冠一起摇」是同一类毛病。修法是统一周期 + 按槽位
/// 错开初相。本文件钉住「错开」这件事真的成立，且不误伤单只动物的既有行为。
final class AnimalBlinkPhaseTests: XCTestCase {

    // MARK: - 值域与确定性

    func testLeadStaysInsideExactlyOnePeriod() {
        for seed in 0..<128 {
            let lead = CuteAnimalView.blinkLead(seed: seed)
            XCTAssertGreaterThanOrEqual(lead, 0, "seed \(seed) 的初相为负 → 眨眼会提前到上一拍")
            XCTAssertLessThan(lead, CuteAnimalView.blinkPeriod, "seed \(seed) 的初相溢出一个周期 → 相位折回，可能与别人撞上")
        }
    }

    /// 默认 `blinkPhaseSeed = 0` 的调用点（老师角 / 气泡 / 各页角落的单只动物）
    /// 行为必须一个字节都不变：不偏移、不走 `asyncAfter`。
    func testSeedZeroDoesNotShift() {
        XCTAssertEqual(CuteAnimalView.blinkLead(seed: 0), 0,
                       "默认档不该有任何偏移 —— 单只动物的既有调用点行为必须不变")
    }

    func testLeadIsDeterministic() {
        for seed in [0, 1, 3, 7, 42] {
            XCTAssertEqual(CuteAnimalView.blinkLead(seed: seed),
                           CuteAnimalView.blinkLead(seed: seed),
                           "初相必须可复现，否则离屏渲染与真机会拍到不同的相")
        }
    }

    // MARK: - 错峰判据（核心）

    /// 环形最小间隔：把初相同时看作周期圆环上的点，连「跨周期边界」的那一对也算上。
    private func minimumCircularGap(_ leads: [Double]) -> Double {
        guard leads.count > 1 else { return CuteAnimalView.blinkPeriod }
        let sorted = leads.sorted()
        var gap = Double.infinity
        for i in 0..<sorted.count {
            let next = (i + 1 < sorted.count) ? sorted[i + 1] : sorted[0] + CuteAnimalView.blinkPeriod
            gap = min(gap, next - sorted[i])
        }
        return gap
    }

    /// 地面带满员 8 只：任意两只的闭眼窗口都不重叠（间隔 > 闭眼时长）。
    ///
    /// ⚠️ 这是**反证级**断言：一旦有人把 `blinkLead` 改回恒 0（撤销错峰），
    /// 最小间隔立刻塌成 0，本条必须红 —— 仅仅「跑得起来」不算通过。
    func testFullRosterNeverOverlaps() {
        let leads = (0..<8).map { CuteAnimalView.blinkLead(seed: $0) }
        let gap = minimumCircularGap(leads)
        XCTAssertGreaterThan(gap, CuteAnimalView.blinkDuration,
                             "最小间隔 \(gap) 不超过闭眼时长 → 会看到两只一起闭眼，错峰等于没做")
        // 留一倍余量：不只是「勉强不重叠」，而是要肉眼明显地一只接一只。
        XCTAssertGreaterThan(gap, CuteAnimalView.blinkDuration * 1.5,
                             "最小间隔 \(gap) 只比闭眼时长多一点 → 观感仍是「几乎同时」")
    }

    /// 低差异序列的性质：从小到大任何一种人数都要铺得开。
    ///
    /// ⚠️ 只断言「8 只」这一个人数是不够的 —— 判据可能在别的人数上断掉而我们
    /// 碰巧没测。实际会出现的规模是 1…8（地面带按进度增减居民），全跑一遍。
    func testEveryRosterSizeSpreadsOut() {
        for count in 2...8 {
            let leads = (0..<count).map { CuteAnimalView.blinkLead(seed: $0) }
            let gap = minimumCircularGap(leads)
            XCTAssertGreaterThan(gap, CuteAnimalView.blinkDuration,
                                 "\(count) 只时最小间隔只有 \(gap) → 这个人数下会一起眨")
        }
    }

    /// 连续的槽位号必须给出互不相同的初相（都传同一个值 = 错峰白做）。
    func testConsecutiveSeedsDiffer() {
        let leads = (0..<8).map { CuteAnimalView.blinkLead(seed: $0) }
        XCTAssertEqual(Set(leads.map { String(format: "%.6f", $0) }).count, leads.count,
                       "有槽位拿到了完全相同的初相 → 那两只仍然一起眨")
    }

    // MARK: - 接线哨兵

    /// 编排层必须把**每只各自的槽位号**喂进去。
    ///
    /// ⚠️ 钉的是调用形态整串而不是「文件里出现过几次 blinkPhaseSeed」——
    /// 后者连 `if false { ... }` 这种死代码都能计数（假绿）。
    func testGroundBandFeedsEachSlotItsOwnSeed() throws {
        let tree = try source(named: "TreeCanvas", in: "Components")
        XCTAssertTrue(tree.contains("blinkPhaseSeed: index"),
                      "地面带必须按槽位号传初相种子；传常量就等于整排一起眨")
    }

    /// `LivelyAnimal` 必须把种子透传给 `CuteAnimalView`（不然编排层传了也是白传）。
    func testLivelyAnimalForwardsTheSeed() throws {
        let lively = try source(named: "LivelyAnimal", in: "Components")
        XCTAssertTrue(lively.contains("blinkPhaseSeed: blinkPhaseSeed"),
                      "LivelyAnimal 必须把初相种子透传给 CuteAnimalView")
    }

    /// 眨眼定时器读的是同一个周期常量（别在两处各写一个 3.2）。
    func testBlinkTimerReadsTheSharedPeriod() throws {
        let animals = try source(named: "Animals", in: "Theme")
        XCTAssertTrue(animals.contains("Timer.publish(every: Self.blinkPeriod"),
                      "定时器周期必须取自 blinkPeriod 常量，否则纯函数算出的初相和实际拍子对不上")
    }

    // MARK: - 读源码

    private func source(named: String, in folder: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/AILanguageCoachTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
        let url = root
            .appendingPathComponent("Sources/AppUI/\(folder)/\(named).swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
