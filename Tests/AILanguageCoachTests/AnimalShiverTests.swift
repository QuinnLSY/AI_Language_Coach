import AIDomain
@testable import AppUI
import XCTest

/// 下雪哆嗦（2026-10-21 重写）的**纯函数**判据。
///
/// 用户报的三件事，这一节钉前两件（第三件「退出下雪还残留」靠结构保证 +
/// 渲染回归 `testSnowIdleLooksExactlyLikeClearWeather`）：
/// ① 「不需要一直颤抖，隔 15–20 秒轻微颤抖一下」→ 节奏判据；
/// ② 「整个身子包括帽子等配件一起颤抖」→ 姿态判据（绕脚底倾斜，帽子摆得最多）。
///
/// 反证纪律：把 `intervalRange` 改成 `0.1...0.2` → `testIntervalIsFifteenToTwentySeconds` 红；
/// 把 `tilt` 改成恒 0 → `testTiltAlternatesWithTheSameSides` 红；
/// 在哆嗦路径里加回 `repeatForever` → `testShiverNeverRunsAnInfiniteAnimation` 红。
final class AnimalShiverTests: XCTestCase {

    // MARK: - 什么时候抖

    /// 只有「下雪 + 醒着」才抖。
    func testOnlySnowingAwakeAnimalsTremble() {
        XCTAssertTrue(AnimalShiver.trembles(weather: .snow, isSleeping: false))
        XCTAssertFalse(AnimalShiver.trembles(weather: .rain, isSleeping: false), "下雨该打伞，不该哆嗦")
        XCTAssertFalse(AnimalShiver.trembles(weather: .clear, isSleeping: false), "晴天不许抖")
        XCTAssertFalse(AnimalShiver.trembles(weather: nil, isSleeping: false), "不跟随天气不许抖")
        XCTAssertFalse(AnimalShiver.trembles(weather: .snow, isSleeping: true), "睡着不折腾")
    }

    /// 判据必须与 `AnimalWeatherBehavior` 同源：天气档位再加一档时不会两边打架。
    func testTremblingFollowsTheWeatherBehaviorTable() {
        for weather in ForestWeather.allCases {
            let expected = AnimalWeatherBehavior.forWeather(weather) == .shiver
            XCTAssertEqual(AnimalShiver.trembles(weather: weather, isSleeping: false), expected,
                           "\(weather.displayName) 的哆嗦判据与降水行为表不一致")
        }
    }

    // MARK: - 多久抖一次

    /// 两段之间 15…20 秒（用户明确要求），一段本身要短（不是「一直抖」）。
    func testIntervalIsFifteenToTwentySeconds() {
        XCTAssertEqual(AnimalShiver.intervalRange.lowerBound, 15, accuracy: 1e-9)
        XCTAssertEqual(AnimalShiver.intervalRange.upperBound, 20, accuracy: 1e-9)
        XCTAssertGreaterThan(AnimalShiver.burstDuration, 0.4, "一段哆嗦太短，看不见")
        XCTAssertLessThan(AnimalShiver.burstDuration, 1.2, "一段哆嗦太长，又变成一直在抖")
    }

    /// 间隔按种子错开：一屏八只不许同时哆嗦（同黄金比例低差异序列）。
    func testIntervalsAreStaggeredAcrossSeeds() {
        let waits = (0..<8).map { AnimalShiver.wait(seed: $0) }
        for wait in waits {
            XCTAssertGreaterThanOrEqual(wait, AnimalShiver.intervalRange.lowerBound - 1e-9)
            XCTAssertLessThanOrEqual(wait, AnimalShiver.intervalRange.upperBound + 1e-9)
        }
        let spread = (waits.max() ?? 0) - (waits.min() ?? 0)
        XCTAssertGreaterThan(spread, 2.0, "八只的哆嗦间隔几乎一样（会整排一起抖）")
        // 相邻两只至少差半秒，否则读成「一起抖」
        for index in 1..<waits.count {
            XCTAssertGreaterThan(abs(waits[index] - waits[index - 1]), 0.4,
                                 "第 \(index) 只与上一只的间隔太接近")
        }
    }

    // MARK: - 抖成什么样

    /// 静止时位移与倾斜**必须**都是 0：下雪但没在抖的那一帧要与晴天逐像素相同。
    func testRestingPhaseIsExactlyZero() {
        XCTAssertEqual(AnimalShiver.offset(phase: 0, size: 96), 0)
        XCTAssertEqual(AnimalShiver.tilt(phase: 0), 0)
    }

    /// 每一程都往一边倒：奇偶交替，幅度一致（读成「左右哆嗦」而不是「一边抽」）。
    func testPhasesAlternateSidesWithEqualAmplitude() {
        let amplitude = AnimalShiver.amplitudeRatio * 96
        XCTAssertEqual(AnimalShiver.offset(phase: 1, size: 96), -amplitude, accuracy: 1e-9)
        XCTAssertEqual(AnimalShiver.offset(phase: 2, size: 96), amplitude, accuracy: 1e-9)
        XCTAssertEqual(AnimalShiver.offset(phase: 3, size: 96), -amplitude, accuracy: 1e-9)
        XCTAssertEqual(AnimalShiver.tilt(phase: 1), -AnimalShiver.tiltDegrees, accuracy: 1e-9)
        XCTAssertEqual(AnimalShiver.tilt(phase: 2), AnimalShiver.tiltDegrees, accuracy: 1e-9)
    }

    /// 「轻微」：横向不超过身位的 2%，倾斜不超过 1.5°。
    func testTrembleIsSubtle() {
        XCTAssertLessThanOrEqual(AnimalShiver.amplitudeRatio, 0.02, "哆嗦幅度太大，读成被电了")
        XCTAssertGreaterThan(AnimalShiver.amplitudeRatio, 0.005, "哆嗦幅度太小，看不出来")
        XCTAssertLessThanOrEqual(AnimalShiver.tiltDegrees, 1.5, "倾斜太大，像在鞠躬")
        XCTAssertGreaterThan(AnimalShiver.tiltDegrees, 0.4, "倾斜太小，帽子看不出在动")
    }

    /// 倾斜是**绕脚底**的刚性变换：同样角度下，帽子（离脚底最远）位移最大。
    ///
    /// 这是「整只一起抖」的量化版本：只要 `tilt` 参与绘制，帽尖就比脚端摆得多；
    /// 纯平移做不到这一点（上下位移一样）。
    func testTiltMakesTheHatSwingMost() {
        let size: CGFloat = 96
        let hatHeight: CGFloat = size * 0.55      // 帽尖离脚底的高度
        let feetHeight: CGFloat = size * 0.06
        let angle = AnimalShiver.tilt(phase: 2) * .pi / 180
        let hatShift = abs(sin(angle) * Double(hatHeight))
        let feetShift = abs(sin(angle) * Double(feetHeight))
        XCTAssertGreaterThan(hatShift, feetShift, "倾斜没让帽子比脚端摆得多")
        XCTAssertGreaterThan(hatShift, 0.4, "帽尖的摆动小于半个点，肉眼看不出来")
    }

    // MARK: - 结构（源码哨兵）

    /// 哆嗦路径里**不许**出现 `repeatForever`。
    ///
    /// 这就是「退出下雪之后还偶尔在抖、要切换好几次天气才恢复」的根因形态：
    /// 无限循环一旦漏取消就永远转下去。现在是「一段六程、跑完就结束」，
    /// 令牌一变整段任务被取消。这条哨兵钉住这个结构，改回无限动画当场红。
    func testShiverNeverRunsAnInfiniteAnimation() throws {
        let source = try Self.code("Sources/AppUI/Theme/Animals.swift")
        let start = try XCTUnwrap(source.range(of: ".task(id: shiverToken)"), "找不到哆嗦的节拍任务")
        let end = try XCTUnwrap(source.range(of: ".onChange(of: hopTick)"),
                                "找不到哆嗦任务的收尾位置")
        let slice = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(slice.contains("repeatForever"),
                       "哆嗦又变回无限循环动画了（退出下雪会残留）")
        XCTAssertTrue(slice.contains("Task.isCancelled"), "哆嗦循环没有取消判据")
    }

    /// 哆嗦的三个闸门必须都在令牌里：天气 / 夹具闸门 / 减弱动态效果。
    ///
    /// 少任何一个都是静默失效（少天气 = 晴天也抖；少夹具 = 离屏帧不确定；
    /// 少 reduceMotion = 「减弱动态效果」开着还在抖）。
    func testShiverTokenChecksAllThreeGates() throws {
        let source = try Self.code("Sources/AppUI/Theme/Animals.swift")
        let start = try XCTUnwrap(source.range(of: "private var shiverToken: Int"),
                                  "找不到哆嗦令牌")
        let end = try XCTUnwrap(source.range(of: "private var activeShiverPhase: Int"),
                                "找不到令牌的收尾位置")
        let slice = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(slice.contains("Self.animationsEnabled"), "令牌没接离屏夹具闸门")
        XCTAssertTrue(slice.contains("motion.reduceMotion"), "令牌没接减弱动态效果")
        XCTAssertTrue(slice.contains("AnimalShiver.trembles"), "令牌没接天气判据")
    }

    /// 读源码并**剔掉注释行**（否则文档注释里写到 `repeatForever` 就把哨兵骗绿了 —— 实测踩过）。
    private static func code(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
