import SwiftUI

// MARK: - 夏：大树后那片草场上的风车（#622）

/// 一座风车的**静态属性**（站位 / 景深 / 转速）：由种子定死，重绘不许换一批。
struct ForestWindmill: Identifiable, Equatable, Sendable {

    let id: Int
    /// 景深（0 = 站在最近处，1 = 地平线）：决定它多高、多小、多淡。
    let depth: Double
    /// 横向位置（面板宽的比例）。
    let lane: Double
    /// 塔高（pt，**未**按景深缩放）。
    let height: Double
    /// 转速（度 / 风相位弧度）：越大转得越快。
    let spinGain: Double
    /// 叶片初相（度）：两座不同相，才不会像同一个电机带动的。
    let phase: Double
}

/// 风车的布局（纯函数 / 确定性，可单测）。
enum WindmillLayout {

    /// 夏天那片草场上的两座风车。
    ///
    /// ⚠️ 2026-10-22 由六座减到两座（用户：「把风车数量减为两个」）：
    /// 它们现在站在**看得见的地面**上、又是一座有墙有顶的房子，六座挤在一条坡线上
    /// 只会排成一排风车田的篱笆；两座一左一右刚好是「远处有两座风车」。
    static let summerField: [ForestWindmill] = make(seed: 0x5749_4E44)   // "WIND"

    /// 两座的站位：**定在树干左右**（0.31 / 0.69），抖动只给深度 / 塔高 / 转速。
    ///
    /// ⚠️ 位置不再按 index 分区随机：两座时随机出来的 `lane` 会一头扎到 0.91
    /// （贴着右边缘），而「一左一右陪衬大树」才是这个装饰要的画面。
    static let lanes: [Double] = [0.31, 0.69]

    /// 景深：一近一远（0.34 / 0.60）—— 两座一样大一样远，看着就是复制品。
    static let depths: [Double] = [0.34, 0.60]

    /// 塔基往草地上沉多少 pt：沉下去的那一截被草坡挡住，风车才像**种在坡上**，
    /// 而不是贴在坡线上面（浮空 3pt 就看得见缝）。
    static let footSink: CGFloat = 6

    /// 远景那条草坡的高度（pt）：脊线落在面板底往上 178 × 0.5625 ≈ 100pt 处。
    ///
    /// 为什么要另画一条坡（而不是把风车直接摆在地面带那条近坡上）：
    /// 面板里唯一的地面是近坡，而它是个**鼓包**、还站满了小动物 —— 两座风车摆在
    /// 0.25 / 0.75 正好压在两只小动物身后，整座都被挡住（2026-10-22 实测出图：
    /// 只剩几根白色帆叶从兔子耳朵后面露出来）。「远处的地」在这块面板里**不存在**，
    /// 得自己长出来：一条更平、更淡、脊线高出近坡 40 多 pt 的坡。
    static let farMeadowHeight: CGFloat = 196

    /// 远景草坡表面在 `x` 处的高度（面板坐标）。
    ///
    /// 与 `HillShape` **同一条曲线**：单段对称二次曲线，两端落在面板底、中间鼓起来。
    /// 控制点在框顶再往上 0.125 个坡高，于是
    /// `f(t) = (1−t)² + t² − 0.25·t(1−t)`（= `1 − 2.25·t(1−t)`，两种写法同一个值）。
    ///
    /// ⚠️ 第三项的系数是 **0.25** 不是 2.25：`(1−t)² + t²` 已经把 `-2t(1−t)` 算进去了，
    /// 控制点上抬那 0.125 个坡高只再贡献 `-0.25t(1−t)`。写成 2.25 的话坡面会被
    /// 压成一条浅弧（t=0.25 处只有 0.20 个坡高），风车跟着飞到带顶之上（实测踩过）。
    static func meadowSurfaceY(x: CGFloat, width: CGFloat, panelHeight: CGFloat) -> CGFloat {
        let t = Double(ForestSceneGeometry.clamp01(width > 0 ? x / width : 0.5))
        let f = (1 - t) * (1 - t) + t * t - 0.25 * t * (1 - t)
        return panelHeight - farMeadowHeight + farMeadowHeight * CGFloat(f)
    }

    /// 塔基所在的地面（面板坐标）：**远景草坡**的坡面，再往下沉 `footSink`。
    ///
    /// ⚠️ 2026-10-22 修「风车飘在空中」：旧版写的是
    /// `panelHeight − 带高 + 26 − horizonSpan × depth`。`horizonSpan`(150) 是**画布**坐标里
    /// 地平线到树根线的距离，可面板里整块地面带总共只有 150pt —— depth 一过 0.17，
    /// 塔基就已经飞出带顶，六座风车全挂在天上（用户截图：树根营地那一排关卡后面
    /// 浮着一排幽灵）。现在塔基咬在**看得见的那条坡**上，坡在哪它就在哪。
    static func groundY(
        _ mill: ForestWindmill, width: CGFloat, panelHeight: CGFloat
    ) -> CGFloat {
        meadowSurfaceY(x: width * mill.lane, width: width, panelHeight: panelHeight)
            + footSink
    }

    /// 近坡（地面带那条、小动物站的坡）表面在 `x` 处的高度（面板坐标）—— 判据用。
    static func nearSlopeY(x: CGFloat, width: CGFloat, panelHeight: CGFloat) -> CGFloat {
        panelHeight - ForestSceneGeometry.groundBandHeight
            + ForestSceneGeometry.hillSurfaceY(
                x: x,
                bandWidth: width,
                bandHeight: ForestSceneGeometry.groundBandHeight
            )
    }

    /// 塔身的外框（面板坐标）：塔基站在 `groundY` 上，向上长 `height × 缩放`。
    static func frame(
        _ mill: ForestWindmill, width: CGFloat, panelHeight: CGFloat
    ) -> CGRect {
        let style = Self.style(mill)
        let towerHeight = mill.height * style.scale
        let towerWidth = towerHeight * 0.52
        let ground = groundY(mill, width: width, panelHeight: panelHeight)
        return CGRect(
            x: width * mill.lane - towerWidth / 2,
            y: ground - towerHeight,
            width: towerWidth,
            height: towerHeight
        )
    }

    /// 融天比例留多少（相对景深那把尺）。
    static let hazeShare: CGFloat = 0.32

    /// 该景深上的规格：**只借景深的「小」与一点点「灰」**。
    ///
    /// ⚠️ 不能整套照搬 `ForestSceneGeometry.style(forDepth:)`：那四件套（缩小 / 变淡 /
    /// 失焦 / 融天）是给**大片色块**调的 —— 山丘、远景灌木，整片退化也还是「远山」。
    /// 压在一座只有 40~50pt 高的风车上，塔身当场化成一团白雾：用户 2026-10-22 的原话
    /// 是「过于虚化了，要有明确的实体」。所以这里只留景深的**主线索（远 = 小）**，
    /// 不透明度不降、模糊归零、融天砍到三成 —— 远，但看得清是座风车。
    static func style(_ mill: ForestWindmill) -> ForestDepthStyle {
        let base = ForestSceneGeometry.style(forDepth: mill.depth)
        return ForestDepthStyle(
            scale: base.scale,
            opacity: 1,
            blur: 0,
            haze: base.haze * hazeShare
        )
    }

    /// 叶片此刻的转角（度）：初相 + 风相位 × 转速。
    ///
    /// ⚠️ 读的是**全局风钟的相位**，不是另起一个计时器：风停（减弱动效、
    /// 氛围隐藏档）时相位不再推进，叶片就停在那儿 —— 不用另写一条冻结分支。
    static func bladeAngle(_ mill: ForestWindmill, windPhase: Double) -> Double {
        mill.phase + windPhase * mill.spinGain
    }

    /// 造两座风车（纯函数：同种子永远同一片草场）。
    ///
    /// 站位与远近是**写死的composition**（一左一右、一近一远），随机只用在
    /// 「细节」上：深度抖动 ±0.03、塔高、转速、叶片初相。重绘不许换一批 ——
    /// 用户会看见风车瞬移。
    static func make(seed: UInt64) -> [ForestWindmill] {
        var rng = SeededRandom(seed: seed)
        return lanes.indices.map { index in
            ForestWindmill(
                id: index,
                // ① 由近及远：depth 大 = 更远 = 更小。两座挨得太近会像复制品。
                depth: depths[index] + (rng.next() - 0.5) * 0.06,
                lane: lanes[index] + (rng.next() - 0.5) * 0.04,
                // ② 塔高只有半只小动物高（小动物约 90~100pt）：远，但还认得出是风车。
                height: rng.next(in: 56...68),
                // ③ 两座转速要差得开：一样快就像同一个电机带动的两根轴。
                spinGain: rng.next(in: index == 0 ? 24...30 : 40...48),
                phase: rng.next(in: 0...360)
            )
        }
    }
}

/// 夏天大树后那片草场：一条更淡的远坡 + 坡上两座风车，叶片被同一阵风推着转。
///
/// 四件让它「退到树后面」的事，全部由景深推出来（不各写一套数）：
/// 1. **站在自己的坡上**（`FarMeadowShape`：脊线高出近坡 40 多 pt，小动物的头顶够不着）；
/// 2. **更小**（`ForestDepthStyle.scale` + 40~54pt 的塔高）；
/// 3. **略带霾**（`hazeShare`：只留三成，再多就成鬼影）；
/// 4. **朝天空色收敛一点点**（`WindmillFigure.haze`）。
///
/// ⚠️ 层级：**风车先画、远坡后画** —— 坡把风车的脚埋掉几 pt，才像从坡后长出来的；
/// 反过来画风车就是「立在坡前面」。
///
/// ⚠️ 本层**不自己起表**：叶片角度是风钟相位的函数，风钟每帧推进 → 视图每帧
/// 重算。少一颗 `TimelineView`，也天生满足了「减弱动效 = 风停 = 叶片停」。
struct ForestWindmills: View {

    let theme: ForestTheme

    @Environment(\.forestWind) private var wind

    var body: some View {
        GeometryReader { proxy in
            let windPhase = wind?.phase ?? 0
            ZStack(alignment: .topLeading) {
                ForEach(WindmillLayout.summerField) { mill in
                    let box = WindmillLayout.frame(
                        mill, width: proxy.size.width, panelHeight: proxy.size.height
                    )
                    let style = WindmillLayout.style(mill)
                    WindmillFigure(
                        theme: theme,
                        // 空气透视：远的那座朝天空色收敛一点点（与山丘同一条来源，比例小）
                        haze: style.haze,
                        angle: WindmillLayout.bladeAngle(mill, windPhase: windPhase)
                    )
                    .frame(width: box.width, height: box.height)
                    .opacity(style.opacity)
                    .blur(radius: style.blur)
                    .position(x: box.midX, y: box.midY)
                }

                // 远坡：压在风车**之后**画（把脚埋进去），本身又是近坡（地面带）
                // 身后的一层 —— 三层叠出「近坡 → 动物 → 远坡 → 风车 → 天」的纵深。
                FarMeadowShape()
                    .fill(
                        LinearGradient(
                            colors: [
                                // 脊线那头更融天（远处被空气照亮），坡脚留住一点本色
                                ForestAerialPerspective.adjust(
                                    theme.hillMid,
                                    depth: ForestSceneGeometry.farHillDepth,
                                    haze: theme.aerialHaze),
                                ForestAerialPerspective.adjust(
                                    theme.hillMid,
                                    depth: ForestSceneGeometry.midHillDepth,
                                    haze: theme.aerialHaze)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: WindmillLayout.farMeadowHeight)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 远景那条草坡：与 `HillShape`（天空层那三层山）同一条单段二次曲线。
///
/// 两端落在画框底、中间鼓起来 —— 与天空层的山、与地面带的草坡是**同一种地貌**，
/// 只是缩放不同。写成一个 Shape 而不是复用 `ForestSky` 里的私有 `HillShape`：
/// 那个是窗口背景的，捏不到面板坐标里来。
private struct FarMeadowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.125)
        )
        path.closeSubpath()
        return path
    }
}

/// 一座风车：塔身 + 红瓦顶 + 小窗 + 四片帆叶（unit 画框，靠 frame 缩放）。
///
/// ⚠️ 描边不能省：一整座只有 40~55pt 高，压在**同色系**的草坡上（绿底），
/// 不勾边就只剩一团糊掉的色块。用户 2026-10-22 要「明确的实体」，
/// 落地做法就是这几道 1.2pt 的深木色描边 + 塔身与帆叶**一深一浅**。
private struct WindmillFigure: View {

    let theme: ForestTheme
    /// 融天比例（0…1）：越远越接近天空色。
    let haze: CGFloat
    let angle: Double

    private var lineWidth: CGFloat { 1.2 }

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            let tower = theme.windmillTower.hazed(haze, into: theme.aerialHaze)
            let roof = theme.windmillRoof.hazed(haze, into: theme.aerialHaze)
            let sail = theme.windmillBlade.hazed(haze, into: theme.aerialHaze)
            let wood = theme.windmillFrame.hazed(haze, into: theme.aerialHaze)
            ZStack(alignment: .top) {
                // 塔身（下宽上窄的梯形）
                WindmillTowerShape()
                    .fill(tower)
                    .overlay(WindmillTowerShape().stroke(wood, lineWidth: lineWidth))
                    .frame(width: w, height: h * 0.86)
                    .offset(y: h * 0.14)

                // 红瓦顶
                WindmillRoofShape()
                    .fill(roof)
                    .overlay(WindmillRoofShape().stroke(wood, lineWidth: lineWidth))
                    .frame(width: w * 0.94, height: h * 0.20)

                // 小窗：读得出这是有人住的房子，不是一座塔
                RoundedRectangle(cornerRadius: min(w, h) * 0.03)
                    .fill(sail.opacity(0.92))
                    .overlay(
                        RoundedRectangle(cornerRadius: min(w, h) * 0.03)
                            .stroke(wood, lineWidth: lineWidth * 0.6)
                    )
                    .frame(width: w * 0.24, height: h * 0.13)
                    .position(x: w / 2, y: h * 0.60)

                // 四片帆叶：绕塔顶那根轴转
                WindmillSailsShape()
                    .fill(sail)
                    .overlay(WindmillSailsShape().stroke(wood, lineWidth: lineWidth))
                    .frame(width: h * 0.66, height: h * 0.66)
                    .rotationEffect(.degrees(angle))
                    .position(x: w / 2, y: h * 0.19)
            }
            .frame(width: w, height: h, alignment: .top)
        }
    }
}

// MARK: - 画法

/// 塔身：底宽顶窄的梯形。
private struct WindmillTowerShape: Shape {
    func path(in rect: CGRect) -> Path {
        let topWidth = rect.width * 0.64
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX - topWidth / 2, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX + topWidth / 2, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// 红瓦顶：一个略带弧度的圆锥。
private struct WindmillRoofShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY),
                          control: CGPoint(x: rect.minX + rect.width * 0.16,
                                           y: rect.minY + rect.height * 0.42))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                          control: CGPoint(x: rect.maxX - rect.width * 0.16,
                                           y: rect.minY + rect.height * 0.42))
        path.closeSubpath()
        return path
    }
}

/// 四片帆叶：从轴心向四个方向伸出的细长木栅。
private struct WindmillSailsShape: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let reach = min(rect.width, rect.height) / 2
        let halfWidth = reach * 0.17
        var path = Path()
        for index in 0..<4 {
            let angle = Double(index) * .pi / 2
            let dir = CGPoint(x: cos(angle), y: sin(angle))
            let perp = CGPoint(x: -sin(angle), y: cos(angle))
            let inner = reach * 0.16
            let a = CGPoint(x: center.x + dir.x * inner + perp.x * halfWidth,
                            y: center.y + dir.y * inner + perp.y * halfWidth)
            let b = CGPoint(x: center.x + dir.x * reach + perp.x * halfWidth,
                            y: center.y + dir.y * reach + perp.y * halfWidth)
            let c = CGPoint(x: center.x + dir.x * reach - perp.x * halfWidth,
                            y: center.y + dir.y * reach - perp.y * halfWidth)
            let d = CGPoint(x: center.x + dir.x * inner - perp.x * halfWidth,
                            y: center.y + dir.y * inner - perp.y * halfWidth)
            path.move(to: a)
            path.addLine(to: b)
            path.addLine(to: c)
            path.addLine(to: d)
            path.closeSubpath()
        }
        return path
    }
}

private extension Color {

    /// 按融天比例朝霾色收敛（大气透视的「远」）。
    ///
    /// 走 `ForestAerialPerspective`（与山丘同一把尺），而不是各层自己调透明度：
    /// 透明度只改「淡」，改不出「发灰、被天空照亮」——那才是远。
    func hazed(_ amount: CGFloat, into haze: Color) -> Color {
        guard amount > 0 else { return self }
        guard let base = NSColor(self).usingColorSpace(.sRGB),
              let hazeNS = NSColor(haze).usingColorSpace(.sRGB) else { return self }
        let channels = [base.redComponent, base.greenComponent, base.blueComponent]
        let hazeChannels = [hazeNS.redComponent, hazeNS.greenComponent, hazeNS.blueComponent]
        let mixed = (0..<3).map { index in
            channels[index] + (hazeChannels[index] - channels[index]) * amount
        }
        return Color(.sRGB, red: mixed[0], green: mixed[1], blue: mixed[2],
                     opacity: Double(base.alphaComponent))
    }
}
