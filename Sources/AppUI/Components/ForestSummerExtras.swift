import SwiftUI

// MARK: - 夏：草地上的叶隙光斑与夏夜流萤（#623）

// MARK: 光斑（白天）

/// 一块叶隙光斑的静态属性：被树冠筛下来的那一小摊阳光。
struct ForestDapple: Identifiable, Equatable, Sendable {

    let id: Int
    /// 横向位置（地面带宽的比例）。
    let lane: Double
    /// 长轴（pt）；短轴按 `squash` 压扁 —— 光摊在坡面上，是椭圆不是圆。
    let length: Double
    /// 压扁比（短轴 / 长轴）。
    let squash: Double
    /// 呼吸周期（秒）：树冠在动，光斑跟着一明一暗。
    let breathePeriod: Double
    /// 初相。
    let phase: Double
    /// 落在坡面里的深浅（pt，越大越靠里）。
    let inset: Double
}

/// 光斑的布局与呼吸（纯函数 / 确定性）。
enum DappleLayout {

    /// 夏日草地上的十块光斑。
    static let summerGlade: [ForestDapple] = make(seed: 0x4441_504C, count: 10)   // "DAPL"

    /// 光斑随风挪动的增益（比草叶慢：是一摊光，不是一片叶子）。
    static let driftGain: CGFloat = 0.55

    static func make(seed: UInt64, count: Int) -> [ForestDapple] {
        var rng = SeededRandom(seed: seed)
        return (0..<max(count, 0)).map { index in
            ForestDapple(
                id: index,
                lane: rng.next(in: 0.06...0.94),
                length: rng.next(in: 22...46),
                squash: rng.next(in: 0.30...0.46),
                breathePeriod: rng.next(in: 3.4...6.2),
                phase: rng.next(),
                inset: rng.next(in: 0...10)
            )
        }
    }

    /// 光斑踩的地面（地面带内的 y）：坡面 + 往坡里落的深浅。
    ///
    /// ⚠️ 与落叶堆 / 南瓜 / 雪人 / 雪堆同一条命名与口径（`XxxLayout.baseY`）：
    /// 光斑曾是唯一把 `inset` 加在 `center` 里的，调用点照别处的写法再加一次
    /// 就翻成两倍 —— 十块光斑整片沉进坡里（2026-10-23 审计实测）。
    /// 「往坡里落多少」从此只在这里加，且只加一次。
    static func baseY(
        _ dapple: ForestDapple, width: CGFloat, groundLine: ForestGroundSurface
    ) -> CGFloat {
        groundLine(width * dapple.lane) + dapple.inset
    }

    /// 光斑中心（面板/地面带坐标）：横向随风慢慢挪，纵向**就是传进来的地面**。
    ///
    /// ⚠️ `groundY` 一律走 `baseY(_:width:groundLine:)`：本函数**不再**自己加 `inset`
    /// —— 加了就是两倍（见 `baseY` 的说明）。
    static func center(
        _ dapple: ForestDapple, width: CGFloat, groundY: CGFloat, windDrift: CGFloat
    ) -> CGPoint {
        CGPoint(x: width * dapple.lane + windDrift, y: groundY)
    }

    /// 明暗呼吸（0.55…1）：树冠在风里动，漏下来的光就一明一暗。
    static func brightness(_ dapple: ForestDapple, elapsed: Double) -> Double {
        let t = elapsed / dapple.breathePeriod * 2 * .pi + dapple.phase * 2 * .pi
        return 0.55 + 0.45 * (0.5 + 0.5 * sin(t))
    }

    /// 冻结档（秒）：**每块各自**反推到呼吸的**最亮**那一瞬。
    ///
    /// ⚠️ 为什么按各自的初相反推：一层共用一个冻结时刻的话，亮度由各自的初相
    /// 决定，可能刚好停在最暗那一瞬（实测有块停在 0.58）——关动效就成了关内容。
    static func frozenElapsed(_ dapple: ForestDapple) -> Double {
        dapple.breathePeriod * (0.25 - dapple.phase)
    }
}

/// 夏日草地上被树冠筛下来的光斑（只在白天）。
///
/// ⚠️ 用 `.plusLighter` 而不是「画一个黄椭圆盖上去」：光是**加上去**的，
/// 盖上去的黄在绿草地上只会读成一块脏黄斑。
struct ForestDapples: View {

    let theme: ForestTheme
    let groundLine: ForestGroundSurface
    var still: Bool = false

    @Environment(\.appMotion) private var motion
    @Environment(\.forestWind) private var wind
    // ⚠️ 光斑也是走 `AmbientTicker` 的那一类（和蝴蝶 / 蒲公英絮 / 流萤 / 蜻蜓一样），
    // 隔着三层 view 收不到 `still:` —— 不读这个环境值的话，「连点天空 5 次」
    // 之后林子安静了、地上的光斑还在呼吸（2026-10-23 审计补的第四处）。
    @Environment(\.forestAmbientStill) private var ambientStill

    var body: some View {
        // 光斑是阳光：夜里没有（夜里那一档颜色本身就是「没有光」的意思）。
        guard !theme.isNight else { return AnyView(EmptyView()) }
        let frozen = still || ambientStill || motion.reduceMotion
        return AnyView(GeometryReader { proxy in
            AmbientTicker(paused: frozen) { tick in
                let now = frozen ? 0 : tick
                ZStack(alignment: .topLeading) {
                    ForEach(DappleLayout.summerGlade) { dapple in
                        let x = proxy.size.width * dapple.lane
                        let clock = frozen ? DappleLayout.frozenElapsed(dapple) : now
                        let drift = (wind?.offset(x: x, height: 0) ?? 0) * DappleLayout.driftGain
                        // ⚠️ `inset` 由 `baseY` 加且只加一次：`center` 不再自己加
                        // （两边都加 = 光斑整片沉进坡里，2026-10-23 审计实测）。
                        let spot = DappleLayout.center(
                            dapple, width: proxy.size.width,
                            groundY: DappleLayout.baseY(dapple, width: proxy.size.width,
                                                        groundLine: groundLine),
                            windDrift: drift
                        )
                        Ellipse()
                            .fill(
                                theme.dappleLight
                                    .opacity(0.26 * DappleLayout.brightness(dapple, elapsed: clock))
                            )
                            .frame(width: dapple.length, height: dapple.length * dapple.squash)
                            .blur(radius: 3.2)
                            .blendMode(.plusLighter)
                            .position(x: spot.x, y: spot.y)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true))
    }
}

// MARK: 流萤（夏夜）

/// 一只贴着草尖飞的萤火虫。
///
/// ⚠️ 与 `ForestMotes` 那批萤火虫**不是一批**：那批飘在整个窗口的高处、
/// 又小又冷（是「天上有虫」）；这批是夏天夜里**贴着草地**飞的，更大、
/// 更暖、飞得更慢、明灭更明显 —— 近处的一只，不是远处的一片。
struct ForestFirefly: Identifiable, Equatable, Sendable {

    let id: Int
    /// 横向基准（地面带宽的比例）。
    let lane: Double
    /// 离草坡表面的高度（pt）。
    let altitude: Double
    /// 光晕直径（pt）。
    let size: Double
    /// 漫游周期（秒）。
    let period: Double
    /// 初相。
    let phase: Double
    /// 横向 / 纵向行程（pt）。
    let travelX: Double
    let travelY: Double
    /// 明灭周期（秒）—— 与漫游**不同频**，两者永不同步（同频就是节拍器）。
    let blinkPeriod: Double
}

/// 流萤的航线与明灭（纯函数 / 确定性）。
enum FireflyLayout {

    /// 夏夜里贴着草地飞的六只。
    static let summerNight: [ForestFirefly] = make(seed: 0x4649_5246, count: 6)   // "FIRF"

    static func make(seed: UInt64, count: Int) -> [ForestFirefly] {
        var rng = SeededRandom(seed: seed)
        let total = max(count, 0)
        return (0..<total).map { index in
            let pitch = 1.0 / Double(max(total, 1))
            let lane = (Double(index) + 0.5 + (rng.next() - 0.5) * 0.72) * pitch
            // ⚠️ 高度必须大于纵向起伏：否则飞着飞着钻进草里（与蝴蝶同一条纪律）
            let travelY = rng.next(in: 4...11)
            return ForestFirefly(
                id: index,
                lane: min(max(lane, 0.08), 0.92),
                altitude: travelY + rng.next(in: 8...34),
                size: rng.next(in: 7...12),
                period: rng.next(in: 5.5...9.5),
                phase: rng.next(),
                travelX: rng.next(in: 14...34),
                travelY: travelY,
                blinkPeriod: rng.next(in: 1.8...3.4)
            )
        }
    }

    /// 此刻的位置（面板/地面带坐标）：横向一个周期、纵向两个（8 字漫游）。
    static func position(
        _ fly: ForestFirefly, width: CGFloat, groundY: CGFloat, elapsed: Double
    ) -> CGPoint {
        let t = elapsed / fly.period * 2 * .pi + fly.phase * 2 * .pi
        return CGPoint(
            x: width * fly.lane + CGFloat(fly.travelX * sin(t)),
            y: groundY - fly.altitude + CGFloat(fly.travelY * sin(2 * t))
        )
    }

    /// 此刻的亮度（0.18…1）：慢亮慢灭，不是一闪一闪的灯泡。
    static func glow(_ fly: ForestFirefly, elapsed: Double) -> Double {
        // ⚠️ 初相统一用 `2π`（不是 6.28 这种近似）：`frozenElapsed` 是按 2π 反推的，
        // 这里差 0.0032 就是「冻结时刚好差一点点没到最亮」。
        let t = elapsed / fly.blinkPeriod * 2 * .pi + fly.phase * 2 * .pi
        return 0.18 + 0.82 * (0.5 + 0.5 * sin(t))
    }

    /// 冻结档（秒）：**每只各自**反推到最亮的那一瞬（关动效不许做成关灯）。
    static func frozenElapsed(_ fly: ForestFirefly) -> Double {
        fly.blinkPeriod * (0.25 - fly.phase)
    }
}

/// 夏夜贴着草尖飞的流萤（只在夜里）。
struct ForestFireflies: View {

    let theme: ForestTheme
    let groundLine: ForestGroundSurface
    var still: Bool = false

    @Environment(\.appMotion) private var motion
    @Environment(\.forestWind) private var wind
    /// 「林子完全安静」档（连点天空 5 次）—— 隔着三层 view，走环境值不传参。
    @Environment(\.forestAmbientStill) private var ambientStill

    var body: some View {
        guard theme.isNight else { return AnyView(EmptyView()) }
        let frozen = still || ambientStill || motion.reduceMotion
        return AnyView(GeometryReader { proxy in
            AmbientTicker(paused: frozen) { tick in
                let now = frozen ? 0 : tick
                ZStack(alignment: .topLeading) {
                    ForEach(FireflyLayout.summerNight) { fly in
                        let x = proxy.size.width * fly.lane
                        let base = groundLine(x)
                        let clock = frozen ? FireflyLayout.frozenElapsed(fly) : now
                        let spot = FireflyLayout.position(
                            fly, width: proxy.size.width,
                            groundY: base, elapsed: clock
                        )
                        // 与蝴蝶 / 蒲公英絮同一条口径（见 `WindField.airHeight`）。
                        let push = (wind?.offset(
                            x: spot.x,
                            height: WindField.airHeight(groundY: base, objectY: spot.y)
                        ) ?? 0) * 1.8
                        Circle()
                            .fill(theme.fireflyGlow
                                .opacity(0.75 * FireflyLayout.glow(fly, elapsed: clock)))
                            .frame(width: fly.size, height: fly.size)
                            .blur(radius: fly.size * 0.32)
                            .blendMode(.plusLighter)
                            .position(x: spot.x + push, y: spot.y)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true))
    }
}

// MARK: 蜻蜓（夏天白天）

/// 一只贴在草尖上的蜻蜓的**静态属性**（站位 / 悬停节奏 / 扇翅节奏）：由种子定死。
struct ForestDragonfly: Identifiable, Equatable, Sendable {

    let id: Int
    /// 横向基准（地面带宽的比例 0…1）。
    let lane: Double
    /// 巡航高度（离草坡表面多少 pt）。
    let altitude: Double
    /// 体长（pt）—— 蜻蜓是细长的，翼展约等于体长。
    let size: Double
    /// 一次「悬停 → 急转」的周期（秒）。
    let dartPeriod: Double
    /// 初相（0…1）。
    let phase: Double
    /// 扇翅周期（秒）—— 比蝴蝶快一档（蜻蜓的翅膀是抖出残影的）。
    let flapPeriod: Double
    /// 一次急转挪多远（pt）。
    let dartSpan: Double
    /// 悬停时的微颤幅度（pt）：悬停不是钉住的，是在原地抖。
    let jitter: Double
    /// 站位种子：派生每一轮的悬停点（同一轮永远同一个点 → 重绘不换地方）。
    let stationSeed: UInt64
}

/// 蜻蜓的悬停与急转（纯函数 / 确定性）。
enum DragonflyLayout {

    /// 夏天草尖上的五只蜻蜓。
    static let summerGlade: [ForestDragonfly] = make(seed: 0x4452_4144, count: 5)   // "DRAD"

    /// 一个周期里**悬停**占的比例（剩下那一段是急转）。
    ///
    /// 0.74 → 8 秒的周期里悬停约 6 秒、急转约 2 秒：蜻蜓是「钉在那儿盯半天，
    /// 忽然蹿出去」。反过来（急转占大头）就成了一只一直在乱飞的虫，
    /// 那不是蜻蜓，是蚊子。
    static let hoverFraction: Double = 0.74

    /// 悬停微颤在一轮里的振荡次数（**必须是整数**）：首尾两端都归零，航迹才连续
    /// —— 端点不为零的话，每次进出悬停都会瞬移一下（旧版飘絮踩过同一个坑）。
    static let hoverBeats = 3

    /// 急转时抬起的弧度（pt）：换地方是**蹿**过去的，不是贴着草平移过去。
    static let dartLift: Double = 5

    /// 高宽比（翼展 / 体长）。
    static let aspect: Double = 0.9

    /// 风位移增益：蜻蜓是自己飞的主 —— 风推得动草，推不动它（比蝴蝶的 2.2 小一档）。
    static let windGain: CGFloat = 1.2

    static func make(seed: UInt64, count: Int) -> [ForestDragonfly] {
        var rng = SeededRandom(seed: seed)
        let total = max(count, 0)
        return (0..<total).map { index in
            let pitch = 1.0 / Double(max(total, 1))
            let lane = (Double(index) + 0.5 + (rng.next() - 0.5) * 0.7) * pitch
            let dartSpan = rng.next(in: 18...34)
            // ⚠️ 巡航高度必须**大于**纵向游走：游走比高度还大的话，蜻蜓会一头
            // 扎进草坡里（航线的最低点 = 高度 − 游走）。
            let wander = dartSpan * 0.35
            return ForestDragonfly(
                id: index,
                lane: min(max(lane, 0.10), 0.90),
                altitude: wander + rng.next(in: 12...30),
                // ⚠️ 体长 22…30pt 是**故意**比蝴蝶（13…19pt）大的：蜻蜓的翼展本来
                // 就比蝴蝶大一圈。而膜翅在 20pt 的虫身上只有 1pt 宽 —— 第一版按
                // 17…25pt 出图，五只加起来只多出 294 墨量（放大翅面后是 529，
                // 同一把尺的前后对比）。
                size: rng.next(in: 22...30),
                dartPeriod: rng.next(in: 5.5...9.5),
                phase: rng.next(),
                flapPeriod: rng.next(in: 0.18...0.28),
                dartSpan: dartSpan,
                jitter: rng.next(in: 1.2...2.6),
                stationSeed: seed &+ UInt64(index + 1) &* 0x85EB_CA6B
            )
        }
    }

    /// 第 `cycle` 轮的悬停点（面板/地面带坐标）：横向围着自己的 `lane`、
    /// 高度贴着草尖 —— 每一轮换一个点，蜻蜓因此是**一块一块草尖轮流停**。
    static func hoverAnchor(
        _ fly: ForestDragonfly, cycle: Int, width: CGFloat, groundY: CGFloat
    ) -> CGPoint {
        var rng = SeededRandom(
            seed: fly.stationSeed &+ UInt64(bitPattern: Int64(cycle)) &* 0x9E37_79B9_7F4A_7C15
        )
        let dx = rng.next(in: -fly.dartSpan...fly.dartSpan)
        let dy = rng.next(in: -fly.dartSpan * 0.35...fly.dartSpan * 0.35)
        return CGPoint(x: width * fly.lane + dx, y: groundY - fly.altitude + dy)
    }

    /// 此刻的位置（面板/地面带坐标）：悬停段**原地微颤**，急转段**蹿去下一个点**。
    ///
    /// ⚠️ 两段的接缝必须对上，否则每次状态切换都是一次瞬移：
    /// - 悬停段的微颤取 `sin(u · 2π · hoverBeats)`，`u` 从 0 到 1 → 两端都是 0；
    /// - 急转段从 `from` 平滑走到 `to`，抬起的弧度 `sin(u · π)` 两端也都是 0；
    /// - 急转的终点正是下一轮的悬停点（`cycle + 1`）。
    static func position(
        _ fly: ForestDragonfly, width: CGFloat, groundY: CGFloat, elapsed: Double
    ) -> CGPoint {
        let raw = elapsed / fly.dartPeriod + fly.phase
        let local = raw - raw.rounded(.down)
        let cycle = Int(raw.rounded(.down))
        let from = hoverAnchor(fly, cycle: cycle, width: width, groundY: groundY)
        if local < hoverFraction {
            let beat = sin(local / hoverFraction * 2 * .pi * Double(hoverBeats))
            return CGPoint(x: from.x + CGFloat(fly.jitter * beat),
                           y: from.y + CGFloat(fly.jitter * 0.6 * beat))
        }
        let to = hoverAnchor(fly, cycle: cycle + 1, width: width, groundY: groundY)
        let u = (local - hoverFraction) / (1 - hoverFraction)
        let eased = u * u * (3 - 2 * u)
        return CGPoint(x: from.x + (to.x - from.x) * eased,
                       y: from.y + (to.y - from.y) * eased - CGFloat(dartLift * sin(u * .pi)))
    }

    /// 此刻朝哪边飞：急转的方向（悬停时它已经在盯着下一个落点了）。
    static func heading(
        _ fly: ForestDragonfly, width: CGFloat, groundY: CGFloat, elapsed: Double
    ) -> Double {
        let raw = elapsed / fly.dartPeriod + fly.phase
        let cycle = Int(raw.rounded(.down))
        let from = hoverAnchor(fly, cycle: cycle, width: width, groundY: groundY)
        let to = hoverAnchor(fly, cycle: cycle + 1, width: width, groundY: groundY)
        return to.x - from.x
    }

    /// 翅的伸展量（0…1）：1 = 完全展开。
    static func flap(_ fly: ForestDragonfly, elapsed: Double) -> Double {
        0.5 + 0.5 * cos(elapsed / fly.flapPeriod * 2 * .pi)
    }

    /// 冻结档（秒）：**每只各自**停在悬停段的正中间。
    ///
    /// ⚠️ 为什么不按周期中段取：中段有可能落在急转的半空中 —— 一只被定在半空
    /// 的蜻蜓看着像钉在墙上。停在悬停段，出来的是「正停在那儿盯」的姿态，
    /// 那才是静照里的蜻蜓（关动效不许做成关内容，也不许做成定格穿帮）。
    static func frozenElapsed(_ fly: ForestDragonfly) -> Double {
        // `+ 1` 只为把结果抬到正数（相位可能已经过了悬停中点）：
        // 悬停点按轮次派生，抬一轮只是换了个落点，不影响确定性。
        fly.dartPeriod * (hoverFraction * 0.5 - fly.phase + 1)
    }
}

/// 夏天草尖上的蜻蜓（只在白天）：悬停盯半天，忽然蹿去下一根草尖。
///
/// ⚠️ 与 `ForestFireflies` 互补：白天是蜻蜓、夜里是流萤 —— 夏天的草地因此
/// 一天两副样子，跟光斑（只白天）/ 流萤（只夜里）同一条日夜分工。
struct ForestDragonflies: View {

    let theme: ForestTheme
    let groundLine: ForestGroundSurface
    var still: Bool = false

    @Environment(\.appMotion) private var motion
    @Environment(\.forestWind) private var wind
    /// 「林子完全安静」档（连点天空 5 次）—— 隔着三层 view，走环境值不传参。
    @Environment(\.forestAmbientStill) private var ambientStill

    var body: some View {
        // 蜻蜓是**白天**的虫：夜里它停在草叶背面，画面上不该有。
        guard !theme.isNight else { return AnyView(EmptyView()) }
        let frozen = still || ambientStill || motion.reduceMotion
        return AnyView(GeometryReader { proxy in
            AmbientTicker(paused: frozen) { tick in
                let now = frozen ? 0 : tick
                ZStack(alignment: .topLeading) {
                    ForEach(DragonflyLayout.summerGlade) { fly in
                        let base = groundLine(proxy.size.width * fly.lane)
                        let clock = frozen ? DragonflyLayout.frozenElapsed(fly) : now
                        let spot = DragonflyLayout.position(
                            fly, width: proxy.size.width, groundY: base, elapsed: clock
                        )
                        // 风场要的是**离地高度**（与蝴蝶 / 流萤共用 `WindField.airHeight`）
                        let push = (wind?.offset(
                            x: spot.x,
                            height: WindField.airHeight(groundY: base, objectY: spot.y)
                        ) ?? 0) * DragonflyLayout.windGain
                        DragonflyBody(theme: theme,
                                      flap: DragonflyLayout.flap(fly, elapsed: clock))
                            .frame(width: CGFloat(fly.size),
                                   height: CGFloat(fly.size) * DragonflyLayout.aspect)
                            // 朝飞行方向：往左蹿就翻个面（不然永远是同一侧的侧影）
                            .scaleEffect(
                                x: DragonflyLayout.heading(fly, width: proxy.size.width,
                                                           groundY: base, elapsed: clock) < 0
                                    ? -1 : 1,
                                y: 1, anchor: .center
                            )
                            .position(x: spot.x + push, y: spot.y)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true))
    }
}

/// 一只蜻蜓：四片膜翅 + 胸腹 + 两只复眼（unit 画框，靠 frame 缩放）。
private struct DragonflyBody: View {

    let theme: ForestTheme
    /// 翅的伸展量（0…1，见 `DragonflyLayout.flap`）。
    let flap: Double

    var body: some View {
        ZStack {
            DragonflyWings(flap: flap)
                .fill(theme.dragonflyWing.opacity(0.6))
                .overlay(
                    DragonflyWings(flap: flap)
                        .stroke(theme.dragonflyWing.opacity(0.92), lineWidth: 0.6)
                )
            DragonflyFrame()
                .fill(theme.dragonflyBody)
            DragonflyEyes()
                .fill(theme.dragonflyEye)
        }
    }
}

/// 四片膜翅：从胸节伸出去，前翅略朝前、后翅略朝后（unit 画框）。
///
/// ⚠️ `flap` 改的是**翅的伸展长度**而不是把它转起来：蜻蜓的翅抖得极快，
/// 肉眼看到的是翅面在「展开—收窄」之间来回（透视上的残影），不是两把扇子
/// 上下翻 —— 真去转它，20fps 下只会读成抽搐。
private struct DragonflyWings: Shape {

    /// 伸展量（0…1）：1 = 完全展开，0.62 = 收到最窄的那一瞬。
    var flap: Double

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let midY = rect.midY
        let spread = 0.62 + 0.38 * flap
        var path = Path()
        // ⚠️ 翅的**厚度**是 0.08 个画框宽而不是「一条线加细描边」：膜翅在 26pt
        // 的虫身上只有 2pt 宽，画成描边会在缩放与抗锯齿下整片消失（第一版实测
        // 五只一共才 294 墨量 —— 草地看起来还是空的）。
        let blade = w * 0.08
        // 前翅：朝上 / 朝下，略往前偏
        wing(&path, root: CGPoint(x: rect.minX + w * 0.64, y: midY),
             length: h * 0.46 * spread, thickness: blade, angle: -.pi / 2 + 0.30)
        wing(&path, root: CGPoint(x: rect.minX + w * 0.64, y: midY),
             length: h * 0.46 * spread, thickness: blade, angle: .pi / 2 - 0.30)
        // 后翅：短一截，略往后偏
        wing(&path, root: CGPoint(x: rect.minX + w * 0.55, y: midY),
             length: h * 0.42 * spread, thickness: blade, angle: -.pi / 2 - 0.34)
        wing(&path, root: CGPoint(x: rect.minX + w * 0.55, y: midY),
             length: h * 0.42 * spread, thickness: blade, angle: .pi / 2 + 0.34)
        return path
    }

    /// 一片翅：一枚细长的椭圆，从**翅根**沿 `angle` 方向长出去。
    private func wing(_ path: inout Path, root: CGPoint, length: CGFloat,
                      thickness: CGFloat, angle: CGFloat) {
        let blade = CGRect(x: -length / 2, y: -thickness / 2, width: length, height: thickness)
        var transform = CGAffineTransform(translationX: root.x, y: root.y)
        transform = transform.rotated(by: angle)
        transform = transform.translatedBy(x: length / 2, y: 0)
        path.addEllipse(in: blade, transform: transform)
    }
}

/// 胸 + 细长的腹部 + 头（unit 画框）。
///
/// ⚠️ 那条**收细到尾尖的腹部**是「这是蜻蜓不是蝴蝶」的辨识点（蝴蝶是短胖的
/// 身子加一对大翅膀），20pt 上也要留出来。
private struct DragonflyFrame: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let midY = rect.midY
        var path = Path()
        // 胸：一节短粗的椭圆（翅膀就长在这一节上）
        path.addEllipse(in: CGRect(x: rect.minX + w * 0.52, y: midY - h * 0.09,
                                   width: w * 0.20, height: h * 0.18))
        // 腹：从胸一路收细到尾尖
        path.move(to: CGPoint(x: rect.minX + w * 0.54, y: midY - h * 0.055))
        path.addQuadCurve(to: CGPoint(x: rect.minX + w * 0.10, y: midY - h * 0.012),
                          control: CGPoint(x: rect.minX + w * 0.30, y: midY - h * 0.045))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.10, y: midY + h * 0.012))
        path.addQuadCurve(to: CGPoint(x: rect.minX + w * 0.54, y: midY + h * 0.055),
                          control: CGPoint(x: rect.minX + w * 0.30, y: midY + h * 0.045))
        path.closeSubpath()
        // 头：一小颗（复眼另画在它上面）
        path.addEllipse(in: CGRect(x: rect.minX + w * 0.72, y: midY - h * 0.07,
                                   width: w * 0.13, height: h * 0.14))
        return path
    }
}

/// 两只复眼（蜻蜓的脑袋就是那两颗大眼）。
private struct DragonflyEyes: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let midY = rect.midY
        let eye = w * 0.06
        var path = Path()
        path.addEllipse(in: CGRect(x: rect.minX + w * 0.735,
                                   y: midY - h * 0.035 - eye / 2,
                                   width: eye, height: eye))
        path.addEllipse(in: CGRect(x: rect.minX + w * 0.735,
                                   y: midY + h * 0.035 - eye / 2,
                                   width: eye, height: eye))
        return path
    }
}
