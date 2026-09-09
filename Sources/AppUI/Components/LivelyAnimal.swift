import SwiftUI

/// 林间活力小动物：在 TalkingAnimal 的点击冒泡之上，
/// 增加随机间隔的小幅游走 / 跳一跳 / 摇头动画，跳/摇时 50% 概率冒一句自己的话。
/// - 跳一跳：气泡**随动物一起移动**（相对动物静止）；
/// - 摇头：只有身体旋转，气泡**固定不动**；
/// - 游走：整体（含气泡）小幅平移后归位。
public struct LivelyAnimal: View {

    @Environment(\.forestTheme) private var theme

    public let kind: AnimalKind
    public let isSleeping: Bool
    public let size: CGFloat
    public var facing: CGFloat = 1
    public var phrases: [String] = []
    /// 气泡出现/消失回调（父级据此把该个体抬到最上层）。
    public var onBubbleChange: ((Bool) -> Void)? = nil

    /// 自发动作（与点击冒泡相互独立）。
    private enum Action {
        case wander(CGSize)
        case hop
        case shake
    }

    @State private var bubble: String?
    @State private var clickTick = 0
    @State private var wanderOffset: CGSize = .zero
    @State private var hopLift: CGFloat = 0
    @State private var shakeAngle: Double = 0
    @State private var isActing = false

    public init(kind: AnimalKind, isSleeping: Bool = false, size: CGFloat = 48,
                facing: CGFloat = 1, phrases: [String] = [],
                onBubbleChange: ((Bool) -> Void)? = nil) {
        self.kind = kind
        self.isSleeping = isSleeping
        self.size = size
        self.facing = facing
        self.phrases = phrases
        self.onBubbleChange = onBubbleChange
    }

    public var body: some View {
        ZStack(alignment: .top) {
            if let bubble {
                SpeechBubble(text: bubble, maxWidth: 150)
                    .offset(y: -(size * 0.86))
                    .transition(.opacity.combined(with: .scale(scale: 0.55, anchor: .bottom)))
                    .zIndex(3)
            }

            CuteAnimalView(kind: kind, isSleeping: isSleeping, size: size, bobbing: false)
                .scaleEffect(x: facing, y: 1, anchor: .center)
                .rotationEffect(.degrees(shakeAngle))
                .offset(y: hopLift)
                .zIndex(2)
        }
        .offset(wanderOffset)
        .frame(width: size, height: size)
        .contentShape(Circle().inset(by: -size * 0.08))
        .onTapGesture { showBubble() }
        .task(id: clickTick) {
            guard bubble != nil else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { bubble = nil }
            onBubbleChange?(false)
        }
        .task {
            await idleLifeLoop()
        }
        .accessibilityLabel("\(kind.displayName)（点击听它说话）")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - 点击冒泡

    private func showBubble() {
        guard !phrases.isEmpty else { return }
        let pool = phrases.filter { $0 != bubble }
        let next = pool.randomElement() ?? phrases[0]
        let isNew = bubble == nil
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { bubble = next }
        if isNew { onBubbleChange?(true) }
        clickTick += 1
    }

    // MARK: - 自发小动作（节奏克制：6~14 秒一次）

    private func idleLifeLoop() async {
        // 个体错峰启动，避免整排动物同时动作
        try? await Task.sleep(for: .seconds(Double.random(in: 2...6)))
        while !Task.isCancelled {
            guard !isActing, !isSleeping else {
                try? await Task.sleep(for: .seconds(2))
                continue
            }
            try? await Task.sleep(for: .seconds(Double.random(in: 6...14)))
            guard !Task.isCancelled, !isSleeping else { continue }
            await performRandomAction()
        }
    }

    private func performRandomAction() async {
        isActing = true
        defer { isActing = false }

        let roll = Int.random(in: 0..<3)
        switch roll {
        case 0:
            await wander()
        case 1:
            await hop()
        default:
            await shake()
        }
    }

    /// 跳一跳：50% 冒泡，气泡相对动物静止（跟随起跳）。
    private func hop() async {
        if Bool.random() { showBubble() }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.55)) { hopLift = -size * 0.32 }
        try? await Task.sleep(for: .seconds(0.34))
        withAnimation(.spring(response: 0.24, dampingFraction: 0.5)) { hopLift = 0 }
        try? await Task.sleep(for: .seconds(0.3))
    }

    /// 摇一摇：只有身体左右摆，气泡固定不动。
    private func shake() async {
        if Bool.random() { showBubble() }
        let swings: [(Double, Double)] = [(-8, 0.12), (8, 0.12), (-6, 0.11), (6, 0.11), (0, 0.14)]
        for (angle, duration) in swings {
            withAnimation(.easeInOut(duration: duration)) { shakeAngle = angle }
            try? await Task.sleep(for: .seconds(duration))
        }
        shakeAngle = 0
    }

    /// 小幅游走：上下左右随机偏移几步再回家，气泡随之移动。
    private func wander() async {
        let dx = CGFloat.random(in: -10...10)
        let dy = CGFloat.random(in: -6...4)
        withAnimation(.easeInOut(duration: 0.45)) { wanderOffset = CGSize(width: dx, height: dy) }
        try? await Task.sleep(for: .seconds(0.9))
        withAnimation(.easeInOut(duration: 0.45)) { wanderOffset = .zero }
        try? await Task.sleep(for: .seconds(0.5))
    }
}
