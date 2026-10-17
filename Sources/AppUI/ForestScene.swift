import AppKit
import SwiftUI

/// 森林场景的**统一地基**（纯函数，可单测）。
///
/// **它解决的问题**：森林此前是七层各画各的贴片 —— 天空层按容器高定位、树按 1080pt
/// 画布、地面带按 150pt、栖木按「带顶 +22/38」，四条坐标线互不通约；每层自带一套
/// 投影方向、一套「伪随机」、一条硬邦邦的分界线。拼起来就是用户看到的
/// 「一块一块，不是一个整体」（2026-10-17 前端提升专项的根因审计结论）。
///
/// **地基只有一条轴：景深（depth）**。0 = 站在林间地面上（最近），1 = 地平线（最远）。
/// 「这该画多高、多大、多淡、往哪边歪」全部从 depth 推出来，各层不再各自拍数：
///
/// - `ForestSceneGeometry`：唯一的 groundLine / 地平线 / 草坡表面曲线，
///   以及 depth → y / scale / opacity / blur / haze 的映射；
/// - `ForestAerialPerspective`：大气透视 —— 越远越灰、越亮、越融进天空色
///   （把分离图层「缝」成一体的核心技法）；
/// - `ForestLighting`：全局唯一光源方向（太阳钉在右上，所有影子同一个朝向）；
/// - `WindField`：全局风场 `sin(相位 − x·k)` —— 相位按 x 延迟，
///   跨层同相位就是同方向同幅度，风从此是**一个空间函数**而不是每层各抖各的；
/// - `ForestNoise`：fBm 噪声（树冠轮廓 / 山脊线用它，替掉三份自造 sin 伪随机）。
///
/// ⚠️ 纪律：本文件**只有纯函数** —— 没有 View、动画、计时器。所以它不会被 `View` 的
/// `@MainActor` 连坐（测试在非隔离上下文直接调），也不会给
/// `MotionTokenWiringTests` 的内联动画天花板添数。
///
/// ⚠️ 钉死的几何一根手指都没碰：`TreeCanvas.canvasHeight` / `learnerY` /
/// `TreeViewport` 锚点算式不读这里（`TreeScrollViewTests` 钉着），本文件只**供**
/// 插画层取用；P0-C 起地面带与树冠改读这里，取值与现行值逐一相同（见各常量的注释）。
// MARK: - 景深轴与地面几何

/// 森林的**唯一坐标源**：地面在哪、地平线在哪、草坡表面怎么弯。
///
/// 两个坐标空间共用同一套常量，所以它们永远对得上：
/// - **画布空间**（可滚动的树）：depth 0 = 树根线 `canvasHeight − trunkGroundHeight`；
/// - **地面带空间**（钉在视口底部的 150pt）：depth 0 = 草坡表面线 `bandHeight − slopeInset`。
///
/// 滚动到底时画布底边与地面带底边重合，此时画布的树根线正好落在地面带里
/// （`groundBandHeight − trunkGroundHeight` = 30pt 处）—— 树干扎进草坡，两个空间就此缝合。
public enum ForestSceneGeometry {

    // MARK: 常量（全部取现行值；P0-C 起各使用点改为同源，像素不变）

    /// 树干扎根带的高度（= `TreeCanvas.groundHeight` 现值 120）。
    public static let trunkGroundHeight: CGFloat = 120
    /// 林间地面带的高度（= `TreeViewport.groundBandHeight` 现值 150）。
    public static let groundBandHeight: CGFloat = 150
    /// 草坡表面线离地面带底边的距离（现值：地面带内 `height − 34`）。
    public static let slopeInset: CGFloat = 34
    /// 草坡（`HillCap`）的高度（现值 96）。
    public static let hillCapHeight: CGFloat = 96
    /// 草坡鼓包控制点高出坡顶的量（现值 `HillCap` 里的 `minY − 12`）。
    public static let hillCapBulge: CGFloat = 12
    /// 地平线相对树根线的垂直距离（画布坐标）。
    ///
    /// 150 = 天空层山丘的高度：远处的山就该长在地平线上，而不是各层各挂一截。
    public static let horizonSpan: CGFloat = 150

    // MARK: 建议景深（标准层的共同词汇，免去各层拍数）

    /// 草坡（最近的前景）。
    public static let nearHillDepth: CGFloat = 0.05
    /// 大树（根在景深 0，但树身高过地平线 —— 大气透视按它**站的位置**取，不按屏幕高度）。
    public static let treeDepth: CGFloat = 0.18
    /// 中景山丘。
    public static let midHillDepth: CGFloat = 0.40
    /// 远景山丘（贴在地平线附近）。
    public static let farHillDepth: CGFloat = 0.68

    // MARK: 画布空间（树）

    /// 树根线（画布坐标）—— **全森林唯一的地面定义**。
    ///
    /// 关卡节点、学员锚点、年轮徽记全都以这条线为基准；改这里之前先看
    /// `TreeScrollViewTests` 钉住什么。
    public static func groundLine(canvasHeight: CGFloat) -> CGFloat {
        canvasHeight - trunkGroundHeight
    }

    /// 地平线（画布坐标）：远景山丘与天空相接处。
    public static func horizonY(canvasHeight: CGFloat) -> CGFloat {
        groundLine(canvasHeight: canvasHeight) - horizonSpan
    }

    /// 站在 `depth` 处的**地面高度**（画布坐标 y，越小越高）。
    ///
    /// 只给「站在地面上的东西」用（山丘、草丛、小动物、植株）：
    /// 它们的 depth 由**落点**决定，不是屏幕高度 —— 一棵高树的树冠虽在屏幕高处，
    /// 但它站在 depth 0 上，大气透视按 `treeDepth` 取。
    public static func standingY(forDepth depth: CGFloat, canvasHeight: CGFloat) -> CGFloat {
        groundLine(canvasHeight: canvasHeight) - horizonSpan * clamp01(depth)
    }

    /// 反查：画布上这条线是哪个景深（0 = 树根线，1 = 地平线；越界夹住）。
    public static func depth(forStandingY y: CGFloat, canvasHeight: CGFloat) -> CGFloat {
        clamp01((groundLine(canvasHeight: canvasHeight) - y) / horizonSpan)
    }

    // MARK: 地面带空间（钉在视口底部的那 150pt）

    /// 草坡表面线（地面带局部坐标）—— 带内一切「站在坡上」的东西的基准。
    public static func slopeLine(bandHeight: CGFloat = groundBandHeight) -> CGFloat {
        bandHeight - slopeInset
    }

    /// 草坡顶沿（地面带局部坐标）：`HillCap` 那条**曾经硬邦邦的直边**的位置。
    public static func hillCapTop(bandHeight: CGFloat = groundBandHeight) -> CGFloat {
        bandHeight - hillCapHeight
    }

    /// 带内 `depth` 处的地面高度（depth 0 = 草坡表面线，1 = 带顶 = 天际）。
    public static func bandY(forDepth depth: CGFloat, bandHeight: CGFloat = groundBandHeight) -> CGFloat {
        slopeLine(bandHeight: bandHeight) * (1 - clamp01(depth))
    }

    /// 反查：带内这条线是哪个景深。
    public static func bandDepth(forY y: CGFloat, bandHeight: CGFloat = groundBandHeight) -> CGFloat {
        clamp01((slopeLine(bandHeight: bandHeight) - y) / max(slopeLine(bandHeight: bandHeight), 1))
    }

    /// 草坡表面在 `x` 处的高度（地面带局部坐标）—— 与 `HillCap` 的二次曲线**逐点相同**。
    ///
    /// 这是「一块一块」的直接解药：草叶、灌木、小花、小动物此前都站在一条**直线**
    /// （`height − 34`）上，而坡本身是个鼓包 —— 直边与弯坡每次都对不上，边缘处物件
    /// 于是浮在坡上方 30 多pt。有了这条曲线，谁站在坡上就问坡自己要高度。
    public static func hillSurfaceY(
        x: CGFloat, bandWidth: CGFloat, bandHeight: CGFloat = groundBandHeight
    ) -> CGFloat {
        guard bandWidth > 0 else { return slopeLine(bandHeight: bandHeight) }
        let t = clamp01(x / bandWidth)
        let capTop = hillCapTop(bandHeight: bandHeight)
        // 与 HillCap 的 path 一致：(0, 底) → 控制点 (mid, capTop − bulge) → (W, 底)
        let u = 1 - t
        return capTop
            + hillCapHeight * (u * u + t * t)
            - 2 * hillCapBulge * t * u
    }

    // MARK: depth → 视觉参数

    /// 一层东西在某个景深上该长什么样（缩放 / 透明度 / 模糊 / 融天比例）。
    ///
    /// 收成一个值而不是四个函数：调用点只读一次，四参数就不可能各拍各的。
    public static func style(forDepth depth: CGFloat) -> ForestDepthStyle {
        let d = clamp01(depth)
        return ForestDepthStyle(
            scale: 1 - 0.22 * d,
            opacity: 1 - 0.30 * d,
            blur: 2.4 * d,
            haze: ForestAerialPerspective.hazeAmount(depth: d)
        )
    }

    /// 夹到 0...1（景深轴的有界性：越过地平线没有更远，穿过地面没有更近）。
    public static func clamp01(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }
}

/// 坡面函数：`x`（宿主坐标系）→ 该处的坡面高度 y。
///
/// 为什么是函数而不是一根直线：草坡是**鼓包**（中心高、两角低），站在坡上的东西
/// （草叶 / 灌木 / 小花 / 小动物 / 对话植物）必须各问各的高度 —— 从前它们共用一条
/// 直线 `带高 − slopeInset`，于是中心埋进坡里 20pt、两角浮空 34pt（「一块一块」的
/// 根因之一）。`ForestSceneGeometry.hillSurfaceY` 是它的标准实现。
///
/// `@Sendable`：调用点（视图 body）是主 actor 隔离的，而活动编排要走 `async let`
/// 的子任务 —— 闭包只捕 CGFloat 与非隔离静态函数，标了它才过得了 Swift 6 的隔离检查。
public typealias ForestGroundSurface = @Sendable (CGFloat) -> CGFloat

/// `ForestSceneGeometry.style(forDepth:)` 的返回值：一层在某个景深上的完整视觉规格。
public struct ForestDepthStyle: Sendable, Equatable {

    /// 缩放（1 = 近处原大，0.78 = 地平线处）。
    public var scale: CGFloat
    /// 不透明度（1 → 0.70）：远景淡一层，后面还有山和天空。
    public var opacity: CGFloat
    /// 模糊半径 pt（0 → 2.4）：远景轻微失焦，替掉硬边。
    public var blur: CGFloat
    /// 融天比例（0.05 → 0.52）：见 `ForestAerialPerspective`。
    public var haze: CGFloat

    public init(scale: CGFloat, opacity: CGFloat, blur: CGFloat, haze: CGFloat) {
        self.scale = scale
        self.opacity = opacity
        self.blur = blur
        self.haze = haze
    }
}

// MARK: - 大气透视

/// 大气透视：**越远的东西越灰、越亮、越像天空色**。
///
/// 这是把七层贴片缝成一整个场景的核心技法 —— 层与层之间不再靠「颜色恰好接近」
/// 蒙混过关，而是按景深连续地朝霾色收敛：近处保留本色与饱和，远处自动融进天空。
/// 用户看到的「衔接不自然」有相当一部分是各层饱和度/明度各自为政造成的。
public enum ForestAerialPerspective {

    /// 近处也留的一点融天比例。
    ///
    /// 不是 0：完全 0 会让最近的层与背景「纸片贴纸」地分开，留 5% 让空气感从头就有。
    public static let nearHaze: CGFloat = 0.05
    /// 地平线处的融天比例（再高，山就真的看不见了）。
    public static let farHaze: CGFloat = 0.52
    /// 饱和度衰减系数：地平线处降到 55%（远处发灰）。
    public static let saturationFalloff: Double = 0.45
    /// 明度提升系数：地平线处提亮 10%（远景被天空照亮）。
    public static let brightnessGain: Double = 0.10

    /// 该深度上「被空气吃掉」的比例。
    public static func hazeAmount(depth: CGFloat) -> CGFloat {
        let d = ForestSceneGeometry.clamp01(depth)
        return nearHaze + (farHaze - nearHaze) * d
    }

    /// 该深度上的饱和度倍率（1 = 本色）。
    public static func saturation(depth: CGFloat) -> Double {
        1 - saturationFalloff * Double(ForestSceneGeometry.clamp01(depth))
    }

    /// 该深度上的明度倍率（1 = 本色）。
    public static func brightness(depth: CGFloat) -> Double {
        1 + brightnessGain * Double(ForestSceneGeometry.clamp01(depth))
    }

    /// 把颜色调成「在 `depth` 这个距离上看到的颜色」。
    ///
    /// - Parameters:
    ///   - color: 图层本色（主题令牌）。
    ///   - depth: 该层站的位置的景深。
    ///   - haze: 霾色 = 当时天空在地平线附近的颜色（白天 `theme.aerialHaze`）。
    public static func adjust(_ color: Color, depth: CGFloat, haze: Color) -> Color {
        let d = ForestSceneGeometry.clamp01(depth)
        guard d > 0 else { return color }
        guard let base = NSColor(color).usingColorSpace(.sRGB),
              let hazeNS = NSColor(haze).usingColorSpace(.sRGB) else {
            return color
        }
        let amount = Double(hazeAmount(depth: d))
        let sat = saturation(depth: d)
        let bright = brightness(depth: d)
        let channels = [
            Double(base.redComponent),
            Double(base.greenComponent),
            Double(base.blueComponent),
        ]
        let gray = 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
        let hazeChannels = [
            Double(hazeNS.redComponent),
            Double(hazeNS.greenComponent),
            Double(hazeNS.blueComponent),
        ]
        var mixed: [Double] = []
        mixed.reserveCapacity(3)
        for index in 0..<3 {
            // 先去饱和（发灰），再提亮（被天空照亮），最后按比例融向霾色
            var value = gray + (channels[index] - gray) * sat
            value = min(max(value * bright, 0), 1)
            value = value + (hazeChannels[index] - value) * amount
            mixed.append(value)
        }
        return Color(
            .sRGB,
            red: mixed[0],
            green: mixed[1],
            blue: mixed[2],
            opacity: Double(base.alphaComponent)
        )
    }
}

public extension ForestTheme {

    /// 地平线附近的霾色（大气透视的收敛目标）。
    ///
    /// 取天空渐变的**末端**（贴地平线那一档）：远景就该融进它，而不是融进天顶的深蓝。
    var aerialHaze: Color {
        sky.last ?? sky.first ?? .clear
    }
}

// MARK: - 明暗档（插画层的「墨」）

/// 往主题的 `shadow` 令牌里压暗一档 —— 背光叶簇、叶底暗部、树皮皱纹用它。
///
/// 为什么不写死 `Color.black`：插画层的一切颜色都必须过主题（日夜 / 季节），
/// 硬编码的黑在夜档会脏成一团；`theme.shadow` 本身就是「当时的空气色」
/// （白天深绿 `0x2E4A32`、夜里近黑），拿它当墨，压出来的一档自然跟着主题走。
/// 与 `ForestAerialPerspective.adjust`（往亮里融）是一对：一个提亮、一个压暗。
public enum ForestTone {

    /// 把 `color` 往 `ink` 里混 `amount`（0…1；`ink` 自身的不透明度会先乘上来）。
    public static func deepen(_ color: Color, amount: Double, ink: Color) -> Color {
        let a = min(max(amount, 0), 1)
        guard a > 0,
              let base = NSColor(color).usingColorSpace(.sRGB),
              let inkNS = NSColor(ink).usingColorSpace(.sRGB) else {
            return color
        }
        let mix = a * Double(inkNS.alphaComponent)
        func channel(_ index: Int) -> Double {
            let b = [base.redComponent, base.greenComponent, base.blueComponent][index]
            let i = [inkNS.redComponent, inkNS.greenComponent, inkNS.blueComponent][index]
            return min(max(b * (1 - mix) + i * mix, 0), 1)
        }
        return Color(
            .sRGB,
            red: channel(0), green: channel(1), blue: channel(2),
            opacity: Double(base.alphaComponent)
        )
    }
}

// MARK: - 全局光照

/// 全局唯一的光源：太阳钉在**右上**（`ForestSky` 的天体就在 `.topTrailing`）。
///
/// 此前每个影子各写各的：植株 `(0, 1.6)`、单词卡 `(0, 2)`、动物另一套 ——
/// 影子方向不统一，画面就像几盏灯各自照明。现在所有投影都从这一支方向推：
/// 近处长一点、实一点，远处短一点、淡一点（透视）。
public enum ForestLighting {

    /// 光源方向的比例分量（无需单位化：x 负 = 影子朝左，y 正 = 影子朝下）。
    public static let light = CGVector(dx: -0.36, dy: 0.93)
    /// 近处（depth 0）投影的基础长度 pt。
    public static let nearShadowLength: CGFloat = 3.4
    /// 投影长度随景深的衰减（远处影子短）。
    public static let depthFalloff: CGFloat = 0.55

    /// 该景深上的投影长度。
    public static func shadowLength(forDepth depth: CGFloat) -> CGFloat {
        nearShadowLength * (1 - depthFalloff * ForestSceneGeometry.clamp01(depth))
    }

    /// 该景深上的投影偏移（`.shadow(x:y:)` 直接用）。
    public static func shadowOffset(forDepth depth: CGFloat) -> CGSize {
        let length = shadowLength(forDepth: depth)
        return CGSize(width: light.dx * length, height: light.dy * length)
    }

    /// 该景深上投影的浓度倍率（1 → 0.60）：远处影子淡。
    public static func shadowStrength(forDepth depth: CGFloat) -> Double {
        1 - 0.40 * Double(ForestSceneGeometry.clamp01(depth))
    }
}

// MARK: - 全局风场

/// 全局风场：一个**空间函数** `sin(相位 − x·k)`，不是每层各抖各的。
///
/// 三个让它「缝合」得起来的性质：
/// 1. **相位按 x 延迟** —— 同一时刻，风从画面一侧推向另一侧，跨层看到的是同一阵风；
/// 2. **高处振幅大** —— 树冠比草叶晃得厉害（`heightFactor`），但两者**同相位**；
/// 3. **阵风呼吸** —— `gust` 让整体风力有大小呼吸，不是恒速抖动。
///
/// 用法：调用方持有一个「相位」（随时间推进），每帧问 `offset(x:phase:height:)`。
/// 纯函数、无状态 —— 层与层之间因此不可能对不上。
public enum WindField {

    /// 空间波数：每 pt 的相位延迟（弧度）。0.010 → 波长 ≈ 628pt，
    /// 一整块面板恰好一个半波 —— 看得见风向，又不会一面坡三种风。
    public static let waveNumber: Double = 0.010
    /// 地面处（height = 0）的基准振幅 pt。
    public static let baseAmplitude: Double = 3.2
    /// 高处放大：离地 `heightReference` 处振幅再涨 90%。
    public static let heightGain: Double = 0.9
    /// 「离地多高算高」的参照高度 pt。
    public static let heightReference: CGFloat = 400
    /// 风速（弧度/秒）：一个完整摆动约 7 秒 —— 风不是抽搐。
    public static let speed: Double = 0.9
    /// 阵风波动的频率（弧度/秒）。
    public static let gustWave: Double = 0.31

    /// 时间 → 相位。调用方每帧传入经过的秒数即可。
    public static func phase(elapsed: Double) -> Double {
        elapsed * speed
    }

    /// 高度放大系数（1 → 1.9，钳在参照高度）。
    public static func heightFactor(_ height: CGFloat) -> Double {
        1 + heightGain * min(max(Double(height) / Double(heightReference), 0), 1)
    }

    /// 阵风倍率（0.5 → 1.0）：风力本身的呼吸。
    ///
    /// ⚠️ 它是**全局标量**（只跟相位/时间有关，与 x 无关）—— 所以它刻意不混进
    /// `wave(x:phase:)` 的空间恒等式里：同一帧里所有层共享同一个阵风。
    public static func gust(_ phase: Double) -> Double {
        0.75 + 0.25 * sin(phase * gustWave)
    }

    /// 风场的**空间波形**（-1…1）。
    ///
    /// ⚠️ **跨层一致性的判据就是这条恒等式**：
    /// `wave(x: a, phase: p) == wave(x: b, phase: p + (b−a)·waveNumber)`
    /// —— 波沿 +x 方向走，任何两层只要落在同一个波位上，看到的风一模一样。
    /// （阵风是全局标量，不参与这条空间恒等式。）
    public static func wave(x: CGFloat, phase: Double) -> Double {
        sin(phase - Double(x) * waveNumber)
    }

    /// `x` 处、`height` 高的东西，在 `phase` 相位的横向位移（pt）。
    public static func offset(x: CGFloat, phase: Double, height: CGFloat = 0) -> CGFloat {
        baseAmplitude * heightFactor(height) * gust(phase) * wave(x: x, phase: phase)
    }
}

// MARK: - fBm 噪声

/// fBm 值噪声：树冠轮廓、山脊线、一切「有机边缘」的原料。
///
/// 替掉三份自造 sin 伪随机（`ForestSky`、`TreeCanvas.pr`、`GladeFloor.pseudo`）：
/// 那三份都是单频 sin，出来的轮廓一眼「规则波形」；fBm 多频叠加才像自然边缘。
/// 确定性（同输入同输出）是硬要求 —— 重绘不许换一张轮廓。
public enum ForestNoise {

    /// 2D 值噪声，[0, 1]。
    public static func value(_ x: Double, _ y: Double, seed: UInt64 = 0) -> Double {
        let xi = Int(x.rounded(.down))
        let yi = Int(y.rounded(.down))
        let xf = x - Double(xi)
        let yf = y - Double(yi)
        let u = smootherstep(xf)
        let v = smootherstep(yf)
        let a = lattice(xi, yi, seed: seed)
        let b = lattice(xi + 1, yi, seed: seed)
        let c = lattice(xi, yi + 1, seed: seed)
        let d = lattice(xi + 1, yi + 1, seed: seed)
        // 双线性 + 平滑权重：连续（邻近输入 → 邻近输出），值域仍是 [0,1] 的凸组合
        return a + (b - a) * u + (c - a) * v + (a - b - c + d) * u * v
    }

    /// 分形布朗运动（2D，[0, 1]）：`octaves` 个八度叠加，频率 ×2、幅度 ×0.5。
    public static func fbm(
        _ x: Double, _ y: Double, octaves: Int = 4, seed: UInt64 = 0
    ) -> Double {
        var sum = 0.0
        var amplitude = 0.5
        var frequency = 1.0
        var norm = 0.0
        let count = max(1, octaves)
        for _ in 0..<count {
            sum += amplitude * value(x * frequency, y * frequency, seed: seed)
            norm += amplitude
            frequency *= 2
            amplitude *= 0.5
        }
        return sum / norm
    }

    /// 山脊噪声（1D，[0, 1]）：每八度做 `1 − |2v−1|` 的脊化变换 ——
    /// 出来的轮廓有**锋利的 crest** 与平缓的坡，适合山脊线与树冠的团块感。
    public static func ridge(_ x: Double, octaves: Int = 3, seed: UInt64 = 0) -> Double {
        var sum = 0.0
        var amplitude = 0.5
        var frequency = 1.0
        var norm = 0.0
        let count = max(1, octaves)
        for index in 0..<count {
            let n = value(x * frequency, Double(index) * 7.31 + 1.7, seed: seed)
            sum += amplitude * (1 - abs(2 * n - 1))
            norm += amplitude
            frequency *= 2
            amplitude *= 0.5
        }
        return sum / norm
    }

    /// 格点哈希 → [0, 1]。整数格点进、确定值出；相邻格点不相关。
    private static func lattice(_ xi: Int, _ yi: Int, seed: UInt64) -> Double {
        var h: UInt64 = seed &+ 0x9E3779B97F4A7C15
        h ^= UInt64(bitPattern: Int64(xi)) &* 0xBF58476D1CE4E5B9
        h ^= UInt64(bitPattern: Int64(yi)) &* 0x94D049BB133111EB
        h = (h ^ (h >> 29)) &* 0xD6E8FEB86659FD93
        h ^= h >> 32
        return Double(h >> 11) * (1.0 / Double(1 << 53))
    }

    /// smootherstep（一阶与二阶导都在端点为 0）—— 噪声连续且没有折角。
    private static func smootherstep(_ t: Double) -> Double {
        let c = min(max(t, 0), 1)
        return c * c * c * (c * (c * 6 - 15) + 10)
    }
}
