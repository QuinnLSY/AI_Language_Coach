import SwiftUI

// MARK: - 冬：积起来的雪（#626）

/// 一道雪脊：一个叶团**顶沿**上积的那一层雪。
///
/// 坐标与 `LeafCluster` **同一套**（画框像素）—— 雪脊是「这一团叶的顶」派生出来的，
/// 不是另排一张表：团挪了、雪跟着挪，不可能对不上。
///
/// ⚠️ 记的是**团本身**的中心与半径 + 一道「盖住顶部多少」的比例，不是另算一个小椭圆。
/// 小椭圆那版实测是「一冠白色荷叶」：椭圆一缩小，就只在叶团中间盖了个白斑，
/// 既没贴着叶缘、也读不出「雪压在叶子上」。
struct SnowCap: Equatable, Sendable {

    let center: CGPoint
    /// 叶团的半径（雪脊照抄它 —— 雪贴着叶缘）。
    let radii: CGSize
    /// 盖住这一团**顶部**多少（相对团高的比例，0.25…0.55）。
    let cover: Double
    /// 雪线下沿的起伏相位（由团的轮廓种子定 —— 同 seed 同形状，重绘不换）。
    let phase: Double
}

/// 积雪的布局（纯函数 / 确定性，可单测）。
///
/// 三件事都收在这里，因为它们是同一件事的三个面：冠上的雪帽、枝上的雪线、
/// 草地上的雪盖 —— 共用「雪有多厚、落在哪儿」这一组常数，改一处不会只改半边。
enum SnowCoverLayout {

    /// 雪盖住叶团顶部多少（相对团高的比例）—— 即雪舌**中间**的总厚度。
    ///
    /// 0.34：再高就把整团糊白（叶色全没了，实测 0.40 时整冠读成一朵云），
    /// 再低就成了一条白线（读成给叶团描了道边）。
    static let coverRatio: Double = 0.34

    /// 各团的厚薄差（±）：雪不是均厚的一层，团大的压得多、团小的只挂一点。
    static let coverVariation: Double = 0.07

    /// 冠的下面这一截不积雪（比例，自上而下）。
    ///
    /// 0.60：冠底那 2/5 是叶背、被上层叶子挡着 —— 雪积不上去。硬给它们也扣帽子，
    /// 整冠就是一片白鳞（实测第一版正是这样）。
    static let dustedPortion: Double = 0.60

    /// 第 `band` 层（自上而下 0 起）该有哪些雪脊。
    ///
    /// ⚠️ 按**层**取而不是整冠一起：树冠是四层各自随风摆的（`CanopyLayout.bands`），
    /// 雪脊若不分层，风一吹就「叶子在晃、雪钉在半空」。
    static func caps(in size: CGSize, band: Int) -> [SnowCap] {
        guard size.width > 0, size.height > 0 else { return [] }
        return CanopyLayout.clusters(in: size)
            .filter { $0.center.y < size.height * dustedPortion }
            .filter { CanopyLayout.bandIndex(atY: $0.center.y, in: size) == band }
            .map { cluster in
                // 每团的厚薄由自己的轮廓种子定（同 seed 永远同厚薄 —— 重绘不许换）
                let jitter = Double(cluster.seed % 21) / 20.0 * 2 - 1   // -1…1
                return SnowCap(
                    center: cluster.center,
                    radii: cluster.radii,
                    cover: coverRatio + jitter * coverVariation,
                    phase: Double(cluster.seed % 89) / 89.0 * .pi * 2
                )
            }
    }

    /// 全冠的雪帽（跨层，只给测试与判据用）。
    static func allCaps(in size: CGSize) -> [SnowCap] {
        (0..<CanopyLayout.bandCount).flatMap { caps(in: size, band: $0) }
    }

    /// 枝上的雪：沿枝的**上侧**画一条线（只取中段：枝梢太细，挂不住雪）。
    ///
    /// 返回的是「这一截雪线」的折线点与粗细 —— 纯函数，形状与测试共用。
    static func limbSnow(_ limb: LimbSpec, samples: Int = 7) -> (points: [CGPoint], width: CGFloat)? {
        let from: CGFloat = 0.12
        let to: CGFloat = 0.62
        guard samples >= 2, limb.rootWidth > 0.6 else { return nil }
        var points: [CGPoint] = []
        points.reserveCapacity(samples)
        for index in 0..<samples {
            let t = from + (to - from) * CGFloat(index) / CGFloat(samples - 1)
            let base = limb.point(at: t)
            let normal = limb.normal(at: t)
            // 取「朝上」的那一侧（y 更小）：雪积在枝的上表面
            let up = normal.dy <= 0 ? normal : CGVector(dx: -normal.dx, dy: -normal.dy)
            let lift = limb.width(at: t) * 0.28
            points.append(CGPoint(x: base.x + up.dx * lift, y: base.y + up.dy * lift))
        }
        return (points, max(limb.width(at: 0.3) * 0.46, 0.9))
    }

    // MARK: 草地

    /// 草地雪盖的厚度（pt）：压住草根、盖住坡面的一条。
    static let blanketThickness: CGFloat = 9

    /// 雪盖下沿的起伏（±pt）：雪线不是一条尺子画出来的直线。
    static let blanketRipple: CGFloat = 2.4
}

/// 草地上的一个雪堆（被风堆起来的那种）。
struct SnowDrift: Identifiable, Equatable, Sendable {

    let id: Int
    /// 横向位置（地面带宽的比例）。
    let lane: Double
    /// 宽 / 高（pt）：雪堆是扁的、圆头的。
    let width: Double
    let height: Double
    /// 往坡里落（pt）。
    let inset: Double
}

/// 雪堆的布局（纯函数 / 确定性）。
enum SnowDriftLayout {

    /// 冬天草地上被风堆起来的三个雪堆。
    static let winterGlade: [SnowDrift] = make(seed: 0x4452_4946, count: 3)   // "DRIF"

    static func baseY(
        _ drift: SnowDrift, width: CGFloat, groundLine: ForestGroundSurface
    ) -> CGFloat {
        groundLine(width * drift.lane) + drift.inset
    }

    /// 雪堆外框（地面带坐标）：踩在坡面上，向上鼓 `height`。
    static func frame(
        _ drift: SnowDrift, width: CGFloat, groundLine: ForestGroundSurface
    ) -> CGRect {
        let base = baseY(drift, width: width, groundLine: groundLine)
        return CGRect(
            x: width * drift.lane - drift.width / 2,
            y: base - drift.height,
            width: drift.width,
            height: drift.height
        )
    }

    static func make(seed: UInt64, count: Int) -> [SnowDrift] {
        var rng = SeededRandom(seed: seed)
        let total = max(count, 0)
        return (0..<total).map { index in
            SnowDrift(
                id: index,
                lane: rng.next(in: 0.14...0.86),
                width: rng.next(in: 26...46),
                height: rng.next(in: 7...11),
                inset: rng.next(in: 0...5)
            )
        }
    }
}

// MARK: - 树冠上的雪

/// 树冠顶上的积雪：一层雪帽，裁在冠的轮廓里（雪不会飘出叶子外面）。
///
/// ⚠️ 帽子逐层给（`band`），由 `TreeCrown` 包进该层的 `WindSway` ——
/// 雪是**落在这层叶子上的**，叶子晃它就跟着晃。
///
/// ⚠️ 帽子还有一圈**暗部**（`snowShade` 画在下沿）：雪有厚度，全靠一色白
/// 就是一片贴纸；下沿压一道冷影，雪才「坐」在叶子上。
struct CrownSnow: View {

    let theme: ForestTheme
    /// 第几层（自上而下 0 起）。
    let band: Int
    let size: CGSize
    /// 裁边：整冠轮廓（雪帽不许探出叶子）。
    let mask: [LeafCluster]

    var body: some View {
        let caps = SnowCoverLayout.caps(in: size, band: band)
        ZStack(alignment: .topLeading) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                let full = CGSize(width: cap.radii.width * 2, height: cap.radii.height * 2)
                // 暗部：比雪面多盖一截，露在雪的下沿 —— 雪有厚度，一色白就是贴纸
                crescent(full, cover: cap.cover + 0.035,
                         phase: cap.phase, color: theme.snowShade)
                    .position(x: cap.center.x, y: cap.center.y)
                crescent(full, cover: cap.cover, phase: cap.phase, color: theme.snowCover)
                    .position(x: cap.center.x, y: cap.center.y)
            }
        }
        .mask(CrownUnionShape(clusters: mask).fill(.black))
        .allowsHitTesting(false)
    }

    private func crescent(
        _ full: CGSize, cover: Double, phase: Double, color: Color
    ) -> some View {
        SnowTongueShape(cover: cover, phase: phase)
            .fill(color)
            .frame(width: full.width, height: full.height)
    }
}

/// 叶团顶沿的一条**雪舌**：外沿顺着这团叶的上轮廓，下沿是一道**往下鼓**的圆润弧。
///
/// ⚠️ 下沿不许是水平直线（也不许是整团椭圆顶掉一半）：那会把每团切成
/// 「白碗 + 绿底」，整冠叠起来读成一朵云 / 一叠白蘑菇（两版实测）。
/// 真实积雪的下沿是鼓的 —— 中间压得厚、两侧收成薄边。
private struct SnowTongueShape: Shape {

    /// 中间比两侧多积多少（相对框高的比例）—— 即雪舌下沿鼓下去多少。
    let cover: Double

    /// 雪线下沿的起伏相位（每团不同：雪线不是尺子画的）。
    let phase: Double

    /// 雪舌横向占叶团多宽（叶团宽度的比例）。
    ///
    /// 0.86：留出一圈叶色。占满整团（1.0）时每团是一顶完整的白碗，
    /// 叠起来读成「一树白花」—— 雪是**压在叶子顶上的一层**，不是把叶团换了个颜色。
    private let widthRatio: CGFloat = 0.86

    /// 下沿起伏的幅度（相对框高）与波数。
    private let rippleAmp: CGFloat = 0.055
    private let rippleWaves: Double = 3

    func path(in rect: CGRect) -> Path {
        guard rect.width > 2, rect.height > 2 else { return Path() }
        let cx = rect.midX
        let midY = rect.midY
        let rx = rect.width / 2
        let ry = rect.height / 2
        // 雪舌的两端落在叶团上轮廓的哪一点：由**横向宽度**定
        let psi0 = acos(min(max(widthRatio, 0.2), 0.98))
        let xEdge = rx * cos(psi0)
        let yEdge = midY - ry * sin(psi0)
        // `cover` 是雪舌**中间**的总厚度（相对框高）。两端已经因为轮廓下探有了
        // `topToEdge` 那么厚，因此下沿只需再鼓到差额 —— 否则雪舌会厚出半个团。
        let topToEdge = ry - ry * sin(psi0)
        let sag = max(rect.height * CGFloat(cover) - topToEdge, 0)
        let steps = 18

        var path = Path()
        // 外沿：这团叶的上轮廓（自右向左），只取雪舌那一段
        path.move(to: CGPoint(x: cx + xEdge, y: yEdge))
        for step in 1...steps {
            let psi = psi0 + (CGFloat.pi - 2 * psi0) * CGFloat(step) / CGFloat(steps)
            path.addLine(to: CGPoint(x: cx + rx * cos(psi), y: midY - ry * sin(psi)))
        }
        // 内沿：自左向右，往下鼓 `sag` 的一道弧，再叠一层**两端归零**的起伏 ——
        // 起伏必须归零，否则雪舌的左右角会和外沿裂开一道口子。
        let innerSteps = 26
        for step in 0...innerSteps {
            let s = CGFloat(step) / CGFloat(innerSteps)
            let x = cx - xEdge + 2 * xEdge * s
            let bulge = CGFloat(sin(Double(s) * .pi))
            let ripple = CGFloat(sin(Double(s) * .pi * rippleWaves + phase)) * bulge
            let y = yEdge + sag * bulge + rect.height * rippleAmp * ripple
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.closeSubpath()
        return path
    }
}

/// 枝上的积雪：沿每根枝的上表面一条细白线。
///
/// 只取中段（`SnowCoverLayout.limbSnow` 的 0.12…0.62）：枝梢比一根头发还细，
/// 挂不住雪；硬画就成了「树杈镶了银边」。
struct LimbSnow: View {

    let theme: ForestTheme
    let limbs: [LimbSpec]
    /// 裁边：整冠轮廓（与枝干同一条裁法）。
    let mask: [LeafCluster]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(limbs.enumerated()), id: \.offset) { _, limb in
                if let snow = SnowCoverLayout.limbSnow(limb) {
                    Path { path in
                        path.addLines(snow.points)
                    }
                    .stroke(theme.snowCover,
                            style: StrokeStyle(lineWidth: snow.width,
                                               lineCap: .round, lineJoin: .round))
                }
            }
        }
        .mask(CrownUnionShape(clusters: mask).fill(.black))
        .allowsHitTesting(false)
    }
}

// MARK: - 草地上的雪

/// 草地上的雪：**整片**盖住的地面积雪 + 坡坎的阴影 + 被风堆起来的几个雪堆。
///
/// ⚠️ 铺满整块草地而不是「沿坡线一条 9pt 的白边」：积雪覆盖的是**整块草地**，
/// 只描一条边就成了「给坡顶镶了道白线」（实测第一版）。冬天的地面就是白的，
/// 草叶 / 灌木 / 小花从雪里冒出来 —— 所以这一层画在它们**之前**。
///
/// ⚠️ 但「整块草地」= **坡面以下**，不是「地面带这个矩形」。第一版写成
/// `Rectangle().frame(height: proxy.size.height)`，雪于是铺到了带顶 ——
/// 带顶以上是**天空**（草坡是个鼓包，两角低、中间高），那一整条直角边横着切过大树：
/// 用户 2026-10-22 截图里的「季节背景只占了下面一块、还把大树遮住了」正是它。
/// 现在雪的轮廓取 `groundLine`（`HillCap` 的解析孪生）**以下**那一片，与草坡逐点重合。
struct ForestSnowField: View {

    let theme: ForestTheme
    let groundLine: ForestGroundSurface

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .topLeading) {
                // ① 整片雪地：带顶（远）偏冷、带底（近）偏亮。
                // ⚠️ 这里**不套大气透视**：地面带是视口最前面的一层（`nearHillDepth`），
                // 再给它加雾就成了「雪地浮在云里」。天空的冷由 `snowShade` 自己带。
                // ⚠️ 带顶**不许**和带底一个亮度：一片均匀的白会把地面压成一张纸，
                // 上面的雪堆 / 草叶 / 居民全浮不起来。
                SnowFieldShape(groundLine: groundLine)
                    .fill(
                        LinearGradient(
                            colors: [theme.snowShade, theme.snowGround],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: width, height: proxy.size.height)

                // ② 坡坎：雪面不是一块平板 —— 坡线那里压一道冷影，地形才立得住
                SnowBlanketShape(
                    groundLine: groundLine,
                    thickness: SnowCoverLayout.blanketThickness,
                    ripple: SnowCoverLayout.blanketRipple
                )
                .fill(theme.snowShade.opacity(0.85))

                // ③ 雪堆：顶面更亮、根部一道冷影，才读得出「这一坨是堆起来的」
                ForEach(SnowDriftLayout.winterGlade) { drift in
                    let box = SnowDriftLayout.frame(
                        drift, width: width, groundLine: groundLine)
                    Ellipse()
                        .fill(theme.snowShade)
                        .frame(width: box.width * 1.06, height: box.height * 0.52)
                        .position(x: box.midX, y: box.maxY - box.height * 0.12)
                    Ellipse()
                        .fill(theme.snowDrift)
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY - box.height * 0.08)
                }
            }
            .frame(width: width, height: proxy.size.height, alignment: .topLeading)
        }
        // 坡坎阴影带的两端会顺着坡面探出带底（`groundLine + thickness` 可能超过带高），
        // 而 `GeometryReader` **不裁剪** —— 不裁就会把雪漏到地面带外面去。
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 雪地的轮廓：坡面**以下**那一整片（坡面以上是天空，一点雪都不许上去）。
///
/// 与 `HillCap` 同一条二次曲线（`groundLine` 就是它的解析孪生），所以雪与草坡
/// 逐点重合 —— 不会出现「雪比坡多盖一块、或坡比雪多露一条」。
private struct SnowFieldShape: Shape {

    let groundLine: ForestGroundSurface

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0 else { return Path() }
        let steps = 48
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: groundLine(rect.minX)))
        for step in 1...steps {
            let x = rect.minX + rect.width * CGFloat(step) / CGFloat(steps)
            path.addLine(to: CGPoint(x: x, y: groundLine(x)))
        }
        // 下沿：贴着带底收回来（多走 2pt 再夹住，避免最后一像素露缝）
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY + 2))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY + 2))
        path.closeSubpath()
        return path
    }
}

/// 坡坎的阴影带：沿坡面一条，下沿是起伏的雪线。
///
/// ⚠️ 这不是「雪本身」—— 雪已经铺满整带了；这条带只负责在坡线那里压出一道影，
/// 让雪面读得出高低（否则一片死白）。
private struct SnowBlanketShape: Shape {

    let groundLine: ForestGroundSurface
    let thickness: CGFloat
    let ripple: CGFloat

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0 else { return Path() }
        let steps = 48
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: groundLine(rect.minX)))
        for step in 1...steps {
            let x = rect.minX + rect.width * CGFloat(step) / CGFloat(steps)
            path.addLine(to: CGPoint(x: x, y: groundLine(x)))
        }
        // 下沿：从右往左回到起点，厚度上叠两道不同频率的起伏（一条直线读成「贴了张纸」）
        for step in stride(from: steps, through: 0, by: -1) {
            let x = rect.minX + rect.width * CGFloat(step) / CGFloat(steps)
            let wave = sin(Double(x) * 0.088) * Double(ripple)
                + sin(Double(x) * 0.207 + 1.3) * Double(ripple) * 0.45
            path.addLine(to: CGPoint(x: x, y: groundLine(x) + thickness + CGFloat(wave)))
        }
        path.closeSubpath()
        return path
    }
}
