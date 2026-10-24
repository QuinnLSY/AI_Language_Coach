import SwiftUI

// MARK: - 冬：草地上的雪人（#627）

/// 草地上堆的一个雪人（静态属性：由种子定死，重绘不许换一批）。
struct ForestSnowman: Identifiable, Equatable, Sendable {

    let id: Int
    /// 横向位置（地面带宽的比例）。
    let lane: Double
    /// 个头相对**参照动物体型**的倍率（三个雪人高矮各不同）。
    let heightScale: Double
    /// 整体坐歪的角度（度）：手堆的雪人不会笔直。
    let lean: Double
    /// 帽子歪的角度（度）。
    let hatTilt: Double
    /// 围巾垂下来那一角歪的角度（度）。
    let scarfTilt: Double
    /// 枝桠手臂抬起的角度（度，越大越"张手"）。
    let armLift: Double
    /// 往雪里陷的深浅（pt）：雪人重，会陷进雪地一点。
    let sink: Double
}

/// 雪人的布局与造型（纯函数 / 确定性，可单测）。
///
/// 一切尺寸都从**一个框**派生（`frame`），框的高度又是拿小动物当尺子量出来的 ——
/// 圆球、帽子、鼻子、围巾、枝桠全是这个框的百分比，因此换面板宽度时整体等比缩放，
/// 不会出现「帽子比头还大」这类比例失控。
enum SnowmanLayout {

    /// 冬天草地上的三个雪人。
    static let winterGlade: [ForestSnowman] = make(seed: 0x534E_4F57, count: 3)   // "SNOW"

    /// **一个半小动物高**（比小动物高一头，但比果树矮得多）。
    ///
    /// ⚠️ 分母不是另拍的一个数：是草地上真的小动物的高
    /// （`ForestGroundPlan.referenceResidentSize`）。雪人、果树、南瓜、落叶堆
    /// 与小动物因此永远同一把尺 —— 源码哨兵禁止在这里另抄一份公式。
    static let animalHeights: CGFloat = 1.45

    /// 框宽 / 框高（含身子的最大宽度，不含伸出去的枝桠）。
    static let widthRatio: CGFloat = 0.78

    // MARK: 造型比例（全部相对框）

    /// 身球（下球）高占框高的比例。
    static let bodyHeightRatio: CGFloat = 0.52
    /// 头球直径 / 身球高。
    static let headScale: CGFloat = 0.62
    /// 头球压进身球多少（相对头径）：两块雪要**叠着**，不能悬空。
    static let headOverlap: CGFloat = 0.14

    // MARK: 尺寸

    /// 雪人高（pt）= 一只小动物高 × 1.45 × 各自的倍率。
    static func height(_ snowman: ForestSnowman, quantizedWidth: CGFloat) -> CGFloat {
        ForestGroundPlan.referenceResidentSize(quantizedWidth: quantizedWidth)
            * animalHeights * snowman.heightScale
    }

    /// 雪人底（地面带内的 y）：踩在草坡表面上（再往下陷一点 —— 雪人是重的）。
    static func baseY(
        _ snowman: ForestSnowman, width: CGFloat, groundLine: ForestGroundSurface
    ) -> CGFloat {
        groundLine(width * snowman.lane) + snowman.sink
    }

    /// 整个雪人的外框（地面带内坐标）。
    static func frame(
        _ snowman: ForestSnowman, width: CGFloat, quantizedWidth: CGFloat,
        groundLine: ForestGroundSurface
    ) -> CGRect {
        let tall = height(snowman, quantizedWidth: quantizedWidth)
        let wide = tall * widthRatio
        let base = baseY(snowman, width: width, groundLine: groundLine)
        return CGRect(
            x: width * snowman.lane - wide / 2,
            y: base - tall,
            width: wide,
            height: tall
        )
    }

    // MARK: 零件（全在框内坐标里）

    /// 身球（下球）：贴框底，宽 = 框宽。
    static func bodyRect(in box: CGRect) -> CGRect {
        let tall = box.height * bodyHeightRatio
        let wide = min(box.width, tall * 1.06)
        return CGRect(
            x: box.midX - wide / 2,
            y: box.maxY - tall,
            width: wide,
            height: tall
        )
    }

    /// 头球：坐在身球上（压进 `headOverlap`，两球叠着才是一个雪人）。
    static func headRect(in box: CGRect) -> CGRect {
        let body = bodyRect(in: box)
        let diameter = body.height * headScale
        let bottom = body.minY + diameter * headOverlap
        return CGRect(
            x: box.midX - diameter / 2,
            y: bottom - diameter,
            width: diameter,
            height: diameter
        )
    }

    /// 尖顶帽：从头顶一直顶到框顶（框顶就是帽尖）。
    static func hatRect(in box: CGRect) -> CGRect {
        let head = headRect(in: box)
        let wide = head.width * 0.86
        let tall = max(head.minY - box.minY, head.height * 0.30)
        return CGRect(
            x: box.midX - wide / 2,
            y: box.minY,
            width: wide,
            height: tall
        )
    }

    /// 帽檐：压在帽子底沿、比帽子宽一点（不然帽子像贴在头上的三角纸）。
    static func hatBrimRect(in box: CGRect) -> CGRect {
        let hat = hatRect(in: box)
        let wide = hat.width * 1.26
        let tall = max(hat.height * 0.22, 2.0)
        return CGRect(
            x: box.midX - wide / 2,
            y: hat.maxY - tall * 0.45,
            width: wide,
            height: tall
        )
    }

    /// 胡萝卜鼻子：从脸的**中偏右**伸出来，尖朝外（右下）。
    static func noseRect(in box: CGRect) -> CGRect {
        let head = headRect(in: box)
        let long = head.width * 0.34
        let thick = head.width * 0.135
        return CGRect(
            x: head.midX - long * 0.12,
            y: head.midY - thick * 0.5 + head.height * 0.04,
            width: long,
            height: thick
        )
    }

    /// 围巾：绕在**脖子**上（头球的下缘），横跨身球宽度。
    ///
    /// ⚠️ 中心放在头球下缘、**不许再往上**：往上抬 0.4 个围巾高就会切掉下巴，
    /// 整张脸只剩眼睛和鼻子，读成「围巾勒在脸上」（实测）。
    static func scarfRect(in box: CGRect) -> CGRect {
        let body = bodyRect(in: box)
        let head = headRect(in: box)
        let tall = max(body.height * 0.13, 2.2)
        let y = head.maxY - tall * 0.10
        return CGRect(
            x: body.midX - body.width * 0.52,
            y: y,
            width: body.width * 1.04,
            height: tall
        )
    }

    /// 围巾垂下来那一角（挂在左侧）。
    static func scarfTailRect(in box: CGRect) -> CGRect {
        let scarf = scarfRect(in: box)
        let body = bodyRect(in: box)
        let tall = body.height * 0.36
        let wide = max(scarf.height * 0.92, 1.8)
        return CGRect(
            x: scarf.minX + scarf.width * 0.20,
            y: scarf.maxY - tall * 0.10,
            width: wide,
            height: tall
        )
    }

    /// 两只眼睛（煤球）的中心。
    static func eyeCenters(in box: CGRect) -> [CGPoint] {
        let head = headRect(in: box)
        let gap = head.width * 0.20
        let y = head.minY + head.height * 0.30
        return [
            CGPoint(x: head.midX - gap, y: y),
            CGPoint(x: head.midX + gap, y: y)
        ]
    }

    /// 身上的纽扣（煤球）中心：沿身球中线往下排。
    static func buttonCenters(in box: CGRect) -> [CGPoint] {
        let body = bodyRect(in: box)
        return (0..<3).map { index in
            CGPoint(
                x: body.midX,
                y: body.minY + body.height * (0.26 + Double(index) * 0.20)
            )
        }
    }

    /// 枝桠手臂的根（身球左右两侧，略微偏上）。
    static func armRoots(in box: CGRect) -> (left: CGPoint, right: CGPoint) {
        let body = bodyRect(in: box)
        let y = body.minY + body.height * 0.34
        return (
            left: CGPoint(x: body.minX + body.width * 0.06, y: y),
            right: CGPoint(x: body.maxX - body.width * 0.06, y: y)
        )
    }

    /// 一根枝桠的形状（身球坐标里的折线）：主干 + 末端两个小叉。
    ///
    /// `side` 取 -1（左）/ +1（右），`lift` 是抬起角度（度）。
    static func armPath(
        root: CGPoint, side: CGFloat, lift: Double, span: CGFloat
    ) -> [CGPoint] {
        let radians = lift * .pi / 180
        let dx = CGFloat(cos(radians)) * span * side
        let dy = -CGFloat(sin(radians)) * span
        let tip = CGPoint(x: root.x + dx, y: root.y + dy)
        // 中段稍微往下坠一点（枝桠不是尺子画的直线）
        let mid = CGPoint(
            x: root.x + dx * 0.52,
            y: root.y + dy * 0.52 + span * 0.06
        )
        let fork = CGPoint(x: root.x + dx * 0.74, y: root.y + dy * 0.74)
        let forkSpan = span * 0.30
        return [
            root, mid, tip,
            fork,
            CGPoint(x: fork.x + forkSpan * side * 0.72, y: fork.y - forkSpan * 0.72),
            fork,
            CGPoint(x: fork.x + forkSpan * side * 0.48, y: fork.y + forkSpan * 0.62)
        ]
    }

    /// 造几个雪人（纯函数：同种子永远同一地雪人）。
    ///
    /// - 三个**分散**在草地上（左 / 中 / 右各一），谁也不叠在谁身上；
    /// - 高矮、歪向、帽子角度、手臂抬法各不相同 —— 不是一个模子翻出来的；
    /// - 站位避开正中间最窄的一段：那里留给小动物站着说话。
    static func make(seed: UInt64, count: Int) -> [ForestSnowman] {
        var rng = SeededRandom(seed: seed)
        let total = max(count, 0)
        let anchors: [Double] = [0.17, 0.49, 0.83]
        return (0..<total).map { index in
            let anchor = index < anchors.count
                ? anchors[index]
                : 0.17 + (0.83 - 0.17) * Double(index) / Double(max(total - 1, 1))
            return ForestSnowman(
                id: index,
                lane: min(max(anchor + (rng.next() - 0.5) * 0.05, 0.12), 0.88),
                heightScale: rng.next(in: 0.86...1.14),
                lean: rng.next(in: -2.6...2.6),
                hatTilt: rng.next(in: -7...7),
                scarfTilt: rng.next(in: -14...14),
                armLift: rng.next(in: 16...34),
                sink: rng.next(in: 0...2.0)
            )
        }
    }
}

/// 冬天草地上的几个雪人：两个雪球、一顶尖帽、一条红围巾、一根胡萝卜、两根枝桠。
///
/// 让它读起来是「雪人」而不是「三个白球」的六件事：
/// 1. **两个球叠着**（头压进身 `headOverlap`）—— 分开摆就是两个雪堆；
/// 2. **尖顶帽**（锥 + 帽檐 + 顶球）—— 一眼就是人堆的；
/// 3. **红围巾**绕脖一圈再垂一角 —— 冬天里唯一的高饱和，先看见它才看见雪人；
/// 4. **胡萝卜朝外** —— 它同时是「鼻子」和「这是雪人不是雪堆」的凭据；
/// 5. **煤球眼睛 + 纽扣** —— 有脸才有人格；
/// 6. **枝桠朝上张开** —— 手臂垂着就读成两根树枝。
///
/// ⚠️ 雪人本身**不跟风掰**（它是压实的雪，风推不动）：会动只有围巾的尾角。
struct ForestSnowmen: View {

    let theme: ForestTheme
    let groundLine: ForestGroundSurface
    /// 量化宽度（与地面带同一步长）：雪人的大小只在这上面变化。
    let quantizedWidth: CGFloat

    @Environment(\.forestWind) private var wind

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .topLeading) {
                ForEach(SnowmanLayout.winterGlade) { snowman in
                    let box = SnowmanLayout.frame(
                        snowman,
                        width: width,
                        quantizedWidth: quantizedWidth,
                        groundLine: groundLine
                    )
                    SnowmanFigure(
                        theme: theme,
                        snowman: snowman,
                        box: box,
                        tailSway: (wind?.offset(x: box.midX, height: 0) ?? 0) * tailGain
                    )
                    .frame(width: box.width, height: box.height)
                    .rotationEffect(.degrees(snowman.lean), anchor: .bottom)
                    .position(x: box.midX, y: box.midY)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 围巾尾角的摆幅 / 一点风的位移（雪人自己不动，只有这角布会晃）。
    private let tailGain: Double = 2.4
}

// MARK: - 画法

private struct SnowmanFigure: View {

    let theme: ForestTheme
    let snowman: ForestSnowman
    let box: CGRect
    /// 围巾尾角的摆动（度）。
    let tailSway: Double

    var body: some View {
        let local = CGRect(origin: .zero, size: box.size)
        ZStack(alignment: .topLeading) {
            // ① 雪地上的影：雪人是实心的一坨，脚下要有东西压着
            Ellipse()
                .fill(theme.snowShade.opacity(0.75))
                .frame(width: local.width * 1.10, height: local.height * 0.10)
                .position(x: local.midX + local.width * 0.04,
                          y: local.maxY - local.height * 0.02)

            // ② 身球 + 头球：先铺一层暗雪（比雪面下移一点点）当厚度，再盖亮雪
            ball(SnowmanLayout.bodyRect(in: local))
            ball(SnowmanLayout.headRect(in: local))

            // ③ 纽扣（煤球）：三颗，越往下越大 —— 身子是圆的，透视
            ForEach(Array(SnowmanLayout.buttonCenters(in: local).enumerated()),
                    id: \.offset) { index, center in
                Circle()
                    .fill(theme.snowmanCoal)
                    .frame(width: local.width * (0.055 + CGFloat(index) * 0.008),
                           height: local.width * (0.055 + CGFloat(index) * 0.008))
                    .position(center)
            }

            // ④ 枝桠手臂：从身球两侧伸出来、朝上张开
            ForEach(0..<2, id: \.self) { index in
                let roots = SnowmanLayout.armRoots(in: local)
                let root = index == 0 ? roots.left : roots.right
                let side: CGFloat = index == 0 ? -1 : 1
                let points = SnowmanLayout.armPath(
                    root: root,
                    side: side,
                    lift: snowman.armLift,
                    span: local.height * 0.34
                )
                Path { path in
                    path.addLines(points)
                }
                .stroke(theme.snowmanTwig,
                        style: StrokeStyle(lineWidth: max(local.width * 0.035, 1.1),
                                           lineCap: .round, lineJoin: .round))
            }

            // ⑤ 眼睛
            ForEach(Array(SnowmanLayout.eyeCenters(in: local).enumerated()),
                    id: \.offset) { _, center in
                Circle()
                    .fill(theme.snowmanCoal)
                    .frame(width: local.width * 0.075, height: local.width * 0.075)
                    .position(center)
            }

            // ⑥ 胡萝卜鼻子（尖朝外，稍微下垂）
            SnowmanNoseShape(rect: SnowmanLayout.noseRect(in: local))
                .fill(theme.snowmanNose)
                .rotationEffect(.degrees(9), anchor: .leading)

            // ⑦ 围巾：绕脖一圈 + 垂下一角
            Capsule()
                .fill(theme.snowmanScarf)
                .frame(width: SnowmanLayout.scarfRect(in: local).width,
                       height: max(SnowmanLayout.scarfRect(in: local).height, 1.8))
                .position(x: SnowmanLayout.scarfRect(in: local).midX,
                          y: SnowmanLayout.scarfRect(in: local).midY)

            let tail = SnowmanLayout.scarfTailRect(in: local)
            Capsule()
                .fill(theme.snowmanScarfDeep)
                .frame(width: tail.width, height: tail.height)
                .rotationEffect(.degrees(snowman.scarfTilt + tailSway), anchor: .top)
                .position(x: tail.midX, y: tail.midY)

            // ⑧ 尖顶帽（锥 + 帽檐 + 顶球）
            let hat = SnowmanLayout.hatRect(in: local)
            SnowmanHatShape()
                .fill(theme.snowmanHat)
                .frame(width: hat.width, height: hat.height)
                .rotationEffect(.degrees(snowman.hatTilt), anchor: .bottom)
                .position(x: hat.midX, y: hat.midY)

            let brim = SnowmanLayout.hatBrimRect(in: local)
            Capsule()
                .fill(theme.snowmanHatBand)
                .frame(width: brim.width, height: brim.height)
                .rotationEffect(.degrees(snowman.hatTilt * 0.5), anchor: .center)
                .position(x: brim.midX, y: brim.midY)

            // 顶上那颗毛球：帽尖歪出去时它跟着走（`hatTilt` 让锥体绕底转）
            Circle()
                .fill(theme.snowDrift)
                .frame(width: hat.width * 0.26, height: hat.width * 0.26)
                .position(
                    x: hat.midX - hat.height * CGFloat(sin(snowman.hatTilt * .pi / 180)),
                    y: hat.minY + hat.width * 0.10
                )
        }
        .frame(width: local.width, height: local.height, alignment: .topLeading)
    }

    /// 一个雪球：暗雪在下（露出下沿 = 厚度），亮雪盖上。
    private func ball(_ rect: CGRect) -> some View {
        ZStack {
            Ellipse()
                .fill(theme.snowShade)
                .frame(width: rect.width, height: rect.height)
                .offset(y: rect.height * 0.045)
            Ellipse()
                .fill(theme.snowDrift)
                .frame(width: rect.width * 0.98, height: rect.height * 0.98)
                .offset(y: -rect.height * 0.012)
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }
}

/// 胡萝卜鼻子：一个朝右的细长锥（尖端在下一点）。
private struct SnowmanNoseShape: Shape {

    let rect: CGRect

    func path(in _: CGRect) -> Path {
        var path = Path()
        let tipY = rect.midY + rect.height * 0.30
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: tipY),
            control: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.20)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY),
            control: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.10)
        )
        path.closeSubpath()
        return path
    }
}

/// 尖顶帽：底边宽、顶上收成一点（略往一边歪由外部旋转）。
private struct SnowmanHatShape: Shape {

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control: CGPoint(x: rect.midX - rect.width * 0.30, y: rect.minY + rect.height * 0.28)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.midX + rect.width * 0.30, y: rect.minY + rect.height * 0.28)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY),
            control: CGPoint(x: rect.midX, y: rect.maxY + rect.height * 0.10)
        )
        path.closeSubpath()
        return path
    }
}
