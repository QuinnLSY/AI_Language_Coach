import AIDomain
import SwiftUI

/// 向参天大树攀升的闯关画布。关卡数据来自 `LearnerProgress`，UI 不内置业务数据。
public struct TreeCanvas: View {

    let theme: ForestTheme
    let progress: LearnerProgress
    /// 小学员形象（沿树攀爬的学员，戴红领巾；可点击说话）。
    let studentAnimal: AnimalKind
    /// 小学员点击冒泡开关（设置可关）。
    var bubblesAllowed: Bool = true
    var onSelectLevel: (TreeLevel) -> Void = { _ in }

    private let canvasHeight: CGFloat = 1080
    private let groundHeight: CGFloat = 120

    public init(theme: ForestTheme, progress: LearnerProgress, studentAnimal: AnimalKind = .bear,
                bubblesAllowed: Bool = true,
                onSelectLevel: @escaping (TreeLevel) -> Void = { _ in }) {
        self.theme = theme
        self.progress = progress
        self.studentAnimal = studentAnimal
        self.bubblesAllowed = bubblesAllowed
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
    /// 小动物气泡总开关（设置可关）。
    var bubblesAllowed: Bool = true
    /// 实际生效的活动开关（配置 && 白天）。夜晚自动安静。
    var activityAllowed: Bool = true
    /// 活动频率（0...1）：值越大动作间隔越短。
    var activityFrequency: Double = 0.5
    /// 右下角表情按钮回调（与设置里的开关联动）。
    var onActivityToggle: (() -> Void)? = nil

    /// 离场告别语（轮换时随机抽一条）。
    static let leavePhrases = [
        "我先回家吃点心啦～",
        "妈妈叫我回家吃饭！",
        "林子那边好像有好玩的，我去瞧瞧～",
        "拜拜，明天再来找你们玩！",
        "咦，那边的蘑菇好像发芽了，我去看看！",
    ]
    /// 进场打招呼语（轮换时随机抽一条）。
    static let greetPhrases = [
        "嗨～我来了！",
        "你们好呀，我是新搬来的邻居！",
        "嘿！一起玩吗？",
        "刚才在路上捡到一个新单词，分你们一半！",
        "大家好，这里的草真香呀～",
    ]

    /// 当前气泡归属（点击或自发动作）——气泡统一画在带子顶层，永远不被遮挡。
    @State private var speakingIndex: Int?
    @State private var bubbleText: String?
    @State private var bubbleTick = 0
    /// 各居民的**持续位移**：游走后停在新位置，不回原位。
    @State private var offsets: [CGSize] = Array(repeating: .zero, count: Self.maxResidents)
    /// 鸟类是否正栖在枝桠上。
    @State private var perched: [Bool] = Array(repeating: false, count: Self.maxResidents)
    /// 动作触发器（父级递增，LivelyAnimal 变化即执行）。
    @State private var actionTicks: [Int] = Array(repeating: 0, count: Self.maxResidents)
    @State private var actionKinds: [Int] = Array(repeating: 0, count: Self.maxResidents)
    /// 各槽位的物种（轮换：随机离开/进入）。空时用伪随机初始顺序兜底。
    @State private var kinds: [AnimalKind] = []
    /// 各槽位朝向（游走时按移动方向翻转）。
    @State private var facings: [CGFloat] = []

    private static let maxResidents = 8
    // 各类元素的**上限**：始终按上限创建视图，靠透明度控制显隐。
    // 这样拖动分割线时元素不会突然创建/销毁（那正是画面抖动的来源）。
    private let grassCount = 26
    private let maxBushes = 4
    private let maxFlowers = 7

    /// 稳定伪随机（同 index/salt 永远同值），保证布局不随重绘跳动。
    private func pr(_ index: Int, _ salt: Int) -> CGFloat {
        let x = sin(Double(index * 137 + salt * 61)) * 43758.5453
        let frac = x - floor(x)
        return CGFloat(frac)
    }

    /// 居民数量随宽度增减：300 → 3 只，~500 → 6 只，越宽越多；上限物种数 8。
    private func residentCount(_ width: CGFloat) -> Int {
        min(max(Int((width - 120) / 70) + 1, 3), Self.maxResidents)
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
            let inset: CGFloat = 74
            let span = max(1, width - inset * 2)
            // 量化宽度：一切「离散决策」（数量、个体大小）只在 28pt 档位上变化，
            // 连续量（坐标）仍跟随真实宽度平滑移动 —— 消除拖动时的逐帧重排抖动。
            let step: CGFloat = 28
            let qw = (width / step).rounded() * step
            let count = residentCount(qw)
            let bushCount = min(1 + Int(qw / 190), maxBushes)
            let flowerCount = min(2 + Int(qw / 150), maxFlowers)
            let order = speciesOrder()

            ZStack(alignment: .bottomLeading) {
                // 草坡
                HillCap()
                    .fill(theme.hillNear)
                    .frame(height: 96)

                // 远处草丛（固定数量，按宽度均布；倾角只跟 index 走，不随宽度乱跳）
                ForEach(0..<grassCount, id: \.self) { i in
                    grassBlade(x: inset + CGFloat(i) / CGFloat(grassCount - 1) * span,
                               h: 9 + pr(i, 1) * 11,
                               w: 2.6 + pr(i, 2) * 1.6,
                               seed: i,
                               groundLine: groundLine)
                }

                // 灌木丛（增加层次，压住“排排站”的感觉）
                ForEach(0..<maxBushes, id: \.self) { i in
                    bush(x: inset + pr(i, 12) * span,
                         groundLine: groundLine,
                         seed: i)
                        .opacity(i < bushCount ? 1 : 0)
                        .animation(.easeOut(duration: 0.2), value: bushCount)
                }

                // 小花（错落 + 三种花色）
                ForEach(0..<maxFlowers, id: \.self) { i in
                    flower(x: inset + pr(i, 8) * span,
                           groundLine: groundLine,
                           palette: i % 3)
                        .opacity(i < flowerCount ? 1 : 0)
                        .animation(.easeOut(duration: 0.2), value: flowerCount)
                }

                // 树干底部的两根枝桠栖木（鸟类专用；画在树干透出区域的中心两侧）
                perchStubs(width: width, height: height)

                // 林间居民：各物种独立个体，朝向/大小/站位/动与静各不相同
                ForEach(0..<Self.maxResidents, id: \.self) { i in
                    resident(
                        kind: order[i % order.count],
                        index: i,
                        visibleCount: count,
                        span: span,
                        inset: inset,
                        groundLine: groundLine,
                        quantizedWidth: qw
                    )
                }

                // 气泡顶层：永远画在所有居民之上（最新出现的气泡不被任何气泡/动物遮挡）
                if let speaker = speakingIndex, speaker < count, let text = bubbleText {
                    let home = homePosition(index: speaker, count: count, span: span,
                                            inset: inset, groundLine: groundLine, quantizedWidth: qw)
                    SpeechBubble(text: text, maxWidth: 150)
                        .fixedSize()
                        .position(
                            x: home.x + offsets[speaker].width,
                            y: home.y + offsets[speaker].height - home.size * 0.78
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.55, anchor: .bottom)))
                        .zIndex(999)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: width, height: height, alignment: .bottomLeading)
            // 档位切换时让位置/大小平滑过渡，而不是瞬移
            .animation(.easeOut(duration: 0.18), value: qw)
            // 初始化物种/朝向状态（轮换的基础）
            .onAppear { ensureResidents(count: count, order: order) }
            .onChange(of: count) { _, newCount in ensureResidents(count: newCount, order: order) }
            // 活动编排（宽度或活动开关/频率变化时重启循环，取最新几何与开关值）
            .task(id: "\(qw)-\(activityAllowed)-\(activityFrequency)-\(theme.isNight)") {
                async let life: () = orchestrateLife(count: count, span: span, inset: inset,
                                                     groundLine: groundLine, quantizedWidth: qw,
                                                     width: width, order: order)
                async let rotation: () = orchestrateRotation(count: count, span: span, inset: inset,
                                                             groundLine: groundLine, quantizedWidth: qw,
                                                             order: order)
                _ = await (life, rotation)
            }
            // 气泡自动收起（3 秒），被新气泡打断时任务自动重启
            .task(id: bubbleTick) {
                guard speakingIndex != nil else { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    speakingIndex = nil
                    bubbleText = nil
                }
            }
            // 关闭活动（设置开关或入夜）：全体回家排排站好（带过渡动画）
            .onChange(of: activityAllowed) { _, allowed in
                if !allowed { sendEveryoneHome() }
            }
            .onChange(of: theme.isNight) { _, night in
                if night { sendEveryoneHome() }
            }
        }
        .frame(maxWidth: .infinity)
        // 右下角表情按钮：开心 = 允许活动，平静 = 已安静（与设置联动）
        .overlay(alignment: .bottomTrailing) {
            activityButton
        }
    }

    // MARK: 活动编排（唯一的心跳：游走 / 跳 / 摇 / 飞枝）

    private func orchestrateLife(count: Int, span: CGFloat, inset: CGFloat, groundLine: CGFloat,
                                 quantizedWidth: CGFloat, width: CGFloat,
                                 order: [AnimalKind]) async {
        // 个体错峰启动，避免整排动物同时动作
        try? await Task.sleep(for: .seconds(Double.random(in: 3...6)))
        // 动作间隔由活动频率决定：0 → ~12s，1 → ~4s（再叠加随机抖动）
        let interval = (12 - activityFrequency * 8) * Double.random(in: 0.8...1.25)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled, activityAllowed, !theme.isNight else { continue }
            guard count > 0 else { continue }
            let index = Int.random(in: 0..<count)
            let isBird = order[index % order.count] == .owl

            if isBird && !perched[index] && Int.random(in: 0..<10) < 3 {
                // 鸟类：飞上枝桠，停留一阵（期间会小幅挪动），再飞回草地
                await flyToPerch(index, count: count, span: span, inset: inset,
                                 groundLine: groundLine, quantizedWidth: quantizedWidth, width: width)
                // 枝上小憩：随机停留 + 小幅挪动
                let stay = Int.random(in: 1...2)
                for _ in 0..<stay {
                    try? await Task.sleep(for: .seconds(Double.random(in: 4...8)))
                    guard !Task.isCancelled, activityAllowed, !theme.isNight else { break }
                    if Bool.random() { shuffleOnPerch(index, count: count, span: span, inset: inset,
                                                      groundLine: groundLine, quantizedWidth: quantizedWidth, width: width) }
                }
                try? await Task.sleep(for: .seconds(Double.random(in: 3...6)))
                guard !Task.isCancelled else { return }
                await flyBackToGrass(index, count: count, span: span, inset: inset,
                                     groundLine: groundLine, quantizedWidth: quantizedWidth)
            } else if perched[index] {
                // 已在枝上：要么小幅挪动，要么飞回草地
                if Bool.random() {
                    shuffleOnPerch(index, count: count, span: span, inset: inset,
                                   groundLine: groundLine, quantizedWidth: quantizedWidth, width: width)
                } else {
                    await flyBackToGrass(index, count: count, span: span, inset: inset,
                                         groundLine: groundLine, quantizedWidth: quantizedWidth)
                }
            } else {
                // 地面：游走（真位移，不回原位）/ 跳 / 摇
                let roll = Int.random(in: 0..<10)
                if roll < 5 {
                    wander(index, count: count, span: span, inset: inset,
                           groundLine: groundLine, quantizedWidth: quantizedWidth)
                } else if roll < 8 {
                    trigger(index, kind: 0)
                } else {
                    trigger(index, kind: 1)
                }
            }
        }
    }

    /// 触发跳/摇动作。
    private func trigger(_ index: Int, kind: Int) {
        actionKinds[index] = kind
        actionTicks[index] += 1
    }

    /// 地面游走：在草地范围内累计位移（走到哪停在哪），跳动前进，不会走出草坡。
    private func wander(_ index: Int, count: Int, span: CGFloat, inset: CGFloat,
                        groundLine: CGFloat, quantizedWidth: CGFloat) {
        let home = homePosition(index: index, count: count, span: span, inset: inset,
                                groundLine: groundLine, quantizedWidth: quantizedWidth)
        let current = offsets[index]
        // 左右各留出草坡内边距，纵向限制在坡面附近
        let slackLeft = home.x - inset * 0.45
        let slackRight = (inset + span + inset * 0.45) - home.x
        let nx = min(max(current.width + CGFloat.random(in: -24...24), -slackLeft), slackRight)
        let ny = min(max(current.height + CGFloat.random(in: -16...6), -20), 7)
        // 按移动方向转身
        if facings.indices.contains(index), abs(nx - current.width) > 2 {
            facings[index] = nx > current.width ? 1 : -1
        }
        Task { await hopTo(index, target: CGSize(width: nx, height: ny), steps: 3, hopHeight: 7) }
    }

    /// 枝桠位置（相对树干中心对称两根）。
    private func perchPoint(_ k: Int, width: CGFloat) -> CGPoint {
        CGPoint(x: width * 0.5 + (k == 0 ? -1 : 1) * width * 0.085,
                y: 22 + CGFloat(k) * 16)
    }

    /// 树干底部的枝桠栖木（视觉上接住飞上来的鸟）。
    @ViewBuilder
    private func perchStubs(width: CGFloat, height: CGFloat) -> some View {
        ForEach(0..<2, id: \.self) { k in
            let point = perchPoint(k, width: width)
            Capsule()
                .fill(theme.trunkShade.opacity(0.9))
                .frame(width: 36, height: 5)
                .rotationEffect(.degrees(k == 0 ? -6 : 6))
                .position(point)
        }
    }

    /// 鸟类飞上枝桠。
    private func flyToPerch(_ index: Int, count: Int, span: CGFloat, inset: CGFloat,
                            groundLine: CGFloat, quantizedWidth: CGFloat, width: CGFloat) async {
        let home = homePosition(index: index, count: count, span: span, inset: inset,
                                groundLine: groundLine, quantizedWidth: quantizedWidth)
        let perch = perchPoint(Int.random(in: 0..<2), width: width)
        withAnimation(.spring(response: 0.9, dampingFraction: 0.75)) {
            offsets[index] = CGSize(width: perch.x - home.x, height: perch.y - home.y - 4)
            perched[index] = true
        }
    }

    /// 在枝上小幅挪动（沿枝 ±10pt）。
    private func shuffleOnPerch(_ index: Int, count: Int, span: CGFloat, inset: CGFloat,
                                groundLine: CGFloat, quantizedWidth: CGFloat, width: CGFloat) {
        let home = homePosition(index: index, count: count, span: span, inset: inset,
                                groundLine: groundLine, quantizedWidth: quantizedWidth)
        let delta = CGFloat.random(in: -10...10)
        withAnimation(.easeInOut(duration: 0.5)) {
            offsets[index].width += delta
        }
    }

    /// 飞回草地（落到离家最近的空位：直接回家）。
    private func flyBackToGrass(_ index: Int, count: Int, span: CGFloat, inset: CGFloat,
                                groundLine: CGFloat, quantizedWidth: CGFloat) async {
        withAnimation(.spring(response: 0.9, dampingFraction: 0.75)) {
            offsets[index] = .zero
            perched[index] = false
        }
    }

    /// 全体回家排排站好（关闭活动 / 入夜时调用，带过渡动画）。
    private func sendEveryoneHome() {
        withAnimation(.spring(response: 0.7, dampingFraction: 0.8)) {
            for i in 0..<Self.maxResidents {
                offsets[i] = .zero
                perched[i] = false
            }
            speakingIndex = nil
            bubbleText = nil
        }
    }

    // MARK: 花草

    private func grassBlade(x: CGFloat, h: CGFloat, w: CGFloat, seed: Int, groundLine: CGFloat) -> some View {
        Capsule()
            .fill(theme.foliage.opacity(0.7))
            .frame(width: w, height: h)
            .rotationEffect(.degrees(Double((pr(seed, 6) - 0.5) * 24)))
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

    /// 家位置（与 resident() 完全同一套伪随机，编排与绘制共用）。
    private func homePosition(index: Int, count: Int, span: CGFloat, inset: CGFloat,
                              groundLine: CGFloat, quantizedWidth: CGFloat)
        -> (x: CGFloat, y: CGFloat, size: CGFloat) {
        let depth = pr(index, 14)
        let base = min(54, 28 + quantizedWidth * 0.045) * (0.72 + depth * 0.42)
        let size = base * (0.94 + pr(index, 5) * 0.14)
        let pitch = span / CGFloat(max(1, count))
        let jitter = (pr(index, 4) - 0.5) * min(24, pitch * 0.34)
        let x = inset + (CGFloat(index) + 0.5) * pitch + jitter
        let y = groundLine - size * 0.5 - depth * 10 + pr(index, 9) * 6
        return (x, y, size)
    }

    private func resident(kind: AnimalKind, index: Int, visibleCount: Int,
                          span: CGFloat, inset: CGFloat, groundLine: CGFloat,
                          quantizedWidth: CGFloat) -> some View {
        let visible = index < visibleCount
        let home = homePosition(index: index, count: visibleCount, span: span, inset: inset,
                                groundLine: groundLine, quantizedWidth: quantizedWidth)
        let facing = facingAt(index: index, fallback: kind)
        let currentKind = kindAt(index: index, fallback: kind)

        return ZStack {
            // 脚底阴影（落到脚部而不是身体中心；鸟在枝上时收起）
            if !perched[index] {
                Ellipse()
                    .fill(theme.shadow)
                    .frame(width: home.size * 0.92, height: home.size * 0.15)
                    .offset(y: home.size * 0.42)
            }

            LivelyAnimal(
                kind: currentKind,
                isSleeping: theme.isNight,
                size: home.size,
                facing: facing,
                actionTick: actionTicks[index],
                actionKind: actionKinds[index],
                onTap: { requestBubble(index) },
                onSpontaneousBubble: { requestBubble(index) }
            )
        }
        .position(x: home.x + offsets[index].width, y: home.y + offsets[index].height)
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.6, anchor: .bottom)
        .allowsHitTesting(visible)
        .animation(.easeOut(duration: 0.2), value: visibleCount)
    }

    // MARK: 物种轮换（随机离开 → 新邻居进入）

    /// 初始化/对齐各槽位的物种与朝向状态（数量或首次出现时调用）。
    private func ensureResidents(count: Int, order: [AnimalKind]) {
        guard kinds.count != Self.maxResidents || facings.count != Self.maxResidents else { return }
        if kinds.isEmpty {
            kinds = (0..<Self.maxResidents).map { order[$0 % order.count] }
        } else {
            kinds = (0..<Self.maxResidents).map { kinds.indices.contains($0) ? kinds[$0] : order[$0 % order.count] }
        }
        if facings.isEmpty {
            facings = (0..<Self.maxResidents).map { pr($0, 3) > 0.5 ? 1 : -1 }
        } else {
            facings = (0..<Self.maxResidents).map { facings.indices.contains($0) ? facings[$0] : 1 }
        }
    }

    private func kindAt(index: Int, fallback: AnimalKind) -> AnimalKind {
        kinds.indices.contains(index) ? kinds[index] : fallback
    }

    private func facingAt(index: Int, fallback: AnimalKind) -> CGFloat {
        facings.indices.contains(index) ? facings[index] : 1
    }

    /// 轮换编排：随机间隔让一只小动物告别离开，随后一只新邻居进场打招呼。
    private func orchestrateRotation(count: Int, span: CGFloat, inset: CGFloat,
                                     groundLine: CGFloat, quantizedWidth: CGFloat,
                                     order: [AnimalKind]) async {
        // 轮换节奏比日常动作慢得多：25~55 秒一次（频率越高越勤快）
        let base = 55 - activityFrequency * 30
        try? await Task.sleep(for: .seconds(base * Double.random(in: 0.9...1.2)))
        while !Task.isCancelled {
            // 轮换属于「活动」：开关关闭或入夜时静默等待
            guard activityAllowed, !theme.isNight else {
                try? await Task.sleep(for: .seconds(5))
                continue
            }
            guard count > 0 else { continue }
            let index = Int.random(in: 0..<count)

            // ① 告别气泡（气泡开关关闭时静默离开）
            if bubblesAllowed {
                requestRawBubble(index, pool: Self.leavePhrases)
                try? await Task.sleep(for: .seconds(2.6))
            }
            guard !Task.isCancelled else { return }

            // ② 沿地面走出画面（朝最近一侧边缘小跳离场）
            let home = homePosition(index: index, count: count, span: span, inset: inset,
                                    groundLine: groundLine, quantizedWidth: quantizedWidth)
            let current = offsets[index]
            let bandCenter = inset + span / 2
            let exitLeft = home.x + current.width < bandCenter
            let exitX = exitLeft ? -(inset + 40) : (inset + span + 40) - home.x
            if facings.indices.contains(index) { facings[index] = exitLeft ? -1 : 1 }
            await hopTo(index, target: CGSize(width: exitX, height: current.height),
                        steps: 4, hopHeight: 9)
            try? await Task.sleep(for: .seconds(0.35))
            guard !Task.isCancelled else { return }

            // ③ 换物种、瞬移回进场边缘、走进来
            let pool = AnimalKind.allCases.filter { $0 != kindAt(index: index, fallback: order.first ?? .fox) }
            let newKind = pool.randomElement() ?? .rabbit
            if kinds.indices.contains(index) { kinds[index] = newKind }
            let enterLeft = exitLeft
            let enterX = enterLeft ? -(inset + 40) : (inset + span + 40) - home.x
            if offsets.indices.contains(index) {
                offsets[index] = CGSize(width: enterX, height: current.height)
            }
            try? await Task.sleep(for: .seconds(0.15))
            await hopTo(index, target: CGSize(width: 0, height: current.height),
                        steps: 6, hopHeight: 8)

            // ④ 打招呼气泡
            if bubblesAllowed {
                requestRawBubble(index, pool: Self.greetPhrases)
            }
            try? await Task.sleep(for: .seconds(base * Double.random(in: 0.85...1.3)))
        }
    }

    /// 多段小跳从当前位置移动到目标位移（跳动前进，而不是平移）。
    @discardableResult
    private func hopTo(_ index: Int, target: CGSize, steps: Int, hopHeight: CGFloat) async {
        guard offsets.indices.contains(index) else { return }
        let start = offsets[index]
        for step in 1...max(1, steps) {
            guard !Task.isCancelled else { return }
            let t = Double(step) / Double(steps)
            let x = start.width + (target.width - start.width) * t
            let y = start.height + (target.height - start.height) * t
            // 起跳：横移一段 + 向上抬起
            withAnimation(.spring(response: 0.20, dampingFraction: 0.6)) {
                offsets[index] = CGSize(width: x, height: y - hopHeight)
            }
            try? await Task.sleep(for: .seconds(0.17))
            // 落地
            withAnimation(.spring(response: 0.16, dampingFraction: 0.7)) {
                offsets[index] = CGSize(width: x, height: y)
            }
            try? await Task.sleep(for: .seconds(0.13))
        }
    }

    /// 轮换专用冒泡（不走物种文案池，直接给文案）。
    private func requestRawBubble(_ index: Int, pool: [String]) {
        guard !pool.isEmpty else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            speakingIndex = index
            bubbleText = pool.randomElement()
        }
        bubbleTick += 1
    }

    /// 请求冒泡（点击或自发动作统一入口）：顶层展示，3 秒后自动收起。
    private func requestBubble(_ index: Int) {
        guard bubblesAllowed else { return }
        let kind = kindAt(index: index, fallback: AnimalKind.allCases[index % AnimalKind.allCases.count])
        requestRawBubble(index, pool: kind.phrases)
    }

    // MARK: 右下角活动开关（与设置联动）

    private var activityButton: some View {
        Button {
            onActivityToggle?()
        } label: {
            Image(systemName: activityAllowed ? "face.smiling" : "face.dashed")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(activityAllowed ? theme.accent : theme.secondaryText)
                .frame(width: 30, height: 30)
                .background(Circle().fill(theme.surface.opacity(0.9)))
                .overlay(Circle().strokeBorder(theme.divider, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.trailing, 12)
        .padding(.bottom, 10)
        .help(activityAllowed ? "小动物们正在自由活动（点击让它们排排站好）" : "小动物们已安静（点击放它们出来玩）")
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
