import SwiftUI

/// 卷轴周围的庆祝烟花（今日任务全部完成时放一次）。
///
/// 为什么不用 `Canvas` + `TimelineView`：那套在离屏渲染里取不到稳定帧，
/// 而这里恰恰要能被离屏截图钉住（「到底放没放烟花」只能看图说话）。
/// 改用**一次性动画**：`progress` 从 0 补间到 1，每颗粒子自己带 delay 与时长，
/// 放完就停（父级几秒后把整张视图摘掉，不留常驻计时器）。
public struct CelebrationFireworks: View {

    /// 一颗火星。
    public struct Spark: Identifiable, Sendable {
        public let id: Int
        /// 第几簇（决定起点）。
        public let burst: Int
        /// 飞散方向（弧度）。
        public let angle: Double
        /// 飞散距离（pt）。
        public let distance: CGFloat
        /// 直径。
        public let size: CGFloat
        /// 起爆延迟（秒）。
        public let delay: Double
        /// 飞行时长（秒）。
        public let life: Double

        public init(id: Int, burst: Int, angle: Double, distance: CGFloat,
                    size: CGFloat, delay: Double, life: Double) {
            self.id = id
            self.burst = burst
            self.angle = angle
            self.distance = distance
            self.size = size
            self.delay = delay
            self.life = life
        }
    }

    public var tint: Color
    public var secondary: Color
    /// 四簇烟花的起点（相对自身尺寸的比例）。
    ///
    /// 2026-09-29 用户口径「需要明显一点的烟花」：三簇扩成四簇，铺得更开，
    /// 黑板那侧与树面板那侧都吃这一份提升。
    public var anchors: [CGPoint] = [
        CGPoint(x: 0.10, y: 0.30),
        CGPoint(x: 0.38, y: 0.12),
        CGPoint(x: 0.66, y: 0.26),
        CGPoint(x: 0.92, y: 0.38),
    ]

    @State private var progress: CGFloat = 0

    public init(tint: Color, secondary: Color) {
        self.tint = tint
        self.secondary = secondary
    }

    public var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            ZStack {
                ForEach(Self.sparks) { spark in
                    let origin = Self.anchor(forBurst: spark.burst, anchors: anchors)
                    let travel = spark.distance * progress
                    Circle()
                        .fill(spark.burst % 2 == 0 ? tint : secondary)
                        .frame(width: spark.size, height: spark.size)
                        // 抛物线：横向匀速，纵向叠一个「往下掉」的二次项。
                        .offset(
                            x: origin.x * w + cos(spark.angle) * travel - w / 2,
                            y: origin.y * h + sin(spark.angle) * travel + 26 * progress * progress - h / 2
                        )
                        .opacity(Double(max(0, 1 - progress)))
                        .animation(
                            .easeOut(duration: spark.life).delay(spark.delay),
                            value: progress
                        )
                }
            }
            .frame(width: w, height: h)
        }
        .allowsHitTesting(false)
        .onAppear {
            progress = 0
            withAnimation { progress = 1 }
        }
    }

    /// 第 `burst` 簇的起点（纯函数，便于单测）。
    ///
    /// 簇数多于锚点时挤在最后一簇（既有行为）；**锚点表为空时退回画面中上部** ——
    /// `anchors` 是 `public var`，外部给了空表不该让 `anchors[burst]` 越界把整棵树带崩。
    public static func anchor(forBurst burst: Int, anchors: [CGPoint]) -> CGPoint {
        guard !anchors.isEmpty else { return CGPoint(x: 0.5, y: 0.3) }
        return anchors[min(burst, anchors.count - 1)]
    }

    /// 四簇 × 14 颗 = 56 颗火星。**写死而不用随机**：随机会让每次重绘都换一批位置，
    /// 离屏截图与真机对不上，也无法断言。
    ///
    /// 2026-09-29 用户口径「需要明显一点的烟花」：火星更多、飞得更远、颗粒更大。
    public static let sparks: [Spark] = {
        var list: [Spark] = []
        var id = 0
        for burst in 0..<4 {
            for i in 0..<14 {
                let angle = Double(i) / 14 * 2 * Double.pi
                let distance: CGFloat = 62 + CGFloat((i * 7 + burst * 13) % 11) * 5
                list.append(
                    Spark(
                        id: id,
                        burst: burst,
                        angle: angle,
                        distance: distance,
                        size: 6 + CGFloat((i + burst) % 3) * 1.8,
                        delay: Double(burst) * 0.38,
                        life: 1.7
                    )
                )
                id += 1
            }
        }
        return list
    }()
}
