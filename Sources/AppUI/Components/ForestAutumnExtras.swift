import SwiftUI

// MARK: - 秋：草地上的落叶堆与南瓜（#625）

// MARK: 落叶堆

/// 一片落叶的色调：一堆里三色混着 —— 只一色读不出「落叶堆」，像一摊色块。
enum AutumnLeafTone: String, CaseIterable, Sendable {

    case gold
    case rust
    case brown

    /// 叶色的取色（主题是唯一取色处，View 里不许写字面量）。
    func color(_ theme: ForestTheme) -> Color {
        switch self {
        case .gold: return theme.autumnLeafGold
        case .rust: return theme.autumnLeafRust
        case .brown: return theme.autumnLeafBrown
        }
    }
}

/// 一堆积起来的落叶（静态属性：由种子定死，重绘不许换一批）。
struct ForestLeafPile: Identifiable, Equatable, Sendable {

    let id: Int
    /// 横向位置（地面带宽的比例）。
    let lane: Double
    /// 堆宽相对**参照动物体型**的倍率。
    let spanScale: Double
    /// 堆高 / 堆宽（一堆叶子是扁的，不是一座小山）。
    let squash: Double
    /// 往坡里落的深浅（pt，越大越靠前 —— 靠前的压在草上，靠后的半埋进草里）。
    let inset: Double
    /// 堆里几片叶。
    let leafCount: Int
    /// 堆脚边散出来的几片。
    let looseCount: Int
    /// 整堆的倾斜（度）：被风扫过的堆是斜的，不是左右对称的小山。
    let tilt: Double
}

/// 堆里 / 堆边的一片叶（unit，相对**堆框**）。
struct LeafSpot: Equatable, Sendable {

    let x: Double
    let y: Double
    /// 叶长 / 堆宽。
    let scale: Double
    /// 叶的转角（度）。
    let angle: Double
    let tone: AutumnLeafTone
}

/// 落叶堆的布局与造型（纯函数 / 确定性，可单测）。
enum LeafPileLayout {

    /// 秋天草地上的四堆落叶。
    static let autumnGlade: [ForestLeafPile] = make(seed: 0x4C45_4146, count: 4)   // "LEAF"

    /// 一堆落叶有多宽 = 参照动物体型 × 这个系数。
    ///
    /// ⚠️ 分母是草地上真的小动物（它的画框是方的，体型既是它的高也是它的宽）——
    /// 一堆落叶得比小动物**矮一大截、宽一小圈**，才读得出「这是地上的一堆」，
    /// 而不是又一个蹲着的东西。
    static let animalSpanRatio: CGFloat = 0.88

    /// 一片叶的宽 / 长。
    ///
    /// ⚠️ 太扁（≤ 0.46）的叶子在 10pt 这个尺度上只剩一根细条，读成草叶、枝丫，
    /// 不是叶子 —— 第一版就栽在这里（一堆叶子看着像一堆碎枝）。
    static let leafAspect: CGFloat = 0.58

    /// 散叶随风挪动的增益（比草叶慢：是躺在地上的叶子，不是在风里飞的那批）。
    static let driftGain: CGFloat = 0.42

    /// 堆宽（pt）。
    static func span(_ pile: ForestLeafPile, quantizedWidth: CGFloat) -> CGFloat {
        ForestGroundPlan.referenceResidentSize(quantizedWidth: quantizedWidth)
            * animalSpanRatio * pile.spanScale
    }

    /// 堆底（地面带内的 y）：踩在草坡表面上 —— 和小动物、果树踩的是同一条曲线。
    static func baseY(
        _ pile: ForestLeafPile, width: CGFloat, groundLine: ForestGroundSurface
    ) -> CGFloat {
        groundLine(width * pile.lane) + pile.inset
    }

    /// 整堆外框（地面带内坐标）：堆底踩在坡面上，向上鼓 `span × squash`。
    static func frame(
        _ pile: ForestLeafPile, width: CGFloat, quantizedWidth: CGFloat,
        groundLine: ForestGroundSurface
    ) -> CGRect {
        let wide = span(pile, quantizedWidth: quantizedWidth)
        let tall = wide * pile.squash
        let base = baseY(pile, width: width, groundLine: groundLine)
        return CGRect(
            x: width * pile.lane - wide / 2,
            y: base - tall,
            width: wide,
            height: tall
        )
    }

    /// 堆里的叶片（**山形**：越往上站得越窄、叶子越小 — 一堆是堆起来的，不是撒开的）。
    ///
    /// ⚠️ 三色轮转再叠一层随机（`index` 打底，不许全堆一个色）：只一色读不出
    /// 「落叶堆」，像一摊色块；三色交错才像不同树上落下来的。
    static func leafSpots(_ pile: ForestLeafPile) -> [LeafSpot] {
        var rng = SeededRandom(seed: 0x5049_4C45 &+ UInt64(pile.id) &* 0x9E37_79B9)   // "PILE"
        let tones = AutumnLeafTone.allCases
        return (0..<max(pile.leafCount, 0)).map { index in
            // 先抽一个「高度层」（0 = 堆底，1 = 堆顶），横向可站的范围按层收窄
            let level = rng.next()
            let half = 0.46 * (1 - level * 0.58)
            return LeafSpot(
                x: 0.5 + (rng.next() - 0.5) * 2 * half,
                y: 1.0 - level * 0.86,
                scale: (0.32 - level * 0.10) * (0.88 + rng.next() * 0.24),
                angle: (rng.next() - 0.5) * 76,
                tone: tones[(index + Int(rng.next() * Double(tones.count))) % tones.count]
            )
        }
    }

    /// 堆脚边散出来的那几片（unit：**故意在堆框外** —— 散叶本来就在堆外）。
    static func looseSpots(_ pile: ForestLeafPile) -> [LeafSpot] {
        var rng = SeededRandom(seed: 0x4C4F_4F53 &+ UInt64(pile.id) &* 0x85EB_CA6B)   // "LOOS"
        let tones = AutumnLeafTone.allCases
        return (0..<max(pile.looseCount, 0)).map { index in
            let side: Double = index % 2 == 0 ? -1 : 1
            return LeafSpot(
                x: 0.5 + side * (0.54 + rng.next() * 0.26),
                y: 0.72 + rng.next() * 0.42,
                scale: 0.26 + rng.next() * 0.12,
                // 躺在地上的叶子不会立着：转角收在 ±38°（更斜的读成草茎、小虫）
                angle: (rng.next() - 0.5) * 76,
                tone: tones[Int(rng.next() * Double(tones.count)) % tones.count]
            )
        }
    }

    /// 造几堆落叶（纯函数：同种子永远同一地落叶）。
    ///
    /// - `lane` 按序均分再各抖一点（不许两堆叠在一处 —— 那就读成「一堆」了）；
    /// - 堆宽 / 扁度 / 深浅各不相同 —— 四堆不是一个模子翻出来的。
    static func make(seed: UInt64, count: Int) -> [ForestLeafPile] {
        var rng = SeededRandom(seed: seed)
        let total = max(count, 0)
        let pitch = 1.0 / Double(max(total, 1))
        return (0..<total).map { index in
            let lane = (Double(index) + 0.5 + (rng.next() - 0.5) * 0.70) * pitch
            return ForestLeafPile(
                id: index,
                lane: min(max(lane, 0.12), 0.88),
                spanScale: rng.next(in: 0.86...1.20),
                // ⚠️ 堆高不能太扁：叶子本身就有 6–11pt 高，堆高不到两层叶子，
                // 底下一坨就露在外面 —— 出来是一摊褐色的泥（第一版实测如此）。
                squash: rng.next(in: 0.42...0.54),
                inset: rng.next(in: 0...9),
                leafCount: 14 + Int(rng.next() * 5),
                looseCount: 1 + Int(rng.next() * 2),
                tilt: rng.next(in: -7...7)
            )
        }
    }
}

/// 秋天草地上的几堆落叶：一堆压一堆，边上散着几片，风来时散叶挪一挪。
///
/// 三件让它读起来像「落叶」而不是「色块」的事：
/// 1. **踩在同一条坡面曲线上**（`groundLine`），不是浮在草上方；
/// 2. **是堆起来的**（山形，越上越窄、叶越小），不是均匀撒开的；
/// 3. **三色混着、带叶缘** —— 一片片分得开，才像不同树上落下来的。
///
/// ⚠️ 本层**不自己起表**：散叶的挪动是风钟位移的函数 —— 风停（减弱动效、
/// 氛围隐藏档）时 `offset` 恒 0，叶子躺回原处，不用另写一条冻结分支。
struct ForestLeafPiles: View {

    let theme: ForestTheme
    let groundLine: ForestGroundSurface
    /// 量化宽度（与地面带同一步长）：堆的大小只在这上面变化。
    let quantizedWidth: CGFloat

    @Environment(\.forestWind) private var wind

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .topLeading) {
                ForEach(LeafPileLayout.autumnGlade) { pile in
                    let box = LeafPileLayout.frame(
                        pile,
                        width: width,
                        quantizedWidth: quantizedWidth,
                        groundLine: groundLine
                    )
                    LeafPileFigure(
                        theme: theme,
                        pile: pile,
                        drift: (wind?.offset(x: box.midX, height: 0) ?? 0)
                            * LeafPileLayout.driftGain
                    )
                    .frame(width: box.width, height: box.height)
                    .position(x: box.midX, y: box.midY)
                }
            }
            .frame(width: width, height: proxy.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 一堆落叶：底下一坨（整堆的厚度）→ 一片片叶 → 堆脚边散出来的几片。
private struct LeafPileFigure: View {

    let theme: ForestTheme
    let pile: ForestLeafPile
    /// 风把散叶推的位移（pt）—— 由调用方从风钟取，本视图不自己起表。
    let drift: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let box = CGRect(origin: .zero, size: proxy.size)
            let spots = LeafPileLayout.leafSpots(pile)
            let loose = LeafPileLayout.looseSpots(pile)

            ZStack(alignment: .topLeading) {
                // 整堆的厚度：一堆叶子不是一片片浮着的，底下是实的一坨。
                // ⚠️ 比框小一圈、坐得偏下 —— 上缘要是整整齐齐露一条弧，
                // 堆就成了「盘子」；叶尖盖住它，才是一堆叶子堆出来的形状。
                Ellipse()
                    .fill(theme.autumnLeafBrown)
                    .frame(width: box.width * 0.94, height: box.height * 0.88)
                    .position(x: box.midX, y: box.maxY - box.height * 0.44)

                ForEach(0..<spots.count, id: \.self) { index in
                    blade(spots[index], in: box)
                }

                // 堆脚边散出来的几片：只有它们跟着风挪（堆本身挪不动）
                ForEach(0..<loose.count, id: \.self) { index in
                    blade(loose[index], in: box)
                        .offset(x: drift, y: 0)
                }
            }
            .frame(width: box.width, height: box.height, alignment: .topLeading)
            .rotationEffect(.degrees(pile.tilt), anchor: .bottom)
        }
    }

    private func blade(_ spot: LeafSpot, in box: CGRect) -> some View {
        let length = box.width * spot.scale
        return LeafBladeShape()
            .fill(spot.tone.color(theme))
            .overlay(
                LeafBladeShape()
                    .stroke(theme.autumnLeafEdge.opacity(0.70), lineWidth: 0.5)
            )
            .frame(width: length, height: length * LeafPileLayout.leafAspect)
            .rotationEffect(.degrees(spot.angle))
            .position(x: box.minX + box.width * spot.x,
                      y: box.minY + box.height * spot.y)
    }
}

// MARK: 南瓜

/// 草地上的一个南瓜（静态属性：由种子定死，重绘不许换一批）。
struct ForestPumpkin: Identifiable, Equatable, Sendable {

    let id: Int
    /// 横向位置（地面带宽的比例）。
    let lane: Double
    /// 瓜高相对**参照动物体型**的倍率。
    let heightScale: Double
    /// 瓜宽 / 瓜高（南瓜是扁的，不是球）。
    let widthRatio: Double
    /// 坐歪的角度（度）。
    let lean: Double
    /// 几条棱（南瓜是被棱分成一瓣瓣的）。
    let ribs: Int
    /// 瓜蒂歪的角度（度）。
    let stemTilt: Double
    /// 往坡里陷的深浅（pt：南瓜重，会陷进草里一点）。
    let sink: Double
}

/// 南瓜的布局与造型（纯函数 / 确定性，可单测）。
enum PumpkinLayout {

    /// 秋天草地上的三个南瓜。
    static let autumnPatch: [ForestPumpkin] = make(seed: 0x5055_4D50, count: 3)   // "PUMP"

    /// **「比小动物矮一半还多」** —— 南瓜是躺在地上的，不能跟小动物抢个头。
    ///
    /// ⚠️ 分母不是另拍的一个数：是草地上真的小动物的高
    /// （`ForestGroundPlan.referenceResidentSize`，与 `homePosition`、果树
    /// 同一条公式的中位值）。南瓜与小动物因此永远同一把尺。
    static let animalHeights: CGFloat = 0.42

    /// 瓜高（pt）= 一只小动物高 × 0.42 × 各自的倍率。
    static func height(_ pumpkin: ForestPumpkin, quantizedWidth: CGFloat) -> CGFloat {
        ForestGroundPlan.referenceResidentSize(quantizedWidth: quantizedWidth)
            * animalHeights * pumpkin.heightScale
    }

    /// 瓜底（地面带内的 y）：踩在草坡表面上（再往下陷一点 —— 南瓜是重的）。
    static func baseY(
        _ pumpkin: ForestPumpkin, width: CGFloat, groundLine: ForestGroundSurface
    ) -> CGFloat {
        groundLine(width * pumpkin.lane) + pumpkin.sink
    }

    /// 整只瓜的外框（地面带内坐标）。
    static func frame(
        _ pumpkin: ForestPumpkin, width: CGFloat, quantizedWidth: CGFloat,
        groundLine: ForestGroundSurface
    ) -> CGRect {
        let tall = height(pumpkin, quantizedWidth: quantizedWidth)
        let wide = tall * pumpkin.widthRatio
        let base = baseY(pumpkin, width: width, groundLine: groundLine)
        return CGRect(
            x: width * pumpkin.lane - wide / 2,
            y: base - tall,
            width: wide,
            height: tall
        )
    }

    /// 瓜蒂在**瓜框**内的相对矩形（坐在顶上那个凹里）。
    static func stemRect(_ pumpkin: ForestPumpkin, in box: CGRect) -> CGRect {
        let tall = box.height * 0.34
        let wide = box.width * 0.15
        return CGRect(
            x: box.midX - wide / 2,
            y: box.minY - tall * 0.62,
            width: wide,
            height: tall
        )
    }

    /// 造几个南瓜（纯函数：同种子永远同一地南瓜）。
    ///
    /// - `lane` 按序排开再各抖一点 —— 三个**不许叠在一处**（叠了就读成「一个大的」）；
    /// - 高矮 / 扁瘦 / 歪向 / 棱数各不相同 —— 不是一个模子翻出来的；
    /// - 站的是**中间那片空地**：两边外侧留给果树（#624），南瓜不跟它们挤。
    static func make(seed: UInt64, count: Int) -> [ForestPumpkin] {
        var rng = SeededRandom(seed: seed)
        let total = max(count, 0)
        let stride = 0.21
        let anchor = 0.30
        return (0..<total).map { index in
            ForestPumpkin(
                id: index,
                lane: min(max(anchor + stride * Double(index)
                              + (rng.next() - 0.5) * 0.05, 0.18), 0.82),
                heightScale: rng.next(in: 0.82...1.18),
                widthRatio: rng.next(in: 1.16...1.38),
                lean: rng.next(in: -5.5...5.5),
                ribs: 3 + Int(rng.next() * 2),
                stemTilt: rng.next(in: -24...24),
                sink: rng.next(in: 0...2.4)
            )
        }
    }
}

/// 秋天草地上的几个南瓜：坐在坡上，一瓣一瓣的，顶上带一截青蒂。
///
/// 三件让它读起来像「南瓜」而不是「橙圆球」的事：
/// 1. **是扁的、顶上有个凹**（`PumpkinBodyShape`）—— 圆球读成橘子；
/// 2. **有棱**（比果身深的弧线）—— 南瓜是被棱分成一瓣瓣的；
/// 3. **蒂是青的、歪的** —— 刚摘下来那截，也是「这不是果子是瓜」的凭据。
///
/// ⚠️ 南瓜**不跟风动**：它是躺在地上的重东西，风推不动它（会动的是散叶）。
/// 本层因此连风钟都不读。
struct ForestPumpkins: View {

    let theme: ForestTheme
    let groundLine: ForestGroundSurface
    /// 量化宽度（与地面带同一步长）：瓜的大小只在这上面变化。
    let quantizedWidth: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .topLeading) {
                ForEach(PumpkinLayout.autumnPatch) { pumpkin in
                    let box = PumpkinLayout.frame(
                        pumpkin,
                        width: width,
                        quantizedWidth: quantizedWidth,
                        groundLine: groundLine
                    )
                    PumpkinFigure(theme: theme, pumpkin: pumpkin)
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)
                }
            }
            .frame(width: width, height: proxy.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 一只南瓜：影 → 瓜身 → 棱 → 高光 → 蒂（unit 画框，靠 frame 缩放）。
private struct PumpkinFigure: View {

    let theme: ForestTheme
    let pumpkin: ForestPumpkin

    var body: some View {
        GeometryReader { proxy in
            let box = CGRect(origin: .zero, size: proxy.size)
            let stem = PumpkinLayout.stemRect(pumpkin, in: box)
            // 影子方向走全局光源（太阳右上 → 影子左下），与小动物、果树同源。
            let shade = ForestLighting.shadowOffset(
                forDepth: ForestSceneGeometry.nearHillDepth)

            ZStack(alignment: .topLeading) {
                // 陷进草里的那一圈影：南瓜是压在草上的，不是浮着的
                Ellipse()
                    .fill(theme.shadow)
                    .frame(width: box.width * 0.94, height: box.height * 0.20)
                    .offset(x: shade.width, y: shade.height)
                    .position(x: box.midX, y: box.maxY - box.height * 0.04)

                PumpkinBodyShape()
                    .fill(theme.pumpkinBody)
                    .overlay(
                        PumpkinBodyShape()
                            .stroke(theme.pumpkinRib.opacity(0.45), lineWidth: 0.7)
                    )
                    .frame(width: box.width, height: box.height)
                    .position(x: box.midX, y: box.midY)

                // 棱：把瓜分成一瓣瓣（没有棱，它就是一颗橙色的球）
                PumpkinRibShape(count: pumpkin.ribs)
                    .stroke(theme.pumpkinRib.opacity(0.85),
                            lineWidth: max(box.width * 0.040, 1.0))
                    .frame(width: box.width, height: box.height)
                    .position(x: box.midX, y: box.midY)

                // 高光偏左上（太阳钉在右上 → 亮斑落在朝上偏左那一侧）
                Ellipse()
                    .fill(theme.pumpkinSheen.opacity(0.50))
                    .frame(width: box.width * 0.26, height: box.height * 0.16)
                    .rotationEffect(.degrees(-18))
                    .position(x: box.minX + box.width * 0.33,
                              y: box.minY + box.height * 0.36)

                // 瓜蒂：坐在顶上那个凹里，还带点青
                RoundedRectangle(cornerRadius: stem.width * 0.45)
                    .fill(theme.pumpkinStem)
                    .frame(width: stem.width, height: stem.height)
                    .rotationEffect(.degrees(pumpkin.stemTilt), anchor: .bottom)
                    .position(x: stem.midX, y: stem.midY)
            }
            .frame(width: box.width, height: box.height, alignment: .topLeading)
            .rotationEffect(.degrees(pumpkin.lean), anchor: .bottom)
        }
    }
}

// MARK: - 画法

/// 一片叶子：两头尖的叶形（椭圆读成瓜子，尖头才读成叶子）。
private struct LeafBladeShape: Shape {

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
        path.closeSubpath()
        return path
    }
}

/// 南瓜身：扁圆、**顶上中间有个凹**（蒂坐进去的那个坑）。
///
/// ⚠️ 这个凹是「这是南瓜」的凭据之一：正圆读成橘子 / 气球，顶上一凹才读成瓜。
private struct PumpkinBodyShape: Shape {

    func path(in rect: CGRect) -> Path {
        // 顶部中点比两侧低一点 —— 中间那个坑
        let dip = rect.height * 0.11
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.minY + dip),
            control: CGPoint(x: rect.minX + rect.width * 0.04,
                             y: rect.minY + rect.height * 0.06)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY),
            control: CGPoint(x: rect.maxX - rect.width * 0.04,
                             y: rect.minY + rect.height * 0.06)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control: CGPoint(x: rect.maxX - rect.width * 0.02,
                             y: rect.maxY - rect.height * 0.06)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.midY),
            control: CGPoint(x: rect.minX + rect.width * 0.02,
                             y: rect.maxY - rect.height * 0.06)
        )
        path.closeSubpath()
        return path
    }
}

/// 南瓜的棱：几条竖向弧（中间的鼓得多 —— 瓜是中间那瓣最圆）。
private struct PumpkinRibShape: Shape {

    let count: Int

    func path(in rect: CGRect) -> Path {
        let total = max(count, 1)
        var path = Path()
        for index in 0..<total {
            let t = Double(index + 1) / Double(total + 1)
            let x = rect.minX + rect.width * t
            // 越靠中间鼓得越厉害（边上那瓣几乎是一条竖线）
            let bulge = rect.width * 0.10 * (1 - abs(t - 0.5) * 2)
            path.move(to: CGPoint(x: x, y: rect.minY + rect.height * 0.16))
            path.addQuadCurve(
                to: CGPoint(x: x, y: rect.maxY - rect.height * 0.10),
                control: CGPoint(x: x + bulge, y: rect.midY)
            )
        }
        return path
    }
}
