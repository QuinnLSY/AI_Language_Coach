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
                        .padding(.top, 44)
                }
                if !ambientStill {
                    Fireflies()
                }
            } else {
                if showsCelestial {
                    SunView(theme: theme, still: ambientStill)
                        .frame(width: 130, height: 130)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(.trailing, 64)
                        .padding(.top, 44)
                }
                if !ambientStill {
                    Clouds()
                }
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
    @State private var drift = false

    var body: some View {
        ZStack {
            Cloud(scale: 1.0, opacity: 0.95).offset(x: drift ? 60 : -40, y: -210).padding(.leading, 90)
            Cloud(scale: 0.7, opacity: 0.8).offset(x: drift ? -50 : 40, y: -280).padding(.leading, 320)
            Cloud(scale: 0.55, opacity: 0.7).offset(x: drift ? 40 : -30, y: -170).padding(.leading, 520)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .loopAnimation(.easeInOut(duration: 26).repeatForever(autoreverses: true), value: drift)
        .onAppear { drift = true }
    }

    struct Cloud: View {
        let scale: CGFloat
        let opacity: Double
        var body: some View {
            ZStack {
                Capsule().fill(.white.opacity(opacity)).frame(width: 120 * scale, height: 38 * scale)
                Circle().fill(.white.opacity(opacity)).frame(width: 52 * scale, height: 52 * scale).offset(x: -26 * scale, y: -12 * scale)
                Circle().fill(.white.opacity(opacity)).frame(width: 42 * scale, height: 42 * scale).offset(x: 22 * scale, y: -15 * scale)
            }
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

private struct Hills: View {
    let theme: ForestTheme
    var body: some View {
        ZStack(alignment: .bottom) {
            HillShape(bump: 0.55).fill(theme.hillFar).frame(height: 150)
            HillShape(bump: 0.42).fill(theme.hillMid).frame(height: 112)
            HillShape(bump: 0.30).fill(theme.hillNear).frame(height: 78)
        }
        .frame(height: 150)
        .frame(maxWidth: .infinity)
    }
}

private struct HillShape: Shape {
    let bump: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let midX = rect.midX
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: midX, y: rect.maxY - rect.height * bump),
            control: CGPoint(x: midX * 0.45, y: rect.maxY - rect.height * bump * 1.25)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - rect.height * bump * 0.45),
            control: CGPoint(x: midX * 1.55, y: rect.maxY - rect.height * bump * 1.05)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - 确定性随机（保证星图稳定不闪烁重排）

private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let value = (state >> 11) & UInt64(1 << 24 - 1)
        return Double(value) / Double(1 << 24)
    }
}
