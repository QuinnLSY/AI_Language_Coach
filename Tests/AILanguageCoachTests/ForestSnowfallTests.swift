import AIDomain
@testable import AppUI
import CoreGraphics
import XCTest

/// 雪花布局（2026-10-21 重写）的**纯函数**判据。
///
/// 用户报的三件事各自对应一条：
/// ① 「雪花几乎看不见」→ 密度 / 尺寸 / 白芯（渲染回归里量，这里钉数量与大小档位）；
/// ② 「一边缓慢降落，一边缓慢左右摆动」→ 纵向只有下落、横向只有正弦摆动；
/// ③ 「**绝对不会往上移动**」→ `fallOffset` 在可见区内必须单调不减（本节第一条）。
///
/// 反证纪律：把 `fallOffset` 里的 `-margin + wrapped` 改成 `+margin - wrapped`
/// （方向反了）→ `testFlakesOnlyFallDownwards` 当场红；
/// 把 `max(wrapped, 0)` 删掉 → 同上。
final class ForestSnowfallTests: XCTestCase {

    private let height: CGFloat = 620
    private let width: CGFloat = 360

    // MARK: - 只往下

    /// 可见区内 y **只增不减**；唯一的方向反转是「已经落到画外下方 → 回到画外上方」。
    ///
    /// 这条是用户那句「绝对不会往上移动」的正面判据：只要 `elapsed` 往前推，
    /// 屏幕上的雪花就只能是往下走。折返必须发生在**画外**（`previous >= height`），
    /// 也就是说肉眼看不到任何上升。
    func testFlakesOnlyFallDownwards() {
        for density in [SnowfallDensity.far, .near] {
            for flake in SnowfallLayout.field(seed: 0x534E_4F57, density: density) {
                var previous = SnowfallLayout.fallOffset(flake, height: height, elapsed: 0)
                var elapsed = 0.0
                while elapsed < 400 {
                    elapsed += 0.05
                    let y = SnowfallLayout.fallOffset(flake, height: height, elapsed: elapsed)
                    if y < previous {
                        XCTAssertGreaterThanOrEqual(
                            previous, height,
                            "雪花在可见区里往上跳了（\(previous) → \(y)，flake #\(flake.id)）"
                        )
                    }
                    previous = y
                }
            }
        }
    }

    /// 纵向永远落在「画布 + 上下两段余量」里，不会飞出天际线。
    func testFallStaysWithinTheTravelBand() {
        let margin = SnowfallLayout.margin(height: height)
        for flake in SnowfallLayout.field(seed: 7, density: .near) {
            for step in 0..<200 {
                let y = SnowfallLayout.fallOffset(
                    flake, height: height, elapsed: Double(step) * 0.37
                )
                XCTAssertGreaterThanOrEqual(y, -margin - 0.001, "雪花从画面上方飞出去了")
                XCTAssertLessThanOrEqual(y, height + margin + 0.001, "雪花落到画布外面去了")
            }
        }
    }

    /// 下落速度就是声明的那个（pt/s）：慢得能看清，又不会「几乎不动」。
    func testFallSpeedMatchesTheDeclaredSpeed() {
        for density in [SnowfallDensity.far, .near] {
            let span = Double(SnowfallLayout.travel(height: height))
            for flake in SnowfallLayout.field(seed: 11, density: density) {
                // 取一段不含折返的窗口：从折返点之后出发
                let start = (span - flake.start * span) / flake.speed + 0.5
                let dt = 3.0
                let a = SnowfallLayout.fallOffset(flake, height: height, elapsed: start)
                let b = SnowfallLayout.fallOffset(flake, height: height, elapsed: start + dt)
                XCTAssertEqual(Double(b - a), flake.speed * dt, accuracy: 0.5,
                               "下落速度与声明不符（flake #\(flake.id)）")
            }
        }
    }

    /// 「缓慢」有硬下限也有硬上限：远 / 近两档都在 10…26 pt/s，比雨（90…160pt/s）慢一个数量级。
    func testFallIsSlow() {
        for density in [SnowfallDensity.far, .near] {
            for flake in SnowfallLayout.field(seed: 3, density: density) {
                XCTAssertGreaterThan(flake.speed, 9, "雪花落得太快，像冰雹")
                XCTAssertLessThan(flake.speed, 27, "雪花落得太慢，像静止的点")
            }
        }
    }

    // MARK: - 左右轻摆

    /// 横摆只在 x 上：幅度不超 `sway`，且 `elapsed` 变化时 y 完全不受它影响。
    func testSwayOnlyMovesHorizontally() {
        for flake in SnowfallLayout.field(seed: 5, density: .near) {
            for step in 0..<120 {
                let elapsed = Double(step) * 0.13
                let sway = SnowfallLayout.swayOffset(flake, elapsed: elapsed)
                XCTAssertLessThanOrEqual(abs(Double(sway)), flake.sway + 0.001,
                                         "横摆幅度超出了声明值")
                let point = SnowfallLayout.point(flake, width: width, height: height,
                                                elapsed: elapsed)
                let fall = SnowfallLayout.fallOffset(flake, height: height, elapsed: elapsed)
                XCTAssertEqual(Double(point.y), Double(fall), accuracy: 0.001,
                               "横摆把雪花带到纵向去了（雪不许左右摆着摆着往上飘）")
            }
        }
    }

    /// 摆动**真的在来回**（不是单边漂移）：同一片的 x 相对基准位有正有负。
    func testSwayCrossesBothSides() {
        for flake in SnowfallLayout.field(seed: 9, density: .far) {
            var sawLeft = false
            var sawRight = false
            for step in 0..<400 {
                let sway = Double(SnowfallLayout.swayOffset(
                    flake, elapsed: Double(step) * 0.05
                ))
                if sway < -flake.sway * 0.5 { sawLeft = true }
                if sway > flake.sway * 0.5 { sawRight = true }
            }
            XCTAssertTrue(sawLeft && sawRight, "这片雪只在单边摆（不是左右轻摆）")
        }
    }

    // MARK: - 密度 / 尺寸 / 确定性

    /// 远景铺满、近景更大：两档不是同一批雪花换个名字。
    func testNearFlakesAreBiggerAndFewer() {
        let far = SnowfallLayout.field(seed: 1, density: .far)
        let near = SnowfallLayout.field(seed: 1, density: .near)
        XCTAssertGreaterThan(far.count, near.count, "远景该比近景密")
        let farAverage = far.map(\.size).reduce(0, +) / Double(far.count)
        let nearAverage = near.map(\.size).reduce(0, +) / Double(near.count)
        XCTAssertGreaterThan(nearAverage, farAverage * 1.2, "近景雪花没有更大，景深分不出来")
        XCTAssertGreaterThanOrEqual(near.count, 16, "近景太稀，看着像掉了几个白点")
        XCTAssertGreaterThanOrEqual(far.count, 30, "远景太稀，天上像没下雪")
    }

    /// 同种子 → 同一批（重绘不许换一场新雪）；换种子 → 换一批。
    func testFieldIsDeterministicPerSeed() {
        let first = SnowfallLayout.field(seed: 0x534E_4F57, density: .near)
        let second = SnowfallLayout.field(seed: 0x534E_4F57, density: .near)
        XCTAssertEqual(first, second, "同种子生成了两批不同的雪")
        let other = SnowfallLayout.field(seed: 0x534E_4F58, density: .near)
        XCTAssertNotEqual(first, other, "换种子没换雪（种子没接进去）")
    }

    /// 开屏就是满天雪：`elapsed = 0` 时雪花已经分布在整幅画面里，不是挤在顶上。
    func testFieldIsAlreadySpreadAtTimeZero() {
        let margin = SnowfallLayout.margin(height: height)
        let flakes = SnowfallLayout.field(seed: 0x4E45_4152, density: .near)
        let visible = flakes.filter { flake in
            let y = SnowfallLayout.fallOffset(flake, height: height, elapsed: 0)
            return y >= 0 && y <= height
        }
        XCTAssertGreaterThan(visible.count, flakes.count / 2,
                             "开场时大半雪花还在画外（要等很久才看得到下雪）")
        XCTAssertGreaterThan(margin, 0)
    }

    /// 冻结档（`reduceMotion` / 离屏出图）里画面**照样有雪** —— 关动效不许做成关内容。
    func testFrozenFrameStillHasFlakesOnScreen() {
        let flakes = SnowfallLayout.field(seed: 0x534E_4F57, density: .near)
        let visible = flakes.filter { flake in
            let y = SnowfallLayout.fallOffset(
                flake, height: height, elapsed: SnowfallLayout.frozenElapsed
            )
            return y >= 0 && y <= height
        }
        XCTAssertGreaterThan(visible.count, flakes.count / 2,
                             "静止档画面上几乎没有雪（关动效把内容也关了）")
    }

    /// 横向落点不许跑出画面（窄面板也不能有半片雪挂在边上）。
    func testHorizontalPositionStaysInsideTheCanvas() {
        let narrow: CGFloat = 150
        for flake in SnowfallLayout.field(seed: 13, density: .near) {
            for step in 0..<80 {
                let point = SnowfallLayout.point(
                    flake, width: narrow, height: height, elapsed: Double(step) * 0.21
                )
                XCTAssertGreaterThanOrEqual(point.x, 0, "雪花跑到画布左边外面")
                XCTAssertLessThanOrEqual(point.x, narrow, "雪花跑到画布右边外面")
            }
        }
    }
}
