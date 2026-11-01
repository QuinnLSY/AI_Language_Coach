import SwiftUI

/// 中景植被：树与草坡之间那一带灌木与蕨丛。
///
/// 为什么需要它：改前从树根到草坡之间是**空的绿地** —— 近景的草、花、小动物全挤在
/// 底部 150pt 那条带子里，中间什么都没有。眼睛读到的就是"前中后只有两层"。
/// 这一层站在坡面稍上方（更远），用大气透视压暗压淡，把纵深补齐。
///
/// 三条纪律：
/// 1. **站在坡上要问坡**：底部走 `ForestSceneGeometry.hillSurfaceY`，不写死直线，
///    否则灌木会浮空或埋进坡里（这是项目里踩过的老坑）；
/// 2. **画在树之后**：远的东西先画，被树挡住一角才对；
/// 3. **不挂 ticker**：这一层是静止的。风只吹近景的草与树冠 —— 远处的灌木按透视
///    本来就该动得几乎看不见，为此多开一条时间源不值。
struct ForestMidVegetation: View {

    let theme: ForestTheme

    /// 每一丛：（横向比例，高度，宽度，离坡面的抬升）
    ///
    /// `lift` 是"更远"的廉价表达：坡面越远在屏幕上越高，抬一点点就退后一截。
    private static let shrubs: [(t: CGFloat, height: CGFloat, width: CGFloat, lift: CGFloat)] = [
        (0.08, 26, 30, 10),
        (0.27, 21, 24, 14),
        (0.46, 30, 34, 9),
        (0.63, 18, 21, 15),
        (0.81, 25, 28, 11),
        (0.93, 20, 23, 13),
    ]

    var body: some View {
        Canvas { context, size in
            guard size.width > 0 else { return }
            let band = ForestSceneGeometry.groundBandHeight
            // 比草坡（0.05）远得多、比大树（0.18）也远：这一层归中景。
            let color = ForestAerialPerspective.adjust(
                theme.hillNear, depth: 0.34, haze: theme.aerialHaze
            )

            for shrub in Self.shrubs {
                let x = shrub.t * size.width
                let baseY = ForestSceneGeometry.hillSurfaceY(
                    x: x, bandWidth: size.width, bandHeight: band
                ) - shrub.lift
                guard baseY > 0 else { continue }

                // 细枝：灌木不是"贴地的一团"，要有根茎。
                context.fill(
                    Path(CGRect(x: x - 0.7, y: baseY - shrub.height * 0.35,
                                width: 1.4, height: shrub.height * 0.35)),
                    with: .color(color)
                )

                // 三团叶簇：中间高、两侧低，**左右对称** ——
                // 按序号递减缩放会读成「被风吹歪的一坨」，不像一丛植物。
                for index in 0..<3 {
                    let scale: CGFloat = index == 1 ? 1.0 : 0.82
                    let width = shrub.width * scale
                    let height = shrub.height * 0.86 * scale
                    let offsetX = (CGFloat(index) - 1) * shrub.width * 0.30
                    let lift = index == 1 ? shrub.height * 0.18 : 0
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: x + offsetX - width / 2,
                            y: baseY - height - lift,
                            width: width,
                            height: height
                        )),
                        with: .color(color)
                    )
                }
            }
        }
        .frame(height: ForestSceneGeometry.groundBandHeight)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
