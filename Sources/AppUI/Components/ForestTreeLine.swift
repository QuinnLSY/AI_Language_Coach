import SwiftUI

/// 远景树线：远山脊线上的几株剪影。
///
/// 为什么需要它：改前整片森林**只有一棵树**（右栏那棵成长之树），山是空的 ——
/// 于是画面读起来像"一棵树插在草地上"，而不是"一片林子里的那棵树"。
/// 远景树线是最便宜的解药：纯静态几何、不挂任何 ticker、不参与命中测试。
///
/// 三条纪律：
/// 1. **与远山同一条曲线**：底部落在 `HillShape` 的脊线上（`ridgeY`），不另造地貌；
/// 2. **同一根景深轴**：颜色过 `ForestAerialPerspective`，比远山略近一档（能看见轮廓，
///    但仍被霾吃掉大部分饱和度）；
/// 3. **画在远山之后、中山之前**：中山会把树的下半截自然遮住 —— 「山后有林」
///    靠遮挡关系成立，而不是靠画得更高。
struct ForestTreeLine: View {

    let theme: ForestTheme

    /// 远山那一层的高度，与 `Hills` 里 `.frame(height: 150)` 同源。
    var hillHeight: CGFloat = 150

    /// 位置刻意不均匀，但整体要**够密**：六棵等距会读成"一排道具"，
    /// 十一棵疏密相间才像山脊上的一段林线。
    private static let trees: [(t: CGFloat, height: CGFloat, crown: CGFloat)] = [
        (0.06, 24, 11),
        (0.13, 30, 13),
        (0.20, 22, 10),
        (0.32, 27, 12),
        (0.41, 34, 15),
        (0.52, 23, 10),
        (0.60, 29, 13),
        (0.70, 24, 11),
        (0.78, 31, 14),
        (0.88, 26, 12),
        (0.95, 21, 9),
    ]

    var body: some View {
        Canvas { context, size in
            guard size.width > 0 else { return }
            // 比远山（0.68）近三档：山脊上的树有体积、有背光面。太淡会读成
            // "发光的棒棒糖"，太深又会从远景里跳出来抢成长之树的主角位 ——
            // 0.32 是"能看清轮廓、但明显被霾压着"的那一档。
            let color = ForestAerialPerspective.adjust(
                theme.hillFar, depth: 0.32, haze: theme.aerialHaze
            )

            for tree in Self.trees {
                let x = tree.t * size.width
                let baseY = Self.ridgeY(at: tree.t, height: hillHeight)
                // ⚠️ 树干只占一小截：这个距离上（几百米外）树干本来就看不清，
                // 画满整棵树高会变成"棒棒糖插在山脊上"。树冠几乎坐在山脊线上才对。
                let trunkHeight = tree.height * 0.42
                let crownBase = baseY - trunkHeight

                // 树干（细到只剩一根线：这个距离上看得见的只有轮廓）
                let trunk: CGFloat = 1.4
                context.fill(
                    Path(CGRect(x: x - trunk / 2, y: crownBase, width: trunk, height: trunkHeight)),
                    with: .color(color)
                )

                // 树冠：三层自下而上收窄的椭圆叠成塔形剪影
                for layer in 0..<3 {
                    let scale = 1 - CGFloat(layer) * 0.28
                    let width = tree.crown * 2 * scale
                    let height = tree.crown * 1.7 * scale
                    let centerY = crownBase - CGFloat(layer) * tree.crown * 0.7 - height * 0.12
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: x - width / 2,
                            y: centerY - height / 2,
                            width: width,
                            height: height
                        )),
                        with: .color(color)
                    )
                }
            }
        }
        .frame(height: hillHeight, alignment: .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 远山脊线在横向比例 `t` 处的高度（与 `HillShape` 的二次曲线逐点相同）。
    ///
    /// `HillShape`：(0, H) → 控制点 (mid, −0.125H) → (W, H)。
    /// 二次贝塞尔 y(t) = (1−t)²·H + 2(1−t)t·(−0.125H) + t²·H。
    static func ridgeY(at t: CGFloat, height: CGFloat) -> CGFloat {
        let u = 1 - t
        return height * (u * u + t * t) - 0.25 * height * u * t
    }
}
