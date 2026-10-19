import SwiftUI

/// 森林天空：**白天**（太阳 / 云朵 / 明亮林冠）与**夜晚**（月亮 / 星星 / 萤火虫）。
public struct ForestSky: View {

    let theme: ForestTheme
    /// 是否绘制太阳 / 月亮装饰。
    /// 右上角的天体同时是「日夜切换」控件（见 `CelestialToggle`）：由主界面把它画在内容层之上，
    /// 因此这里传 `false`，避免同一位置出现两个天体（一个不可点、一个可点）。
    var showsCelestial: Bool
    /// 氛围演出隐藏档（批次六 · E「连点天空 5 次」触发）：云、萤火虫收起来，
    /// 星星不眨眼、太阳光环不转 —— 林子进入完全安静的静态。
    /// 会话级状态（`ForestStage.ambientHidden`），重启恢复默认演出。
    var ambientStill: Bool

    public init(theme: ForestTheme, showsCelestial: Bool = true, ambientStill: Bool = false) {
        self.theme = theme
        self.showsCelestial = showsCelestial
        self.ambientStill = ambientStill
    }

    /// 今天有没有降水（雨 / 雪）—— 云量密度的判据。
    ///
    /// 天气档位收窄后「多云」没有了：真实世界里雨雪天本就少见晴空白云，
    /// 所以「有降水 = 云更密」，晴天才是基础三朵云。
    private var hasPrecipitation: Bool {
        theme.weather == .rain || theme.weather == .snow
    }

    public var body: some View {
        ZStack {
            LinearGradient(colors: theme.sky, startPoint: .top, endPoint: .bottom)

            if theme.isNight {
                StarsField(still: ambientStill)
                if showsCelestial {
                    MoonGlow(theme: theme)
                        .frame(width: 120, height: 120)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(.trailing, 64)
                        .appPadding(.top, 44)
                }
                if !ambientStill {
                    Fireflies()
                    // 有降水的天（雨 / 雪）云更密：夜里也要**看得出云** ——
                    // 设置里写着「今天下雨」，白天那一档的白云挂到夜空上像贴纸，
                    // 这里换成被月光照亮的冷灰蓝。
                    Clouds(dense: hasPrecipitation, tint: Color(hex: 0x5F7391))
                }
            } else {
                if showsCelestial {
                    SunView(theme: theme, still: ambientStill)
                        .frame(width: 130, height: 130)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(.trailing, 64)
                        .appPadding(.top, 44)
                }
                if !ambientStill {
                    // 有降水的天（雨 / 雪）云量加一倍 —— 还是同一朵云的形状，只是天更挤。
                    Clouds(dense: hasPrecipitation)
                }
            }

            // 雨（#418-A）：日夜都下，颜色跟 `theme.rainColor` 走；
            // 静态档（连点天空 5 次）整个雨层也收 —— 「林子完全安静」包含雨停。
            if theme.weather == .rain, !ambientStill {
                RainLayer(color: theme.rainColor)
            }

            // 雪（2026-10 收窄天气档位时新增）：与雨同构，只是粒是圆的、落得更慢，
            // 颜色跟 `theme.snowColor` 走；静态档同样整层收。
            if theme.weather == .snow, !ambientStill {
                SnowLayer(color: theme.snowColor)
            }

            VStack {
                Spacer(minLength: 0)
                Hills(theme: theme)
            }
        }
        .clipped()
        // 天空整体（云 / 星 / 萤火虫 / 山丘）是纯氛围装饰：VoiceOver 扫到 70 颗无名星星
        // 只会淹没真正的控件。日夜切换走 CelestialToggle（独立控件，在内容层，不受这里影响）。
        .accessibilityHidden(true)
    }
}

// MARK: - 右上角天体（同时是日夜切换按钮）

/// 右上角的太阳 / 月亮组件：**点击或拖拽都能切换日夜**（批次六 · E）。
/// - 白天显示太阳 → 点击 / 往下拖过阈值进入夜晚；
/// - 夜晚显示月亮 → 点击 / 往上拖过阈值回到白天。
/// 视觉与天空里的天体完全一致（同一份 `SunView` / `MoonGlow`），另外叠一圈 hover 光环提示可点。
public struct CelestialToggle: View {

    @Environment(\.forestTheme) private var theme
    let action: () -> Void
    /// 氛围演出隐藏档下太阳的光环不转（与 `ForestSky` 的静态档同一份状态）。
    var spins: Bool

    @State private var hovering = false
    /// 拖拽中的视觉位移（已按方向钳制；松手弹回 0）。
    @State private var dragHeight: CGFloat = 0

    public init(action: @escaping () -> Void, spins: Bool = true) {
        self.action = action
        self.spins = spins
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                if theme.isNight {
                    MoonGlow(theme: theme).frame(width: 120, height: 120)
                } else {
                    SunView(theme: theme, still: !spins).frame(width: 130, height: 130)
                }

                // hover 反馈：一圈淡淡的光环（不改变天体本身的形状）
                Circle()
                    .strokeBorder(theme.accent.opacity(hovering ? 0.55 : 0), lineWidth: 2)
                    .frame(width: 112, height: 112)
            }
            .frame(width: 130, height: 130)
            .scaleEffect(hovering ? 1.06 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(.appPressable)
        .onHover { hovering = $0 }
        .appAnimation(.reveal, value: hovering)
        // 拖拽（E·可玩彩蛋）：白天往下拖太阳、夜里往上拖月亮，过阈值松手即切换。
        // simultaneousGesture 让轻点（位移 < minimumDistance）仍然走按钮那条路。
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    dragHeight = ForestAtmosphere.clampedDragOffset(
                        isNight: theme.isNight, dragHeight: value.translation.height)
                }
                .onEnded { value in
                    let shouldToggle = ForestAtmosphere.shouldToggleByDrag(
                        isNight: theme.isNight, dragHeight: value.translation.height)
                    withAnimation(.app(.panel)) { dragHeight = 0 }
                    if shouldToggle { action() }
                }
        )
        .offset(y: dragHeight)
        .help(theme.isNight ? "点击或往上拖回白天" : "点击或往下拖进夜晚")
        .accessibilityLabel(theme.isNight ? "切换到白天" : "切换到夜晚")
    }
}

// MARK: - 白天

/// 氛围演出隐藏档的开关（纯函数，便于单测）：连点天空 5 次收起演出时，
/// 星星 / 太阳光环**当场**停 —— 「林子完全安静」这句承诺只有这一处判据。
///
/// ⚠️ 2026-09-30 审查修掉的一处：早先写成 `onAppear { if !still { spin = true } }` ——
/// `still` 只在视图出现那一瞬被读一次，之后切静态档，动画值还是 `true`，光环照转、
/// 星星照眨（云与萤火虫是整层移除所以没事，只有这两处是「靠动画值停」）。
/// 现在把 `still` 直接乘进动画的 `value`：档位一变，动画的驱动值就变，切换即停。
enum AmbientMotion {
    static func animates(armed: Bool, still: Bool) -> Bool { armed && !still }
}

private struct SunView: View {
    let theme: ForestTheme
    /// 静态档（氛围演出隐藏）：光环不转。
    var still: Bool = false
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle()
                .fill(theme.glow.opacity(0.22))
                .frame(width: 130, height: 130)
            Circle()
                .fill(theme.glow.opacity(0.35))
                .frame(width: 96, height: 96)
            Circle()
                .fill(
                    RadialGradient(colors: [Color(hex: 0xFFF0B8), theme.glow],
                                   center: .center, startRadius: 4, endRadius: 40)
                )
                .frame(width: 68, height: 68)

            ForEach(0..<12, id: \.self) { index in
                Capsule()
                    .fill(theme.glow.opacity(0.75))
                    .frame(width: 5, height: 16)
                    .offset(y: -54)
                    .rotationEffect(.degrees(Double(index) * 30))
            }
            .rotationEffect(.degrees(AmbientMotion.animates(armed: spin, still: still) ? 360 : 0))
            .loopAnimation(
                .linear(duration: 60).repeatForever(autoreverses: false),
                value: AmbientMotion.animates(armed: spin, still: still)
            )
        }
        // ⚠️ 无条件置 true：静态档由上面的 `animates` 拦，不是靠这里不启动。
        // （早先在这里判 `if !still`，切档时视图不会重新 appear，永远拦不住。）
        .onAppear { spin = true }
    }
}

private struct Clouds: View {
    /// 降水档（#418-A 的多云档收窄而来）：在基础三朵之上再添三朵 ——
    /// 还是同一套云的形状，只是天更挤。判据是「今天有降水」而非单独的天气档位。
    var dense: Bool = false
    /// 云的着色（夜里不能是白的：白云挂在夜空上像贴纸，见 `ForestSky` 夜间分支）。
    var tint: Color = .white
    @State private var drift = false

    var body: some View {
        ZStack {
            Cloud(scale: 1.0, opacity: 0.95, tint: tint).offset(x: drift ? 60 : -40, y: -210).padding(.leading, 90)
            Cloud(scale: 0.7, opacity: 0.8, tint: tint).offset(x: drift ? -50 : 40, y: -280).padding(.leading, 320)
            Cloud(scale: 0.55, opacity: 0.7, tint: tint).offset(x: drift ? 40 : -30, y: -170).padding(.leading, 520)
            if dense {
                Cloud(scale: 0.9, opacity: 0.9, tint: tint).offset(x: drift ? 30 : -20, y: -240).padding(.leading, 210)
                Cloud(scale: 0.65, opacity: 0.85, tint: tint).offset(x: drift ? -35 : 25, y: -185).padding(.leading, 430)
                Cloud(scale: 0.75, opacity: 0.9, tint: tint).offset(x: drift ? 45 : -45, y: -300).padding(.leading, 620)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .loopAnimation(.easeInOut(duration: 26).repeatForever(autoreverses: true), value: drift)
        .onAppear { drift = true }
    }

    struct Cloud: View {
        let scale: CGFloat
        let opacity: Double
        var tint: Color = .white
        var body: some View {
            ZStack {
                Capsule().fill(tint.opacity(opacity)).frame(width: 120 * scale, height: 38 * scale)
                Circle().fill(tint.opacity(opacity)).frame(width: 52 * scale, height: 52 * scale).offset(x: -26 * scale, y: -12 * scale)
                Circle().fill(tint.opacity(opacity)).frame(width: 42 * scale, height: 42 * scale).offset(x: 22 * scale, y: -15 * scale)
            }
        }
    }
}

// MARK: - 雨（#418-A）

/// 雨丝层：细长胶囊从天而降（各自错峰、匀速下落、循环）。日夜共用，
/// 颜色由 `theme.rainColor` 给（夜里暗一档）。位置用种子随机 —— 与星星一样，
/// 布局必须稳定，不能每次布局都换一场新雨。
private struct RainLayer: View {
    let color: Color

    private static let drops: [CGPoint] = {
        var generator = SeededRandom(seed: 20_260_430)
        return (0..<26).map { _ in
            CGPoint(x: Double(generator.next()), y: Double(generator.next()) * 0.72)
        }
    }()

    @State private var falling = false

    private var animates: Bool { AmbientMotion.animates(armed: falling, still: false) }

    var body: some View {
        GeometryReader { proxy in
            ForEach(0..<Self.drops.count, id: \.self) { index in
                let point = Self.drops[index]
                Capsule()
                    .fill(color)
                    .frame(width: 2, height: 13)
                    .position(
                        x: point.x * proxy.size.width,
                        // ⚠️ 行程要**真的跨过天空**（2026-10-01 修）：原先只落 30pt 就
                        // 瞬移回起点，观感是原地抖动，不像下雨。这里按天空高度的六成落。
                        y: point.y * proxy.size.height + (animates ? proxy.size.height * 0.6 : 0)
                    )
                    .opacity(animates ? 0.72 : 0.3)
                    // 匀速直落、不回弹（autoreverses: false）—— 雨不是荡秋千。
                    .loopAnimation(
                        .linear(duration: Double(88 + (index % 5) * 14) / 100)
                            .repeatForever(autoreverses: false),
                        value: animates
                    )
            }
        }
        .onAppear { falling = true }
    }
}

// MARK: - 雪（2026-10 收窄天气档位时新增）

/// 单枚雪片（从 `SnowLayer` 拆出来：整层塞进一个 `ForEach` 会让 Swift 前端
/// 类型检查超时，报「unable to type-check this expression in reasonable time」）。
private struct Snowflake: View {
    let color: Color
    /// 外圈直径（pt）；白芯按 0.73 比例收在里面。
    let size: CGFloat
    var x: CGFloat
    var y: CGFloat
    var swayOffset: CGFloat
    var opacity: Double
    var animates: Bool
    var swaying: Bool
    var fallDuration: Double
    var swayDuration: Double

    var body: some View {
        ZStack {
            // 粒芯：一点纯白 —— 白天淡蓝灰的雪片靠这点白读出「雪」而不是「灰点」
            // （白天空太亮，整片压深就不像雪了；白芯是那个「像」的关键）。
            Circle().fill(.white.opacity(0.85))
                .frame(width: size * 0.73, height: size * 0.73)
            Circle().fill(color)
                .frame(width: size, height: size)
        }
        .position(x: x, y: y)
        // 横向轻摆：雪片小，摆幅也小（±9pt）—— 幅度大了像被风横着吹走。
        .offset(x: swayOffset)
        .opacity(opacity)
        .loopAnimation(
            .easeInOut(duration: swayDuration).repeatForever(autoreverses: true),
            value: swaying
        )
        // 匀速缓落、不回弹 —— 与雨同一套落法，只是慢一半。
        .loopAnimation(
            .linear(duration: fallDuration).repeatForever(autoreverses: false),
            value: animates
        )
    }
}

/// 雪片层：圆点从天缓缓飘落（各自错峰、比雨慢一半，还带一点横向游移 ——
/// 雪不是直直砸下来的）。日夜共用，颜色由 `theme.snowColor` 给。
/// 位置用种子随机 —— 与星星 / 雨一样，布局必须稳定，不能每次布局换一场新雪。
private struct SnowLayer: View {
    let color: Color

    private static let flakes: [CGPoint] = {
        var generator = SeededRandom(seed: 20_261_103)
        return (0..<22).map { _ in
            CGPoint(x: generator.next(), y: generator.next() * 0.72)
        }
    }()

    @State private var falling = false
    @State private var swaying = false

    private var animates: Bool { AmbientMotion.animates(armed: falling, still: false) }

    var body: some View {
        GeometryReader { proxy in
            ForEach(0..<Self.flakes.count, id: \.self) { index in
                let point = Self.flakes[index]
                Snowflake(
                    color: color,
                    // 三档大小错落：一眼望去不是同一枚雪花复制 22 遍。
                    size: 3.2 + CGFloat(index % 3) * 0.6,
                    x: point.x * proxy.size.width,
                    // 行程同样真的跨过天空（与雨同一条 2026-10-01 修出来的判据）：
                    // 按天空高度的五成五落，匀速直落。
                    y: point.y * proxy.size.height + (animates ? proxy.size.height * 0.55 : 0),
                    swayOffset: swaying ? CGFloat((index % 5) - 2) * 9 : 0,
                    opacity: animates ? 0.85 : 0.5,
                    animates: animates,
                    swaying: swaying,
                    fallDuration: Double(160 + (index % 5) * 20) / 100,
                    swayDuration: 2.4 + Double(index % 4) * 0.5
                )
            }
        }
        .onAppear {
            falling = true
            swaying = true
        }
    }
}

// MARK: - 夜晚

private struct MoonGlow: View {
    let theme: ForestTheme
    var body: some View {
        ZStack {
            Circle().fill(theme.glow.opacity(0.16)).frame(width: 130, height: 130)
            Circle().fill(theme.glow.opacity(0.22)).frame(width: 96, height: 96)
            Circle()
                .fill(RadialGradient(colors: [Color(hex: 0xFFFBE8), theme.glow],
                                     center: .center, startRadius: 3, endRadius: 36))
                .frame(width: 62, height: 62)
                .overlay(
                    Circle().fill(theme.sky.last ?? .black).frame(width: 56, height: 56).offset(x: 16, y: -10)
                )
        }
    }
}

private struct StarsField: View {
    private static let points: [CGPoint] = {
        var generator = SeededRandom(seed: 20260909)
        return (0..<70).map { _ in
            CGPoint(x: Double(generator.next()), y: Double(generator.next()) * 0.7)
        }
    }()

    /// 静态档（氛围演出隐藏）：星星挂在那儿但不眨眼。
    var still: Bool = false
    @State private var twinkle = false

    var body: some View {
        GeometryReader { proxy in
            ForEach(0..<Self.points.count, id: \.self) { index in
                let point = Self.points[index]
                Circle()
                    .fill(Color(hex: 0xFFF3C4))
                    .frame(width: index % 9 == 0 ? 4 : 2.5, height: index % 9 == 0 ? 4 : 2.5)
                    .position(x: point.x * proxy.size.width, y: point.y * proxy.size.height)
                    .opacity(still ? 0.75
                        : (twinkle ? (index % 3 == 0 ? 0.35 : 0.9) : (index % 3 == 0 ? 0.95 : 0.55)))
            }
        }
        .loopAnimation(
            .easeInOut(duration: 3.2).repeatForever(autoreverses: true),
            value: AmbientMotion.animates(armed: twinkle, still: still)
        )
        // 同上：静态档由 `animates` 拦在动画的驱动值上，不是靠这里不启动。
        .onAppear { twinkle = true }
    }
}

private struct Fireflies: View {
    private static let points: [CGPoint] = {
        var generator = SeededRandom(seed: 77_777)
        return (0..<14).map { _ in
            CGPoint(x: Double(generator.next()), y: 0.35 + Double(generator.next()) * 0.6)
        }
    }()

    @State private var float = false

    var body: some View {
        GeometryReader { proxy in
            ForEach(0..<Self.points.count, id: \.self) { index in
                let point = Self.points[index]
                Circle()
                    .fill(Color(hex: 0xD8FF8A))
                    .frame(width: 5, height: 5)
                    .shadow(color: Color(hex: 0xD8FF8A), radius: 6)
                    .position(
                        x: point.x * proxy.size.width + (float ? CGFloat(index % 5) * 8 - 16 : 0),
                        y: point.y * proxy.size.height + (float ? -18 : 12)
                    )
                    .opacity(float ? 0.95 : 0.25)
                    // ⚠️ 必须走 `.loopAnimation`（批次七·G）：裸 `.animation(.repeatForever)`
                    // 是 reduceMotion 的法外之地 ——「减弱动态效果」开着它照样飘。
                    .loopAnimation(
                        .easeInOut(duration: Double(3 + index % 4)).repeatForever(autoreverses: true),
                        value: float
                    )
            }
        }
        .onAppear { float = true }
    }
}

// MARK: - 地面

/// 天际线上的三层山丘（画在天空层底部，被半透明的三栏透出来）。
///
/// 从前这里是「另一套山」：自创的双段二次曲线、各自的高度与凸包，和林间地面带的
/// 草坡（`HillCap`）各长各的 —— 同一片屏幕底部出现两条互不相认的山脊线，正是
/// 用户说的「一块一块」。现在三件事统一：
/// 1. **同一条曲线家族**：单段对称二次曲线，与 `ForestSceneGeometry.hillSurfaceY`
///    （草坡的解析孪生）同一族；最近那层的高度直接取 `hillCapHeight`——
///    它的脊线与地面带草坡的脊线**落在同一水平线上**，树栏与聊天栏从此共用一个地平线；
/// 2. **同一根景深轴**：远 / 中 / 近三层按 `farHillDepth` / `midHillDepth` /
///    `nearHillDepth` 过大气透视，最远那层融进天际的霾色，不再是一块饱和绿贴在天上；
/// 3. **同一套常量**：高度差（150 / 120 / 96）只是同一族曲线的三次缩放。
private struct Hills: View {
    let theme: ForestTheme
    var body: some View {
        ZStack(alignment: .bottom) {
            HillShape().fill(
                ForestAerialPerspective.adjust(theme.hillFar,
                                               depth: ForestSceneGeometry.farHillDepth,
                                               haze: theme.aerialHaze)
            ).frame(height: 150)
            HillShape().fill(
                ForestAerialPerspective.adjust(theme.hillMid,
                                               depth: ForestSceneGeometry.midHillDepth,
                                               haze: theme.aerialHaze)
            ).frame(height: 120)
            // 最近那层与林间地面带的草坡**同高同族**：脊线对齐，两栏一个地平线。
            HillShape().fill(
                ForestAerialPerspective.adjust(theme.hillNear,
                                               depth: ForestSceneGeometry.nearHillDepth,
                                               haze: theme.aerialHaze)
            ).frame(height: ForestSceneGeometry.hillCapHeight)
        }
        .frame(height: 150)
        .frame(maxWidth: .infinity)
    }
}

/// 山丘轮廓：单段对称二次曲线（与 `HillCap` / `hillSurfaceY` 同一族）。
/// 鼓包量取控制点超出顶沿的比例（0.125 = `hillCapBulge / hillCapHeight`）——
/// 于是「远处的山与近处的坡是同一种地貌」，只是缩放不同。
private struct HillShape: Shape {
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
// 确定性随机改用地基那份 `SeededRandom`（`ForestScene.swift`）：星图 / 雨 /
// 萤火虫 / 花粉共用同一套伪随机，各写一份迟早出现「同一片林子两种随机器」的割裂。
