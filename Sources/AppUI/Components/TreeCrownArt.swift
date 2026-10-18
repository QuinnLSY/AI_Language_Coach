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
    /// 这一团是不是镜像对里「翻面」的那一枚（见 `clusters(in:)` 的镜像成对）。
    ///
    /// 只有 `leafMarks` 用：碎叶的 x 偏移要跟着翻号 —— 团心已经翻过面，
    /// 偏移不翻的话碎叶的整体范围左右差出 ~2pt（2026-10-18 实测）。
    public var mirrored: Bool

    public init(center: CGPoint, radii: CGSize, seed: UInt64, tone: Double, order: Int, mirrored: Bool) {
        self.center = center
        self.radii = radii
        self.seed = seed
        self.tone = tone
        self.order = order
        self.mirrored = mirrored
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

/// 树冠的**构图**：40 团叶 + 一棵递归长出来的枝干骨架 + 4 层各自随风的风层。
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

    // MARK: 冠的体量（下宽上窄）

    /// 冠幅（横向）占画框宽的比例。
    ///
    /// 0.78：腰位比第 3 版（老 `crownScale` 0.82）**窄一档**，这是下宽上窄
    /// 的代价 ——  flare 把下角往外推，横向预算就那么多，腰不收窄、裙摆角
    /// 就会顶到画框边（实测 0.82 时左右下角出框 6.6pt，风摆再无余量）。
    /// 「大三分之一」主要靠纵向跨幅与裙摆出界去拿，横向上不出去是硬边。
    private static let crownWidthScale: CGFloat = 0.78

    /// 冠高（纵向）占画框高的比例。
    ///
    /// 0.86：冠从画框 ~4% 长到 ~97%（第 3 版实测是 7.8%…94.1%）——
    /// 纵向跨幅 ~0.93 vs 老 0.863，配合裙摆探到树干中段，把左右下两个角
    /// 的天空吃进来（用户 2026-10-18：「树冠的范围可以再大三分之一……
    /// 左和右下方两边红框的区域补上一些树冠分层」）。
    private static let crownHeightScale: CGFloat = 0.86

    /// 冠的几何中心在画框内的纵向位置（比例）。< 0.5 = 中心偏上：
    /// 上窄下宽的冠重心压在下半幅，顶部才收得起来。
    ///
    /// 0.34：与树干尖（无课程时落在画框 36.7% 处）几乎重合 ——
    /// 树干正好捅进树冠的心脏，而不是从叶子上方戳过去。
    private static let crownCenterY: CGFloat = 0.34

    /// 下宽上窄的**展幅系数**：朝下的方向半径 ×(1+flare)，朝上 ×(1−flare)，左右不变。
    ///
    /// 0.32 是量出来的：冠腰半幅 ≈ 1.14 rx、肩部（最宽处，在冠心下方 43% 高处）
    /// ≈ 1.15 rx、冠顶 ≈ 0.73×、冠底 ≈ 1.45× —— 与照片里的大冠乔木（橡 / 榕一类）
    /// 同形：最宽点在冠心偏下，上下都收。再小读不出「下宽上窄」，
    /// 再大冠腰被挤出画框（风摆 ~7pt + 茂密度缩放 ~5pt/侧，每侧只留 ~12pt）。
    public static let flare: CGFloat = 0.32

    /// 某一簇叶所在方向的展幅倍率（`sin θ > 0` = 朝下，θ 与 `clusters` 里同一个）。
    public static func envelope(_ sinTheta: CGFloat) -> CGFloat {
        1 + flare * max(-1, min(1, sinTheta))
    }

    /// 画框 → 冠的半径与中心。
    ///
    /// `clusters` / `leafMarks` / `silhouetteBounds` / `bands` 共用这一处：
    /// 四处各算一套，迟早出现「碎叶撒在冠外」这种只在一处改了的事故。
    public static func crownFrame(in size: CGSize) -> (rx: CGFloat, ry: CGFloat, center: CGPoint) {
        (
            size.width * 0.5 * crownWidthScale,
            size.height * 0.5 * crownHeightScale,
            CGPoint(x: size.width * 0.5, y: size.height * crownCenterY)
        )
    }

    /// 叶团的**极坐标环**：`(个数, 环半径, 团半径, 种子基, 弧段)`，全部相对冠幅。
    ///
    /// 为什么是「四十来个**同样大小**的叶团重重叠叠」而不是「几团大的各自为政」：
    /// 树冠轮廓上得有几十个同尺度的起伏（20—40pt），人眼才读作叶；
    /// 四五颗大团无论怎么调色都读作**一堆球**（v5 / v6 的实测结论）。
    /// 重叠量是刻意的（环距 0.34、团半径 0.32）：只有外沿那一段弧露出来，
    /// 露出来的弧连成一条**扇贝边**，轮廓于是不是蛋、也不是花瓣。
    ///
    /// 环与环的**角度相位错开 0.37 圈**：不错开就每一环同角度，
    /// 拼出来是一朵花，一眼看出是圆的。
    ///
    /// `arc`（弧度，θ = 90° 是正下方）非空时，这一环只撒在那一段弧上 ——
    /// 裙摆环用它把自己限制在正下偏左右，整圈撒就只是又一条均质的边。
    private static let lobeRings: [(
        count: Int, distance: CGFloat, radius: CGFloat, seed: UInt64,
        arc: (from: Double, to: Double)?, toneShift: Double
    )] = [
        (1, 0.00, 0.46, 3, nil, 0),          // 芯
        (7, 0.34, 0.32, 31, nil, 0),         // 内圈
        (13, 0.66, 0.27, 71, nil, 0),        // 外圈（剪影主体）
        (9, 0.88, 0.20, 113, nil, 0),        // 破边：这一圈决定轮廓的起伏
        // 裙摆（用户 2026-10-18 报障：「左和右下方两边补上一些树冠分层」）：
        // 只撒 26°…154° 那一段弧（正下偏左右）。distance 0.88 与破边圈同级
        // 而半径更大 —— 弧的端点接近水平，再往外推左右下角就顶到画框边
        // （实测 distance 0.90 + radius 0.23 时左右各出框 6.6pt）。
        // 它的本事是**分层**：一团沉一档色调的叶浪压在冠腰受光面下沿，
        // 读作「又一层裙摆」，把红框那片天空补上。
        (10, 0.88, 0.21, 173, (0.46, 2.68), -0.10),
        // 裙摆外沿（同一报障的第二层）：只管 53°…127° 那两段**陡坡** ——
        // 红框就在那儿。distance 0.98 比裙摆还外一档、半径更小、色调再沉一档，
        // 读作「裙摆外面又压了一层暗叶」。它的活是把**最宽处从冠心下方
        // （43% 高）推到下摆（80% 高）** —— 真实大冠乔木（橡 / 榕）最宽点就在
        // 下摆，只宽在腰上读作球，不读作树。
        // 弧段收窄到陡坡是故意的：端点再放平（朝 30° 去）就会顶到画框左右边
        // （风摆 ~7pt + 茂密度缩放 ~5pt/侧，每侧要留 ~12pt），下角的份额从陡坡出。
        // 半径压到 0.16 是给冠底留的：distance 1.0 + radius 0.18 时含碎叶的
        // 底沿会探到 309pt，越过画框（300）与测试上限（306）。
        (6, 0.98, 0.16, 233, (0.92, 2.22), -0.12),
    ]

    /// 整环的**镜像移位** m（按环序号）：相位取自镜像对称的形式
    /// `phase = 0.25 − m/(2n)`（圈）时，第 k 团与第 (m−k) mod n 团关于竖轴
    /// 互为镜像（θ → π−θ），而团与团之间仍是 2π/n **等距铺满整圈**。
    ///
    /// 为什么非得对称：整环基相（`ringIndex·0.37`）会让叶团系统性地贴近 180°
    /// 而远离 0°，再叠上种子抖动，左肩比右肩外凸 ~19pt —— 整冠读作「往左歪」
    /// （2026-10-18 实测：肩弦左 1.166 rx / 右 1.038 rx）。三个移位 −2 / −12 / −16
    /// 是挑出来的：既让每环自镜像，又让环与环的角度互相错开（不错开则拼成一朵花）。
    /// 取偶数值，「正中一枚」才落在正下方（冠底那个包）而不是正上方。
    ///
    /// 弧环（裙摆两圈）用不到这一项 —— 它们的弧段本身关于 π/2 对称。
    private static let mirrorShifts: [Int] = [0, -2, -12, -16, 0, 0]

    /// 镜像侧的**受控微偏置**（rad）：θ → π−θ+bias。
    ///
    /// 严格镜像读作「复制粘贴的另一半」（用户 2026-10-18：「树冠不用完全对称，
    /// 左右稍微有一点区别」）。0.02 rad ≈ 1.1°：让镜像团连**高度**一起微错
    /// （只错 x 是整体平移，只错 y 是倾斜，两个都错才像自然生长）。
    /// ⚠️ 单靠它不够：剪影最外沿那几个团的角度恰在极值附近，cos 的导数为 0，
    /// 角度偏置在那儿是**二阶小量** —— 实测 0.02 rad 只差出 0.45pt，肉眼不可见。
    /// 一阶的那一半由 `mirrorXOffset` 出（纯 x 错位），两者叠加 ≈ 2pt。
    private static let mirrorBias: Double = 0.02

    /// 镜像侧的整体横向错位（pt）：一阶可测的「不机械」。
    ///
    /// 真实大树的两半本来就不是旋转关系，而是「一侧整体胖一点」——
    /// 所以这里错的是**位置**不是角度。1.5pt 是量出来的：看得出不机械，
    /// 看不出往一边歪；v6 的系统性偏斜是 19pt，差着一个量级，偏斜防护
    /// 因此由「差值上限」守（见 `TreeCrownBandsTests` 近似对称判据），
    /// 不再由「严格相等」守。
    private static let mirrorXOffset: CGFloat = 1.5

    /// 画框尺寸 → 40 团叶的绝对几何。
    public static func clusters(in size: CGSize) -> [LeafCluster] {
        guard size.width > 0, size.height > 0 else { return [] }
        let (rx, ry, center) = crownFrame(in: size)
        var result: [LeafCluster] = []
        for (ringIndex, ring) in lobeRings.enumerated() {
            var rng = SeededRandom(seed: ring.seed)
            let count = ring.count
            guard count > 0 else { continue }

            // —— 镜像配对表：第 k 团的搭档是谁 ——
            //
            // 整环用 (m−k) mod n；弧环（裙摆）用 n−1−k（弧段关于 π/2 对称，
            // 等分点天然成对）。⚠️ 不能给整环也用 (k, n−1−k)：镜像把角度映射到
            // (0, π) 下半圈，那样配只能取到弧内的角，整环塌进下半圈
            // （2026-10-18 实测：冠心高度的腰弦从 1.10 rx 掉到 0.79 rx）。
            let shift = mirrorShifts[ringIndex]
            let phase = 0.25 - Double(shift) / (2 * Double(count))
            var partner = [Int](repeating: 0, count: count)
            if ring.arc != nil {
                for k in 0..<count { partner[k] = count - 1 - k }
            } else {
                for k in 0..<count { partner[k] = ((shift - k) % count + count) % count }
            }

            // 每对的抖动**预取一次、两枚共享**：镜像才严丝合缝（各抽各的 = 没镜像）。
            // 团种子也按对共享 —— `leafMarks` 的碎叶种子由团种子推导，于是碎叶
            // 也自动成镜像，涂色范围左右严格一致（`TreeCrownBandsTests` 钉这条）。
            var unitJitter = [Double](repeating: 0, count: count)
            var distanceJitter = [CGFloat](repeating: 1, count: count)
            var radiusJitter = [CGFloat](repeating: 1, count: count)
            var paired = [Bool](repeating: false, count: count)
            for k in 0..<count where !paired[k] {
                let p = partner[k]
                paired[k] = true
                paired[p] = true
                let id = min(k, p)
                unitJitter[id] = rng.next(in: -0.035...0.035)
                distanceJitter[id] = rng.next(in: 0.94...1.06)
                radiusJitter[id] = rng.next(in: 0.86...1.10)
            }

            for index in 0..<count {
                let p = partner[index]
                let id = min(index, p)
                let isCenterPiece = p == index   // 正中一枚：正下方，自镜像
                let mirrored = index > p
                let unit: Double
                if let arc = ring.arc {
                    // 弧段环：在 [from, to] 上等分（只 1 团时就取中点）
                    let span = (arc.to - arc.from) / Double(max(count - 1, 1))
                    unit = (arc.from + span * Double(id)) / (2 * Double.pi)
                } else if isCenterPiece {
                    // 正中一枚钉在**正下方**（unit 0.25 圈 = θ π/2）：它的镜像是
                    // 它自己，角度再抖就不再自镜像（径向抖动照旧，不影响左右对称）。
                    unit = 0.25
                } else {
                    unit = phase + Double(id) / Double(count)
                }
                var theta = unit * 2 * Double.pi + (isCenterPiece ? 0 : unitJitter[id])
                if mirrored { theta = Double.pi - theta + mirrorBias }
                let sinTheta = CGFloat(sin(theta))
                // 下宽上窄：朝下的方向整簇往外推（中心与半径一起）
                let spread = envelope(sinTheta)
                let distance = ring.distance * distanceJitter[id] * spread
                let radius = ring.radius * radiusJitter[id] * spread
                let y = center.y + sinTheta * distance * ry
                // 竖直位置归一化：-1 = 冠顶，+1 = 冠底
                let vertical = (y - center.y) / max(ry, 1)
                // 前层：偏下、偏里的那几团 —— 它们挡住枝干的**下半截**，
                // 于是枝干只在缝里露头（一根根全露是「插满棍子的球」，
                // 全盖住是「一团绿」，两种都试过）。
                let isFront = sinTheta > 0.15 && distance < 0.78
                result.append(LeafCluster(
                    center: CGPoint(
                        // 镜像侧整体右错一档（`mirrorXOffset`）：破「机械复制」
                        x: center.x + CGFloat(cos(theta)) * distance * rx
                            + (mirrored ? mirrorXOffset : 0),
                        y: y),
                    radii: CGSize(width: radius * rx, height: radius * ry),
                    seed: ring.seed &+ UInt64(id &* 17) &+ UInt64(ringIndex &* 3),
                    // 越靠冠底越沉（叶背光），前层整体再亮一档；裙摆再沉一档
                    tone: min(max(
                        0.30 + 0.26 * Double(0.5 - vertical / 2) + (isFront ? 0.34 : 0) + ring.toneShift,
                        0.06), 1.0),
                    order: isFront ? 1 : 0,
                    mirrored: mirrored
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

    // MARK: 风层（分层飘动）

    /// 树冠分几层各自摆。
    ///
    /// 4 层是「看得出层次」的下限：2 层只是「上下两截各晃各的」，
    /// 6 层以上边际收益递减而每层都要重绘一整份枝叶（30fps）。
    public static let bandCount: Int = 4

    /// 某个 y 落在第几层（自上而下 0 起）。
    public static func bandIndex(atY y: CGFloat, in size: CGSize) -> Int {
        guard size.height > 0 else { return 0 }
        let t = y / size.height
        return min(max(Int(t * CGFloat(bandCount)), 0), bandCount - 1)
    }

    /// 树冠在风场里的「离地高度」（pt）。
    ///
    /// 树冠在画布顶上、林带在画布底下，隔着大半个画布 —— 取 ≥
    /// `WindField.heightReference`（400）的值即可拿到最高档的高度放大：
    /// 树是全场最高的东西，摆得比草叶大是刻意的（`heightGain` 就是干这个的）。
    public static let windHeight: CGFloat = 900

    /// 第 `band` 层（自上而下 0 起）的位移增益：**顶轻底重**。
    ///
    /// 冠顶是自由端，风来了它摆得最多；裙摆压在树干口、兜住的叶子最多，
    /// 整层只是微微欠身。四档 0.80 → 0.36 是量出来的：再小顶层与底层
    /// 拉不开差距（读作整冠平移），再大顶层会把叶子推出面板。
    public static func bandWindGain(_ band: Int) -> CGFloat {
        let table: [CGFloat] = [0.80, 0.62, 0.48, 0.36]
        return table[min(max(band, 0), table.count - 1)]
    }

    /// 第 `band` 层的旋转增益（度 / pt）。
    ///
    /// 四层**共用一个支点**（树冠根部 = 画框底边中心）：每层转过的角度
    /// 自上而下递减，合起来是一道连续的弯（鱼竿），不是四段各自扭。
    /// 接缝处的错位 = 层高 × 相邻层角差 ≈ 1pt，肉眼读作叶浪，不是裂口。
    public static func bandWindRotationGain(_ band: Int) -> CGFloat {
        let table: [CGFloat] = [0.28, 0.22, 0.17, 0.12]
        return table[min(max(band, 0), table.count - 1)]
    }

    /// 树冠的全部内容按**风层**分好组（叶团 / 碎叶 / 枝干各一份，下标对齐）。
    ///
    /// 为什么要分组：风不能整冠一起摇（用户 2026-10-18 原话：「不要一整个树冠
    /// 一起摇动，要把树冠分层，有层次的飘动」）。每一层是一次独立的
    /// `WindSway`，各自读风场里**不同的 x** —— 相位因此错开，一层先动、
    /// 下一层后到，整棵树是在风里起伏，不是一块板在转。
    public struct CrownBands: Sendable, Equatable {
        public var clusters: [[LeafCluster]]
        public var marks: [[LeafMark]]
        public var limbs: [[LimbSpec]]
    }

    /// 画框尺寸 → 分好层的树冠内容。
    public static func bands(in size: CGSize) -> CrownBands {
        var result = CrownBands(
            clusters: Array(repeating: [], count: bandCount),
            marks: Array(repeating: [], count: bandCount),
            limbs: Array(repeating: [], count: bandCount)
        )
        for cluster in clusters(in: size) {
            result.clusters[bandIndex(atY: cluster.center.y, in: size)].append(cluster)
        }
        for mark in leafMarks(in: size) {
            result.marks[bandIndex(atY: mark.center.y, in: size)].append(mark)
        }
        for limb in limbs(in: size) {
            // 枝归哪一层看**中点**：枝是刚性的，整根跟着一层走；
            // 按起点或终点分会把一根枝劈成两半（两层各画一半，接缝处一道硬折）。
            let midY = (limb.from.y + limb.to.y) * 0.5
            result.limbs[bandIndex(atY: midY, in: size)].append(limb)
        }
        return result
    }

    // MARK: 枝干

    /// 主枝的角度 / 长度（相对半高）/ 宽度（相对画框宽）/ 弯曲量。
    ///
    /// 角度以「正上」为 0、向右为正（度）。九根主枝的角度**不是等分的**：
    /// 等分读起来像扇子，真树的枝是「一主八副」，朝光那侧更舒展。
    ///
    /// 长度是**自然收短**后的值（2026-10-18 第二、三、四轮）：v6 按「枝要冲到冠顶」
    /// 给长度（中央 0.94），结果被 minTopY **齐平钳断** —— 枝顶全停在同一高度、
    /// taper 还停在母枝的粗档，读作「被剪断的枝」（用户连续两轮报障）。
    /// 现在长度按「origin 到 minTopY 的垂直预算」倒算：越陡的枝越短，
    /// 自然 tip 落在下 2/3 内，钳制只是兜底（真被钳到 = 参数改坏了，
    /// 判据 `testLimbTipsStayInTheLowerTwoThirds` 钉着「没有枝贴线」）。
    ///
    /// 第四轮（扇形定稿）：九根以中央为轴铺开 ±78°，**长度中间长、两边短** ——
    /// 用户 2026-10-18：「九根树枝中间的长，两边的短，成一个扇形分布，
    /// 延伸方向各不相同」。中央脊最长（tip 伸得最高，y≈113），向两侧递减，
    /// 最外的 ±78° 最短（tip 沉到 y≈200）—— 一道从中心向外泻开的扇。
    /// 右侧整体比左侧长半档（受控微不对称，纯对称读作圆规画的）。
    /// ⚠️ 别改回「边长边短」：平枝长度大是为了横向撑宽，但那样中央塌、
    /// 整棵枝干读作「两侧张牙舞爪」；扇形要的是中央挑高。
    private static let primaries: [(
        angle: Double, length: CGFloat, width: CGFloat, bend: CGFloat
    )    ] = [
        // 中央脊：最长，正上方微挑（2° 内）—— 它是扇子的轴
        (0, 0.67, 0.104, 0.020),
        // 右半扇：±20 → ±78 长度递减，宽度也递减（外侧枝受光少、体积小）
        (20, 0.64, 0.086, -0.050),
        (40, 0.61, 0.078, 0.046),
        (60, 0.53, 0.072, -0.052),
        (78, 0.45, 0.070, 0.054),
        // 左半扇：同梯度、短半档（微不对称）
        (-20, 0.64, 0.092, 0.045),
        (-40, 0.59, 0.082, -0.048),
        (-60, 0.51, 0.076, -0.055),
        (-78, 0.43, 0.070, -0.058),
    ]

    /// 画框尺寸 → 枝干骨架（9 主枝 → 各三岔 → 再三岔 → 末端三细梢，共 360 根）。
    ///
    /// 根端落在冠心下方 0.75 半高一带（第四轮：0.40 → 0.75，「上下空间
    /// 扩展为现在的两倍」）—— 主枝从树干的低段发出，斜向上穿到树冠中部，
    /// 垂直跨度 ~104pt（原来 ~52pt）。枝根全埋在叶子里，只从叶缝里露头。
    /// 读起来就是「树干长进了树冠里」，而不是「树冠搁在树干上」。
    public static func limbs(in size: CGSize) -> [LimbSpec] {
        guard size.width > 0, size.height > 0 else { return [] }
        let halfH = size.height * 0.50
        let (_, _, center) = crownFrame(in: size)
        let origin = CGPoint(x: center.x, y: center.y + 0.75 * halfH)
        // 枝顶不许越过画框上 1/3 线：露进树冠上半的深色枝尖读作
        // 「被截断的枝」（用户 2026-10-18 报障，截图四处红框全是它）。
        let minTopY = size.height / 3
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
                minTopY: minTopY,
                isTipFork: false,
                into: &result
            )
        }
        return result
    }

    /// 画一根枝（不分叉）：`from` → 二次贝塞尔 → `to`，锥形 taper 到枝尖。
    ///
    /// 枝顶与枝腹都不许越过 `minTopY`：越线即整根**按角度缩短**（等比收 x）
    /// —— 不是砍断，砍断会让 `to` 与 `control` 脱节、接缝一道硬折。
    /// 正常情况下长度参数已按垂直预算收好，这里是兜底：**真被钳到说明
    /// 参数改坏了**（判据 `testLimbTipsStayInTheLowerTwoThirds` 钉「无枝贴线」）。
    private static func limb(
        from origin: CGPoint,
        angle: Double,
        length: CGFloat,
        width: CGFloat,
        bend: CGFloat,
        level: Int,
        seed: UInt64,
        scale: CGFloat,
        minTopY: CGFloat
    ) -> LimbSpec {
        var rng = SeededRandom(seed: seed)
        let radians = angle * Double.pi / 180
        var to = CGPoint(
            x: origin.x + CGFloat(sin(radians)) * length,
            y: origin.y - CGFloat(cos(radians)) * length
        )
        if to.y < minTopY {
            let reach = max(origin.y - minTopY, 0.01)
            let full = max(origin.y - to.y, 0.01)
            to = CGPoint(
                x: origin.x + (to.x - origin.x) * (reach / full),
                y: minTopY
            )
        }
        let mid = CGPoint(x: (origin.x + to.x) / 2, y: (origin.y + to.y) / 2)
        // 控制点沿法线偏一点：法线 = 方向左转 90°
        let normal = CGVector(dx: -cos(radians), dy: -sin(radians))
        let wobble = CGFloat(rng.next(in: 0.6...1.0))
        var control = CGPoint(
            x: mid.x + normal.dx * bend * length * wobble,
            y: mid.y + normal.dy * bend * length * wobble
        )
        // 枝腹也要过线：二次贝塞尔的 y 极值必在 from/control/to 三点里，
        // to 与 control 都压住，整条曲线才整体压住。
        if control.y < minTopY { control.y = minTopY }
        return LimbSpec(
            from: origin,
            control: control,
            to: to,
            rootWidth: width,
            tipWidth: max(width * 0.16, 1.4 * scale),
            // 越细的枝越亮（受光面积 / 体积比更大），描边浓度因此跟着级数走
            tone: 0.24 + 0.16 * Double(level)
        )
    }

    /// 递归长枝：母枝 → 三岔（两分 + 一延续）→ 末端三细梢。
    ///
    /// - `depth`：还能再分几级（2 → 三级枝）。depth 用尽的枝在 tip 前分出
    ///   一簇**末端细梢**（三根，左右 + 中）—— 钝头读作「被剪断的枝」，
    ///   用户 2026-10-18 第二轮报障（截图四个红圈全是枝尖）。
    /// - 子枝从母枝 **38% / 66% / 88%** 处岔出（不是末端）：真树枝是在枝的
    ///   中后段分岔，都从末端分，就成了「一把叉子」。
    /// - 中间那岔是**延续枝**（spread 0，沿母枝方向，留长 0.30…0.40）：
    ///   真树的枝是「一个延伸 + 两侧分枝」，缺了延续枝就读作纯粹的叉。
    /// - **垂直预算**：子枝/细梢的长度先按「锚点到 minTopY 的剩余垂直量」
    ///   折算（越陡的岔口余量越少）—— 不预算就会齐平钳成钝头。
    ///   预算留 5pt 给末端细梢、细梢自己留 1pt 贴线余量。
    /// - `isTipFork`：末端细梢自己，**不再分**（否则无限递归）。
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
        minTopY: CGFloat,
        isTipFork: Bool,
        into result: inout [LimbSpec]
    ) {
        let mother = limb(
            from: origin, angle: angle, length: length, width: width,
            bend: bend, level: level, seed: seed, scale: scale, minTopY: minTopY
        )
        result.append(mother)
        // 末端细梢是叶子里的最后一层：自己不再分（防无限递归）
        guard !isTipFork else { return }
        var rng = SeededRandom(seed: seed &* 1_299_709 &+ 7)
        // 三岔：两侧岔开 + 中间一根**延续枝**（沿母枝方向继续长）——
        // 真树的枝正是「一个延伸 + 两侧分枝」，只两侧分会读作一把叉。
        // 第三轮 2 岔 → 3 岔、末端叉 2 → 3：枝数 75 → 360，撑起参天大树
        // 的密度（用户 2026-10-18：「树枝多画几个，末端有分叉，
        // 现在太少了，不符合参天大树的形象」）。
        let isTerminal = depth == 0
        let anchors: [CGFloat] = isTerminal ? [0.90, 0.90, 0.90] : [0.38, 0.66, 0.88]
        let spreads: [Double] = [-1, 0, 1]
        let spreadRange: ClosedRange<Double> = isTerminal ? 48...68 : 12...20
        let lengthCoef: ClosedRange<Double> = isTerminal ? 0.18...0.26 : 0.22...0.30
        // 延续枝留长些：它是这一级的「脊」，比两侧分枝长 1/4 往上
        let middleCoef: ClosedRange<Double> = 0.30...0.40
        let widthCoef: CGFloat = isTerminal ? 0.34 : 0.52
        for index in 0..<3 {
            let isMiddle = spreads[index] == 0
            let anchor = mother.point(at: anchors[index])
            // spread = 0 时乘 0（延续枝沿母枝方向，不偏）
            let forkAngle = angle + spreads[index] * rng.next(in: spreadRange)
            // 剩余垂直量 → 长度上限：枝尖（末端细梢还占 5pt）不许越线。
            let reserve: CGFloat = isTerminal ? 1 : 5
            let budget = max(anchor.y - minTopY - reserve, 1)
            let vertical = CGFloat(abs(cos(forkAngle * Double.pi / 180)))
            let maxLen = budget / max(vertical, 0.05)
            var len = length * CGFloat(rng.next(in: isMiddle ? middleCoef : lengthCoef))
            // 末端细梢的下限：5pt 以下的「叉」在 380pt 画框里看不见
            if isTerminal { len = max(len, 5) }
            len = min(len, maxLen)
            grow(
                from: anchor,
                // 两侧各岔一次（spread 的符号）：同侧连岔两次就读成梳子了
                // 分岔角 12…20°：角度再大就成了一把「断枝」——
                // 真树枝的岔口是**慢慢分开**的，不是折出去的
                // 末端细梢张角 48…68°：张角小会被垂直预算吃掉
                // （贴线枝尖的剩余垂直量只有几 pt），大张角才活得下来
                angle: forkAngle,
                length: len,
                width: width * widthCoef,
                bend: -bend,
                depth: isTerminal ? 0 : depth - 1,
                level: level + 1,
                seed: seed &* 6_364_136 &+ UInt64(index &+ 1) &* 97,
                scale: scale,
                minTopY: minTopY,
                isTipFork: isTerminal,
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
        // 与 clusters 同一处取帧（`crownFrame`）：四处各算一套，迟早出现
        // 「碎叶撒在冠外」这种只在一处改了的事故。
        let (_, ry, center) = crownFrame(in: size)
        let centreY = center.y
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
                // 镜像团的碎叶：x 偏移跟着翻号（团心已翻面，偏移不翻 →
                // 涂色范围左右差出 ~2pt）。y 不翻 —— 镜像保高度。
                let xOffset = cluster.radii.width * radius * CGFloat(cos(theta))
                    * (cluster.mirrored ? -1 : 1)
                marks.append(LeafMark(
                    center: CGPoint(
                        x: cluster.center.x + xOffset,
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
