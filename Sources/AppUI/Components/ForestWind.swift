import SwiftUI

// MARK: - 全局风钟（P1：风场接线的唯一相位源）

/// 全局风钟：全场景**唯一**的风相位源。
///
/// 为什么必须是共享的一颗、而不是各层自己起表：`WindField.gust` 是**全局标量**
/// （只跟相位有关）—— 各层若各算各的相位，「阵风呼吸」会错开（草在最盛时
/// 花在收敛），用户看到的就是各抖各的，不是同一阵风。一颗钟推进、所有层读，
/// 层与层因此不可能对不上。
///
/// 冻结语义：`blowing = false`（reduceMotion / 氛围隐藏档）时相位冻结在 0，
/// `offset` 恒 0 —— **草是直的**。不是「停在当时的弯度上」：设置一变，
/// 一棵歪着上半身的草比瞬间立正更瘆人。
@Observable
@MainActor
public final class ForestWindClock {

    /// 当前相位（弧度）= `WindField.phase(elapsed:)` 的产物。
    public private(set) var phase: Double = 0
    /// 风是否在吹。false = 冻结（`offset` 恒 0）。
    public private(set) var isBlowing: Bool = false

    /// 累计吹风时长（秒）。**只在吹的时候累计** —— 暂停再继续，
    /// 风从原处接着吹，不会「睡了一秒、相位跳一大步」把草甩到反方向。
    private var elapsed: Double = 0
    private var lastTick: Date?

    public init() {}

    /// 每帧推进一次。`blowing = false` 时只记时间、不累计相位。
    public func advance(to date: Date, blowing: Bool) {
        if let last = lastTick, blowing {
            elapsed += date.timeIntervalSince(last)
        }
        lastTick = date
        isBlowing = blowing
        phase = WindField.phase(elapsed: elapsed)
    }

    /// `x` 处、顶端离地 `height` 的东西，当前被风推了多少 pt。冻结时恒 0。
    public func offset(x: CGFloat, height: CGFloat) -> CGFloat {
        guard isBlowing else { return 0 }
        return WindField.offset(x: x, phase: phase, height: height)
    }
}

private struct ForestWindClockKey: EnvironmentKey {
    /// 默认**没有风**：未注入的上下文（离屏渲染夹具、SwiftUI 预览）里
    /// 一切受风层静止 —— 既有渲染测试因此零影响，新测试想验风就显式注入。
    static let defaultValue: ForestWindClock? = nil
}

public extension EnvironmentValues {
    /// 全局风钟。nil = 没有风（受风层全部静止）。
    var forestWind: ForestWindClock? {
        get { self[ForestWindClockKey.self] }
        set { self[ForestWindClockKey.self] = newValue }
    }
}

// MARK: - 风钟驱动器

/// 风钟驱动器：全场景唯一一颗 `TimelineView`（30fps）推着风钟走。
///
/// 挂在整个窗口根上（MainView 的 ZStack），受风层散在各处也能共享同一相位。
/// `TimelineView` 而不是 `Timer`：视图不可见时它自己停，不烧电、不扰民。
struct ForestWindDriver: View {
    let clock: ForestWindClock
    /// 氛围隐藏档（连点天空 5 次）：林子完全安静 —— 与云的收起同一句承诺。
    var still: Bool = false

    @Environment(\.appMotion) private var motion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { context in
            Color.clear
                // ⚠️ 走 onChange 而不是在闭包里直接写：body 求值途中改可观察状态
                // 会触发「Modifying state during view update」。onChange 在更新
                // 之后跑，且天然只在 date 真变时跑（首帧不跑，无所谓）。
                .onChange(of: context.date) { _, date in
                    clock.advance(to: date, blowing: WindField.isBlowing(ambientHidden: still, reduceMotion: motion.reduceMotion))
                }
        }
    }
}

// MARK: - 风场摆动

/// 风场摆动：把 content 按 `WindField` 在 `(x, height)` 处的位移摆一动。
///
/// 三个设计要点：
/// 1. **自己读风钟**（`@Environment`）—— 相位变化只重渲染这一小片，
///    不牵动整条地面带 30fps 地重建；
/// 2. 绕**底**旋转（`anchor: .bottom`）：草是根部扎根在晃，不是整棵平移
///    （平移像贴纸在滑）；
/// 3. 未注入风钟 → 位移恒 0：离屏夹具与旧渲染测试一个像素都不变。
struct WindSway<Content: View>: View {

    /// 元素在场景里的横向位置（pt）—— 风场的空间自变量。
    /// 同一 x 的草与花看到的是同一阵风（相位按 x 延迟，风从画面一侧推向另一侧）。
    let x: CGFloat
    /// 元素顶端离地高度（pt）—— 高处摆得大（`WindField.heightFactor`）。
    let height: CGFloat
    /// 位移增益：重的（灌木）小、轻的（草叶）大。
    var gain: CGFloat = 1
    /// 旋转增益（度 / pt）。
    var rotationGain: CGFloat = 0.9

    private let content: Content

    init(
        x: CGFloat,
        height: CGFloat,
        gain: CGFloat = 1,
        rotationGain: CGFloat = 0.9,
        @ViewBuilder content: () -> Content
    ) {
        self.x = x
        self.height = height
        self.gain = gain
        self.rotationGain = rotationGain
        self.content = content()
    }

    @Environment(\.forestWind) private var wind

    var body: some View {
        let push = (wind?.offset(x: x, height: height) ?? 0) * gain
        content
            .offset(x: push)
            .rotationEffect(.degrees(push * rotationGain), anchor: .bottom)
    }
}
