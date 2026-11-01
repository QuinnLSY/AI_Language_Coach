import SwiftUI

// MARK: - 云的漂移（纯函数）

/// 云在风里的横向位置（纯函数，可单测）。
///
/// 为什么云要单独一套（而不是直接复用 `WindField.offset`）：草是**摆动**
/// （正弦，来回），云是**位移**（一直往一个方向走，走到头再从另一侧进来）。
/// 拿正弦去推云，云会像被一根绳子拴住来回荡 —— 那不是风，那是钟摆。
///
/// 但它必须跟草**同一阵风**（这是「云跟风」的全部意义）：两处共用一颗风钟
/// （`ForestWindClock`），这里是「累计吹了多久」→「云飘到哪」的换算。
public enum CloudDrift {

    /// 一朵云横穿整条行程要多久（秒，**阵风加权**后的秒）。
    ///
    /// 78 秒：比草的摆动周期（约 7 秒）慢一个数量级 —— 云本来就该慢得几乎
    /// 察觉不到，只在用户盯着看的时候发现「它刚才好像不在这儿」。
    public static let crossingSeconds: Double = 78

    /// 两端淡出的比例（占整条行程）。
    ///
    /// 为什么必须淡出：行程是**折回**的（走到头从另一侧进来），淡出后那一下
    /// 瞬移发生在透明度为 0 的时刻 —— 看不见跳变。不淡出的话，每 78 秒
    /// 画面右侧会有一朵云凭空消失、左侧凭空出现。
    public static let edgeFade: Double = 0.22

    /// 一朵云此刻的漂移状态。
    public struct State: Equatable, Sendable {
        /// 行程进度（0…<1）。
        public let progress: Double
        /// 相对行程中心的横向位移（pt，±travel/2）。
        public let x: CGFloat
        /// 可见度（0…1）：两端淡出，中段全亮。
        public let alpha: Double
    }

    /// 每朵云的初相（0…<1）：错峰，免得整片云同时淡入淡出。
    ///
    /// 0.5 起、每朵 +0.37（与 1 互质的一档）：十一朵以内不会撞在同一个位置上。
    public static func startPhase(index: Int) -> Double {
        wrap(0.5 + Double(index) * 0.37)
    }

    /// 阵风加权的时间：`∫₀ᵗ (0.75 + 0.25·sin(ωs)) ds`，`ω = speed · gustWave`。
    ///
    /// `WindField.gust` 是「此刻风有多大」（0.5…1.0 的呼吸），直接拿它乘速度会让
    /// 云忽快忽慢却**不可积**（位置会随帧率漂）。这里给它一个原函数：
    /// 位置只由时间决定，帧率再抖也不会跑偏，而云的快慢仍然跟着阵风呼吸。
    ///
    /// 展开：`0.75t + (0.25/ω)(1 − cos ωt)`。`t = 0` 时为 0，导数正好是
    /// `0.75 + 0.25 sin ωt` —— 单测拿数值微分对一遍（判据是「差 ≤ 1e-4」）。
    public static func gustWeightedTime(seconds: Double) -> Double {
        // `isFinite` 先于 `> 0`：`+∞` 也满足 `> 0`，但 `cos(∞)` 是 NaN，
        // 一路传到 `CGFloat` 就是「云的位置成了 NaN」—— 整层直接不画。
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let omega = WindField.speed * WindField.gustWave
        // ω 是常量（0.9 × 0.31），理论上恒 > 0；仍留一道保护，免得哪天有人把它调成 0
        // 而这里除出 inf（`inf` 会被下游的 `CGFloat` 与 `Int` 一路收成一个崩）。
        guard omega > 0 else { return 0.75 * seconds }
        return 0.75 * seconds + 0.25 / omega * (1 - cos(omega * seconds))
    }

    /// `index` 那朵云在「风累计吹了 `seconds` 秒」时的位置。
    ///
    /// - Parameter travel: 整条行程的长度（pt）。调用方按画幅给（宽 + 一朵云的宽度），
    ///   这样云能从完全在画外的地方进来、再从完全在画外的地方出去。
    public static func state(index: Int, seconds: Double, travel: CGFloat) -> State {
        let progress = wrap(startPhase(index: index)
                            + gustWeightedTime(seconds: seconds) / crossingSeconds)
        let x = (CGFloat(progress) - 0.5) * travel
        return State(progress: progress, x: x, alpha: visibility(progress: progress))
    }

    /// 行程进度 → 可见度：两端 `edgeFade` 之内线性淡出，中段满值。
    ///
    /// `edgeFade` 之外的整段都是 1（不是钟形曲线）：云该在画面里待得久一点，
    /// 只在**离开 / 进来**的那一小段淡 —— 用 `sin(πp)` 那种钟形会让云一整天
    /// 有一半时间是半透明的，读起来像「雾」而不是「云」。
    public static func visibility(progress: Double) -> Double {
        let p = min(max(progress, 0), 1)
        guard edgeFade > 0 else { return 1 }
        return min(1, p / edgeFade, (1 - p) / edgeFade)
    }

    /// 折回到 0…<1（负数也折对：`-0.2 → 0.8`，不是 `-0.2`）。
    ///
    /// ⚠️ `truncatingRemainder` 对负数给负结果 —— 直接拿去算进度会得到
    /// 一个负的 `alpha`（`opacity` 收负值时 SwiftUI 会钳到 0，云就凭空消失）。
    static func wrap(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder < 0 ? remainder + 1 : remainder
    }
}

// MARK: - 地面云影

/// 草地上的云影：几片越来越淡的暗块，跟着云一起从画面一侧移到另一侧。
///
/// 为什么值得画这一层：云在天上飘、地面一动不动时，两件事各说各的 ——
/// 云影是**唯一**能把「天上有云」和「脚下这片草地」连起来的东西。
/// 它一变，整片林子就从「一张画」变成「有阳光穿过云层的一天」。
///
/// 三条纪律：
/// 1. **同一颗风钟**：与云、与草同一阵风（`CloudDrift.state` 同一次换算）；
/// 2. **画在草与居民之上、气泡之下**：云影盖住草叶与小动物（这是物理事实），
///    但不许盖住对话气泡与单词卡（那是信息）；
/// 3. **不抢点击**：`allowsHitTesting(false)` —— 这一层纯氛围。
struct ForestCloudShadows: View {

    let theme: ForestTheme
    /// 氛围演出隐藏档（连点天空 5 次）：云都收起来了，云影自然也不该留。
    var still: Bool = false

    @Environment(\.forestWind) private var wind

    /// 三片云影：`(纵向位置比例, 宽, 高, 浓度权重)`。
    ///
    /// 三片而不是一片：一片读成「地上有块斑」，两三片错落才读成「云在天上走」。
    /// 高度都在 30–46pt（草坡本身就是 150pt 高的一条带），比草叶高一档正好罩住一片。
    private static let patches: [(y: CGFloat, width: CGFloat, height: CGFloat, weight: Double)] = [
        (0.34, 220, 42, 0.9),
        (0.58, 150, 30, 0.65),
        (0.76, 250, 48, 0.8),
    ]

    /// 阴影浓度。夜里几乎看不见（`theme.shadow` 夜里是 45% 的黑，再乘这个就更淡）——
    /// 刻意如此：夜里的云影本来就不该被看见，但它不该「不存在」（否则月光下
    /// 云过时画面毫无变化，云又变回了贴纸）。
    private var strength: Double { theme.isNight ? 0.28 : 0.72 }

    var body: some View {
        if still {
            EmptyView()
        } else {
            GeometryReader { proxy in
                let width = proxy.size.width
                let height = proxy.size.height
                // 行程 = 画幅宽 × 1.5：两端的 25% 在画外，云影才是「飘进来 / 飘出去」
                // 而不是「在边上凭空出现」。
                let travel = max(width * 1.5, 200)
                let seconds = wind?.blownSeconds ?? 0
                ZStack {
                    ForEach(Array(Self.patches.enumerated()), id: \.offset) { pair in
                        let patch = pair.element
                        let state = CloudDrift.state(index: pair.offset + 5, seconds: seconds,
                                                    travel: travel)
                        Ellipse()
                            .fill(theme.shadow)
                            .frame(width: patch.width, height: patch.height)
                            // 柔边靠模糊而不是渐变：模糊让**四周**一起软下来，
                            // 而椭圆里的径向渐变会把阴影做成一颗「中间实、边缘空」的荷包蛋。
                            .blur(radius: patch.height * 0.42)
                            .opacity(strength * patch.weight * state.alpha)
                            .position(x: width / 2 + state.x, y: height * patch.y)
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
