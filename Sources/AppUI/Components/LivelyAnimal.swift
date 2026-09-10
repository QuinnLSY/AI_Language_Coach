import SwiftUI

/// 林间活力小动物：点击冒泡与自发动作都由父级（ForestGroundBand）编排——
/// 气泡统一画在父级顶层（保证最新点击的永远在最上层），本视图只负责身体动画：
/// - 跳一跳（hopLift）与摇头（shakeAngle）由 `actionTick` 变化触发；
/// - 游走位移由父级持有并应用到 `.offset`，动物走到哪就停在哪。
public struct LivelyAnimal: View {

    @Environment(\.forestTheme) private var theme

    public let kind: AnimalKind
    public let isSleeping: Bool
    public let size: CGFloat
    public var facing: CGFloat = 1
    /// 父级触发的动作序号：每次 +1 执行一次 `actionKind`。
    public var actionTick: Int = 0
    /// 0 = 跳一跳，1 = 摇一摇。
    public var actionKind: Int = 0
    /// 点击回调（父级决定冒泡与层级）。
    public var onTap: (() -> Void)? = nil
    /// 自发动作时请求冒泡（父级决定是否显示，50% 概率由父级抽签也行，这里跳/摇各 50%）。
    public var onSpontaneousBubble: (() -> Void)? = nil

    @State private var hopLift: CGFloat = 0
    @State private var shakeAngle: Double = 0

    public init(kind: AnimalKind, isSleeping: Bool = false, size: CGFloat = 48,
                facing: CGFloat = 1, actionTick: Int = 0, actionKind: Int = 0,
                onTap: (() -> Void)? = nil, onSpontaneousBubble: (() -> Void)? = nil) {
        self.kind = kind
        self.isSleeping = isSleeping
        self.size = size
        self.facing = facing
        self.actionTick = actionTick
        self.actionKind = actionKind
        self.onTap = onTap
        self.onSpontaneousBubble = onSpontaneousBubble
    }

    public var body: some View {
        CuteAnimalView(kind: kind, isSleeping: isSleeping, size: size, bobbing: false)
            .scaleEffect(x: facing, y: 1, anchor: .center)
            .rotationEffect(.degrees(shakeAngle))
            .offset(y: hopLift)
            .frame(width: size, height: size)
            .contentShape(Circle().inset(by: -size * 0.08))
            .onTapGesture { onTap?() }
            .onChange(of: actionTick) { _, _ in
                guard !isSleeping else { return }
                if actionKind == 0 { performHop() } else { performShake() }
            }
            .accessibilityLabel("\(kind.displayName)（点击听它说话）")
            .accessibilityAddTraits(.isButton)
    }

    /// 跳一跳：50% 概率请父级冒一句自己的话（气泡跟随起跳，因为整体在父级随位移移动）。
    private func performHop() {
        if Bool.random() { onSpontaneousBubble?() }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.55)) { hopLift = -size * 0.32 }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.34))
            withAnimation(.spring(response: 0.24, dampingFraction: 0.5)) { hopLift = 0 }
        }
    }

    /// 摇一摇：只有身体左右摆，气泡固定不动（气泡位置由父级持有，不随身体角度变化）。
    private func performShake() {
        if Bool.random() { onSpontaneousBubble?() }
        let swings: [(Double, Double)] = [(-8, 0.12), (8, 0.12), (-6, 0.11), (6, 0.11), (0, 0.14)]
        Task { @MainActor in
            for (angle, duration) in swings {
                withAnimation(.easeInOut(duration: duration)) { shakeAngle = angle }
                try? await Task.sleep(for: .seconds(duration))
            }
            shakeAngle = 0
        }
    }
}
