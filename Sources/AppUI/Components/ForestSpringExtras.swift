import SwiftUI

// MARK: - 春：草地上的蝴蝶与蒲公英（#621）

/// 蝴蝶的**静态属性**（站位 / 航线 / 扇翅节奏）：由种子定死，重绘不许换一批。
struct ForestButterfly: Identifiable, Equatable, Sendable {

    let id: Int
    /// 横向基准（地面带宽的比例 0…1）。
    let lane: Double
    /// 巡航高度（离草坡表面多少 pt）。
    let altitude: Double
    /// 翅展（pt）。
    let size: Double
    /// 航线周期（秒）—— 慢，是「绕着飞」不是「抖」。
    let period: Double
    /// 航线初相（0…1）。
    let phase: Double
    /// 横向行程（pt）与纵向行程（pt）。
    let travelX: Double
    let travelY: Double
    /// 扇翅周期（秒）—— 比航线快一个量级（蝴蝶的翅膀是抖的，身体是飘的）。
    let flapPeriod: Double
}

/// 蝴蝶的航线与姿态（纯函数 / 确定性）。
enum ButterflyLayout {

    /// 春天草地上的三只蝴蝶。
    static let springMeadow: [ForestButterfly] = make(seed: 0x4255_5446, count: 3)   // "BUTF"

    /// 冻结档的时间（秒）：**每只各自**停在航线的四分之一处。
    ///
    /// ⚠️ 为什么按各自的周期算：一层共用一个冻结时刻的话，三只的航线进度
    /// 由各自的初相决定，可能刚好都停在起飞点（看着像三只刚从草里冒出来）。
    static func frozenElapsed(_ butterfly: ForestButterfly) -> Double {
        butterfly.period * 0.25
    }

    static func make(seed: UInt64, count: Int) -> [ForestButterfly] {
        var rng = SeededRandom(seed: seed)
        let total = max(count, 0)
        return (0..<total).map { index in
            let pitch = 1.0 / Double(max(total, 1))
            let lane = (Double(index) + 0.5 + (rng.next() - 0.5) * 0.7) * pitch
            // ⚠️ 巡航高度必须**大于**纵向起伏：起伏比高度还大的话，蝴蝶会一头
            // 扎进草坡里（航线的最低点 = 高度 − 起伏）。
            let travelY = rng.next(in: 7...16)
            return ForestButterfly(
                id: index,
                lane: min(max(lane, 0.08), 0.92),
                altitude: travelY + rng.next(in: 14...40),
                size: rng.next(in: 13...19),
                period: rng.next(in: 7.5...12.5),
                phase: rng.next(),
                travelX: rng.next(in: 26...54),
                travelY: travelY,
                flapPeriod: rng.next(in: 0.24...0.38)
            )
        }
    }

    /// 航线上此刻的位置（面板/地面带坐标）。
    ///
    /// 走的是**李萨如 8 字**（横向一个周期、纵向两个周期）：蝴蝶不飞直线，
    /// 也不该绕圈 —— 8 字是「绕着花打转、忽上忽下」的那一挂。
    static func position(
        _ butterfly: ForestButterfly, width: CGFloat, groundY: CGFloat, elapsed: Double
    ) -> CGPoint {
        let t = phase(of: butterfly, elapsed: elapsed)
        return CGPoint(
            x: width * butterfly.lane + CGFloat(butterfly.travelX * sin(t)),
            y: groundY - butterfly.altitude + CGFloat(butterfly.travelY * sin(2 * t))
        )
    }

    /// 此刻的横向速度方向（-1…1）：用来决定**朝哪边飞**（蝴蝶头朝着飞行方向）。
    static func heading(_ butterfly: ForestButterfly, elapsed: Double) -> Double {
        let t = phase(of: butterfly, elapsed: elapsed)
        return cos(t)
    }

    /// 翅膀的横向压缩比（0.28…1）：1 = 完全张开，0.28 = 侧过来只看得见一条边。
    ///
    /// 用 `|cos|` 而不是 `sin`：翅膀从张开到合拢再张开，`cos` 过零处正好是「侧对
    /// 观众」的那一瞬 —— 扇动因此有**节拍**，不是匀速缩放。
    static func flapScale(_ butterfly: ForestButterfly, elapsed: Double) -> CGFloat {
        let t = elapsed / butterfly.flapPeriod * 2 * .pi
        return CGFloat(0.28 + 0.72 * abs(cos(t)))
    }

    private static func phase(of butterfly: ForestButterfly, elapsed: Double) -> Double {
        elapsed / butterfly.period * 2 * .pi + butterfly.phase * 2 * .pi
    }
}

/// 春天草地上的蝴蝶：绕着花打转，翅膀抖着飞。
///
/// ⚠️ 与 `ForestMotes` 的白天飘絮**不是一类东西**：那是一粒粒看不清形状的小点，
/// 这是有翅膀、有朝向、会扇翅的**虫子** —— 一眼要能认出来。
struct ForestButterflies: View {

    let theme: ForestTheme
    /// 草坡表面函数：蝴蝶贴着坡面上的花飞，不是浮在一条直线上。
    let groundLine: ForestGroundSurface
    var still: Bool = false

    @Environment(\.appMotion) private var motion
    @Environment(\.forestWind) private var wind
    /// 「林子完全安静」档（连点天空 5 次）—— 隔着三层 view，走环境值不传参。
    @Environment(\.forestAmbientStill) private var ambientStill

    var body: some View {
        let frozen = still || ambientStill || motion.reduceMotion
        return GeometryReader { proxy in
            AmbientTicker(paused: frozen) { tick in
                let now = frozen ? 0 : tick
                ZStack(alignment: .topLeading) {
                    ForEach(ButterflyLayout.springMeadow) { butterfly in
                        let x = proxy.size.width * butterfly.lane
                        // 冻结档每只各停各的（见 `frozenElapsed` 的说明）
                        let clock = frozen ? ButterflyLayout.frozenElapsed(butterfly) : now
                        let base = groundLine(x)
                        let spot = ButterflyLayout.position(
                            butterfly, width: proxy.size.width,
                            groundY: base, elapsed: clock
                        )
                        // 蝴蝶很轻，风一吹就偏 —— 与草、风筝同一阵风（同一颗风钟）。
                        // 离地高度走 `WindField.airHeight`：面板坐标 y 朝下且恒正，
                        // `max(0, -spot.y)` 会静默塌成 0（高处放大整档失效）。
                        let push = (wind?.offset(
                            x: spot.x,
                            height: WindField.airHeight(groundY: base, objectY: spot.y)
                        ) ?? 0) * 2.2
                        ButterflyBody(theme: theme)
                            .frame(width: butterfly.size, height: butterfly.size)
                            // 朝飞行方向：往左飞就翻个面（不然永远是同一侧的侧影）
                            .scaleEffect(
                                x: ButterflyLayout.flapScale(butterfly, elapsed: clock)
                                    * (ButterflyLayout.heading(butterfly, elapsed: clock) < 0 ? -1 : 1),
                                y: 1, anchor: .center
                            )
                            .position(x: spot.x + push, y: spot.y)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 一只蝴蝶：上翅 + 下翅 + 身子 + 触角（unit 画框）。
private struct ButterflyBody: View {

    let theme: ForestTheme

    var body: some View {
        ZStack {
            ButterflyWings()
                .fill(theme.butterflyWing)
                .overlay(
                    ButterflyWings()
                        .stroke(theme.butterflyEdge, lineWidth: 0.7)
                )
            ButterflyCore()
                .fill(theme.butterflyBody)
        }
    }
}

/// 四片翅膀（左上 / 右上 / 左下 / 右下）。
private struct ButterflyWings: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let cx = rect.midX
        var path = Path()
        // 上翅：一对朝外上方张开的椭圆
        path.addEllipse(in: CGRect(x: cx - w * 0.48, y: rect.minY + h * 0.06,
                                   width: w * 0.46, height: h * 0.52))
        path.addEllipse(in: CGRect(x: cx + w * 0.02, y: rect.minY + h * 0.06,
                                   width: w * 0.46, height: h * 0.52))
        // 下翅：短一截、往下垂
        path.addEllipse(in: CGRect(x: cx - w * 0.38, y: rect.minY + h * 0.50,
                                   width: w * 0.34, height: h * 0.38))
        path.addEllipse(in: CGRect(x: cx + w * 0.04, y: rect.minY + h * 0.50,
                                   width: w * 0.34, height: h * 0.38))
        return path
    }
}

/// 身子（细长胶囊）与两根触角。
private struct ButterflyCore: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let cx = rect.midX
        var path = Path()
        path.addEllipse(in: CGRect(x: cx - w * 0.045, y: rect.minY + h * 0.18,
                                   width: w * 0.09, height: h * 0.72))
        // 触角：两根往外上方翘的细线
        path.move(to: CGPoint(x: cx, y: rect.minY + h * 0.20))
        path.addQuadCurve(to: CGPoint(x: cx - w * 0.22, y: rect.minY - h * 0.06),
                          control: CGPoint(x: cx - w * 0.10, y: rect.minY + h * 0.04))
        path.move(to: CGPoint(x: cx, y: rect.minY + h * 0.20))
        path.addQuadCurve(to: CGPoint(x: cx + w * 0.22, y: rect.minY - h * 0.06),
                          control: CGPoint(x: cx + w * 0.10, y: rect.minY + h * 0.04))
        return path
    }
}

// MARK: - 蒲公英

/// 一株蒲公英（静态属性）：一根细茎顶着一个白绒球。
struct ForestDandelion: Identifiable, Equatable, Sendable {

    let id: Int
    /// 横向位置（地面带宽的比例）。
    let lane: Double
    /// 茎高（pt）。
    let height: Double
    /// 绒球直径（pt）。
    let puff: Double
    /// 摆动周期（秒）与初相。
    let swayPeriod: Double
    let phase: Double
    /// 摆幅（度）—— 茎细，风一吹弯得比灌木明显。
    let sway: Double
}

/// 一缕飘絮（静态属性）：从绒球上脱开，斜着往上飘走。
struct ForestFluff: Identifiable, Equatable, Sendable {

    let id: Int
    /// 出发点（地面带宽的比例）：贴着某一株的绒球。
    let lane: Double
    /// 出发点高度（离草坡表面 pt）。
    let startHeight: Double
    /// 一次飘行的时长（秒）。
    let period: Double
    /// 初相（0…1）。
    let phase: Double
    /// 上行距离（pt）与横向漂移（pt）。
    let rise: Double
    let drift: Double
    /// 绒球直径（pt）。
    let size: Double
}

/// 蒲公英的布局与飘行（纯函数 / 确定性）。
enum DandelionLayout {

    /// 草地上的三株蒲公英。
    static let stems: [ForestDandelion] = makeStems(seed: 0x4441_4E44, count: 3)   // "DAND"
    /// 飘在空中的五缕絮。
    static let fluffs: [ForestFluff] = makeFluffs(seed: 0x464C_5546, count: 5)     // "FLUF"

    /// 冻结档的时间（秒）：**每缕各自**停在飘行的正中间（progress = 0.5）。
    ///
    /// ⚠️ 为什么按各自的初相反推：一层共用一个冻结时刻的话，进度由各自的初相
    /// 决定，可能刚好都停在「刚脱开绒球」那一瞬（透明、看不见）——
    /// 关动效就成了关内容。反推到 0.5，每缕都停在最实的那一段。
    static func frozenElapsed(_ fluff: ForestFluff) -> Double {
        fluff.period * (0.5 - fluff.phase)
    }

    /// 茎的冻结档（秒）：停在摆动的中段（不是笔直地立着）。
    static func frozenStemElapsed(_ stem: ForestDandelion) -> Double {
        stem.swayPeriod * 0.25
    }

    static func makeStems(seed: UInt64, count: Int) -> [ForestDandelion] {
        var rng = SeededRandom(seed: seed)
        let total = max(count, 0)
        return (0..<total).map { index in
            let pitch = 1.0 / Double(max(total, 1))
            let lane = (Double(index) + 0.5 + (rng.next() - 0.5) * 0.7) * pitch
            return ForestDandelion(
                id: index,
                lane: min(max(lane, 0.08), 0.92),
                height: rng.next(in: 26...44),
                puff: rng.next(in: 11...16),
                swayPeriod: rng.next(in: 2.4...3.8),
                phase: rng.next(),
                sway: rng.next(in: 5...11)
            )
        }
    }

    static func makeFluffs(seed: UInt64, count: Int) -> [ForestFluff] {
        var rng = SeededRandom(seed: seed)
        return (0..<max(count, 0)).map { index in
            ForestFluff(
                id: index,
                lane: rng.next(in: 0.12...0.88),
                startHeight: rng.next(in: 24...46),
                period: rng.next(in: 6.5...11.0),
                phase: rng.next(),
                rise: rng.next(in: 34...70),
                drift: rng.next(in: -38...38),
                size: rng.next(in: 5.5...8.5)
            )
        }
    }

    /// 茎此刻的倾角（度）：绕**根部**摆（`anchor: .bottom` 由调用方给）。
    static func swayDegrees(_ stem: ForestDandelion, elapsed: Double) -> Double {
        stem.sway * sin(elapsed / stem.swayPeriod * 2 * .pi + stem.phase * 2 * .pi)
    }

    /// 飘絮此刻的进度（0…1）：0 = 刚脱开绒球，1 = 飘出画面。
    static func progress(_ fluff: ForestFluff, elapsed: Double) -> Double {
        let raw = elapsed / fluff.period + fluff.phase
        return raw - raw.rounded(.down)
    }

    /// 飘絮此刻的位置（面板/地面带坐标）：斜着往上飘，横向按正弦慢慢荡。
    static func position(
        _ fluff: ForestFluff, width: CGFloat, groundY: CGFloat, elapsed: Double
    ) -> CGPoint {
        let t = progress(fluff, elapsed: elapsed)
        return CGPoint(
            x: width * fluff.lane + CGFloat(fluff.drift * t) + CGFloat(sin(t * 4 * .pi) * 6),
            y: groundY - fluff.startHeight - CGFloat(fluff.rise * t)
        )
    }

    /// 飘絮此刻的透明度：刚脱开时最实，越飘越淡（化进风里）。
    static func opacity(_ fluff: ForestFluff, elapsed: Double) -> Double {
        let t = progress(fluff, elapsed: elapsed)
        if t < 0.10 { return t / 0.10 }
        if t > 0.72 { return max(0, (1 - t) / 0.28) }
        return 1
    }
}

/// 春天草地上的蒲公英：几株白绒球 + 从球上飘走的絮。
///
/// ⚠️ 为什么不是「再撒一层白点」：`ForestMotes` 的白天飘絮已经是一层看不清
/// 形状的小点了 —— 蒲公英要被认出来，靠的是**植株**（一根茎顶一个球）与
/// 「絮是从球上走的」这个因果，不是再多几个白点。
struct ForestDandelions: View {

    let theme: ForestTheme
    let groundLine: ForestGroundSurface
    var still: Bool = false

    @Environment(\.appMotion) private var motion
    @Environment(\.forestWind) private var wind
    /// 「林子完全安静」档（连点天空 5 次）—— 隔着三层 view，走环境值不传参。
    @Environment(\.forestAmbientStill) private var ambientStill

    var body: some View {
        let frozen = still || ambientStill || motion.reduceMotion
        return GeometryReader { proxy in
            AmbientTicker(paused: frozen) { tick in
                let now = frozen ? 0 : tick
                ZStack(alignment: .topLeading) {
                    ForEach(DandelionLayout.stems) { stem in
                        let x = proxy.size.width * stem.lane
                        let base = groundLine(x)
                        let clock = frozen ? DandelionLayout.frozenStemElapsed(stem) : now
                        DandelionStem(theme: theme, puff: stem.puff)
                            .frame(width: stem.puff * 1.5, height: stem.height)
                            .rotationEffect(
                                .degrees(DandelionLayout.swayDegrees(stem, elapsed: clock)),
                                anchor: .bottom
                            )
                            .position(x: x, y: base - stem.height / 2)
                    }
                    ForEach(DandelionLayout.fluffs) { fluff in
                        let x = proxy.size.width * fluff.lane
                        let base = groundLine(x)
                        let clock = frozen ? DandelionLayout.frozenElapsed(fluff) : now
                        let spot = DandelionLayout.position(
                            fluff, width: proxy.size.width,
                            groundY: base, elapsed: clock
                        )
                        // 与蝴蝶同一条口径：离地高度必须由坡面与物体 y 相减得来
                        // （见 `WindField.airHeight`）。
                        let push = (wind?.offset(
                            x: spot.x,
                            height: WindField.airHeight(groundY: base, objectY: spot.y)
                        ) ?? 0) * 2.6
                        DandelionSeed(theme: theme)
                            .frame(width: fluff.size, height: fluff.size)
                            .opacity(DandelionLayout.opacity(fluff, elapsed: clock))
                            .position(x: spot.x + push, y: spot.y)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 一株蒲公英：细茎 + 顶端的白绒球（unit 画框，靠 frame 拉高）。
private struct DandelionStem: View {

    let theme: ForestTheme
    /// 绒球直径（pt）—— 茎的粗细按它算。
    let puff: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            // 茎：从底部往上，越往上越细
            DandelionStemShape()
                .stroke(theme.foliageDeep, style: StrokeStyle(lineWidth: max(puff * 0.10, 0.9),
                                                              lineCap: .round))
            DandelionSeed(theme: theme)
                .frame(width: puff, height: puff)
        }
    }
}

private struct DandelionStemShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.16),
                          control: CGPoint(x: rect.midX + rect.width * 0.30,
                                           y: rect.minY + rect.height * 0.62))
        return path
    }
}

/// 一团白絮：中心一小簇 + 一圈细绒毛（蒲公英的种子伞）。
private struct DandelionSeed: View {

    let theme: ForestTheme

    var body: some View {
        ZStack {
            DandelionHalo()
                .stroke(theme.dandelionPuff.opacity(0.85), lineWidth: 0.7)
            Circle()
                .fill(theme.dandelionPuff)
                .frame(width: 2.6, height: 2.6)
        }
    }
}

/// 绒毛：从中心放射出去的一圈细线（unit 画框）。
private struct DandelionHalo: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        for index in 0..<10 {
            let angle = Double(index) / 10 * 2 * .pi
            path.move(to: center)
            path.addLine(to: CGPoint(x: center.x + CGFloat(cos(angle)) * radius,
                                     y: center.y + CGFloat(sin(angle)) * radius))
        }
        return path
    }
}
