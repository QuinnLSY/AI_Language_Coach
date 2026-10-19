import SwiftUI

/// 小动物的动作词汇表（批次二「小剧场」）。
///
/// 数字即语义：`ForestGroundBand` 的编排层挑一个演，`LivelyAnimal` 负责身体动画。
/// 新增动作只改这张表与 `performAction` 的 switch，调用方零改动。
public enum LivelyAnimalAction: Int, CaseIterable, Sendable {
    /// 跳一跳（庆祝、打招呼都用它）。
    case hop = 0
    /// 摇一摇（左右快速摆头）。
    case shake = 1
    /// 歪头（听到纠错时的「歪头安慰」姿势）。
    case tilt = 2
    /// 打盹点头（慢节奏的前倾点头，困困的）。
    case nod = 3
    /// 伸懒腰（横向舒展 + 纵向压扁再弹回）。
    case stretch = 4
    /// 刨土（快速小幅抖动）。
    case dig = 5
    /// 追尾巴转圈（原地自转一整圈；点击彩蛋同款）。
    case spin = 6
    /// 害羞缩一下（纵向压扁弹回；点击彩蛋同款）。
    case shy = 7
    /// 结对摇摆（左右大幅倾摆；两只同时演就是「结对跳舞」）。
    case wiggle = 8
    /// 竖起耳朵听（身体微微挺直并保持一会儿）。
    ///
    /// ⚠️ 与 `.nod`（打盹点头，前倾慢点）恰好是一对反义：一个精神、一个困，
    /// 别拿其中一个去顶另一个的场。批次四给「老师开口 / 听力练完」用。
    case listen = 9
}

/// 林间活力小动物：点击冒泡与自发动作都由父级（ForestGroundBand）编排——
/// 气泡统一画在父级顶层（保证最新点击的永远在最上层），本视图只负责身体动画：
/// - 跳一跳（hopLift）与摇头（shakeAngle）由 `actionTick` 变化触发；
/// - 游走位移由父级持有并应用到 `.offset`，动物走到哪就停在哪。
public struct LivelyAnimal: View {

    public let kind: AnimalKind
    public let isSleeping: Bool
    public let size: CGFloat
    public var facing: CGFloat = 1
    /// 父级触发的动作序号：每次 +1 执行一次 `actionKind`。
    public var actionTick: Int = 0
    /// 这次演哪个动作（见 `LivelyAnimalAction`）。
    public var actionKind: LivelyAnimalAction = .hop
    /// 点击回调（父级决定冒泡与层级）。
    public var onTap: (() -> Void)? = nil
    /// 自发动作时请求冒泡（父级决定是否显示，50% 概率由父级抽签也行，这里跳/摇各 50%）。
    public var onSpontaneousBubble: (() -> Void)? = nil
    /// 眨眼初相种子：透传给 `CuteAnimalView`。编排层给同一屏的每只动物传不同的值，
    /// 否则它们会整排一起眨。默认 0 = 不偏移（单只用法行为不变）。
    public var blinkPhaseSeed: Int = 0
    /// 当前季节（nil = 不换季节装扮）。由地面带从 `ForestTheme.season` 透传。
    public var season: ForestSeason? = nil
    /// 当前天气（nil = 无降水行为）。下雨打伞、下雪哆嗦；从 `ForestTheme.weather` 透传。
    public var weather: ForestWeather? = nil

    @State private var hopLift: CGFloat = 0
    @State private var shakeAngle: Double = 0
    /// 身体的横向/纵向缩放（害羞压扁、伸懒腰舒展共用一对状态）。
    @State private var bodyScaleX: CGFloat = 1
    @State private var bodyScaleY: CGFloat = 1

    public init(kind: AnimalKind, isSleeping: Bool = false, size: CGFloat = 48,
                facing: CGFloat = 1, actionTick: Int = 0, actionKind: LivelyAnimalAction = .hop,
                onTap: (() -> Void)? = nil, onSpontaneousBubble: (() -> Void)? = nil,
                blinkPhaseSeed: Int = 0, season: ForestSeason? = nil, weather: ForestWeather? = nil) {
        self.kind = kind
        self.isSleeping = isSleeping
        self.size = size
        self.facing = facing
        self.actionTick = actionTick
        self.actionKind = actionKind
        self.onTap = onTap
        self.onSpontaneousBubble = onSpontaneousBubble
        self.blinkPhaseSeed = blinkPhaseSeed
        self.season = season
        self.weather = weather
    }

    public var body: some View {
        CuteAnimalView(kind: kind, isSleeping: isSleeping, size: size, bobbing: false,
                       blinkPhaseSeed: blinkPhaseSeed,
                       season: season, weather: weather)
            .scaleEffect(x: facing, y: 1, anchor: .center)
            .scaleEffect(x: bodyScaleX, y: bodyScaleY, anchor: .bottom)
            .rotationEffect(.degrees(shakeAngle))
            .offset(y: hopLift)
            .frame(width: size, height: size)
            .contentShape(Circle().inset(by: -size * 0.08))
            .onTapGesture { handleTap() }
            .onChange(of: actionTick) { _, _ in performAction() }
            .accessibilityLabel("\(kind.displayName)（点击听它说话）")
            .accessibilityAddTraits(.isButton)
    }

    // MARK: - 动作分派

    /// 按动作表演对应戏码；睡了就不折腾身体（只让父级冒泡）。
    private func performAction() {
        guard !isSleeping else { return }
        switch actionKind {
        case .hop: performHop()
        case .shake: performShake()
        case .tilt: performSwing([(9, 0.28), (9, 0.55), (0, 0.32)])
        case .nod: performSwing([(7, 0.42), (7, 0.42), (7, 0.42), (0, 0.45)])
        case .stretch: performStretch()
        case .dig: performSwing([(3, 0.09), (-3, 0.09), (3, 0.09), (-3, 0.09), (3, 0.09), (0, 0.12)])
        case .spin: performSpin()
        case .shy: performShy()
        case .wiggle: performSwing([(11, 0.16), (-11, 0.16), (11, 0.16), (-11, 0.16), (0, 0.22)])
        case .listen: performListen()
        }
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
        performSwing([(-8, 0.12), (8, 0.12), (-6, 0.11), (6, 0.11), (0, 0.14)])
    }

    /// 通用多段摆动：`performShake` / 歪头 / 打盹点头 / 刨土 / 结对摇摆共用同一套引擎，
    /// 区别只在摆幅与节奏——这是它们各自「性格」的来源。
    private func performSwing(_ swings: [(Double, Double)]) {
        Task { @MainActor in
            for (angle, duration) in swings {
                withAnimation(.easeInOut(duration: duration)) { shakeAngle = angle }
                try? await Task.sleep(for: .seconds(duration))
            }
            shakeAngle = 0
        }
    }

    /// 追尾巴：原地自转一整圈。360° 与 0° 在视觉上无缝衔接，
    /// 转完直接归零（不带动画）不会看到「倒转回去」。
    private func performSpin() {
        Task { @MainActor in
            withAnimation(.easeInOut(duration: 0.6)) { shakeAngle = 360 }
            try? await Task.sleep(for: .seconds(0.62))
            shakeAngle = 0
        }
    }

    /// 害羞：纵向压扁一下再弹回（缩起来 = 害羞，点击彩蛋用）。
    private func performShy() {
        withAnimation(.spring(response: 0.22, dampingFraction: 0.6)) { bodyScaleY = 0.85 }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.3))
            withAnimation(.spring(response: 0.32, dampingFraction: 0.5)) { bodyScaleY = 1 }
        }
    }

    /// 竖起耳朵听：身体挺一下并保持（注意力在线的样子），再慢慢落回。
    private func performListen() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) { bodyScaleY = 1.07 }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.9))
            withAnimation(.spring(response: 0.36, dampingFraction: 0.7)) { bodyScaleY = 1 }
        }
    }

    /// 伸懒腰：横向舒展 + 纵向微压，再慢慢弹回。
    private func performStretch() {
        Task { @MainActor in
            withAnimation(.easeInOut(duration: 0.45)) {
                bodyScaleX = 1.12
                bodyScaleY = 0.9
            }
            try? await Task.sleep(for: .seconds(0.5))
            withAnimation(.spring(response: 0.4, dampingFraction: 0.55)) {
                bodyScaleX = 1
                bodyScaleY = 1
            }
        }
    }

    // MARK: - 点击彩蛋

    /// 点击：白天随机演一个彩蛋（害羞 / 追尾巴转圈）再交给父级冒泡；睡着时不吵醒身体。
    private func handleTap() {
        guard !isSleeping else {
            onTap?()
            return
        }
        if Bool.random() { performShy() } else { performSpin() }
        onTap?()
    }
}
