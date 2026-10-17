import SwiftUI

// MARK: - 氛围微粒（P1-②：萤火虫 / 花粉）

/// 一颗粒子的**静态属性**（布局与节奏）：全部由种子定死，重绘不许换一场。
///
/// 位置与节奏分开定：位置（x/y）决定它飘在哪，节奏（walk/blink）决定它怎么动。
/// 两者用同一个种子串起来，所以「哪一只在哪、怎么动」是**可复现**的 ——
/// 截图回归才有意义（今天绿明天也绿）。
struct ForestMote: Sendable, Equatable {

    /// 横向位置（0...1，相对容器）。
    let x: Double
    /// 纵向位置（0...1，相对容器；0 = 顶）。
    let y: Double
    /// 核心直径（pt）。
    let size: Double
    /// 游走一个来回的时长（秒）—— 长，是「飘」不是「抖」。
    let walkDuration: Double
    /// 明灭一个来回的时长（秒）—— 与游走**不同频**，两者永不同步，
    /// 出来的才是呼吸感；同频就是整片一起亮一起暗的节拍器。
    let blinkDuration: Double
    /// 游走行程（pt）。
    let walkX: Double
    let walkY: Double
}

/// 氛围微粒层：夜里飞的萤火虫、白天飘的花粉/柳絮。
///
/// 三件必须遵守的既有约定（与雨层、云层同一套）：
/// 1. **布局由种子定死**（`SeededRandom`）—— 用 `Int.random` 的代价是每次重绘
///    换一片萤火虫，用户看到的是「虫在瞬移」而不是「虫在飞」；
/// 2. **动效走 `loopAnimation`**：`reduceMotion` 打开时整段失效。⚠️ 失效后停在
///    **中间亮度**那一档（`opacity` 单独算），不是停在 0 —— 关掉动效 = 虫子
///    消失，那是把「关动效」做成了「关内容」；
/// 3. **氛围隐藏档整层移除**：与云、雨同一句承诺（连点天空 5 次，林子安静）。
///
/// ⚠️ 为什么不用 `TimelineView` 驱动：它不受 `appMotion` 约束，离屏渲染会抓到
/// 「那一刻」的帧 —— 同一个断言今天绿明天红（`AmbientSkyRenderTests` 的
/// `testStillSkyRendersDeterministically` 就是靠 `loopAnimation` 这条岔路成立的）。
/// 风钟虽也走 `TimelineView`，但它在 reduceMotion 下相位冻结在 0。
struct ForestMotes: View {

    let theme: ForestTheme
    /// 氛围演出隐藏档：整层收起。
    var still: Bool = false

    /// 夜里的萤火虫：少而亮（14 只），飞得慢、明灭明显。
    nonisolated static let fireflies: [ForestMote] = Self.make(seed: 20_261_017, count: 14, night: true)
    /// 白天的花粉：多而淡（18 粒），飘得轻、几乎不明灭。
    nonisolated static let pollen: [ForestMote] = Self.make(seed: 20_261_018, count: 18, night: false)

    var body: some View {
        GeometryReader { proxy in
            let motes = theme.isNight ? Self.fireflies : Self.pollen
            ZStack {
                ForEach(0..<motes.count, id: \.self) { index in
                    let mote = motes[index]
                    MoteParticle(
                        theme: theme,
                        mote: mote,
                        // 风场要的是**场景横坐标**与**离地高度**：微粒与地面上的草
                        // 因此处在同一条行波上，风来是一起偏的（不是各飘各的）。
                        sceneX: mote.x * proxy.size.width,
                        groundHeight: max(0, proxy.size.height * (1 - mote.y)),
                        still: still
                    )
                    .position(
                        x: mote.x * proxy.size.width,
                        y: mote.y * proxy.size.height
                    )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 造一批微粒。纯函数、无副作用 —— 单测可以直接钉「同种子同结果」。
    nonisolated static func make(seed: UInt64, count: Int, night: Bool) -> [ForestMote] {
        var generator = SeededRandom(seed: seed)
        return (0..<count).map { _ in
            ForestMote(
                x: generator.next(in: 0.05...0.95),
                y: night ? generator.next(in: 0.30...0.85) : generator.next(in: 0.12...0.80),
                // 飘絮比萤火虫小一档：它没有光晕撑着，画太大就是一团白斑。
                // 萤火虫的「大」是光晕给的（直径 ×5.2），虫身本体其实只有 2.4~4.0pt。
                size: night ? generator.next(in: 2.4...4.0) : generator.next(in: 2.2...3.4),
                walkDuration: night ? generator.next(in: 7.0...12.0) : generator.next(in: 9.0...15.0),
                blinkDuration: night ? generator.next(in: 2.2...4.6) : generator.next(in: 3.4...6.0),
                walkX: night ? generator.next(in: 12...30) : generator.next(in: 8...22),
                walkY: night ? generator.next(in: -18...18) : generator.next(in: -12...10)
            )
        }
    }
}

/// 一颗微粒：光晕 + 游走 + 明灭 + 随风漂移。
///
/// 状态只有两个「开关」（armed），位置与亮度都由开关 + 静态属性算出 ——
/// 这样 `reduceMotion` / 氛围隐藏档一变，画面**立刻**回到静止态，
/// 不用等动画跑完（切档后还在飘的虫子是 bug，见 `AmbientMotion` 的教训）。
private struct MoteParticle: View {

    let theme: ForestTheme
    let mote: ForestMote
    /// 这颗粒子在场景里的横向位置（pt），风场的空间自变量。
    let sceneX: CGFloat
    /// 这颗粒子的离地高度（pt）：风场按它放大振幅。
    let groundHeight: CGFloat
    let still: Bool

    @State private var armed = false
    @Environment(\.appMotion) private var motion
    @Environment(\.forestWind) private var wind

    /// 动不动（氛围隐藏档当场生效，不等下一帧）。
    private var animates: Bool { AmbientMotion.animates(armed: armed, still: still) }

    /// 夜里才是萤火虫；白天是飘絮（**两种东西，不是一种东西换了颜色**）。
    ///
    /// ⚠️ 2026-10-18 用户报障「白天和夜晚都是萤火虫」：第一版把白天也画成了
    /// 「暖黄发光小圆点 + 一闪一闪」—— 而**发光 + 明灭**正是萤火虫的全部辨识
    /// 特征，于是白天看着就是一树萤火虫。飘絮必须在这两点上与之**相反**：
    /// 不发光（无光晕）、不闪（明暗差 <0.1，肉眼看不出在动）、米白、扁椭圆。
    private var isFirefly: Bool { theme.isNight }

    /// 明灭的端点亮度。
    ///
    /// ⚠️ 飘絮的两端点只差 0.10：它靠**位置**被看见，不靠亮度变化。
    /// 差一大就是「会闪的白点」—— 那还是萤火虫。
    /// 但也不能太淡：浅蓝天空上的白色小点对比度天然就低，0.2 出头等于看不见
    /// （第一版就是这样，用户只会看到夜里的虫、以为白天什么都没有）。
    private var dim: Double { isFirefly ? 0.22 : 0.34 }
    private var bright: Double { isFirefly ? 0.95 : 0.44 }

    /// 当前亮度。
    ///
    /// ⚠️ `reduceMotion` 单独走**中间档**（0.55 / 0.24）：`loopAnimation` 失效后
    /// 值会直接跳到终值 —— 若终值是 `bright`，整片微粒会同时定在最亮那一瞬，
    /// 像一盏被按亮的灯；若终值是 `dim`，粒子就几乎看不见了。中间档才是
    /// 「不闪但还在」的样子。
    private var opacity: Double {
        if motion.reduceMotion { return isFirefly ? 0.55 : 0.40 }
        return animates ? bright : dim
    }

    /// 絮是**扁**的（横向拉长的椭圆），虫是圆的（正圆发光点）。
    private var coreHeight: CGFloat { mote.size * (isFirefly ? 1.0 : 0.58) }
    /// 光晕直径：夜里大（虫在发光），白天小一圈且是**白雾不是光**。
    private var haloDiameter: CGFloat { mote.size * (isFirefly ? 5.2 : 3.0) }

    var body: some View {
        ZStack {
            // 夜：萤火虫的光晕（`glow` 暖黄，向透明衰减）—— 虫的「亮」全靠这一层。
            // 昼：只是一层极淡的白雾（飘絮不发光，它只是有点毛）。
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            (isFirefly ? theme.glow : Color(hex: 0xFFFDF7)).opacity(isFirefly ? 0.55 : 0.16),
                            (isFirefly ? theme.glow : Color(hex: 0xFFFDF7)).opacity(0)
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: haloDiameter / 2
                    )
                )
                .frame(width: haloDiameter, height: haloDiameter)
            Ellipse()
                .fill(isFirefly ? theme.star : Color(hex: 0xFFFDF7))
                .frame(width: mote.size, height: coreHeight)
        }
        .opacity(opacity)
        // 明灭（内层）：与游走**不同频**，两者永不同步。
        .loopAnimation(
            .easeInOut(duration: mote.blinkDuration).repeatForever(autoreverses: true),
            value: animates
        )
        .offset(
            x: (animates ? mote.walkX : 0) + windPush,
            y: animates ? mote.walkY : 0
        )
        // 游走（外层）：慢速往返 —— 粒子是飘着的，不是被弹来弹去的。
        .loopAnimation(
            .easeInOut(duration: mote.walkDuration).repeatForever(autoreverses: true),
            value: animates
        )
        // ⚠️ 无条件置 true：静止由上面的 `animates` 拦（`still` 只在这里读一次会
        // 漏掉切档，见 `AmbientMotion` 那处「档位要乘进动画 value」的教训）。
        .onAppear { armed = true }
    }

    /// 风把这颗粒子推了多少 pt（横向）。未注入风钟 / 不吹风 → 恒 0。
    private var windPush: CGFloat {
        guard let wind else { return 0 }
        // 空中的粒子比地面上的草摆得开：离地越高风越硬（`WindField.heightFactor`）。
        return wind.offset(x: sceneX, height: groundHeight) * 1.4
    }
}
