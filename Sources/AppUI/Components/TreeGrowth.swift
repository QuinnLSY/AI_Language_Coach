import SwiftUI

/// 树的「成熟度」→ 画面（纯函数，便于单测）。
///
/// #601「成长之树从幼苗开始」的换算层：学员一眼能看出**这棵树是跟着自己长的** ——
/// 全新学员（0 星）看到的是纤细的树干 + 缩着的树冠 + 根畔一株两叶嫩苗；
/// 满星时与改动之前**逐像素相同**（三个档位的上限取的就是当时的常数）。
///
/// ⚠️ 成熟度 `growth` 就是既有的 `TreeCanvas.canopyDensity`（已得星 / 需求星，0…1），
/// 不另立一套口径 —— 两处各算一个「长到多少了」，迟早对不上。
///
/// ⚠️ 这里**只许管颜色与粗细，不许管布局**：`canvasHeight` / `learnerY` /
/// `canopyOffsetY` / 关卡节点的 y 一根手指都不碰（那是 `TreeScrollViewTests`
/// 与 `TreeViewportTests` 钉死的）。所以树干变细是**路径宽度**在变，
/// 树冠变小是**视觉缩放**在变，位置全部原地不动。
public enum TreeGrowth {

    // MARK: - 树干粗细（第一屏信号）

    /// 幼苗档的树干宽度（相对画布宽）：底 0.13 / 顶 0.055。
    ///
    /// 如今是 0.24 / 0.10 —— 340pt 宽的右栏里就是 82pt 对 44pt，
    /// 第一屏（树冠在屏幕上沿之外，看得见的正是这段树干）一眼可辨。
    public static let youngBottomWidth: Double = 0.13
    public static let youngTopWidth: Double = 0.055
    /// 成年档 = `TrunkShape` 改动前的常数（满星必须逐像素回到这里）。
    public static let matureBottomWidth: Double = 0.24
    public static let matureTopWidth: Double = 0.10

    /// 成熟度 → 树干（底宽, 顶宽）（相对画布宽的比例）。
    ///
    /// 线性：测试好钉，且进度本身已经是连续的（36 颗星一级级来）。
    /// 越界钳住：growth < 0 当幼苗、> 1 当成年，绝不画出负宽度。
    public static func trunkWidths(growth: Double) -> (bottom: Double, top: Double) {
        let g = min(max(growth, 0), 1)
        return (
            youngBottomWidth + (matureBottomWidth - youngBottomWidth) * g,
            youngTopWidth + (matureTopWidth - youngTopWidth) * g
        )
    }

    // MARK: - 树冠大小（爬上去才看得见）

    /// 幼苗档的树冠缩放：0.64。
    ///
    /// 下限不是拍的：树冠 `.scaleEffect(anchor: .bottom)` 底边不动，缩到 0.64 时
    /// 冠顶正好落在画框 y≈127 —— 树干尖（130）刚被叶片接住，不会戳出一根
    /// 「小冠 + 长尖」的怪异比例。再小尖就出头了。
    public static let youngCrownScale: Double = 0.64
    /// 成年档 = `Canopy` 改动前的上限（`0.97 + 1.0 * 0.06`）。
    public static let matureCrownScale: Double = 1.03

    /// 成熟度 → 树冠整体缩放（`Canopy` 里的 `scaleEffect` 直接用它）。
    public static func crownScale(growth: Double) -> Double {
        let g = min(max(growth, 0), 1)
        return youngCrownScale + (matureCrownScale - youngCrownScale) * g
    }

    // MARK: - 树冠上抬（接住树干尖）

    /// 幼苗档要把树冠整体往上抬多少（pt）。
    ///
    /// 为什么需要抬：树冠缩到 0.64 之后冠顶落在树干尖**之下** ——
    /// 树干尖（`trunkTipY` = 130）从叶子上方戳出来一截（用户 2026-10-19 报障，
    /// 实测幼苗态中列绿边到 y≈144 才开始、尖在 y≈128，戳出约 16pt）。
    /// 26 是量出来的：抬完冠顶压到尖上方一截，又不至于让树冠脱离树干。
    public static let youngCrownLift: CGFloat = 26

    /// 成熟度 → 树冠整体上抬（pt）。
    ///
    /// 满星恒 0：树冠长满时尖本来就埋在叶子里（成年态实测中列从 y≈80 起全是叶），
    /// 抬一下反而破坏「满星与从前逐像素相同」。线性淡出与 `crownScale` 同一把 `g`。
    public static func crownLift(growth: Double) -> CGFloat {
        let g = min(max(growth, 0), 1)
        return youngCrownLift * (1 - g)
    }

    // MARK: - 根畔嫩苗（0 星的「幼苗」签名）

    /// 嫩苗的淡出窗口：成熟度超过它就不画了（≈ 头 5 颗星）。
    ///
    /// 为什么必须淡出：嫩苗是「起点」的签名，不是常驻装饰 —— 树都长成还挂一株苗，
    /// 读作「这棵树在掉叶子」，叙事反了。
    public static let sproutFadeoutGrowth: Double = 0.15

    /// 嫩苗画在哪（相对树干中心的横移；右侧树根旁 —— 左边是当前关卡节点，
    /// 中间是学员，右边只有伙伴且在更下方，不抢位置）。
    ///
    /// 56 是量出来的：再往左会探进**成年树干**的右沿（midX+41），
    /// 「苗区有没有墨」的判据就分不清是苗还是树干；再往右会挤到伙伴
    /// （midX+54 起）与 l2 节点（midX+102 起）的那一条线上。
    public static let sproutOffsetX: CGFloat = 56
    /// 嫩苗扎根的 y（画布坐标）：地面带盖住画布最下面一段，
    /// 根要埋进草坡里（`ForestSceneGeometry` 的树根线在 960，坡面在带内 34pt 处）。
    public static let sproutRootY: CGFloat = 934
    /// 嫩苗画框（`TreeCanvas` 定位与 `TreeSprout` 共用）。
    public static let sproutWidth: CGFloat = 36
    public static let sproutHeight: CGFloat = 34

    public static func showsSprout(growth: Double) -> Bool {
        growth < sproutFadeoutGrowth
    }

    /// 嫩苗透明度：窗口内从 1 线性淡出到 0（窗口外恒 0）。
    public static func sproutOpacity(growth: Double) -> Double {
        guard showsSprout(growth: growth) else { return 0 }
        return 1 - min(max(growth, 0), sproutFadeoutGrowth) / sproutFadeoutGrowth
    }
}

/// 根畔的两叶嫩苗（#601）—— 全新学员第一眼就能看到的那株「幼苗」。
///
/// 几何全部写死在这一个视图里（30pt 上下的小东西，没有可配置的余地），
/// 判据在 `TreeGrowth`：画不画、多浓，由成熟度说话；
/// 画框与落点也在那边（`TreeCanvas` 定位要读同一套数）。
/// （internal：`TreeCanvas` 在另一个文件里摆它；判据与几何都不外溢。）
struct TreeSprout: View {

    let theme: ForestTheme
    /// 0…1（`TreeGrowth.sproutOpacity`）：淡出到 0 时整株消失。
    var opacity: Double = 1

    var body: some View {
        // ⚠️ 用 `Canvas` 不是耍帅：ZStack + offset 那版把叶子居中到了画框外
        // （离屏渲染实测苗区零墨迹）—— 30pt 的小东西经不起布局歧义，
        // 而 Canvas 的坐标就是帧坐标，画在哪就是哪。
        Canvas { context, _ in
            let w = TreeGrowth.sproutWidth, h = TreeGrowth.sproutHeight

            // 茎：从根里稍稍向左歪着长出来（笔直向上读作塑料）。
            var stem = Path()
            stem.move(to: CGPoint(x: w * 0.56, y: h))
            stem.addQuadCurve(
                to: CGPoint(x: w * 0.44, y: h - 25),
                control: CGPoint(x: w * 0.30, y: h - 13)
            )
            context.stroke(stem, with: .color(theme.foliageDeep),
                           style: StrokeStyle(lineWidth: 2.4, lineCap: .round))

            // 两片叶子：一高一低、一左一右，尖端朝外（透镜形，不用旋转）。
            context.fill(leaf(from: CGPoint(x: w * 0.47, y: h - 22),
                              to: CGPoint(x: w * 0.22, y: h - 30)),
                         with: .color(theme.foliage))
            context.fill(leaf(from: CGPoint(x: w * 0.47, y: h - 18),
                              to: CGPoint(x: w * 0.72, y: h - 27)),
                         with: .color(theme.foliage))
        }
        .opacity(opacity)
        .accessibilityHidden(true)   // 纯装饰，进度信息由关卡节点承载
    }

    /// 一片叶子：从茎上的 `base` 尖到 `tip` 的透镜形（两条二次曲线合起来）。
    private func leaf(from base: CGPoint, to tip: CGPoint) -> Path {
        let bulge: CGFloat = 4.5
        let dx = tip.x - base.x, dy = tip.y - base.y
        // 叶宽方向 = 茎叶方向转 90°。
        let nx = -dy, ny = dx
        let length = max((nx * nx + ny * ny).squareRoot(), 0.001)
        let ux = nx / length * bulge, uy = ny / length * bulge
        var path = Path()
        path.move(to: base)
        path.addQuadCurve(to: tip, control: CGPoint(x: base.x + ux, y: base.y + uy))
        path.addQuadCurve(to: base, control: CGPoint(x: tip.x + ux, y: tip.y + uy))
        path.closeSubpath()
        return path
    }
}
