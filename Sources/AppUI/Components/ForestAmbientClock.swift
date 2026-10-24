import SwiftUI

// MARK: - 全局氛围钟

/// 全局氛围钟：所有**自己推进时间**的氛围装饰层共用的一个相位源。
///
/// 为什么必须收敛成一颗、而不是各层自己起表：九个氛围层（春蝶 / 蒲公英絮 /
/// 风筝 / 落叶 / 四季飞鸟 / 流萤 / 光斑 / 蜻蜓 / 落雪）此前**各起一颗
/// `TimelineView`**，每层 20–24fps。十颗调度器在同一帧窗口里各自落一次，
/// 换来的是十次互相错开的更新事务 —— 每一条都要自己走一遍布局与合成，
/// 机器一满（跑测试 / 开别的应用）就开始掉帧，用户看到的是「林子卡卡的」。
/// 一颗钟推进、所有层读，同一帧里只发生一次更新，层与层的相位也因此天然对齐。
///
/// ⚠️ 与 `ForestWindClock` 是**两颗独立的钟**，不是合并：风钟 30fps（草要跟手），
/// 氛围钟按窗口幅宽在 15–20fps 之间（落叶 / 雪花这类慢层不需要更高）。
/// 硬合到一起要么把慢层提到 30fps（白烧一半算力），要么把风场降到 20fps（风变木）。
///
/// 冻结语义：层自己判 `frozen`（`still` / 氛围隐藏档 / `reduceMotion`）——
/// 钟本身不管冻结，只负责单调累计时间。见 `AmbientTicker`。
@Observable
@MainActor
public final class ForestAmbientClock {

    /// 自时钟创建起累计的秒数（单调递增，只在**真正推进**时累计）。
    public private(set) var elapsed: Double = 0

    private var lastTick: Date?

    public init() {}

    /// 间隔超过这个值（秒）就当「停了一会儿」，不把这段累计进 `elapsed`。
    ///
    /// 应用失活（`scenePhase != .active`）时驱动器整个暂停，恢复后第一帧的
    /// `date` 与上一帧差着好几秒。照常累计的话，一恢复播放落叶会从半空
    /// **瞬移到树冠**、鸟群整群跳过小半个画面。只搬基准时间不累计，
    /// 恢复后从原处接着走。
    static let stallThreshold: Double = 1.0

    /// 每帧推进一次。
    public func advance(to date: Date) {
        if let last = lastTick {
            let gap = date.timeIntervalSince(last)
            if gap <= Self.stallThreshold { elapsed += gap }
        }
        lastTick = date
    }

    /// 直接把钟拨到某个相位（秒）。
    ///
    /// ⚠️ 只为测试夹具存在：离屏渲染要钉「注入了统一帧源的那一帧与冻结档
    /// 同一个姿态」，而冻结档的相位是 30.72s（`FlockLayout.frozenElapsed`），
    /// 靠 `advance(to:)` 一帧帧累不出这个数（`stallThreshold` 只放 1 秒内的间隔）。
    /// 产品路径一律走 `advance(to:)`。
    // periphery:ignore - 只服务于测试夹具，产品路径一律走 advance(to:)
    func seed(elapsed: Double) {
        self.elapsed = max(0, elapsed)
        lastTick = nil
    }
}

private struct ForestAmbientClockKey: EnvironmentKey {
    /// 默认**没有钟**：未注入的上下文（离屏渲染夹具、SwiftUI 预览）里，
    /// 氛围层各自退回自己起表的老路 —— 既有渲染测试因此零影响，
    /// 新测试想验统一帧源就显式注入（见 `ForestBirdsRenderTests`）。
    static let defaultValue: ForestAmbientClock? = nil
}

public extension EnvironmentValues {
    /// 全局氛围钟。nil = 没有统一帧源（各层自己起表）。
    var forestAmbientClock: ForestAmbientClock? {
        get { self[ForestAmbientClockKey.self] }
        set { self[ForestAmbientClockKey.self] = newValue }
    }
}

// MARK: - 氛围钟驱动器

/// 氛围钟驱动器：全场景**唯一**一颗推进氛围钟的 `TimelineView`。
///
/// 挂在整个窗口根上（MainView 的 ZStack，与 `ForestWindDriver` 并排），
/// 九层氛围装饰散在各处也能共享同一相位。
struct ForestAmbientDriver: View {
    let clock: ForestAmbientClock
    /// 窗口幅宽（pt）：帧率预算的自变量，见 `frameInterval`。
    var windowWidth: CGFloat = 0

    /// 应用失活时整个停摆：用户根本看不到画面，没必要继续烧一屏的动画。
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(
            .animation(minimumInterval: Self.frameInterval(windowWidth: windowWidth),
                       paused: scenePhase != .active)
        ) { context in
            Color.clear
                // ⚠️ 走 onChange 而不是在闭包里直接写：body 求值途中改可观察状态
                // 会触发「Modifying state during view update」（与风钟驱动器同一条教训）。
                .onChange(of: context.date) { _, date in
                    clock.advance(to: date)
                }
        }
    }

    /// 帧间隔（秒）= 按窗口幅宽给的帧率预算。
    ///
    /// 为什么幅宽越大帧率越低：每帧要合成的像素数随幅宽涨，帧数却照旧 ——
    /// 大窗口下同样的层数每帧贵得多。按幅宽把帧率往下让一档，
    /// 「像素 × 帧」的总工作量大致守恒，机器越满越不容易掉帧。
    /// （最小窗宽 1080pt，见 #417；这一档只在拉得比默认更宽时才生效。）
    static func frameInterval(windowWidth: CGFloat) -> Double {
        switch windowWidth {
        case 1500...:      return 1.0 / 15.0
        case 1200..<1500:  return 1.0 / 18.0
        default:           return 1.0 / 20.0
        }
    }
}

// MARK: - 氛围层的时间源

/// 氛围层的时间源：把「这一帧的 elapsed」喂给装饰层。
///
/// 三条路，按环境有没有注入钟来分：
/// 1. **冻结**（`still` / 氛围隐藏档 / `reduceMotion`）→ 直接给 0，**连表都不起**。
///    九层此前的写法是「起一颗 `paused: true` 的 TimelineView」，暂停的调度器
///    虽然不回调，却仍在视图树里占着位置；冻结时一棵都不留，reduceMotion
///    档下氛围层的调度器总数是 0。
/// 2. **注入了钟** → 读 `clock.elapsed`，不再自己起表（这就是「统一帧源」）。
/// 3. **没注入钟**（离屏夹具 / 旧渲染测试）→ 自己起一颗 `TimelineView`，
///    行为与改造前逐像素一致。保留这条路是因为渲染夹具不注入氛围钟
///    （与风钟同一条约定），而若干审计类仍在渲染**会动的**那一帧。
///
/// ⚠️ 层自己决定冻结时用什么姿势（`frozenElapsed` 各算各的），
/// 所以这个 `0` 只是「没有时间在走」，不是「停在原点」。
struct AmbientTicker<Content: View>: View {

    var paused: Bool
    /// 自起表那条路的帧间隔（默认与改造前的各层一致）。
    var interval: Double = 1.0 / 20.0

    @ViewBuilder var content: (Double) -> Content

    @Environment(\.forestAmbientClock) private var ambient
    /// 计时起点：只在自起表那条路用得上；用绝对时刻算相位，重绘不跳变。
    @State private var origin = Date()

    var body: some View {
        if paused {
            content(0)
        } else if let ambient {
            content(ambient.elapsed)
        } else {
            TimelineView(.animation(minimumInterval: interval)) { context in
                content(max(context.date.timeIntervalSince(origin), 0))
            }
        }
    }
}
