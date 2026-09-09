import AIDomain
import SwiftUI

/// 向参天大树攀升的闯关画布。关卡数据来自 `LearnerProgress`，UI 不内置业务数据。
public struct TreeCanvas: View {

    let theme: ForestTheme
    let progress: LearnerProgress
    /// 小学员形象（沿树攀爬的学员，戴红领巾；可点击说话）。
    let studentAnimal: AnimalKind
    var onSelectLevel: (TreeLevel) -> Void = { _ in }

    private let canvasHeight: CGFloat = 1080
    private let groundHeight: CGFloat = 120

    public init(theme: ForestTheme, progress: LearnerProgress, studentAnimal: AnimalKind = .bear,
                onSelectLevel: @escaping (TreeLevel) -> Void = { _ in }) {
        self.theme = theme
        self.progress = progress
        self.studentAnimal = studentAnimal
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

                // 小学员（攀爬者）：戴红领巾、可点击说话；随进度沿树干上下。
                TalkingAnimal(
                    kind: studentAnimal,
                    isSleeping: theme.isNight,
                    size: 64,
                    accessory: .student,
                    phrases: studentAnimal.phrases
                )
                .position(x: midX, y: Self.y(for: progress.climbFraction, baseY: baseY) - 36)
                .animation(.spring(response: 0.8, dampingFraction: 0.7), value: progress.climbFraction)
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

// MARK: - 林间地面带（固定吸附在成长之树面板底部，不随树滚动，居民始终可见可点）

struct ForestGroundBand: View {
    let theme: ForestTheme

    /// 稳定伪随机（同 index/salt 永远同值），保证布局不随重绘跳动。
    private func pr(_ index: Int, _ salt: Int) -> CGFloat {
        let x = sin(Double(index * 137 + salt * 61)) * 43758.5453
        let frac = x - floor(x)
        return CGFloat(frac)
    }

    /// 居民数量随宽度增减：300 → 3 只，~500 → 6 只，越宽越多；上限物种数 8。
    private func residentCount(_ width: CGFloat) -> Int {
        min(max(Int((width - 120) / 70) + 1, 3), 8)
    }

    /// 按宽度取前 N 只物种：伪随机打乱 8 个物种，前 N 个各不相同。
    private func speciesOrder() -> [AnimalKind] {
        let all = AnimalKind.allCases
        var order = all
        for i in stride(from: all.count - 1, through: 1, by: -1) {
            let j = Int(pr(i, 11) * CGFloat(i + 1))
            order.swapAt(i, min(j, i))
        }
        return order
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            // 草坡表面（相对本视图坐标）；动物站在坡面上，前后两排错落。
            let groundLine: CGFloat = height - 34
            let count = residentCount(width)
            let inset: CGFloat = 74
            let step = max(46, (width - inset * 2) / CGFloat(max(1, count - 1)))
            let order = speciesOrder()

            ZStack(alignment: .bottomLeading) {
                // 草坡
                HillCap()
                    .fill(theme.hillNear)
                    .frame(height: 96)

                // 远处草丛（密度随宽度）
                ForEach(0..<min(9 + Int(width / 26), 30), id: \.self) { i in
                    grassBlade(x: inset + CGFloat(i) / 29 * (width - inset * 2),
                               h: 9 + pr(i, 1) * 11,
                               w: 2.6 + pr(i, 2) * 1.6,
                               groundLine: groundLine)
                }

                // 灌木丛（增加层次，压住“排排站”的感觉）
                ForEach(0..<min(1 + Int(width / 190), 4), id: \.self) { i in
                    bush(x: inset + pr(i, 12) * (width - inset * 2),
                         groundLine: groundLine,
                         seed: i)
                }

                // 小花（错落 + 三种花色）
                ForEach(0..<min(2 + Int(width / 150), 7), id: \.self) { i in
                    flower(x: inset + pr(i, 8) * (width - inset * 2),
                           groundLine: groundLine,
                           palette: i % 3)
                }

                // 林间居民：各物种独立个体，朝向/大小/站位/动与静各不相同
                ForEach(0..<count, id: \.self) { i in
                    resident(
                        kind: order[i % order.count],
                        index: i,
                        x: inset + CGFloat(i) * step + (pr(i, 4) - 0.5) * 26,
                        groundLine: groundLine,
                        width: width
                    )
                }
            }
            .frame(width: width, height: height, alignment: .bottomLeading)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 花草

    private func grassBlade(x: CGFloat, h: CGFloat, w: CGFloat, groundLine: CGFloat) -> some View {
        Capsule()
            .fill(theme.foliage.opacity(0.7))
            .frame(width: w, height: h)
            .rotationEffect(.degrees(Double((pr(Int(x), 6) - 0.5) * 24)))
            .position(x: x, y: groundLine - h / 2 + 3)
    }

    private func flower(x: CGFloat, groundLine: CGFloat, palette: Int) -> some View {
        let color: Color = palette == 0 ? Color(hex: 0xFF9BB5)
            : palette == 1 ? Color(hex: 0xFFF0B8)
            : Color(hex: 0xFFFFFF)
        return ZStack {
            ForEach(0..<5, id: \.self) { petal in
                Ellipse()
                    .fill(color)
                    .frame(width: 4.4, height: 3.0)
                    .offset(y: -3.2)
                    .rotationEffect(.degrees(Double(petal) * 72))
            }
            Circle()
                .fill(Color(hex: 0xF7B32B))
                .frame(width: 4, height: 4)
        }
        .position(x: x, y: groundLine - 8)
        .opacity(0.95)
    }

    // MARK: 灌木

    private func bush(x: CGFloat, groundLine: CGFloat, seed: Int) -> some View {
        let s: CGFloat = 26 + pr(seed, 13) * 14
        return ZStack {
            Circle().fill(theme.foliage.opacity(0.9)).frame(width: s, height: s * 0.82)
            Circle().fill(theme.foliageDeep.opacity(0.85))
                .frame(width: s * 0.72, height: s * 0.6)
                .offset(x: s * 0.42, y: s * 0.08)
            Circle().fill(theme.foliage.opacity(0.8))
                .frame(width: s * 0.6, height: s * 0.5)
                .offset(x: -s * 0.45, y: s * 0.1)
        }
        .position(x: x, y: groundLine - s * 0.32)
        .opacity(0.95)
    }

    // MARK: 居民个体

    private func resident(kind: AnimalKind, index: Int, x: CGFloat, groundLine: CGFloat, width: CGFloat) -> some View {
        // 前排大、后排小：用伪随机决定“深度”，再按深度给大小与站位
        let depth = pr(index, 14)               // 0(远) ... 1(近)
        let base = min(54, 28 + width * 0.045) * (0.72 + depth * 0.42)
        let size = base * (0.94 + pr(index, 5) * 0.14)
        let facing: CGFloat = pr(index, 3) > 0.5 ? 1 : -1
        let bobbing = pr(index, 7) > 0.38 && !theme.isNight
        let y = groundLine - size * 0.5 - depth * 10 + pr(index, 9) * 6

        return ZStack {
            // 脚底阴影（落到脚部而不是身体中心）
            Ellipse()
                .fill(theme.shadow)
                .frame(width: size * 0.92, height: size * 0.15)
                .offset(y: size * 0.42)

            TalkingAnimal(
                kind: kind,
                isSleeping: theme.isNight,
                size: size,
                bobbing: bobbing,
                facing: facing,
                phrases: kind.phrases
            )
        }
        .position(x: x, y: y)
        .zIndex(Double(Int(depth * 10)))
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
