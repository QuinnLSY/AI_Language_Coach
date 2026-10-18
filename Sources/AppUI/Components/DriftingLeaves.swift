import SwiftUI

// MARK: - B：树冠下常驻的落叶

/// 树冠下**常驻**的落叶：叶子从冠底一片片脱开，顺着风慢慢斜落。
///
/// **它和 `LeafFallLayer` 不是一件事，两者都留着**：
/// - `LeafFallLayer` 是**事件**回应（收一个词飘一片、练完一段飘一小阵、通关缤纷）；
///   它平时一片都不画。
/// - 本层是**氛围**：一直在飘，稀疏、缓慢，安静的时候林子也不至于像一张静止的画。
///
/// 三个设计约束：
/// 1. **位置由时间算出来，不是用 `withAnimation` 推**：`progress = (t / 周期 + 相位) % 1`
///    —— 同一时刻问同一个函数，答案永远一样。用动画推的话，视图一旦重绘就会
///    从头再来一遍（叶子集体瞬移回树冠）。
/// 2. **每片的周期与相位都不同**：周期一样会读成「一排叶子同时下落」，
///    那正是本项目被否掉过好几次的「整齐划一」。
/// 3. **`reduceMotion` 下不动，但仍然看得见**：冻在各自的中段位置，
///    不是整层消失 —— 「关动效」不许做成「关内容」（`ForestMotes` 同一条纪律）。
struct DriftingLeaves: View {

    let theme: ForestTheme

    /// 同时在场几片。再多就成了下雪。
    var count: Int = 8

    /// 验证/静态档：true = 不随时间推进（离屏渲染要可复现的帧）。
    var still: Bool = false

    @Environment(\.appMotion) private var motion

    /// 计时起点：用 `Date` 的绝对时刻算 progress，重绘不会让相位跳变。
    @State private var origin = Date()

    private struct Drift: Identifiable {
        let id: Int
        /// 横向基准位置（面板宽的 0…1）。
        let lane: Double
        /// 起点（树冠下沿一带，画布坐标）。
        let startY: Double
        /// 全程下落距离。
        let fall: Double
        /// 叶长（pt）。
        let size: Double
        /// 全程自旋（度）。
        let spin: Double
        /// 下落周期（秒）。
        let period: Double
        /// 初相（0…1）：错开相位，叶子才不会排成一排一起落。
        let phase: Double
        /// 左右摆幅（pt）与摆动周期（秒）。
        let sway: Double
        let swayPeriod: Double
        /// 明暗档 0…1。
        let tone: Double
    }

    /// 布局表：确定性生成（同一次启动永远是同一批叶子）。
    ///
    /// 周期取 13…21 秒：一片叶子从树冠落到底大约就是这个尺度 ——
    /// 再快就急，像在下雨。
    private static let drifts: [Drift] = {
        var rng = SeededRandom(seed: 0x4C45_4146)   // "LEAF"
        return (0..<10).map { index in
            Drift(
                id: index,
                lane: rng.next(in: 0.08...0.92),
                startY: rng.next(in: 235...300),
                fall: rng.next(in: 420...600),
                size: rng.next(in: 8...13),
                spin: rng.next(in: -200...200),
                period: rng.next(in: 13...21),
                phase: rng.next(in: 0...1),
                sway: rng.next(in: 7...17),
                swayPeriod: rng.next(in: 2.6...4.2),
                tone: rng.next(in: 0.42...0.92)
            )
        }
    }()

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: still || motion.reduceMotion)) { context in
                let elapsed = still || motion.reduceMotion
                    ? 0
                    : context.date.timeIntervalSince(origin)
                ZStack(alignment: .topLeading) {
                    ForEach(Self.drifts.prefix(count)) { drift in
                        leaf(drift, width: width, elapsed: elapsed)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
        .allowsHitTesting(false)
        // 纯氛围：读屏不该读到「一片飘着的叶子」。
        .accessibilityHidden(true)
    }

    private func leaf(_ drift: Drift, width: CGFloat, elapsed: Double) -> some View {
        // progress ∈ [0,1)：落下 → 回到顶上重来。位置是时间的纯函数。
        let raw = elapsed / drift.period + drift.phase
        let progress = raw - raw.rounded(.down)
        let swing = sin(elapsed / drift.swayPeriod * 2 * .pi + drift.phase * 6.28) * drift.sway
        return CrownLeafShape()
            .fill(CanopyPalette.tone(theme.foliage, level: drift.tone, isNight: theme.isNight)
                .opacity(0.9))
            .frame(width: drift.size, height: drift.size * 0.52)
            .rotationEffect(.degrees(drift.spin * progress))
            .position(
                x: width * drift.lane + swing,
                y: drift.startY + drift.fall * progress
            )
            // 起落两端淡出淡入：叶子不该在画面边界上"啪"地出现或消失
            .opacity(Self.fade(progress))
    }

    /// 端点淡入淡出（前 8% 淡入、后 12% 淡出）。
    private static func fade(_ progress: Double) -> Double {
        if progress < 0.08 { return progress / 0.08 }
        if progress > 0.88 { return (1 - progress) / 0.12 }
        return 1
    }
}

/// 一片小叶子：两段对称的二次曲线（叶尖尖、叶根圆）。
///
/// （与树冠碎叶用的是同一条曲线 —— 落叶和树上的叶子本来就该是同一个形状。）
struct CrownLeafShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY),
            control: CGPoint(x: rect.midX, y: rect.minY)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.midY),
            control: CGPoint(x: rect.midX, y: rect.maxY)
        )
        return path
    }
}
