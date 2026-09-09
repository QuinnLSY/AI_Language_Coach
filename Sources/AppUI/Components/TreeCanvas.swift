import AIDomain
import SwiftUI

/// 向参天大树攀升的闯关画布。关卡数据来自 `LearnerProgress`，UI 不内置业务数据。
public struct TreeCanvas: View {

    let theme: ForestTheme
    let progress: LearnerProgress
    var onSelectLevel: (TreeLevel) -> Void = { _ in }

    private let canvasHeight: CGFloat = 1080
    private let groundHeight: CGFloat = 120

    public init(theme: ForestTheme, progress: LearnerProgress, onSelectLevel: @escaping (TreeLevel) -> Void = { _ in }) {
        self.theme = theme
        self.progress = progress
        self.onSelectLevel = onSelectLevel
    }

    public var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let midX = width / 2
            let baseY = canvasHeight - groundHeight
            let currentLevelID = Self.currentLevelID(progress)

            ZStack(alignment: .topLeading) {
                // 树干
                TrunkShape()
                    .fill(
                        LinearGradient(
                            colors: [theme.trunk, theme.trunkShade],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: width, height: canvasHeight)

                // 树冠
                Canopy(theme: theme)
                    .frame(width: width, height: 300)
                    .offset(y: 20)

                // 树枝 + 关卡节点
                ForEach(progress.levels) { level in
                    let y = Self.y(for: level.heightFraction, baseY: baseY)
                    let side: CGFloat = level.branch == .left ? -1 : 1
                    let nodeX = midX + side * (width * 0.30)

                    BranchShape(from: CGPoint(x: midX, y: y), to: CGPoint(x: nodeX, y: y), side: side)
                        .stroke(theme.trunkShade, style: StrokeStyle(lineWidth: 7, lineCap: .round))

                    LevelNode(level: level, theme: theme, isCurrent: level.id == currentLevelID)
                        .position(x: nodeX, y: y)
                        .onTapGesture { onSelectLevel(level) }
                }

                // 藤蔓叶子点缀
                Leaves(theme: theme)
                    .frame(width: width, height: canvasHeight)

                // 攀登者
                CuteAnimalView(kind: .fox, isSleeping: false, size: 62)
                    .position(x: midX, y: Self.y(for: progress.climbFraction, baseY: baseY) - 34)
                    .animation(.spring(response: 0.8, dampingFraction: 0.7), value: progress.climbFraction)

                // 地面与林间动物
                GroundScene(theme: theme)
                    .frame(width: width, height: groundHeight + 40)
                    .offset(y: baseY - 20)
            }
            .frame(width: width, height: canvasHeight)
        }
        .frame(height: canvasHeight)
    }

    private static func y(for fraction: Double, baseY: CGFloat) -> CGFloat {
        let topY: CGFloat = 210
        let clamped = min(max(fraction, 0), 1)
        return baseY - (baseY - topY) * clamped
    }

    private static func currentLevelID(_ progress: LearnerProgress) -> String {
        (progress.levels.first { $0.state == .inProgress } ?? progress.levels.first)?.id ?? ""
    }
}

// MARK: - 树干 / 树冠

private struct TrunkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let bottomWidth = rect.width * 0.24
        let topWidth = rect.width * 0.10
        var path = Path()
        path.move(to: CGPoint(x: rect.midX - bottomWidth / 2, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX - topWidth / 2, y: rect.minY + 130),
            control: CGPoint(x: rect.midX - bottomWidth * 0.44, y: rect.midY)
        )
        path.addLine(to: CGPoint(x: rect.midX + topWidth / 2, y: rect.minY + 130))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX + bottomWidth / 2, y: rect.maxY),
            control: CGPoint(x: rect.midX + bottomWidth * 0.44, y: rect.midY)
        )
        path.closeSubpath()
        return path
    }
}

private struct Canopy: View {
    let theme: ForestTheme
    @State private var sway = false

    var body: some View {
        ZStack {
            Circle().fill(theme.foliageDeep).frame(width: 250, height: 210).offset(x: -70, y: 40)
            Circle().fill(theme.foliageDeep).frame(width: 230, height: 190).offset(x: 78, y: 56)
            Circle().fill(theme.foliage).frame(width: 210, height: 180).offset(x: -20, y: 8)
            Circle().fill(theme.foliage).frame(width: 170, height: 150).offset(x: 66, y: -6)
            Circle().fill(theme.foliage.opacity(0.9)).frame(width: 150, height: 130).offset(x: -84, y: -14)
        }
        .rotationEffect(.degrees(sway ? 1.6 : -1.6), anchor: .bottom)
        .animation(.easeInOut(duration: 5.5).repeatForever(autoreverses: true), value: sway)
        .onAppear { sway = true }
    }
}

private struct BranchShape: Shape {
    let from: CGPoint
    let to: CGPoint
    let side: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        path.addQuadCurve(
            to: to,
            control: CGPoint(x: from.x + side * abs(to.x - from.x) * 0.45, y: from.y - 34)
        )
        return path
    }
}

private struct Leaves: View {
    let theme: ForestTheme

    private static let placements: [(Double, Double, Double)] = [
        (0.12, 0.44, -18), (0.20, 0.62, 22), (0.30, 0.38, -12),
        (0.42, 0.70, 16), (0.55, 0.50, -24), (0.68, 0.64, 14),
        (0.78, 0.42, -16), (0.88, 0.58, 20),
    ]

    var body: some View {
        GeometryReader { proxy in
            ForEach(0..<Self.placements.count, id: \.self) { index in
                let item = Self.placements[index]
                LeafShape()
                    .fill(theme.foliage.opacity(0.85))
                    .frame(width: 26, height: 14)
                    .rotationEffect(.degrees(item.2))
                    .position(
                        x: proxy.size.width / 2 + CGFloat(item.0 - 0.5) * proxy.size.width * 0.22,
                        y: proxy.size.height * item.1
                    )
            }
        }
    }
}

private struct LeafShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY), control: CGPoint(x: rect.midX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.midY), control: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

// MARK: - 关卡节点

private struct LevelNode: View {
    let level: TreeLevel
    let theme: ForestTheme
    let isCurrent: Bool

    var body: some View {
        ZStack {
            if isCurrent {
                Circle()
                    .stroke(theme.accent, lineWidth: 3)
                    .frame(width: 76, height: 76)
                    .scaleEffect(isCurrent ? 1.0 : 0.9)
            }

            Circle()
                .fill(fill)
                .frame(width: 58, height: 58)
                .overlay(
                    Circle()
                        .strokeBorder(border, lineWidth: 2.5)
                )
                .shadow(color: theme.shadow, radius: 6, x: 0, y: 3)

            VStack(spacing: 2) {
                if level.state == .locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(iconColor)
                }
                Text("\(level.earnedStars)/\(level.requiredStars)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(iconColor.opacity(0.9))
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 1) {
                Text(level.title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Text(level.subtitle)
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
            .fixedSize()
            .offset(y: 46)
        }
    }

    private var fill: Color {
        switch level.state {
        case .locked: theme.surfaceAlt
        case .unlocked: theme.surface
        case .inProgress: theme.accent.opacity(0.9)
        case .completed: Color(hex: 0x8FD694)
        }
    }

    private var border: Color {
        level.state == .locked ? theme.divider : theme.accentAlt
    }

    private var iconName: String {
        switch level.state {
        case .completed: "star.fill"
        case .inProgress: "flame.fill"
        default: "leaf.fill"
        }
    }

    private var iconColor: Color {
        level.state == .inProgress ? .white : theme.primaryText
    }
}

// MARK: - 地面

private struct GroundScene: View {
    let theme: ForestTheme

    var body: some View {
        ZStack(alignment: .bottom) {
            HillCap()
                .fill(theme.hillNear)
                .frame(height: 90)

            HStack(alignment: .bottom, spacing: 14) {
                CuteAnimalView(kind: .rabbit, isSleeping: theme.isNight, size: 54)
                CuteAnimalView(kind: .squirrel, isSleeping: theme.isNight, size: 46)
                CuteAnimalView(kind: .hedgehog, isSleeping: theme.isNight, size: 44)
                CuteAnimalView(kind: .owl, isSleeping: theme.isNight, size: 50)
            }
            .offset(y: -6)

            // 草丛
            HStack(spacing: 22) {
                ForEach(0..<16, id: \.self) { _ in
                    Capsule()
                        .fill(theme.foliage.opacity(0.75))
                        .frame(width: 3, height: 16)
                }
            }
            .offset(y: -2)
            .opacity(0.6)
        }
        .frame(maxWidth: .infinity)
    }

    private struct HillCap: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.maxY),
                control: CGPoint(x: rect.midX, y: rect.minY - 12)
            )
            path.closeSubpath()
            return path
        }
    }
}
