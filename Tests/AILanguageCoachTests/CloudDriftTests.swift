import XCTest
@testable import AppUI

/// 云的漂移 + 地面云影（2026-11-01「云跟风 + 地面云影」）。
///
/// 这一批改的是**运动的来源**：云原先自带一颗 26 秒的 `loopAnimation` 来回荡，
/// 与草地的风场、与天上别的层毫无关系。现在它读同一颗风钟（`blownSeconds`），
/// 于是「阵风起来时云会走快一点」这件事有了单一真源。
///
/// 判据分三组：
/// 1. **位移是位移**（一直往一个方向走，不是来回荡）—— 这是「云」与「草」的区别；
/// 2. **两端淡出**（折回那一瞬的瞬移必须发生在透明度为 0 的时刻）；
/// 3. **可积**（阵风加权的时间有原函数：位置只由秒数决定，与帧率无关）。
final class CloudDriftTests: XCTestCase {

    // MARK: - 行程进度

    /// 每朵云的初相错峰、且都落在 [0, 1) 里。
    ///
    /// 反证：`startPhase` 直接 `return 0.5`（不错峰）→ 所有云挤在一处 → 红。
    func testStartPhasesAreSpreadAcrossTheTrip() {
        let phases = (0..<11).map { CloudDrift.startPhase(index: $0) }
        for phase in phases {
            XCTAssertGreaterThanOrEqual(phase, 0)
            XCTAssertLessThan(phase, 1, "初相必须折回 [0, 1)：\(phase)")
        }
        XCTAssertEqual(Set(phases.map { ($0 * 1000).rounded() }).count, phases.count,
                       "十一朵云不该有两朵同相：\(phases)")
    }

    /// **位移不是摆动**：时间往前走，云一直朝同一个方向走。
    ///
    /// 这是这一层与草地的根本区别（草是 `sin`，云是累积位移）。
    /// 反证：`state` 里改用 `sin(...)` 算 x → 红（x 会先增后减）。
    ///
    /// ⚠️ 只走 30 秒：一朵云约 78 秒走完全程，而 0 号云的初相就在半程（0.5）——
    /// 采样窗口跨过折回点时 `x` 会从 +travel/2 跳回 −travel/2，那是**设计如此**
    /// （折回那一瞬透明度为 0，看不见）。判据要的是「一个行程之内不会掉头」。
    func testCloudTravelsInOneDirectionInsteadOfSwinging() {
        let travel: CGFloat = 900
        var previous = CloudDrift.state(index: 0, seconds: 0, travel: travel).x
        var strictlyIncreasingSamples = 0
        for step in 1...30 {
            let x = CloudDrift.state(index: 0, seconds: Double(step), travel: travel).x
            if x > previous { strictlyIncreasingSamples += 1 }
            XCTAssertGreaterThanOrEqual(x, previous, "第 \(step) 秒云往回走了（\(previous) → \(x)）")
            previous = x
        }
        XCTAssertEqual(strictlyIncreasingSamples, 30, "30 个采样里应当每一步都前进")

        // 反过来钉住「折回」本身也成立：走够久之后它确实会重新开始（不会停在终点）。
        // 判据是「出现过负的一步」+「progress 永远不到 1」，不是猜第几秒折回 ——
        // 阵风加权让一圈的实际秒数比 `crossingSeconds` 略短，写死秒数只会钉住我的算术。
        var wrapped = 0
        var previousProgress = CloudDrift.state(index: 0, seconds: 0, travel: travel).progress
        for step in 1...200 {
            let progress = CloudDrift.state(index: 0, seconds: Double(step), travel: travel).progress
            if progress < previousProgress { wrapped += 1 }
            previousProgress = progress
        }
        XCTAssertGreaterThanOrEqual(wrapped, 2, "200 秒里应当折回过至少两次")
    }

    /// 位移永远落在行程之内（含两端各半程），可见度永远是 0…1。
    ///
    /// 云走出画外是**正常**的（它就是在画外起飞、在画外落地），但走出行程
    /// 就是算错了 —— 那意味着折回的位置与画幅对不上，云会永远贴在屏幕一角。
    func testStateStaysInsideTheTripAndInsideTheUnitRange() {
        let travel: CGFloat = 720
        for index in 0..<7 {
            for step in 0...600 {
                let state = CloudDrift.state(index: index, seconds: Double(step) * 0.7, travel: travel)
                XCTAssertGreaterThanOrEqual(state.progress, 0)
                XCTAssertLessThan(state.progress, 1)
                XCTAssertLessThanOrEqual(abs(state.x), travel / 2 + 0.001,
                                         "index \(index) 第 \(step) 步飞出了行程：\(state.x)")
                XCTAssertGreaterThanOrEqual(state.alpha, 0)
                XCTAssertLessThanOrEqual(state.alpha, 1)
            }
        }
    }

    /// 两端淡出：行程头尾为 0，中段满值。
    ///
    /// 反证：`visibility` 恒 `return 1` → 两端为 1 → 红（每 78 秒会有一次凭空消失）。
    func testVisibilityFadesAtBothEndsAndIsFullInTheMiddle() {
        XCTAssertEqual(CloudDrift.visibility(progress: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(CloudDrift.visibility(progress: 1), 0, accuracy: 1e-9)
        XCTAssertEqual(CloudDrift.visibility(progress: 0.5), 1, accuracy: 1e-9)
        // 淡出区之外**整段**满值（不是钟形曲线：云有一半时间半透明会读成雾）
        XCTAssertEqual(CloudDrift.visibility(progress: 0.30), 1, accuracy: 1e-9)
        XCTAssertEqual(CloudDrift.visibility(progress: 0.70), 1, accuracy: 1e-9)
        // 淡出区内线性
        XCTAssertEqual(CloudDrift.visibility(progress: CloudDrift.edgeFade / 2), 0.5, accuracy: 1e-9)
    }

    // MARK: - 阵风加权

    /// 阵风加权时间的导数 = `WindField.gust`（这就是「跟的是同一阵风」的算式证明）。
    ///
    /// 取样避开 `t = 0`：`gust(0) = 0.75`，而单侧差分在 0 处会把曲率算进去。
    /// 步长 1e-3 与容差 1e-4 是「中心差分误差 ≈ h²·|f'''|/6 ≈ 1e-7」的量级 ——
    /// 容差留给实现里的浮点误差，不留给我自己的算术。
    func testGustWeightedTimeDifferentiatesBackToTheGust() {
        let omega = WindField.speed * WindField.gustWave
        let h = 1e-3
        for step in stride(from: 0.5, through: 40.0, by: 0.5) {
            let ahead = CloudDrift.gustWeightedTime(seconds: step + h)
            let behind = CloudDrift.gustWeightedTime(seconds: step - h)
            let slope = (ahead - behind) / (2 * h)
            let expected = 0.75 + 0.25 * sin(omega * step)
            XCTAssertEqual(slope, expected, accuracy: 1e-4,
                           "t = \(step) 处云的速度与阵风对不上：\(slope) vs \(expected)")
        }
    }

    /// 阵风加权时间：0 秒 = 0，之后单调递增；负数与 NaN 都收成 0（不许跑出 inf/NaN）。
    func testGustWeightedTimeIsMonotonicAndGuardsBadInput() {
        XCTAssertEqual(CloudDrift.gustWeightedTime(seconds: 0), 0, accuracy: 1e-12)
        XCTAssertEqual(CloudDrift.gustWeightedTime(seconds: -12), 0, accuracy: 1e-12)
        XCTAssertEqual(CloudDrift.gustWeightedTime(seconds: .nan), 0, accuracy: 1e-12)
        XCTAssertEqual(CloudDrift.gustWeightedTime(seconds: .infinity), 0, accuracy: 1e-12)
        var previous = 0.0
        for step in 1...300 {
            let value = CloudDrift.gustWeightedTime(seconds: Double(step))
            XCTAssertGreaterThan(value, previous, "第 \(step) 秒没有前进")
            previous = value
        }
    }

    /// **帧率无关**：同一个秒数永远给同一个位置。
    ///
    /// 这是「可积」的实用价值 —— 风钟按 30fps 推进，但位置只由累计秒数决定，
    /// 掉帧、暂停、切窗口都不会让云在画面上跳一下。
    func testSameSecondAlwaysGivesTheSamePosition() {
        let first = CloudDrift.state(index: 2, seconds: 41.25, travel: 800)
        for _ in 0..<5 {
            XCTAssertEqual(CloudDrift.state(index: 2, seconds: 41.25, travel: 800), first)
        }
    }

    // MARK: - 接线（源码哨兵）

    /// 云读的是**风钟的累计秒数**，不是自己的 `loopAnimation`。
    ///
    /// ⚠️ 钉的是调用形态整串（`wind?.blownSeconds`），并先剥掉整行注释 ——
    /// 最自然的反证手法就是「把那行注释掉」，而注释里留着一模一样的字符串。
    func testCloudsAreDrivenByTheWindClock() throws {
        let source = try Self.stripped("Components/ForestSky.swift")
        XCTAssertTrue(source.contains("let seconds = wind?.blownSeconds ?? 0"),
                      "云没有读风钟的累计秒数")
        XCTAssertTrue(source.contains("CloudDrift.state(index: pair.offset, seconds: seconds,"),
                      "云的位移没有走 CloudDrift")
        // 负面断言必须配正向断言：`Clouds` 还在文件里（否则「没有 loopAnimation」是空话）
        XCTAssertTrue(source.contains("private struct Clouds: View"), "Clouds 不见了")
        XCTAssertFalse(source.contains(".loopAnimation(.easeInOut(duration: 26)"),
                       "云自己的 26 秒摆动还在（会与风钟抢同一件事）")
    }

    /// 地面云影挂在**林间地面带**里，并且排在居民之后（气泡在它之上）。
    func testCloudShadowsAreMountedInTheGroundBand() throws {
        let source = try Self.stripped("Components/ForestGroundBand.swift")
        XCTAssertTrue(source.contains("@Environment(\\.forestAmbientStill) private var ambientStill"),
                      "云影没接「林子完全安静」档")
        let lines = source.components(separatedBy: "\n")
        let shadow = try XCTUnwrap(
            lines.firstIndex { $0.contains("ForestCloudShadows(theme: theme, still: ambientStill)") },
            "云影没有接进地面带")
        // 正向对照：气泡层确实还在（否则「影子在气泡之前」是空话）
        let bubble = try XCTUnwrap(lines.firstIndex { $0.contains("let text = bubbleTexts[i]") },
                                   "气泡层不见了")
        XCTAssertLessThan(shadow, bubble, "云影必须画在气泡层之前（气泡 zIndex 更高，仍压得住它）")
        // 同一件事的第二半：居民在影子之前 —— 影子该盖住草与小动物。
        // ⚠️ 锚点用**代码行**不用注释行：`stripped` 会把整行注释剥掉。
        let resident = try XCTUnwrap(lines.firstIndex { $0.contains("kind: order[i % order.count],") },
                                     "居民层不见了")
        XCTAssertLessThan(resident, shadow, "云影要盖住居民（云影落在草地上是物理事实）")
    }

    // MARK: - 工具

    /// 读源码并**剥掉整行注释**。
    ///
    /// ⚠️ 不剥的话，最自然的反证（把那一行注释掉）会因为注释里留着同样的字符串而照样绿。
    static func stripped(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // AILanguageCoachTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // 仓库根
            .appendingPathComponent("Sources/AppUI")
            .appendingPathComponent(relativePath)
        let text = try String(contentsOf: url, encoding: .utf8)
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
