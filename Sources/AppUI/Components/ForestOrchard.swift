import SwiftUI

// MARK: - 秋：大树脚下那片小果园（#624）

/// 果子：一棵树只结一种 —— 才读得出「这是棵苹果树」，而不是一片红点。
enum OrchardFruit: String, CaseIterable, Sendable {

    case apple
    case peach
    case citrus

    /// 果子的取色（主题是唯一取色处，View 里不许写字面量）。
    func color(_ theme: ForestTheme) -> Color {
        switch self {
        case .apple: return theme.orchardApple
        case .peach: return theme.orchardPeach
        case .citrus: return theme.orchardCitrus
        }
    }
}

/// 一棵果树的**静态属性**（站位 / 造型 / 结什么果）：由种子定死，重绘不许换一批。
struct ForestFruitTree: Identifiable, Equatable, Sendable {

    let id: Int
    /// 结什么果。
    let fruit: OrchardFruit
    /// 横向位置（地面带宽的比例）。
    let lane: Double
    /// 树干倾角（度，正 = 往右歪）：果树不会棵棵笔直。
    let lean: Double
    /// 冠幅 / 树高。
    let canopySpan: Double
    /// 树干高占全树高的比例（其余是树冠）。
    let trunkRatio: Double
    /// 冠上挂几颗果。
    let fruitCount: Int
    /// 树下掉几颗果。
    let droppedCount: Int
    /// 摆动增益（度 / pt 风位移）：小树比大树摆得多一点。
    let swayGain: Double
}

/// 树冠的一团（unit，相对树冠框）。
struct OrchardLobe: Equatable, Sendable {

    let x: Double
    let y: Double
    /// 半径（占冠框短边的比例）。
    let r: Double
}

/// 果树的布局与造型（纯函数 / 确定性，可单测）。
enum OrchardLayout {

    /// 秋天大树脚下那片小果园：左两棵、右两棵 —— 中间给大树让出来。
    static let autumnGrove: [ForestFruitTree] = make(seed: 0x4652_5549, count: 4)   // "FRUI"

    /// **「两个半小动物高」** —— 需求写死的比例，全场景只此一处。
    ///
    /// ⚠️ 分母不是另拍的一个数：是草地上真的小动物的高
    /// （`ForestGroundPlan.referenceResidentSize`，与 `homePosition` 同一条公式的
    /// 中位值）。果树与小动物因此永远同一把尺 —— 改了动物大小，果树跟着变。
    static let animalHeights: CGFloat = 2.5

    /// 树冠顶与地面带上沿之间留的空（pt）。
    static let topMargin: CGFloat = 4

    /// 树高（pt）= 一只小动物高 × 2.5。
    static func treeHeight(quantizedWidth: CGFloat) -> CGFloat {
        ForestGroundPlan.referenceResidentSize(quantizedWidth: quantizedWidth) * animalHeights
    }

    /// **整片果园共用的一个树高**：先要 2.5 倍，再看林间空地容不容得下。
    ///
    /// 两个理由：
    /// 1. 逐棵不同高 = 一片高矮不齐的杂树，既不好看，也让「两个半」这个说法失真；
    /// 2. 地面带只有 150pt，草坡是**鼓包**（中心高、两角低）—— 靠中间那棵站得最高、
    ///    净空最少。面板一宽，小动物跟着变大、树也跟着变高，树冠就会戳出带顶。
    ///
    /// ⚠️ 所以这里取「要多少」与「容得下多少」的小者：正常宽度（≤ 约 450pt）下
    /// 精确就是 2.5 倍；更宽的面板上会被净空截住（约两倍出头）。宁可比两个半矮
    /// 一点，也不要树冠被地面带上沿齐齐切一刀。
    static func groveHeight(
        width: CGFloat, quantizedWidth: CGFloat, groundLine: ForestGroundSurface
    ) -> CGFloat {
        let desired = treeHeight(quantizedWidth: quantizedWidth)
        let headroom = autumnGrove
            .map { baseY($0, width: width, groundLine: groundLine) }
            .min() ?? width
        return min(desired, max(headroom - topMargin, desired * 0.5))
    }

    /// 树基（地面带内的 y）：踩在草坡表面上 —— 和小动物踩的是同一条曲线。
    static func baseY(
        _ tree: ForestFruitTree, width: CGFloat, groundLine: ForestGroundSurface
    ) -> CGFloat {
        groundLine(width * tree.lane)
    }

    /// 全树外框（地面带内坐标）：树基踩在坡面上，向上长 `groveHeight`。
    static func frame(
        _ tree: ForestFruitTree, width: CGFloat, quantizedWidth: CGFloat,
        groundLine: ForestGroundSurface
    ) -> CGRect {
        let height = groveHeight(
            width: width, quantizedWidth: quantizedWidth, groundLine: groundLine)
        let span = height * tree.canopySpan
        let base = baseY(tree, width: width, groundLine: groundLine)
        return CGRect(
            x: width * tree.lane - span / 2,
            y: base - height,
            width: span,
            height: height
        )
    }

    /// 树干在**全树框**内的相对矩形。
    static func trunkRect(_ tree: ForestFruitTree, in box: CGRect) -> CGRect {
        let height = box.height * tree.trunkRatio
        let width = box.height * 0.085
        return CGRect(
            x: box.midX - width / 2,
            y: box.maxY - height,
            width: width,
            height: height
        )
    }

    /// 树冠在**全树框**内的相对矩形（树干之上那一段）。
    static func canopyRect(_ tree: ForestFruitTree, in box: CGRect) -> CGRect {
        let trunk = trunkRect(tree, in: box)
        return CGRect(
            x: box.minX,
            y: box.minY,
            width: box.width,
            height: max(trunk.minY - box.minY, 1)
        )
    }

    /// 树冠由哪几团叶叠出来（确定性）：一个**菱形簇**（左 / 右 / 顶 / 前下）。
    ///
    /// ⚠️ 不能排成一行：冠框基本是方的，一行三团只铺得出一条横带 —— 出来就是
    /// 「一团扁平的叶子」（实测第一版正是这样）。菱形才填得满，也才有上圆下鼓的树形。
    static func canopyLobes(_ tree: ForestFruitTree) -> [OrchardLobe] {
        var rng = SeededRandom(seed: 0x4C4F_4245 &+ UInt64(tree.id) &* 0x9E37_79B9)   // "LOBE"
        let anchors: [(x: Double, y: Double, r: Double)] = [
            (0.32, 0.56, 0.30),   // 左下
            (0.69, 0.52, 0.31),   // 右
            (0.50, 0.33, 0.30),   // 顶
            (0.47, 0.72, 0.25),   // 前下（探出来的一小团）
        ]
        return anchors.map { anchor in
            let y = anchor.y + (rng.next() - 0.5) * 0.07
            return OrchardLobe(
                x: anchor.x + (rng.next() - 0.5) * 0.07,
                y: y,
                // ⚠️ 团不许冒出冠框顶沿：否则 `frame`（= 「整棵树的外框」）就框
                // 不住树，果树会比「两个半小动物」更高出一截。
                r: min(anchor.r * (0.94 + rng.next() * 0.14), y * 0.94)
            )
        }
    }

    /// 受光那一面相对整团的**缩放**与**偏移**（朝太阳那一侧浮起来）。
    ///
    /// ⚠️ 果子与受光面必须用同一对常数：果子按整团半径撒、亮面却缩了 20%，
    /// 结果就是每颗果都挂在暗边上 —— 看着像浮在树冠外的红点（第一版实测如此）。
    static let canopyLitScale: Double = 0.80
    static let canopyLitOffset: (dx: Double, dy: Double) = (0.045, -0.055)

    /// 果子落在受光面里还留一圈余量（不压在叶缘上）。
    static let fruitReach: Double = 0.86

    /// 果子挂在冠内哪些位置（unit，相对**树冠框**）。
    ///
    /// ⚠️ 每颗都**先抽一团叶、再在团内抖**（不是在整个冠框里均匀撒）：
    /// 直接撒会挂到叶子外的空处，看着像浮在树上的红点。
    /// ⚠️ 抖动半径量的是**受光那一面**（`canopyLitScale` / `canopyLitOffset`）——
    /// 那是眼睛真正看到的叶子，量到整团上去就全落在暗边上了。
    static func fruitSpots(_ tree: ForestFruitTree) -> [CGPoint] {
        let lobes = canopyLobes(tree)
        guard !lobes.isEmpty else { return [] }
        var rng = SeededRandom(seed: 0x4652_5549 &+ UInt64(tree.id) &* 0xBF58_476D)   // "FRUI"
        return (0..<max(tree.fruitCount, 0)).map { index in
            let lobe = lobes[index % lobes.count]
            let angle = rng.next(in: 0...(.pi * 2))
            let reach = lobe.r * canopyLitScale * fruitReach * (0.22 + rng.next() * 0.78)
            return CGPoint(
                x: lobe.x + canopyLitOffset.dx + cos(angle) * reach,
                y: lobe.y + canopyLitOffset.dy + sin(angle) * reach * 0.82
            )
        }
    }

    /// 掉在树下的果子（unit：`x` 相对全树框宽；`y` 是抬升，pt）。
    static func droppedSpots(_ tree: ForestFruitTree) -> [CGPoint] {
        var rng = SeededRandom(seed: 0x4452_4F50 &+ UInt64(tree.id) &* 0x94D0_49BB)   // "DROP"
        return (0..<max(tree.droppedCount, 0)).map { index in
            let side: Double = index % 2 == 0 ? -1 : 1
            return CGPoint(
                x: 0.5 + side * rng.next(in: 0.18...0.46),
                y: rng.next(in: 0...2.2)
            )
        }
    }

    /// 风把树推歪的角度（度）：绕**树根**转（见 `FruitTreeFigure`）。
    static func swayDegrees(_ tree: ForestFruitTree, push: CGFloat) -> Double {
        Double(push) * tree.swayGain
    }

    /// 造一片果园（纯函数：同种子永远同一片）。
    ///
    /// - `lane` 分**左右两簇**（中间那棵大树要露出来），簇内按序错开；
    /// - 结什么果按 `index` 轮转，相邻两棵不重样；
    /// - 冠幅 / 干高比 / 倾角各不相同 —— 四棵不是一个模子翻出来的。
    static func make(seed: UInt64, count: Int) -> [ForestFruitTree] {
        var rng = SeededRandom(seed: seed)
        let total = max(count, 0)
        let fruits = OrchardFruit.allCases
        return (0..<total).map { index in
            let leftSide = index % 2 == 0
            let rank = index / 2
            let anchor = leftSide ? 0.090 : 0.910
            let stride = leftSide ? 0.110 : -0.110
            return ForestFruitTree(
                id: index,
                fruit: fruits[index % fruits.count],
                lane: anchor + stride * Double(rank) + (rng.next() - 0.5) * 0.024,
                lean: rng.next(in: -3.6...3.6),
                canopySpan: rng.next(in: 0.50...0.62),
                trunkRatio: rng.next(in: 0.38...0.46),
                fruitCount: 6 + Int(rng.next() * 3),
                droppedCount: 1 + Int(rng.next() * 2),
                swayGain: rng.next(in: 0.9...1.5)
            )
        }
    }
}

/// 秋天大树脚下那片小果园：四棵结着果子的树，**两个半小动物高**。
///
/// 三件让它读起来像「树」而不是「贴纸」的事：
/// 1. **量的是同一把尺** —— 树高 = 参照动物高 × 2.5（小动物就在同一个画面里，
///    高矮是比得出来的）；
/// 2. **踩在同一条坡面曲线上**（`groundLine`），不是浮在草上方；
/// 3. **树冠是几团叠出来的**，背光那面深、迎光那面亮（太阳钉在右上，
///    与 `ForestLighting` 同一个光源）。
///
/// ⚠️ 本层**不自己起表**：歪的角度是风钟位移的函数 —— 风停（减弱动效、
/// 氛围隐藏档）时 `offset` 恒 0，树站直，不用另写一条冻结分支。
struct ForestOrchard: View {

    let theme: ForestTheme
    let groundLine: ForestGroundSurface
    /// 量化宽度（与地面带同一步长）：树高只在这上面变化。
    let quantizedWidth: CGFloat

    @Environment(\.forestWind) private var wind

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .topLeading) {
                ForEach(OrchardLayout.autumnGrove) { tree in
                    let box = OrchardLayout.frame(
                        tree,
                        width: width,
                        quantizedWidth: quantizedWidth,
                        groundLine: groundLine
                    )
                    FruitTreeFigure(
                        theme: theme,
                        tree: tree,
                        push: wind?.offset(x: box.midX, height: box.height) ?? 0
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

/// 一棵果树：影 → 干 → 枝 → 树冠 → 果 → 落果（unit 画框，靠 frame 缩放）。
private struct FruitTreeFigure: View {

    let theme: ForestTheme
    let tree: ForestFruitTree
    /// 风把树推的位移（pt）—— 由调用方从风钟取，本视图不自己起表。
    let push: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let box = CGRect(origin: .zero, size: proxy.size)
            let trunk = OrchardLayout.trunkRect(tree, in: box)
            let crown = OrchardLayout.canopyRect(tree, in: box)
            let lobes = OrchardLayout.canopyLobes(tree)
            let spots = OrchardLayout.fruitSpots(tree)
            let drops = OrchardLayout.droppedSpots(tree)
            let basis = min(crown.width, crown.height)
            let fruitRadius = basis * 0.062
            // 影子方向走全局光源（太阳右上 → 影子左下），与小动物脚底下那枚同源。
            let shade = ForestLighting.shadowOffset(
                forDepth: ForestSceneGeometry.nearHillDepth)

            ZStack(alignment: .topLeading) {
                // 脚下的影：树是种在坡上的，不是摆上去的
                Ellipse()
                    .fill(theme.shadow)
                    .frame(width: box.width * 0.50, height: box.height * 0.042)
                    .offset(x: shade.width, y: shade.height)
                    .position(x: box.midX, y: box.maxY - box.height * 0.010)

                // 树干（带根盘与倾角）
                FruitTrunkShape(lean: tree.lean)
                    .fill(theme.orchardTrunk)
                    .frame(width: trunk.width, height: trunk.height)
                    .position(x: trunk.midX, y: trunk.midY)

                // 伸进树冠的枝：没有它，树冠是浮在干上的一团
                FruitBranchShape(lean: tree.lean)
                    .stroke(theme.orchardTrunkShade,
                            lineWidth: max(trunk.width * 0.26, 0.9))
                    .frame(width: crown.width, height: crown.height)
                    .position(x: crown.midX, y: crown.midY)

                // 树冠：背光那面（整团铺底）
                ForEach(0..<lobes.count, id: \.self) { index in
                    lobe(lobes[index], in: crown, basis: basis, scale: 1,
                         dx: 0, dy: 0, color: theme.orchardCanopyDeep)
                }
                // 迎光那面（朝太阳那侧收小一点、挪一点 —— 亮面浮在暗面之上）
                ForEach(0..<lobes.count, id: \.self) { index in
                    lobe(lobes[index], in: crown, basis: basis,
                         scale: OrchardLayout.canopyLitScale,
                         dx: OrchardLayout.canopyLitOffset.dx,
                         dy: OrchardLayout.canopyLitOffset.dy,
                         color: theme.orchardCanopy)
                }
                // 最亮的一撮（树冠顶上迎着太阳那一撮）
                if let top = lobes.min(by: { $0.y < $1.y }) {
                    lobe(top, in: crown, basis: basis, scale: 0.52,
                         dx: OrchardLayout.canopyLitOffset.dx * 1.2,
                         dy: OrchardLayout.canopyLitOffset.dy * 1.35,
                         color: theme.orchardCanopyWarm)
                }

                // 挂在冠上的果子（每颗都落在某一团叶子里）
                ForEach(0..<spots.count, id: \.self) { index in
                    let spot = spots[index]
                    let center = CGPoint(
                        x: crown.minX + crown.width * spot.x,
                        y: crown.minY + crown.height * spot.y
                    )
                    FruitFigure(
                        theme: theme,
                        tree: tree,
                        radius: fruitRadius,
                        withStem: index % 3 == 0
                    )
                    .position(x: center.x, y: center.y)
                }

                // 熟透掉在树下的果子
                ForEach(0..<drops.count, id: \.self) { index in
                    let drop = drops[index]
                    FruitFigure(theme: theme, tree: tree, radius: fruitRadius * 0.92)
                        .position(
                            x: box.minX + box.width * drop.x,
                            y: box.maxY - fruitRadius * 0.5 - drop.y
                        )
                }
            }
            .frame(width: box.width, height: box.height, alignment: .topLeading)
            // 绕**树根**转：树是被风推弯的，不是整棵平移
            .rotationEffect(
                .degrees(OrchardLayout.swayDegrees(tree, push: push)),
                anchor: .bottom
            )
        }
    }

    /// 一团叶（unit 团心 + 半径比例 → 冠框内的圆）。
    private func lobe(
        _ lobe: OrchardLobe, in crown: CGRect, basis: CGFloat,
        scale: CGFloat, dx: CGFloat, dy: CGFloat, color: Color
    ) -> some View {
        let diameter = basis * lobe.r * 2 * scale
        return Ellipse()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .position(
                x: crown.minX + crown.width * (lobe.x + dx),
                y: crown.minY + crown.height * (lobe.y + dy)
            )
    }
}

/// 一颗果子：果身 + 高光（+ 有的带一截果柄）。
private struct FruitFigure: View {

    let theme: ForestTheme
    let tree: ForestFruitTree
    let radius: CGFloat
    var withStem: Bool = false

    var body: some View {
        ZStack(alignment: .center) {
            Circle()
                .fill(tree.fruit.color(theme))
                .overlay(
                    Circle().stroke(theme.orchardTrunkShade.opacity(0.35), lineWidth: 0.6)
                )
            // 高光偏左上：亮斑落在受光面上，但要与朝上的果柄错开
            // （同在正上方就糊成一竖条，读不出「一颗圆果」）。
            Circle()
                .fill(theme.orchardFruitSheen.opacity(0.55))
                .frame(width: radius * 0.52, height: radius * 0.52)
                .offset(x: -radius * 0.28, y: -radius * 0.30)
            if withStem {
                RoundedRectangle(cornerRadius: radius * 0.12)
                    .fill(theme.orchardTrunkShade)
                    .frame(width: max(radius * 0.20, 0.7), height: radius * 0.62)
                    .offset(y: -radius * 0.98)
            }
        }
        .frame(width: radius * 2, height: radius * 2)
    }
}

// MARK: - 画法

/// 树干：带根盘、上细下粗、整体有个倾角。
private struct FruitTrunkShape: Shape {

    /// 倾角（度，正 = 往右歪）。
    let lean: Double

    func path(in rect: CGRect) -> Path {
        let shift = CGFloat(tan(lean * .pi / 180)) * rect.height
        let topWidth = rect.width * 0.58
        let flare = rect.width * 0.20
        var path = Path()
        path.move(to: CGPoint(x: rect.midX - rect.width / 2 - flare, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX - topWidth / 2 + shift, y: rect.minY),
            control: CGPoint(x: rect.midX - rect.width / 2,
                             y: rect.maxY - rect.height * 0.45)
        )
        path.addLine(to: CGPoint(x: rect.midX + topWidth / 2 + shift, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX + rect.width / 2 + flare, y: rect.maxY),
            control: CGPoint(x: rect.midX + rect.width / 2,
                             y: rect.maxY - rect.height * 0.45)
        )
        path.closeSubpath()
        return path
    }
}

/// 从干顶伸进树冠的三根枝桠（框底中央是根，向上分叉）。
private struct FruitBranchShape: Shape {

    let lean: Double

    func path(in rect: CGRect) -> Path {
        let shift = CGFloat(tan(lean * .pi / 180)) * rect.height
        let root = CGPoint(x: rect.midX + shift, y: rect.maxY)
        let tips: [(Double, Double)] = [(-0.34, 0.56), (0.04, 0.86), (0.34, 0.62)]
        var path = Path()
        for tip in tips {
            let end = CGPoint(x: root.x + rect.width * tip.0,
                              y: root.y - rect.height * tip.1)
            path.move(to: root)
            path.addQuadCurve(
                to: end,
                control: CGPoint(x: root.x + rect.width * tip.0 * 0.30,
                                 y: root.y - rect.height * tip.1 * 0.40)
            )
        }
        return path
    }
}
