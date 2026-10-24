import SwiftUI

// MARK: - 春：天空里的风筝（#620）

/// 风筝造型（三种）：沙燕（北京风筝）/ 三角（经典菱形）/ 金鱼。
///
/// 三种而不是一种：一排一模一样的菱形 = 贴图，用户一眼就看出是「三个同样的
/// 形状复制粘贴」。造型各不同、站位错落、节奏各异，才读成「三只各自在放的风筝」。
enum KiteShape: String, CaseIterable, Sendable {

    case swallow
    case diamond
    case goldfish

    /// 画框的**高宽比**（`ForestKite.size` 是宽度）。
    var aspect: CGFloat {
        switch self {
        case .swallow: 1.18
        case .diamond: 1.34
        case .goldfish: 1.22
        }
    }

    var displayName: String {
        switch self {
        case .swallow: "沙燕"
        case .diamond: "三角"
        case .goldfish: "金鱼"
        }
    }
}

/// 一只风筝的**静态属性**（造型 / 站位 / 节奏）：全部由种子定死，重绘不许换一批。
///
/// 位置与节奏分开定（与 `ForestMote` 同一条纪律）：站位决定它飘在哪，
/// 节奏决定它怎么摇。同种子 → 同结果，截图回归才有意义。
struct ForestKite: Identifiable, Equatable, Sendable {

    let id: Int
    let shape: KiteShape
    /// 横向位置（面板宽的比例，0…1）。
    let lane: Double
    /// 高度（面板高的比例，自上而下；0 = 顶）。
    let altitude: Double
    /// 画框宽度（pt）。
    let size: Double
    /// 基准倾角（度）：风筝不是吊着的，是被风托着斜在那儿。
    let tilt: Double
    /// 摆动幅度（度）。
    let swing: Double
    /// 上下浮沉幅度（pt）。
    let bob: Double
    /// 摆动周期（秒）—— 慢，是「飘」不是「抖」。
    let period: Double
    /// 初相（0…1）：三只不同相，才不会像挂在同一个钩子上一齐摇。
    let phase: Double
}

/// 风筝布局（纯函数 / 确定性，可单测）：站位、摆角、浮沉、尾飘带。
enum KiteLayout {

    /// 春天天空里的三只风筝。
    static let springSky: [ForestKite] = make(seed: 0x4B49_5445, count: 3)   // "KITE"

    /// 尾飘带的节数（每只一样：三节够读到「一条尾巴」，再多就成了串珠）。
    static let tailNodes = 3

    /// 风位移增益：风筝比草摆得多（`WindField` 已按离地高度放大，这里再乘一档 ——
    /// 它是**悬空的**，下面没有任何东西拽着它）。
    static let windGain: CGFloat = 1.7

    /// 「上三分之一」判定带（面板高的比例，自上而下）。
    ///
    /// 0.36 > 1/3：留一点余量 —— 第三只稍低一点仍是「上方三分之一」，
    /// 但绝不能飘到画面中线以下：那里是树冠与关卡节点，风筝压上去就是挡住内容的贴纸。
    static let altitudeBand: ClosedRange<Double> = 0.09...0.36

    /// 造一批风筝（纯函数：同种子永远同一批 —— 重绘换一批 = 用户在看瞬移）。
    ///
    /// - 站位按 index **分区**再在区内抖：三只既不会挤成一堆，也不会排排站
    ///   （`pitch` 均分 + ±半区的抖动，出来的间距在 0.09…0.42 面板宽之间）；
    /// - `altitude` 生成后夹进 `altitudeBand`：种子只负责「哪只高一点」，
    ///   最终落点由这条带子说了算（用户要的就是「小动物上方三分之一处」）。
    static func make(seed: UInt64, count: Int) -> [ForestKite] {
        var rng = SeededRandom(seed: seed)
        let shapes = KiteShape.allCases
        let total = max(count, 0)
        return (0..<total).map { index in
            let pitch = 1.0 / Double(max(total, 1))
            let lane = (Double(index) + 0.5 + (rng.next() - 0.5) * 0.62) * pitch
            let raw = rng.next(in: 0.12...0.31)
            return ForestKite(
                id: index,
                shape: shapes[index % shapes.count],
                lane: min(max(lane, 0.10), 0.90),
                altitude: min(max(raw, altitudeBand.lowerBound), altitudeBand.upperBound),
                size: rng.next(in: 26...40),
                tilt: rng.next(in: -15...15),
                swing: rng.next(in: 6...12),
                bob: rng.next(in: 3...7),
                period: rng.next(in: 3.2...5.6),
                phase: rng.next()
            )
        }
    }

    /// 冻结档的时间（秒）：`reduceMotion` / 静态出图时停在这儿。
    ///
    /// ⚠️ 不是 0：0 是摆动的一端，三只会**一律歪到同一边**（看着像被同一阵
    /// 怪风定住）。停在中段，出来的是「正被风托着」的姿态 —— 静照里的风筝
    /// 就该是这个样子。关动效不许做成关内容（`ForestMotes` 同一条纪律）。
    static func frozenElapsed(_ kite: ForestKite) -> Double {
        kite.period * 0.5
    }

    /// 摆角（度）：基准倾角 + 正弦摆动。
    static func tiltDegrees(_ kite: ForestKite, elapsed: Double) -> Double {
        kite.tilt + kite.swing * Self.swing(kite, elapsed: elapsed)
    }

    /// 浮沉（pt）：与摆动**同周期、落后四分之一**。
    ///
    /// 落后 π/2 而不是同相：摆到最左时正在往上升 —— 出来的是「被托着一起一伏」；
    /// 同相的话风筝只在原地左右摇，像挂在钩子上。
    static func bobOffset(_ kite: ForestKite, elapsed: Double) -> CGFloat {
        let t = Self.phase(kite, elapsed: elapsed) + .pi / 2
        return CGFloat(kite.bob * sin(t))
    }

    /// 锚点（面板坐标）：站位 + 浮沉。
    static func anchor(
        _ kite: ForestKite, width: CGFloat, height: CGFloat, elapsed: Double
    ) -> CGPoint {
        CGPoint(
            x: width * kite.lane,
            y: height * kite.altitude + bobOffset(kite, elapsed: elapsed)
        )
    }

    /// 尾飘带第 `index` 节的偏移（pt，相对风筝底部中心）。
    ///
    /// ⚠️ 相位**逐节延迟**：整条尾巴一个相位 = 一块硬板跟着风筝转；
    /// 越靠后的结摆得越迟，那才是「尾巴被风带着走」。
    /// 横向偏移逐节**累积**（第 n 节的位移含前面所有节的摆动），尾巴因此是软的。
    static func tailOffset(_ kite: ForestKite, elapsed: Double, index: Int) -> CGSize {
        var x = 0.0
        for k in 0...max(index, 0) {
            x += sin(Self.phase(kite, elapsed: elapsed) - Double(k) * 0.5) * kite.size * 0.13
        }
        return CGSize(width: x, height: kite.size * 0.26 * Double(index + 1))
    }

    /// 摆动相位（弧度）：周期 + 初相。
    private static func phase(_ kite: ForestKite, elapsed: Double) -> Double {
        elapsed / kite.period * 2 * .pi + kite.phase * 2 * .pi
    }

    /// 摆动的正弦值（-1…1）。
    private static func swing(_ kite: ForestKite, elapsed: Double) -> Double {
        sin(Self.phase(kite, elapsed: elapsed))
    }
}

/// 春风里的三只风筝：飘在小动物上方三分之一处，随风摆动。
///
/// 三条既有约定（与 `DriftingLeaves` / `ForestMotes` 同一套）：
/// 1. **位置由时间算出来**（`KiteLayout` 的纯函数），不是 `withAnimation` 推 ——
///    重绘时相位不会跳，叶子/风筝不会集体瞬移；
/// 2. **风读全局风钟**（`@Environment(\.forestWind)`）：风筝与地上的草、
///    飘的落叶处在**同一阵风**里，不是自己另吹一股。未注入风钟（离屏夹具、
///    旧渲染测试）位移恒 0，一个像素都不变；
/// 3. **`reduceMotion` 下冻结在中段**（`frozenElapsed`），不是整层消失。
struct ForestKites: View {

    let theme: ForestTheme
    /// 静态档（离屏出图 / 氛围隐藏）：冻结在中段姿态，不推进时间。
    var still: Bool = false

    @Environment(\.appMotion) private var motion
    @Environment(\.forestWind) private var wind

    var body: some View {
        // ⚠️ 档位判在 body 里（不在 onAppear）：切档不重新 appear，
        // 判在 onAppear 里的话关掉动效后风筝还在摇（既有教训）。
        let frozen = still || motion.reduceMotion
        return GeometryReader { proxy in
            AmbientTicker(paused: frozen) { now in
                let elapsed = frozen ? 0 : now
                ZStack(alignment: .topLeading) {
                    ForEach(KiteLayout.springSky) { kite in
                        flying(kite, width: proxy.size.width, height: proxy.size.height,
                               elapsed: elapsed, frozen: frozen)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
        .allowsHitTesting(false)
        // 纯氛围：读屏不该念「一只风筝」。
        .accessibilityHidden(true)
    }

    private func flying(
        _ kite: ForestKite, width: CGFloat, height: CGFloat, elapsed: Double, frozen: Bool
    ) -> some View {
        let now = frozen ? KiteLayout.frozenElapsed(kite) : elapsed
        let anchor = KiteLayout.anchor(kite, width: width, height: height, elapsed: now)
        let box = CGSize(width: kite.size, height: kite.size * kite.shape.aspect)
        // 风场要的是**场景横坐标**与**离地高度**（与 `MoteParticle` 同一条口径）：
        // 空中的风筝因此落在与草、落叶同一条行波上，风来是一起偏的。
        let push = (wind?.offset(x: anchor.x, height: max(0, height - anchor.y)) ?? 0)
            * KiteLayout.windGain
        return ZStack(alignment: .top) {
            // 提线：往下一小段渐隐。
            // ⚠️ 不画到地面：那 150pt 是草坡与小动物的地盘，一根线横穿过去
            // 会把「三只在放风筝」画成「三根线插在草地里」。
            KiteString()
                .stroke(theme.kiteString.opacity(0.5), style: StrokeStyle(lineWidth: 0.9))
                .frame(width: box.width * 0.55, height: box.height * 1.05)
                .offset(y: box.height * 0.90)

            // 尾飘带：越往下越淡（尾巴尖化进风里）
            ForEach(0..<KiteLayout.tailNodes, id: \.self) { index in
                let step = KiteLayout.tailOffset(kite, elapsed: now, index: index)
                KiteTailBow()
                    .fill(theme.kiteString.opacity(0.72 - Double(index) * 0.18))
                    .frame(width: kite.size * 0.24, height: kite.size * 0.14)
                    .offset(x: step.width, y: box.height * 0.96 + step.height)
            }

            KiteBody(shape: kite.shape, theme: theme)
                .frame(width: box.width, height: box.height)
        }
        .frame(width: box.width, height: box.height)
        .rotationEffect(.degrees(KiteLayout.tiltDegrees(kite, elapsed: now)))
        .position(x: anchor.x + push, y: anchor.y + box.height * 0.45)
    }
}

// MARK: - 风筝本体

/// 风筝本体：三种造型各一套画法（unit 画框 0…1，靠 frame 缩放）。
private struct KiteBody: View {

    let shape: KiteShape
    let theme: ForestTheme

    var body: some View {
        switch shape {
        case .swallow:
            SwallowKite().fill(theme.kiteSwallow)
                .overlay(SwallowMarks().fill(theme.kiteAccent.opacity(0.85)))
        case .diamond:
            DiamondKite().fill(theme.kiteDiamond)
                .overlay(DiamondMarks().fill(theme.kiteAccent.opacity(0.9)))
        case .goldfish:
            GoldfishKite().fill(theme.kiteGoldfish)
                .overlay(GoldfishMarks().fill(theme.kiteAccent.opacity(0.9)))
        }
    }
}

/// 沙燕：头 + 一对上扬的剪刀翼 + 燕尾分叉（`aspect` 1.18）。
private struct SwallowKite: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let cx = rect.midX
        var path = Path()
        // 身体：细长竖椭圆
        path.addEllipse(in: CGRect(x: cx - w * 0.11, y: rect.minY + h * 0.04,
                                   width: w * 0.22, height: h * 0.56))
        // 左翼：从肩部向外上方展开，回到身侧（燕子翅膀的弧）
        path.move(to: CGPoint(x: cx - w * 0.06, y: rect.minY + h * 0.20))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.08),
                          control: CGPoint(x: cx - w * 0.30, y: rect.minY + h * 0.13))
        path.addQuadCurve(to: CGPoint(x: cx - w * 0.04, y: rect.minY + h * 0.38),
                          control: CGPoint(x: cx - w * 0.26, y: rect.minY + h * 0.28))
        path.closeSubpath()
        // 右翼（镜像）
        path.move(to: CGPoint(x: cx + w * 0.06, y: rect.minY + h * 0.20))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.08),
                          control: CGPoint(x: cx + w * 0.30, y: rect.minY + h * 0.13))
        path.addQuadCurve(to: CGPoint(x: cx + w * 0.04, y: rect.minY + h * 0.38),
                          control: CGPoint(x: cx + w * 0.26, y: rect.minY + h * 0.28))
        path.closeSubpath()
        // 燕尾：中间一道 V 形缺口（分叉是沙燕的辨识点）
        path.move(to: CGPoint(x: cx, y: rect.minY + h * 0.54))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.14, y: rect.maxY))
        path.addLine(to: CGPoint(x: cx, y: rect.minY + h * 0.78))
        path.addLine(to: CGPoint(x: rect.maxX - w * 0.14, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// 沙燕的纹样：两只眼睛 + 翼上的两道白条。
private struct SwallowMarks: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let cx = rect.midX
        var path = Path()
        let eye = w * 0.045
        path.addEllipse(in: CGRect(x: cx - w * 0.09, y: rect.minY + h * 0.09,
                                   width: eye, height: eye))
        path.addEllipse(in: CGRect(x: cx + w * 0.09 - eye, y: rect.minY + h * 0.09,
                                   width: eye, height: eye))
        // 翼条：两条细长白道，跟着翅膀的方向斜出去
        path.addRect(CGRect(x: cx - w * 0.30, y: rect.minY + h * 0.22,
                            width: w * 0.20, height: h * 0.035))
        path.addRect(CGRect(x: cx + w * 0.10, y: rect.minY + h * 0.22,
                            width: w * 0.20, height: h * 0.035))
        return path
    }
}

/// 三角：经典菱形（上下两个三角，上半亮、下半靠十字骨分开）。
private struct DiamondKite: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.44))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.44))
        path.closeSubpath()
        return path
    }
}

/// 三角的骨架：十字骨 + 下半一道横档（菱形风筝就是这么糊的）。
private struct DiamondMarks: Shape {
    func path(in rect: CGRect) -> Path {
        let cx = rect.midX
        let waist = rect.minY + rect.height * 0.44
        var path = Path()
        path.addRect(CGRect(x: cx - rect.width * 0.012, y: rect.minY,
                            width: rect.width * 0.024, height: rect.height))
        path.addRect(CGRect(x: rect.minX, y: waist - rect.height * 0.012,
                            width: rect.width, height: rect.height * 0.024))
        path.addRect(CGRect(x: cx - rect.width * 0.16, y: rect.minY + rect.height * 0.68,
                            width: rect.width * 0.32, height: rect.height * 0.022))
        return path
    }
}

/// 金鱼：圆胖的身子 + 大摆尾 + 背鳍。
private struct GoldfishKite: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let cx = rect.midX
        var path = Path()
        path.addEllipse(in: CGRect(x: cx - w * 0.25, y: rect.minY + h * 0.10,
                                   width: w * 0.50, height: h * 0.40))
        // 背鳍
        path.move(to: CGPoint(x: cx - w * 0.05, y: rect.minY + h * 0.10))
        path.addQuadCurve(to: CGPoint(x: cx + w * 0.16, y: rect.minY + h * 0.02),
                          control: CGPoint(x: cx + w * 0.10, y: rect.minY + h * 0.04))
        path.addQuadCurve(to: CGPoint(x: cx + w * 0.06, y: rect.minY + h * 0.14),
                          control: CGPoint(x: cx + w * 0.12, y: rect.minY + h * 0.10))
        path.closeSubpath()
        // 大摆尾：中间 V 形缺口，两端甩到画框下角
        path.move(to: CGPoint(x: cx, y: rect.minY + h * 0.44))
        path.addQuadCurve(to: CGPoint(x: rect.minX + w * 0.04, y: rect.maxY),
                          control: CGPoint(x: cx - w * 0.32, y: rect.minY + h * 0.70))
        path.addLine(to: CGPoint(x: cx, y: rect.minY + h * 0.74))
        path.addLine(to: CGPoint(x: rect.maxX - w * 0.04, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: cx, y: rect.minY + h * 0.44),
                          control: CGPoint(x: cx + w * 0.32, y: rect.minY + h * 0.70))
        path.closeSubpath()
        return path
    }
}

/// 金鱼的纹样：一只眼睛 + 身上一道亮鳞。
private struct GoldfishMarks: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let cx = rect.midX
        var path = Path()
        let eye = w * 0.07
        path.addEllipse(in: CGRect(x: cx - w * 0.17, y: rect.minY + h * 0.22,
                                   width: eye, height: eye))
        path.addEllipse(in: CGRect(x: cx + w * 0.10, y: rect.minY + h * 0.24,
                                   width: w * 0.22, height: h * 0.05))
        return path
    }
}

/// 提线：从风筝底部垂下去、边垂边淡出的一小段（不接到地面）。
private struct KiteString: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.midX - rect.width * 0.42, y: rect.maxY),
                          control: CGPoint(x: rect.midX - rect.width * 0.10,
                                           y: rect.minY + rect.height * 0.62))
        return path
    }
}

/// 尾飘带上的一枚小结（蝴蝶结状：两个小三角对顶）。
private struct KiteTailBow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        path.move(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
