import SwiftUI

/// 森林天空：**白天**（太阳 / 云朵 / 明亮林冠）与**夜晚**（月亮 / 星星 / 萤火虫）。
public struct ForestSky: View {

    let theme: ForestTheme

    public init(theme: ForestTheme) { self.theme = theme }

    public var body: some View {
        ZStack {
            LinearGradient(colors: theme.sky, startPoint: .top, endPoint: .bottom)

            if theme.isNight {
                StarsField()
                MoonGlow(theme: theme)
                    .frame(width: 120, height: 120)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.trailing, 64)
                    .padding(.top, 44)
                Fireflies()
            } else {
                SunView(theme: theme)
                    .frame(width: 130, height: 130)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.trailing, 64)
                    .padding(.top, 44)
                Clouds()
            }

            VStack {
                Spacer(minLength: 0)
                Hills(theme: theme)
            }
        }
        .clipped()
    }
}

// MARK: - 白天

private struct SunView: View {
    let theme: ForestTheme
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle()
                .fill(theme.accent.opacity(0.22))
                .frame(width: 130, height: 130)
            Circle()
                .fill(theme.accent.opacity(0.35))
                .frame(width: 96, height: 96)
            Circle()
                .fill(
                    RadialGradient(colors: [Color(hex: 0xFFF0B8), theme.accent],
                                   center: .center, startRadius: 4, endRadius: 40)
                )
                .frame(width: 68, height: 68)

            ForEach(0..<12, id: \.self) { index in
                Capsule()
                    .fill(theme.accent.opacity(0.75))
                    .frame(width: 5, height: 16)
                    .offset(y: -54)
                    .rotationEffect(.degrees(Double(index) * 30))
            }
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 60).repeatForever(autoreverses: false), value: spin)
        }
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
        .animation(.easeInOut(duration: 26).repeatForever(autoreverses: true), value: drift)
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
            Circle().fill(theme.accent.opacity(0.16)).frame(width: 130, height: 130)
            Circle().fill(theme.accent.opacity(0.22)).frame(width: 96, height: 96)
            Circle()
                .fill(RadialGradient(colors: [Color(hex: 0xFFFBE8), theme.accent],
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

    @State private var twinkle = false

    var body: some View {
        GeometryReader { proxy in
            ForEach(0..<Self.points.count, id: \.self) { index in
                let point = Self.points[index]
                Circle()
                    .fill(Color(hex: 0xFFF3C4))
                    .frame(width: index % 9 == 0 ? 4 : 2.5, height: index % 9 == 0 ? 4 : 2.5)
                    .position(x: point.x * proxy.size.width, y: point.y * proxy.size.height)
                    .opacity(twinkle ? (index % 3 == 0 ? 0.35 : 0.9) : (index % 3 == 0 ? 0.95 : 0.55))
            }
        }
        .animation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true), value: twinkle)
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
                    .animation(
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
