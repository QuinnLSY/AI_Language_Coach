import SwiftUI

// MARK: - 树冠

/// 成长之树的树冠。
///
/// **只填一次剪影，层次全靠四样东西**——这是第 4 版最后收敛到的结构，
/// 前面几稿的失败让这条结论很硬：
///
/// 1. **扇贝边**：30 个同尺度叶团的并集（`CanopyLayout.clusters`），
///    轮廓因此有几十个 20—40pt 的起伏 —— 人眼判「这是树」就是靠这一条；
/// 2. **一道对角渐变**：右上受光、左下背光，是**一整块**渐变，中间没有分界；
/// 3. **枝干**（`CrownBranches`）：递归长出来的骨架，从冠内穿过，
///    上半幅清晰、下半幅用渐变**消隐**进叶里；
/// 4. **碎叶**（`CrownLeafSpeckles`）：叶缘上一圈参差的小叶，把硬边磨掉。
///
/// ⚠️ **试过且否掉的做法**（都画得出，但都难看，别再回去）：
/// - 每团各自填渐变 → 每团都是一个完整圆盘 = **一堆汤圆**；
/// - 每团各自压一道下沿暗面 → 30 道同心弧 = **一片泡沫**；
/// - 「前层叶」整块另填一色（无论更亮还是更暗）→ 一条巨大的扇贝分界线
///   = **另一棵树贴在前面**。分层填充这件事本身就会留下边界，
///   所以现在把「冠底更暗」交给那一整块渐变，不再另起一层。
///
/// 几何在 `CanopyLayout`、配色在 `CanopyPalette`（都是纯函数，可单测）。
struct TreeCrown: View {

    let theme: ForestTheme

    /// 是否画枝干层。**只为反证而存在**：`TreeCrownRenderTests` 用它渲染
    /// 「没有枝干」的对照图，证明枝干真的露在叶团外面（而不是被盖得一片不剩）。
    /// 生产路径永远是默认值 `true`。
    var drawsBranches: Bool = true

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let clusters = CanopyLayout.clusters(in: size)

            ZStack(alignment: .topLeading) {
                // ① 剪影：整块填一次（对角渐变 = 唯一的一道明暗过渡）
                CrownUnionShape(clusters: clusters)
                    .fill(bodyGradient(isNight: theme.isNight))

                // ② 受光的那几块：大而柔的亮面，遮在剪影里
                CrownClumps(theme: theme, clusters: clusters, size: size)

                // ③ 枝干：上半幅清晰，下半幅消隐进叶里
                if drawsBranches {
                    CrownBranches(
                        theme: theme,
                        limbs: CanopyLayout.limbs(in: size),
                        clip: clusters
                    )
                }

                // ④ 碎叶
                CrownLeafSpeckles(theme: theme, marks: CanopyLayout.leafMarks(in: size))

                // ⑤ 统一光
                CrownUnifyingLight(theme: theme, clusters: clusters, size: size)
            }
        }
    }

    /// 剪影底色：右上（太阳那侧）亮、左下（背光那侧）深。
    ///
    /// 三档而不是两档：两档插值在中段会"发闷"，中间那一档把亮度曲线拉直，
    /// 整幅叶子才不会一半过曝一半糊。
    private func bodyGradient(isNight: Bool) -> LinearGradient {
        let lit = CanopyPalette.tone(theme.foliage, level: 0.86, isNight: isNight)
        let mid = CanopyPalette.tone(theme.foliage, level: 0.42, isNight: isNight)
        let deep = CanopyPalette.tone(theme.foliageDeep, level: 0.14, isNight: isNight)
        return LinearGradient(
            colors: [
                ForestAerialPerspective.adjust(lit, depth: 0.22, haze: theme.aerialHaze),
                ForestAerialPerspective.adjust(mid, depth: 0.26, haze: theme.aerialHaze),
                ForestAerialPerspective.adjust(deep, depth: 0.30, haze: theme.aerialHaze),
            ],
            startPoint: UnitPoint(x: 0.82, y: 0.05),
            endPoint: UnitPoint(x: 0.18, y: 0.95)
        )
    }
}

// MARK: - 团块明暗（几块柔面，不是三十道弧）

/// 树冠内部**受光的那几块**：大而柔的亮面，遮在剪影里。
///
/// ⚠️ 为什么不是「每团各画一道下沿暗面」（上一稿，实测像一片泡沫）：
/// 30 团叶各自留一道弧，合起来就是 30 道同心弧 —— 读作**泡沫**，不是叶子。
/// 真树的内部明暗是**几大块**（受光的一侧、背光的一侧、冠底的沉影），
/// 块与块之间靠渐变过渡，中间没有硬边。所以这里只放 3 暗 2 亮，
/// 全部高斯模糊，遮罩裁边。
///
/// 它同时给枝干「压」出前后关系：枝干画在这层之上、前层叶之下。
private struct CrownClumps: View {

    let theme: ForestTheme
    let clusters: [LeafCluster]
    let size: CGSize

    /// ⚠️ **只放亮面，不放暗面**：冠底那一片的暗已经由前层叶（`frontGradient`）
    /// 整块负责了。这里再压一层模糊暗面，两层暗叠在一起就是一团糊 ——
    /// 上一稿实测左下角有一块说不清是什么的深色云。
    ///
    /// 亮面：太阳那一侧（右上）。
    private static let lights: [(x: CGFloat, y: CGFloat, r: CGFloat, a: Double)] = [
        (0.74, 0.18, 0.50, 0.26),
        (0.48, 0.30, 0.32, 0.14),
    ]

    var body: some View {
        let lit = CanopyPalette.tone(theme.foliage, level: 1.0, isNight: theme.isNight)
        ZStack(alignment: .topLeading) {
            ForEach(Array(Self.lights.enumerated()), id: \.offset) { _, spot in
                blob(color: lit, spot: spot, softness: 30)
            }
        }
        .mask(CrownUnionShape(clusters: clusters).fill(.black))
        .allowsHitTesting(false)
    }

    private func blob(
        color: Color,
        spot: (x: CGFloat, y: CGFloat, r: CGFloat, a: Double),
        softness: CGFloat
    ) -> some View {
        let radius = size.width * spot.r
        return Ellipse()
            .fill(RadialGradient(
                colors: [color.opacity(spot.a), color.opacity(0)],
                center: .center,
                startRadius: 0,
                endRadius: radius
            ))
            .frame(width: radius * 2, height: radius * 1.5)
            .offset(x: size.width * spot.x - radius, y: size.height * spot.y - radius * 0.75)
            .blur(radius: softness)
    }
}

// MARK: - 枝干

/// 树冠里的枝干：主枝 + 一级侧枝，全部按「下粗上细」围成多边形填充。
///
/// 颜色刻意压到比叶子**更暗**：树冠内部的枝被叶挡着，只会是剪影。
/// 反过来（枝比叶亮）会读成「发光的树杈」。
private struct CrownBranches: View {

    let theme: ForestTheme
    let limbs: [LimbSpec]
    /// 遮罩：枝干**不许伸出树冠轮廓**。
    ///
    /// 真树的枝会从叶缝里探出来一点，但那需要一根根单独调 —— 一键裁掉更稳：
    /// 不裁的那一版实测就是「一棵树顶着一排天线」（枝端的细梢全在冠外晃）。
    let clip: [LeafCluster]

    var body: some View {
        let base = ForestAerialPerspective.adjust(
            CanopyPalette.tone(theme.trunkShade, level: 0.02, isNight: theme.isNight),
            depth: 0.16,
            haze: theme.aerialHaze
        )
        ZStack(alignment: .topLeading) {
            ForEach(Array(limbs.enumerated()), id: \.offset) { _, limb in
                LimbShape(limb: limb)
                    .fill(base.opacity(0.50 + 0.26 * limb.tone))
            }
        }
        // 裁在树冠轮廓里（不裁就是「树顶着一排天线」，实测过）
        .mask(CrownUnionShape(clusters: clip).fill(.black))
        // 再往冠底**消隐**：越往下枝干越淡，最后化进叶里。
        // 硬裁一刀会在冠底留下一排齐刷刷的断口，加这一层就自然了。
        .mask(LinearGradient(
            stops: [
                .init(color: .black, location: 0.0),
                .init(color: .black, location: 0.46),
                .init(color: .clear, location: 0.88),
            ],
            startPoint: .top,
            endPoint: .bottom
        ))
    }
}

// MARK: - 碎叶

/// 叶团轮廓上的碎叶：一片片小叶子，明暗跟着所在位置走。
///
/// 它同时干两件事：
/// - 把 24 团叶的**硬边打碎**（轮廓上一圈参差 = 「树」而不是「球」）；
/// - 给冠内补一层「叶」的尺度感 —— 团块说「一簇」，碎叶说「叶」。
private struct CrownLeafSpeckles: View {

    let theme: ForestTheme
    let marks: [LeafMark]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                CrownLeafShape()
                    .fill(ForestAerialPerspective.adjust(
                        CanopyPalette.tone(theme.foliage, level: mark.tone, isNight: theme.isNight),
                        depth: 0.14,
                        haze: theme.aerialHaze
                    ))
                    .frame(width: mark.size.width, height: mark.size.height)
                    .rotationEffect(.degrees(mark.angle))
                    .position(x: mark.center.x, y: mark.center.y)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 统一光

/// 罩在整幅树冠上的三件东西：底部沉影、右上边光、叶隙光斑。
///
/// 它们的作用是**把 24 团叶缝回一个整体** —— 不是靠抹掉团块的边界（旧 `CanopyMass`
/// 的路子，代价是层次全无），而是靠一层共同的明暗：同一棵树，离太阳近的那一边
/// 一起亮、贴着地面的那一片一起沉。三件都遮罩在 `CrownUnionShape` 里，
/// 边全部交给遮罩裁，不会在树冠内部留下新的硬边。
private struct CrownUnifyingLight: View {

    let theme: ForestTheme
    let clusters: [LeafCluster]
    let size: CGSize

    /// 叶隙光斑：太阳从右上穿进来的几处亮点（相对画框）。
    ///
    /// 只放 4 处、都在上半幅 —— 光斑是「漏下来的」，铺满整棵树就成了噪点。
    private static let dapples: [(x: CGFloat, y: CGFloat, r: CGFloat, a: Double)] = [
        (0.68, 0.14, 46, 0.24),
        (0.52, 0.26, 32, 0.18),
        (0.80, 0.30, 26, 0.15),
        (0.34, 0.16, 22, 0.12),
    ]

    var body: some View {
        ZStack(alignment: .topLeading) {
            // ① 底部沉影：树冠底沿总是最沉的（叶背光）。
            // ⚠️ 必须通宽（比树冠还宽）：窄矩形的左右边会落在树冠**内部**，
            // 衰减带尽头就是一道新的弧线 —— 又「一块一块」了。
            Rectangle()
                .fill(LinearGradient(
                    colors: [
                        CanopyPalette.tone(theme.foliageDeep, level: 0.0, isNight: theme.isNight)
                            .opacity(0),
                        CanopyPalette.tone(theme.foliageDeep, level: 0.0, isNight: theme.isNight)
                            .opacity(0.58),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .frame(width: size.width * 1.6, height: size.height * 0.62)
                .offset(x: -size.width * 0.30, y: size.height * 0.44)
                .mask(CrownUnionShape(clusters: clusters).fill(.black))

            // ② 右上边光：太阳那一侧的叶面被照亮。
            Ellipse()
                .fill(RadialGradient(
                    colors: [Color.white.opacity(theme.isNight ? 0.10 : 0.20),
                             Color.white.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: size.width * 0.30
                ))
                .frame(width: size.width * 0.72, height: size.height * 0.62)
                .offset(x: size.width * 0.30, y: -size.height * 0.10)
                .mask(CrownUnionShape(clusters: clusters).fill(.black))

            // ③ 叶隙光斑：光真的漏进来了。
            ForEach(Array(Self.dapples.enumerated()), id: \.offset) { _, spot in
                Ellipse()
                    .fill(RadialGradient(
                        colors: [theme.glow.opacity(theme.isNight ? spot.a * 0.45 : spot.a),
                                 theme.glow.opacity(0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: spot.r
                    ))
                    .frame(width: spot.r * 2, height: spot.r * 1.7)
                    .offset(x: size.width * spot.x - spot.r,
                            y: size.height * spot.y - spot.r * 0.85)
                    .blur(radius: 3)
                    .mask(CrownUnionShape(clusters: clusters).fill(.black))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - A：树冠漏下来的光柱（丁达尔）

/// 丁达尔光柱：太阳在右上，几道光柱向左下斜穿下来，落在树干上。
///
/// **为什么放在树冠之前画**（ZStack 里树干之后、树冠之前）：光柱被树冠挡住，
/// 只从叶团的**缝**里透出来 —— 这就是「树冠漏下的光柱」。若画在树冠之后，
/// 光柱会压在叶子上，变成几道半透明的塑料片。
///
/// 三件事让它像光而不像贴片：
/// 1. **上下都衰减**（`ShaftShape` 里的三档 stop）：光源处不突然出现、
///    落点处不突然消失；
/// 2. **高斯模糊 9pt**：光没有边；
/// 3. **每道光柱的浓淡不同**：四道一样浓会读成一把梳子。
struct SunShafts: View {

    let theme: ForestTheme

    /// 画框（由调用方给：从树冠顶上一点往下，盖住树干上半段）。
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                ForEach(Array(Self.shafts.enumerated()), id: \.offset) { _, shaft in
                    ShaftShape(
                        topX: size.width * shaft.topX,
                        topHalfWidth: size.width * shaft.topWidth,
                        bottomX: size.width * shaft.bottomX,
                        bottomHalfWidth: size.width * shaft.bottomWidth,
                        height: size.height * shaft.height
                    )
                    .fill(LinearGradient(
                        stops: [
                            .init(color: tint.opacity(0), location: 0),
                            .init(color: tint.opacity(shaft.opacity * 0.55), location: 0.10),
                            .init(color: tint.opacity(shaft.opacity), location: 0.42),
                            .init(color: tint.opacity(0), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    .blur(radius: 9)
                }

                // 落点那一片被照亮：光柱终究要落在什么上面。
                Ellipse()
                    .fill(RadialGradient(
                        colors: [tint.opacity(theme.isNight ? 0.05 : 0.13), tint.opacity(0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: size.width * 0.30
                    ))
                    .frame(width: size.width * 0.68, height: size.height * 0.20)
                    .offset(x: size.width * 0.02, y: size.height * 0.70)
                    .blur(radius: 12)
            }
            .allowsHitTesting(false)
        }
        .accessibilityHidden(true)
    }

    /// 光的颜色：白天是太阳的暖金（`theme.glow`），夜里是月光的冷白。
    private var tint: Color {
        theme.isNight ? Color(hex: 0xC7D8F2) : theme.glow
    }

    /// 四道光柱：`topX / topWidth / bottomX / bottomWidth / height / opacity`
    ///
    /// 相对画框宽高。**越靠右的越亮越细**（更靠近太阳），越靠左的越浓越宽
    /// —— 那一道穿过了更多叶子，被散射得更开。
    private static let shafts: [(
        topX: CGFloat, topWidth: CGFloat, bottomX: CGFloat, bottomWidth: CGFloat,
        height: CGFloat, opacity: Double
    )] = [
        (0.74, 0.030, 0.28, 0.115, 0.92, 0.20),
        (0.88, 0.018, 0.60, 0.075, 0.74, 0.15),
        (0.60, 0.024, 0.06, 0.100, 0.98, 0.12),
        (0.95, 0.012, 0.84, 0.042, 0.58, 0.10),
    ]
}

/// 一道光柱：上窄下宽的四边形。
///
/// 为什么是梯形不是矩形：真实的丁达尔光束是锥形的（光源是点、光是发散的）。
/// 等宽的带子看着就是「一条半透明的斜杠」。
private struct ShaftShape: Shape {

    var topX: CGFloat
    var topHalfWidth: CGFloat
    var bottomX: CGFloat
    var bottomHalfWidth: CGFloat
    var height: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: topX - topHalfWidth, y: rect.minY))
        path.addLine(to: CGPoint(x: topX + topHalfWidth, y: rect.minY))
        path.addLine(to: CGPoint(x: bottomX + bottomHalfWidth, y: rect.minY + height))
        path.addLine(to: CGPoint(x: bottomX - bottomHalfWidth, y: rect.minY + height))
        path.closeSubpath()
        return path
    }
}
