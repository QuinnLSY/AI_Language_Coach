import SwiftUI

// MARK: - 雪花（2026-10-21 重写：可见、缓落、左右轻摆、绝不上升）

/// 一片雪花的**静态参数**：位置 / 大小 / 节奏全部由种子定死，重绘不许换一批。
///
/// 与 `KiteLayout`（风筝）同一套纪律：站位与节奏分开定 —— 站位决定它从哪儿落，
/// 节奏决定它怎么摆。同种子 → 同结果，截图回归才有意义。
public struct ForestFlake: Identifiable, Equatable, Sendable {

    public let id: Int
    /// 横向基准位置（画布宽的比例 0…1）。
    public let lane: Double
    /// 沿行程的**起始**位置（0…1）：错峰进场，开屏就是满天雪，不是「一起从顶上出发」。
    public let start: Double
    /// 直径（pt）。
    public let size: Double
    /// 横摆幅度（pt）。
    public let sway: Double
    /// 横摆周期（秒）—— 慢，是「摆」不是「抖」。
    public let period: Double
    /// 横摆初相（0…1）：各片不同相，才不会整片雪一起左右荡。
    public let phase: Double
    /// 下落速度（pt/s）。**恒正**：雪只往下走。
    public let speed: Double
}

/// 雪层的景深档：远处（整片天空）与近处（树栏前景）用同一套纯函数，密度 / 大小 / 速度各一档。
public enum SnowfallDensity: Sendable {

    /// 远景：铺满整片天空的底雪 —— 粒小、慢、淡。
    case far
    /// 近景：树栏前景的雪 —— 粒大、稍快、更实（用户就在看这一层）。
    case near

    /// 数量。近景曾经只有 20 片 —— 尺寸的增益压不过数量的劣势，实测近景墨迹
    /// 反而是远景的一半（2026-10-21），「近景更实」根本读不出来。
    /// 上限仍然压在 `far` 之下：近景靠「少而大」分景深，不许反过来铺满。
    var count: Int {
        switch self {
        case .far: 40
        case .near: 30
        }
    }

    var sizeRange: ClosedRange<Double> {
        switch self {
        case .far: 3.2...4.8
        case .near: 6.5...11.0
        }
    }

    /// 下落速度（pt/s）。都叫「缓落」：近景也不许砸下来（雨是 90…160pt/s 那一档）。
    var speedRange: ClosedRange<Double> {
        switch self {
        case .far: 11...17
        case .near: 16...24
        }
    }

    var swayRange: ClosedRange<Double> {
        switch self {
        case .far: 5...10
        case .near: 8...15
        }
    }

    var periodRange: ClosedRange<Double> {
        switch self {
        case .far: 3.2...5.2
        case .near: 2.8...4.6
        }
    }
}

/// 雪花的布局（纯函数，可单测）：**位置是时间的函数**，不是 `withAnimation` 推出来的。
///
/// 为什么不用「`offset` + `repeatForever` 推」那套（雨丝就是这么写的）：
/// ① 无限循环的重启点落在**画内**时，每一程结束都会瞬移回起点，慢速下落时
///    一眼就能看见「往上跳」；② 动画值一旦被重算（天气档位切换、视图重建），
///    位移会**倒着走回去** —— 用户说的「雪花往上移动」正是这一类。
/// 这里改成「算出来的位置」：`y` 是 `elapsed` 的单调递增函数，折返点放在**画外**，
/// 于是雪花只会往下走，永远不会上升。
enum SnowfallLayout {

    /// 上下各留多少余量（画布高的比例）：折返点落在画外，看不见「跳回顶上」。
    static let marginRatio: Double = 0.08

    /// 静止档的时间（秒）：`reduceMotion` / 离屏出图时停在这儿。
    ///
    /// ⚠️ 不是 0：0 是「刚进场」的分布（也能看，但 0 秒时所有雪花都落在各自的
    /// 起始相位上，密集处会挤）。停在一段行程之后，出来的是一张正常的下雪照。
    /// 关动效不许做成关内容（`KiteLayout.frozenElapsed` 同一条纪律）。
    static let frozenElapsed: Double = 9

    static func margin(height: CGFloat) -> CGFloat { max(10, height * marginRatio) }

    /// 一程的总行程（画布高 + 上下两段余量）。
    static func travel(height: CGFloat) -> CGFloat { height + margin(height: height) * 2 }

    /// 造一片雪（纯函数：同种子永远同一批）。
    static func flake(id: Int, density: SnowfallDensity, rng: inout SeededRandom) -> ForestFlake {
        let pitch = 1.0 / Double(max(density.count, 1))
        let lane = (Double(id) + 0.5 + (rng.next() - 0.5) * 0.9) * pitch
        return ForestFlake(
            id: id,
            lane: min(max(lane, 0.02), 0.98),
            start: rng.next(),
            size: rng.next(in: density.sizeRange),
            sway: rng.next(in: density.swayRange),
            period: rng.next(in: density.periodRange),
            phase: rng.next(),
            speed: rng.next(in: density.speedRange)
        )
    }

    /// 一整片雪（纯函数）。
    static func field(seed: UInt64, density: SnowfallDensity) -> [ForestFlake] {
        var rng = SeededRandom(seed: seed)
        return (0..<density.count).map { flake(id: $0, density: density, rng: &rng) }
    }

    /// 纵向位移（pt）：从画外上方（`-margin`）落到画外下方（`height + margin`），然后折返。
    ///
    /// **单调**：`elapsed` 增加时它只会变大；唯一的方向反转是「到画外下方 → 回画外上方」，
    /// 两端都在可见区之外，所以肉眼看不到任何上升。
    static func fallOffset(_ flake: ForestFlake, height: CGFloat, elapsed: Double) -> CGFloat {
        guard height > 0 else { return 0 }
        let margin = margin(height: height)
        let span = Double(travel(height: height))
        guard span > 0 else { return 0 }
        let travelled = flake.start * span + elapsed * flake.speed
        let wrapped = travelled.truncatingRemainder(dividingBy: span)
        return -margin + CGFloat(max(wrapped, 0))
    }

    /// 横向摆动（pt）：正弦，只在 x 上，**不碰 y**。
    static func swayOffset(_ flake: ForestFlake, elapsed: Double) -> CGFloat {
        guard flake.period > 0 else { return 0 }
        let angle = (elapsed / flake.period + flake.phase) * 2 * .pi
        return CGFloat(sin(angle) * flake.sway)
    }

    /// 落点（画布坐标）：横向由基准位 + 摆动，纵向由 `fallOffset`。
    static func point(_ flake: ForestFlake, width: CGFloat, height: CGFloat,
                      elapsed: Double) -> CGPoint {
        let half = CGFloat(flake.size) / 2
        let rawX = CGFloat(flake.lane) * width + swayOffset(flake, elapsed: elapsed)
        return CGPoint(
            x: min(max(rawX, half), max(width - half, half)),
            y: fallOffset(flake, height: height, elapsed: elapsed)
        )
    }
}

/// 一片雪花的样子：白芯 + 一圈极淡的冷边 + 一点柔影。
///
/// 为什么不是「实心圆 + 深边」：白天 / 雪地的底本身就是浅色，纯白圆点会整个化进
/// 背景（用户 2026-10-21：「雪花几乎看不见」）；可一旦压一圈**实心深边**，
/// 它又变成一颗「珠子」（实测第一版出图就是满屏小白珠）。
/// 现在是**柔边 + 柔影**：轮廓靠阴影立住，本体还是软的 —— 像雪，不像珠子。
private struct FlakeFigure: View {

    let theme: ForestTheme
    let flake: ForestFlake
    let near: Bool

    var body: some View {
        Circle()
            .fill(theme.snowCore)
            .frame(width: flake.size, height: flake.size)
            .overlay(
                Circle().strokeBorder(
                    theme.snowRim.opacity(0.45),
                    lineWidth: max(0.6, flake.size * 0.10)
                )
            )
            .shadow(color: theme.snowHalo,
                    radius: flake.size * (near ? 0.34 : 0.22),
                    x: 0, y: flake.size * 0.16)
            .frame(width: flake.size * 2, height: flake.size * 2)
    }
}

/// 下雪层：缓慢下落 + 缓慢左右轻摆，**位置由时间算出来**。
///
/// 三条既有约定（与 `ForestKites` / `ForestMotes` 同一套）：
/// 1. 位置是 `elapsed` 的纯函数（`SnowfallLayout`），重绘不跳相；
/// 2. `reduceMotion` / `still` 时**冻结在一段行程之后**（画面里照样有雪，只是不动）——
///    「关动效不许做成关内容」；
/// 3. 纯装饰：`allowsHitTesting(false)` + 无障碍隐藏（不抢关卡节点与小动物的点击）。
public struct ForestSnowfall: View {

    let theme: ForestTheme
    var density: SnowfallDensity = .far
    /// 静态档（离屏出图 / 氛围隐藏）：时间不推进。
    var still: Bool = false

    @Environment(\.appMotion) private var motion

    private static let seeds: [SnowfallDensity: UInt64] = [.far: 0x534E_4F57, .near: 0x4E45_4152]

    public var body: some View {
        // ⚠️ 档位判在 body 里（不在 onAppear）：切档不重新 appear（既有教训）。
        let frozen = still || motion.reduceMotion
        let flakes = SnowfallLayout.field(
            seed: Self.seeds[density] ?? 0x534E_4F57, density: density
        )
        return GeometryReader { proxy in
            // 落雪是九层里像素最重的一层，改造前它自起 24fps 的表；并入统一氛围钟后
            // 跟着驱动器的预算走（15–20fps，见 `ForestAmbientDriver.frameInterval`）——
            // 帧数让一档、每帧的像素照旧，总工作量反而更稳。
            AmbientTicker(paused: frozen, interval: 1.0 / 24.0) { now in
                let elapsed = frozen
                    ? SnowfallLayout.frozenElapsed
                    : max(now, 0)
                ZStack(alignment: .topLeading) {
                    ForEach(flakes) { flake in
                        let point = SnowfallLayout.point(
                            flake, width: proxy.size.width,
                            height: proxy.size.height, elapsed: elapsed
                        )
                        FlakeFigure(theme: theme, flake: flake, near: density == .near)
                            .position(x: point.x, y: point.y)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
