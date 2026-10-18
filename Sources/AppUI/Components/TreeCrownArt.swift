import AppKit
import SwiftUI

// MARK: - 为什么要有这个文件
//
// 用户 2026-10-18 的报障原话：「树冠永远都是一团，没有树叶、树枝的层次感，
// 现在完全是一团绿，毫无参天大树的宏伟感」。
//
// 三次返工（v4 / v5 / v6）都栽在同一个地方，值得写在这里：
//
// - **v4 的病根是一道路径**：四颗团块并成一道路径只填一次色，交界处因此没有
//   任何边界 —— 那本来是为了消灭「一块一块」，代价是把层次一起消灭了。
// - **v5 / v6 的病根是团块太大**：改成「多团各自明暗」之后，每团都占树冠的
//   四分之一、每条轮廓都是一个完整的圆盘 —— 于是读作**一堆汤圆**，
//   而不是一棵树。人眼判「这是树」靠的是**叶缘的尺度**：树冠轮廓上应该有
//   几十个小起伏（20—40pt），而不是四五个大圆。
//
// 第 4 版（本文件）因此换了三件事，缺一件都不成立：
//
// 1. **叶团少而大、但轮廓是"多尺度"的**：7 团，每团的半径由**三个频率**的
//    周期噪声叠加（大团 / 中团 / 小叶），轮廓因此是层层叠叠的叶浪，
//    不是一条被揉皱的椭圆；
// 2. **层次靠"半条边"**：每团的暗面只在下沿 —— 渐变起点在全透明处，
//    上沿根本不存在，所以团与团读作**互相压着**，而不是并排摆着；
// 3. **枝干是递归长出来的**：主干 → 4 根主枝 → 各分两岔 → 再各分两岔，
//    下粗上细、左右交替弯。一根根从同一点射出去的叫"喷泉"，不叫树。
//
// ⚠️ 三层的「远近」不共用一个 `treeDepth`：背层 0.34 / 前层 0.10。
// 树冠内部本来就有空气 —— 背层更灰更淡，枝干才可能在它上面读成深色剪影。
// 三层同深度 = 枝干与背层同明度 = 枝干看不见。

// MARK: - 树冠配色

/// 叶色的一条**连续冷暖轴**：0 = 最深的叶背，1 = 最亮的向阳叶。
///
/// 为什么是函数而不是两个主题令牌：树冠有 7 团叶 + 一层沉影 + 一片边光 + 上百片
/// 碎叶，每一处都需要自己那一档；令牌只能给两端，中间全靠插值就必然过渡生硬。
/// 基色取主题的 `foliage`，所以季节一换（春嫩 / 夏盛 / 秋黄 / 冬雪）整棵树跟着换。
public enum CanopyPalette {

    /// 冷暖偏移：暗部偏蓝绿、亮部偏黄绿。单位是色相环的 0…1。
    ///
    /// 0.040 ≈ 14°（色相环 360° 制）。这个量是「一眼看得出冷暖」的下限：
    /// 再小就只是明暗，叶子会塑料；再大就成了两种绿，读作两丛不同的植物。
    public static let hueSplit: Double = 0.040

    /// 明暗档的亮度倍率（白天）：暗端 0.50×、亮端 1.30×。
    public static let dayBrightness: (dark: CGFloat, light: CGFloat) = (0.50, 1.30)
    /// 明暗档的亮度倍率（夜里）：叶色本来就暗，再压 0.50× 就糊成一团黑。
    public static let nightBrightness: (dark: CGFloat, light: CGFloat) = (0.78, 1.30)

    /// 饱和度倍率：亮部更「实」，暗部被天光染灰。
    public static let daySaturation: (dark: CGFloat, light: CGFloat) = (0.90, 1.20)
    public static let nightSaturation: (dark: CGFloat, light: CGFloat) = (0.98, 1.10)

    /// 该档位的叶色。
    ///
    /// - Parameters:
    ///   - base: 主题基色（`theme.foliage`）。
    ///   - level: 0…1，越界夹住。
    ///   - isNight: 夜档不压那么深（叶子在夜里没有直射光，但也不是黑块）。
    public static func tone(_ base: Color, level: Double, isNight: Bool) -> Color {
        let t = CGFloat(min(max(level, 0), 1))
        guard let ns = NSColor(base).usingColorSpace(.sRGB) else { return base }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        ns.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        // 暗部 +、亮部 −（色相环正向是黄 → 绿 → 青，所以「偏蓝绿」是加）
        var shifted = hue + CGFloat(0.5 - t) * CGFloat(hueSplit) * 2
        if shifted < 0 { shifted += 1 }
        if shifted > 1 { shifted -= 1 }

        let bright = isNight ? nightBrightness : dayBrightness
        let sat = isNight ? nightSaturation : daySaturation
        return Color(
            hue: Double(shifted),
            saturation: Double(min(max(saturation * (sat.dark + (sat.light - sat.dark) * t), 0), 1)),
            brightness: Double(min(max(brightness * (bright.dark + (bright.light - bright.dark) * t), 0.04), 1)),
            opacity: Double(alpha)
        )
    }
}

// MARK: - 叶团 / 枝干的规格

/// 一片叶团：位置、大小、明暗档、属于哪一层。
///
/// `order` 不是绘制顺序的花招，是**景深**：0 = 背层（更灰更淡）、1 = 前层
/// （最亮最实）。绘制顺序跟着它走，`CanopyLayout.depth(forOrder:)` 给出该层的
/// 大气透视深度 —— 两件事同源，改一处不会漏另一处。
public struct LeafCluster: Sendable, Equatable {
    public var center: CGPoint
    public var radii: CGSize
    public var seed: UInt64
    /// 0…1 的叶色档位（见 `CanopyPalette.tone`）。
    public var tone: Double
    /// 0 = 背层 / 1 = 前层。
    public var order: Int

    public init(center: CGPoint, radii: CGSize, seed: UInt64, tone: Double, order: Int) {
        self.center = center
        self.radii = radii
        self.seed = seed
        self.tone = tone
        self.order = order
    }
}

/// 一根枝：起点 / 控制点 / 终点 + 两端粗细。
///
/// 用二次贝塞尔而不是折线：真树枝是弯的，且弯曲方向**左右交替**（同一侧连弯两次
/// 会读成一根被压弯的弹簧）。`bend` 就是那个交替量的来源。
public struct LimbSpec: Sendable, Equatable {
    public var from: CGPoint
    public var control: CGPoint
    public var to: CGPoint
    /// 根端粗细（pt）。
    public var rootWidth: CGFloat
    /// 末端粗细（pt）：绝不能是 0 —— 0 宽的末端抗锯齿后会消失半截。
    public var tipWidth: CGFloat
    /// 该枝的明暗档（0…1）：细枝比粗枝亮一点（受光面积 / 体积比更大）。
    public var tone: Double

    public init(from: CGPoint, control: CGPoint, to: CGPoint,
                rootWidth: CGFloat, tipWidth: CGFloat, tone: Double) {
        self.from = from
        self.control = control
        self.to = to
        self.rootWidth = rootWidth
        self.tipWidth = tipWidth
        self.tone = tone
    }

    /// 曲线上 t 处的点（纯函数，`LimbShape` 与测试共用）。
    public func point(at t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u * u * from.x + 2 * u * t * control.x + t * t * to.x,
            y: u * u * from.y + 2 * u * t * control.y + t * t * to.y
        )
    }

    /// 曲线上 t 处的单位法线（右手侧）。
    public func normal(at t: CGFloat) -> CGVector {
        let dx = 2 * (1 - t) * (control.x - from.x) + 2 * t * (to.x - control.x)
        let dy = 2 * (1 - t) * (control.y - from.y) + 2 * t * (to.y - control.y)
        let length = max((dx * dx + dy * dy).squareRoot(), 0.001)
        return CGVector(dx: -dy / length, dy: dx / length)
    }

    /// 曲线上 t 处的粗细（下粗上细，`pow(t, 0.7)` 让根部收得慢一些）。
    public func width(at t: CGFloat) -> CGFloat {
        rootWidth + (tipWidth - rootWidth) * pow(min(max(t, 0), 1), 0.7)
    }
}

// MARK: - 布局（纯函数）

/// 树冠的**构图**：7 团叶 + 一棵递归长出来的枝干骨架。
///
/// 全部是相对坐标（x、y ∈ [-1, 1]、半径为半宽 / 半高的比例），乘上画框尺寸即得
/// 绝对坐标。所以树面板加宽（用户可拖分割线）时整棵树等比放大，
/// 不会出现「叶团散开、缝变大」。
///
/// ⚠️ 表里的 `seed` 是**轮廓种子**，不是为了随机——同一个 seed 永远给同一条轮廓。
/// 重绘换轮廓 = 用户看到「叶子在抖」，这是硬约束。
public enum CanopyLayout {

    /// 两层各自的大气透视深度（树站在 `ForestSceneGeometry.treeDepth` = 0.18）。
    ///
    /// 背层刻意比树本身更远（0.34）：它是「树冠内部那一片背光的叶」，
    /// 必须比枝干更灰更淡，枝干才可能读成深色剪影。两层同深度
    /// = 枝干与背层同明度 = 枝干根本看不见。
    public static func depth(forOrder order: Int) -> CGFloat {
        order == 0 ? 0.34 : 0.10
    }

    /// 叶团的**极坐标环**：`(个数, 环半径, 团半径, 种子基)`，全部相对冠幅。
    ///
    /// 为什么是「三十来个**同样大小**的叶团重重叠叠」而不是「几团大的各自为政」：
    /// 树冠轮廓上得有几十个同尺度的起伏（20—40pt），人眼才读作叶；
    /// 四五颗大团无论怎么调色都读作**一堆球**（v5 / v6 的实测结论）。
    /// 重叠量是刻意的（环距 0.34、团半径 0.32）：只有外沿那一段弧露出来，
    /// 露出来的弧连成一条**扇贝边**，轮廓于是不是蛋、也不是花瓣。
    ///
    /// 环与环的**角度相位错开 0.37 圈**：不错开就每一环同角度，
    /// 拼出来是一朵花，一眼看出是圆的。
    private static let lobeRings: [(
        count: Int, distance: CGFloat, radius: CGFloat, seed: UInt64
    )] = [
        (1, 0.00, 0.46, 3),      // 芯
        (7, 0.34, 0.32, 31),     // 内圈
        (13, 0.66, 0.27, 71),    // 外圈（剪影主体）
        (9, 0.88, 0.20, 113),    // 破边：这一圈决定轮廓的起伏
    ]

    /// 冠幅占画框的比例。
    ///
    /// 0.82 是算出来的，不是拍的：最外一圈的最大外沿
    /// = (0.88 × 1.06 + 0.20 × 1.10) × 1.05（叶缘噪声上限）≈ 1.21 倍冠幅，
    /// 而冠幅 = 半宽 × crownScale —— 1.21 × 0.82 ≈ 0.99，正好贴着画框。
    private static let crownScale: CGFloat = 0.82

    /// 画框尺寸 → 30 团叶的绝对几何。
    public static func clusters(in size: CGSize) -> [LeafCluster] {
        guard size.width > 0, size.height > 0 else { return [] }
        let rx = size.width * 0.50 * crownScale
        let ry = size.height * 0.50 * crownScale
        let center = CGPoint(x: size.width * 0.50, y: size.height * 0.50)
        var result: [LeafCluster] = []
        for (ringIndex, ring) in lobeRings.enumerated() {
            var rng = SeededRandom(seed: ring.seed)
            let phase = Double(ringIndex) * 0.37
            for index in 0..<ring.count {
                let unit = ring.count == 1
                    ? 0
                    : phase + Double(index) / Double(ring.count) + rng.next(in: -0.035...0.035)
                let theta = unit * 2 * Double.pi
                let distance = ring.distance * CGFloat(rng.next(in: 0.94...1.06))
                let radius = ring.radius * CGFloat(rng.next(in: 0.86...1.10))
                let y = center.y + CGFloat(sin(theta)) * distance * ry
                // 竖直位置归一化：-1 = 冠顶，+1 = 冠底
                let vertical = (y - center.y) / max(ry, 1)
                // 前层：偏下、偏里的那几团 —— 它们挡住枝干的**下半截**，
                // 于是枝干只在缝里露头（一根根全露是「插满棍子的球」，
                // 全盖住是「一团绿」，两种都试过）。
                let isFront = sin(theta) > 0.15 && distance < 0.78
                result.append(LeafCluster(
                    center: CGPoint(x: center.x + CGFloat(cos(theta)) * distance * rx, y: y),
                    radii: CGSize(width: radius * rx, height: radius * ry),
                    seed: ring.seed &+ UInt64(index &* 17) &+ UInt64(ringIndex &* 3),
                    // 越靠冠底越沉（叶背光），前层整体再亮一档
                    tone: min(max(
                        0.30 + 0.26 * Double(0.5 - vertical / 2) + (isFront ? 0.34 : 0),
                        0.06), 1.0),
                    order: isFront ? 1 : 0
                ))
            }
        }
        return result
    }

    /// 叶缘噪声允许的最大外凸比例（`LeafClusterShape` 的半径上限）。
    ///
    /// 出图复核与「树冠有没有溢出面板」的判据都要乘上它 —— 只算 radii 会漏掉
    /// 叶瓣鼓出来的那一圈，测试于是假绿。
    public static let maxLobeFactor: CGFloat = 1.05

    /// 剪影的包围盒（相对画框）：全部叶团的并集，**含叶缘外凸**。
    public static func silhouetteBounds(in size: CGSize) -> CGRect {
        let all = clusters(in: size)
        guard !all.isEmpty else { return .zero }
        var minX = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for cluster in all {
            let rx = cluster.radii.width * maxLobeFactor
            let ry = cluster.radii.height * maxLobeFactor
            minX = min(minX, cluster.center.x - rx)
            maxX = max(maxX, cluster.center.x + rx)
            minY = min(minY, cluster.center.y - ry)
            maxY = max(maxY, cluster.center.y + ry)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: 枝干

    /// 主枝的角度 / 长度（相对半高）/ 宽度（相对画框宽）/ 弯曲量。
    ///
    /// 角度以「正上」为 0、向右为正（度）。四根主枝的角度**不是等分的**：
    /// 等分读起来像扇子，真树的枝是「一主三副」，朝光那侧更舒展。
    private static let primaries: [(
        angle: Double, length: CGFloat, width: CGFloat, bend: CGFloat
    )] = [
        // 中央主干：一根往上直挑的粗枝，是整棵树的**脊**。
        // 缺了它，四根侧枝就都从同一点朝外张开 —— 读作一把扇子。
        (2, 0.94, 0.104, 0.020),
        (-66, 0.74, 0.076, -0.055),
        (-30, 0.86, 0.092, 0.045),
        (24, 0.84, 0.086, -0.050),
        (60, 0.72, 0.072, 0.052),
    ]

    /// 画框尺寸 → 枝干骨架（主干 → 4 主枝 → 各两岔 → 再各两岔，共 28 根）。
    ///
    /// 根端落在树干尖那一带（相对 y = 0.34，即画框 67% 高处）：树干从下方伸进来，
    /// 末端被叶子盖住；枝叶一压，读起来就是「树干长进了树冠里」。
    public static func limbs(in size: CGSize) -> [LimbSpec] {
        guard size.width > 0, size.height > 0 else { return [] }
        let halfH = size.height * 0.50
        let origin = CGPoint(x: size.width * 0.50, y: size.height * 0.52 + 0.34 * halfH)
        var result: [LimbSpec] = []
        for (index, primary) in primaries.enumerated() {
            grow(
                from: origin,
                angle: primary.angle,
                length: primary.length * halfH,
                width: primary.width * size.width,
                bend: primary.bend,
                depth: 2,
                level: 0,
                seed: UInt64(index &* 37 &+ 5),
                scale: size.width / 380,
                into: &result
            )
        }
        return result
    }

    /// 递归长枝：主干 → 两岔 → 再两岔。
    ///
    /// - `depth`：还能再分几级（2 → 三级枝）。
    /// - 子枝从母枝 **62% / 88%** 处岔出（不是末端）：真树枝是在枝的中后段分岔，
    ///   都从末端分，就成了「一把叉子」。
    /// - 左右交替弯（`bend` 的符号跟着级数与序号翻），同侧连弯读作弹簧。
    private static func grow(
        from origin: CGPoint,
        angle: Double,
        length: CGFloat,
        width: CGFloat,
        bend: CGFloat,
        depth: Int,
        level: Int,
        seed: UInt64,
        scale: CGFloat,
        into result: inout [LimbSpec]
    ) {
        var rng = SeededRandom(seed: seed)
        let radians = angle * Double.pi / 180
        let to = CGPoint(
            x: origin.x + CGFloat(sin(radians)) * length,
            y: origin.y - CGFloat(cos(radians)) * length
        )
        let mid = CGPoint(x: (origin.x + to.x) / 2, y: (origin.y + to.y) / 2)
        // 控制点沿法线偏一点：法线 = 方向左转 90°
        let normal = CGVector(dx: -cos(radians), dy: -sin(radians))
        let wobble = CGFloat(rng.next(in: 0.6...1.0))
        let control = CGPoint(
            x: mid.x + normal.dx * bend * length * wobble,
            y: mid.y + normal.dy * bend * length * wobble
        )
        result.append(LimbSpec(
            from: origin,
            control: control,
            to: to,
            rootWidth: width,
            tipWidth: max(width * 0.16, 1.4 * scale),
            // 越细的枝越亮（受光面积 / 体积比更大），描边浓度因此跟着级数走
            tone: 0.24 + 0.16 * Double(level)
        ))
        guard depth > 0 else { return }
        let forks: [(t: CGFloat, spread: Double)] = [(0.58, -1), (0.84, 1)]
        let anchorSpec = LimbSpec(
            from: origin, control: control, to: to,
            rootWidth: width, tipWidth: width * 0.16, tone: 0
        )
        for (index, fork) in forks.enumerated() {
            grow(
                from: anchorSpec.point(at: fork.t),
                // 左右各岔一次（spread 的符号）：同侧连岔两次就读成梳子了
                // 分岔角 14…24°：角度再大就成了一把「断枝」——
                // 真树枝的岔口是**慢慢分开**的，不是折出去的
                angle: angle + fork.spread * rng.next(in: 14...24),
                // 子枝只留母枝的 0.34…0.44：再长就顶出冠外了
                //（一根枝从枝的中后段分岔，末端还要再岔一次 —— 累计长度是
                // 母枝的 1.5 倍往上，不收就会在轮廓上留下几根"天线"）
                length: length * rng.next(in: 0.34...0.44),
                width: width * 0.52,
                bend: -bend,
                depth: depth - 1,
                level: level + 1,
                seed: seed &* 6_364_136 &+ UInt64(index &+ 1) &* 97,
                scale: scale,
                into: &result
            )
        }
    }
}

// MARK: - 叶片（叶团上的碎叶细节）

/// 一片碎叶：位置、大小、倾角、明暗档。
///
/// 为什么要单独做「叶片」这一层：叶团只给出**块**的层次，还差最后一档 ——
/// **叶**。人眼认「这是树不是一堆球」靠的正是轮廓上一圈参差的碎叶。
/// v5 / v6 缺的就是这一层，所以团块排得再好也读作汤圆。
public struct LeafMark: Sendable, Equatable {
    public var center: CGPoint
    public var size: CGSize
    /// 倾角（度）。
    public var angle: Double
    /// 明暗档 0…1。
    public var tone: Double
}

extension CanopyLayout {

    /// 碎叶：每团 22…30 片，撒在 0.55…1.02 半径的一圈上。
    ///
    /// 为什么贴着轮廓撒而不是均匀铺满：均匀铺满会变成「撒了一层芝麻」的噪点；
    /// 贴着轮廓才有「叶团的边缘是一层层小叶子」的读法，也正好把叶团的
    /// 硬边打碎 —— 轮廓上参差的叶尖是「树」与「球」的分界。
    ///
    /// 确定性：每团用自己的 `seed` 派生一串数，重绘永远同一张分布（硬约束）。
    public static func leafMarks(in size: CGSize) -> [LeafMark] {
        var marks: [LeafMark] = []
        let ry = size.height * 0.50 * crownScale
        let centreY = size.height * 0.50
        for cluster in clusters(in: size) {
            var rng = SeededRandom(seed: cluster.seed &* 977 &+ 13)
            // 14 片 / 团 × 30 团 = 420 片：再多就成了噪点，再少盖不住硬边
            for _ in 0..<14 {
                let theta = rng.next(in: 0...(2 * Double.pi))
                // 0.78…1.14：**压在叶缘上**，一半在里一半在外 ——
                // 这一圈参差就是「轮廓上是叶子」的全部来源
                let radius = rng.next(in: 0.78...1.14)
                let width = rng.next(in: 5...9)
                let y = cluster.center.y + cluster.radii.height * radius * CGFloat(sin(theta))
                // 明暗跟着**位置**走，不跟叶团的 `tone` 走。
                //
                // ⚠️ 这是上一稿的一个真 bug：前层叶团的 tone 很高（它是给
                // "受光面"定的），于是一片片亮叶子撒在冠底那块深色叶上，
                // 看着像在绿的桌布上撒了一把米。碎叶必须和它**脚下**的叶同色。
                let vertical = Double((y - centreY) / max(ry, 1))   // -1 冠顶，+1 冠底
                marks.append(LeafMark(
                    center: CGPoint(
                        x: cluster.center.x + cluster.radii.width * radius * CGFloat(cos(theta)),
                        y: y
                    ),
                    size: CGSize(width: width, height: width * 0.5),
                    // 大体顺着「被风吹」的方向歪，但不成一个角度
                    angle: rng.next(in: -42...28),
                    tone: min(max(
                        0.66 - 0.34 * (vertical * 0.5 + 0.5) + rng.next(in: -0.06...0.06),
                        0.06
                    ), 1.0)
                ))
            }
        }
        return marks
    }
}

// MARK: - 形状

/// 一片叶团的轮廓：椭圆基形 × **三个尺度**的周期叶缘噪声。
///
/// 三个尺度各管一件事，缺一个轮廓就不像叶：
/// - **大团**（绕一圈约 2 团）：整块叶团整体鼓一下、塌一下 —— 冠形因此不对称；
/// - **中团**（约 6 团）：一簇一簇的叶浪，20—40pt 的起伏，这是「层次」的主体；
/// - **小叶**（约 16 片）：边缘的碎叶尖，把轮廓的硬边磨掉。
///
/// 为什么在**单位圆上**采 2D 噪声（`(cos θ, sin θ)` 喂进 `ForestNoise`）：
/// 那是周期的，轮廓首尾天然连续，不会在接缝处留一道折痕。
/// 半径只往里收得多、往外鼓得少（0.87…1.07），所以叶子不会画出面板外。
struct LeafClusterShape: Shape {

    var center: CGPoint
    var radii: CGSize
    var seed: UInt64

    /// 基形半径：噪声围着它上下浮动。
    private static let baseRadius: CGFloat = 0.94
    /// 三个尺度的采样圈半径与幅度（圈越大 → 绕一圈的特征越多）。
    private static let bands: [(radius: Double, amplitude: CGFloat)] = [
        (1.05, 0.055),
        (2.75, 0.030),
        (6.80, 0.016),
    ]
    /// 采样点数：周长 ~600pt 的团，120 段 ≈ 每段 5pt，抗锯齿后无折角。
    private static let samples = 120

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for index in 0..<Self.samples {
            let theta = 2 * Double.pi * Double(index) / Double(Self.samples)
            let cosine = CGFloat(cos(theta))
            let sine = CGFloat(sin(theta))
            var scale = Self.baseRadius
            for (band, spec) in Self.bands.enumerated() {
                let noise = ForestNoise.fbm(
                    cos(theta) * spec.radius,
                    sin(theta) * spec.radius,
                    octaves: 2,
                    seed: seed &+ UInt64(band &* 131)
                )
                // 噪声 [0,1] → [-1,1]，均值 0（基形不受影响）
                scale += spec.amplitude * CGFloat(noise * 2 - 1)
            }
            let point = CGPoint(
                x: center.x + radii.width * scale * cosine,
                y: center.y + radii.height * scale * sine
            )
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// 一根枝的轮廓：沿曲线两侧各偏移半个宽度，围成一个**上细下粗**的闭合形。
///
/// 为什么不用 `stroke(lineWidth:)`：描边是等宽的，一根等宽的枝从树冠里伸出来
/// 就是一根棍子。真实枝干从根部到梢部是连续收细的，只有围成多边形才做得到。
struct LimbShape: Shape {

    var limb: LimbSpec

    /// 采样段数：14 段足够让曲线看不出折角，也不至于让每根枝都变成一笔开销。
    private static let segments = 14

    func path(in rect: CGRect) -> Path {
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        left.reserveCapacity(Self.segments + 1)
        right.reserveCapacity(Self.segments + 1)
        for index in 0...Self.segments {
            let t = CGFloat(index) / CGFloat(Self.segments)
            let point = limb.point(at: t)
            let normal = limb.normal(at: t)
            let half = limb.width(at: t) / 2
            left.append(CGPoint(x: point.x + normal.dx * half, y: point.y + normal.dy * half))
            right.append(CGPoint(x: point.x - normal.dx * half, y: point.y - normal.dy * half))
        }
        var path = Path()
        path.move(to: left[0])
        for point in left.dropFirst() { path.addLine(to: point) }
        for point in right.reversed() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }
}

/// 叶团并成的**一道路径**：只用来当遮罩 / 整块填色（剪影层）。
///
/// ⚠️ 它**不是**整棵树的画法：层次由 `TreeCrown` 的后续几层负责。
/// v4 的错误是把它当成了唯一的一层（于是只剩一层渐变 = 一团绿）。
struct CrownUnionShape: Shape {

    var clusters: [LeafCluster]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for cluster in clusters {
            path.addPath(LeafClusterShape(
                center: cluster.center,
                radii: cluster.radii,
                seed: cluster.seed
            ).path(in: rect))
        }
        return path
    }
}
