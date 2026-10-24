import SwiftUI

// MARK: - 四季天空里的飞鸟群（2026-10-23）

/// 四季各一群什么鸟：秋沿用原来的雁阵，其余三季按「这个季节天上常见什么、
/// 且一眼分得出」配 —— 春白鹭、夏家燕、冬灰鹤。
///
/// ⚠️ 四种鸟不是换个颜色就完事：体型、翼形、尾形、扇翅快慢、队形全都不同
/// （家燕 0.4s 抖一次翅、灰鹤 1.1s 才抡一下；雁是 V 字、鹭与鹤是斜线、
/// 燕子是散群）—— 只换色的话，用户看到的还是「同一只鸟被染了四种颜色」，
/// 季节就白分了。
public enum BirdKind: String, CaseIterable, Sendable {

    /// 春：白鹭 —— 白身长颈，粗圆翼慢扇，松散斜线。
    case egret
    /// 夏：家燕 —— 黑背白腹剪刀尾，尖翼快扇，成群散飞。
    case swallow
    /// 秋：大雁 —— V 字，抻着脖子，中速抡翅。
    case goose
    /// 冬：灰鹤 —— 白身黑翼尖，一字斜线，翼极大、抡得极慢。
    case crane

    /// 这个季节天上飞的是哪一种。
    public static func forSeason(_ season: ForestSeason) -> BirdKind {
        switch season {
        case .spring: return .egret
        case .summer: return .swallow
        case .autumn: return .goose
        case .winter: return .crane
        }
    }

    /// 造这群鸟用的种子：不同季节必须是不同的一群（同一种群重绘不许换一批）。
    public var seed: UInt64 {
        switch self {
        case .egret: return 0x4547_5245      // "EGRE"
        case .swallow: return 0x5357_414C    // "SWAL"
        case .goose: return 0x4745_4553      // "GEES"
        case .crane: return 0x4352_414E      // "CRAN"
        }
    }

    /// 一群几只。雁阵原来是 7 只（一个 V），其余按这个鸟种的常见群体规模取。
    public var count: Int {
        switch self {
        case .egret: return 5
        case .swallow: return 9
        case .goose: return 7
        case .crane: return 6
        }
    }

    /// 翅展区间（pt）。
    ///
    /// ⚠️ 这个尺度是「隔着整幅宽从树面板上方掠过」的尺度：12pt 上下才读得出
    /// 是一只鸟而不是一个点，再大就开始像贴纸。
    public var sizeRange: ClosedRange<Double> {
        switch self {
        case .egret: return 12...16
        case .swallow: return 9...12
        case .goose: return 11...16
        case .crane: return 15...21
        }
    }

    /// 扇翅周期区间（秒）。
    public var flapPeriodRange: ClosedRange<Double> {
        switch self {
        case .egret: return 0.75...1.05
        case .swallow: return 0.34...0.46
        case .goose: return 0.55...0.85
        case .crane: return 1.05...1.45
        }
    }

    /// 扇翅带起的上下起伏区间（pt）。
    public var bobRange: ClosedRange<Double> {
        switch self {
        case .egret: return 1.0...2.2
        case .swallow: return 0.6...1.4
        case .goose: return 1.0...2.6
        case .crane: return 1.6...3.0
        }
    }

    /// 高 / 宽（`size` 是翅展）：身子比翼展矮得多。
    public var aspect: Double {
        switch self {
        case .egret: return 0.66
        case .swallow: return 0.58
        case .goose: return 0.62
        case .crane: return 0.70
        }
    }

    /// 队形。
    public var formation: FlockFormation {
        switch self {
        case .egret: return .line
        case .swallow: return .scatter
        case .goose: return .vee
        case .crane: return .line
        }
    }
}

/// 鸟群的队形：三种，按鸟种定死。
public enum FlockFormation: String, Sendable {

    /// V 字（雁阵）：越靠后越往后退、越往外挪。
    case vee
    /// 斜线（白鹭 / 灰鹤）：沿航向排开，横向只错开一小截。
    case line
    /// 散群（家燕）：每只各有前后上下的固定错位，没有整齐队形。
    case scatter
}

/// 一只鸟的**静态属性**：全部由种子定死，重绘不许换一批。
///
/// 站位（`rank` / `wing` / `drift`）与节奏（扇翅周期 / 初相 / 起伏 / 慢漂初相）
/// 分开定：队形决定它排在哪，节奏决定它怎么扇。同种子 → 同结果，
/// 离屏回归才有意义。
struct ForestBird: Identifiable, Equatable, Sendable {

    let kind: BirdKind
    let id: Int
    /// 队形里的序号：0 = 头鸟，1… 依次往后。
    let rank: Int
    /// 侧向：-1 上（画面上方）/ +1 下；头鸟是 0。
    let wing: Int
    /// 翅展（pt）。
    let size: Double
    /// 扇翅周期（秒）。
    let flapPeriod: Double
    /// 扇翅初相（0…1）：一群不同相，才不像挂在同一根线上的一排纸片。
    let flapPhase: Double
    /// 扇翅带起的上下起伏（pt）。
    let bob: Double
    /// 慢速上下游移的初相（秒）：每只不同，一群才不会整群一起坐电梯。
    let swayPhase: Double
    /// 散群队形里的固定错位（pt，unit 相对翅展）：只有 `scatter` 用得上。
    let drift: CGSize
}

// MARK: - 航线与队形（纯函数 / 确定性，可单测）

/// 飞鸟群的航线与队形（纯函数）。
///
/// 三条用户 2026-10-23 点名的要求都在这里：
/// 1. **贯穿整个中间栏 + 右栏** —— 幅宽由调用方传（`MainView` 传的是
///    `chatW + resizeHandleWidth + treeW`），进出画面按队形跨度留余量；
/// 2. **随机从左往右或从右往左** —— 方向按「趟」定（同一个时刻永远同一个方向，
///    不会飞到一半集体变向；掉头折返是另一种行为，见 `turnsBack`）；
/// 3. **较慢、微小、肉眼可见的上下位移** —— `sway` 用**绝对时间**驱动，
///    周期远长于扇翅，幅度 9pt。
///
/// ⚠️ 为什么不用横渡进度（`progress`）驱动上下位移：进度每趟归零，位移会被绑在
/// 「一趟」上，来回两趟各起伏一次，看起来像在打拍子；而且换趟、掉头折返时相位
/// 会断。绝对时间驱动下位移是连续的慢漂。
enum FlockLayout {

    // MARK: 航线常量

    /// 横渡一趟的时长（秒）：比雁阵原来的 78s 再慢一档 —— 是「缓缓掠过」。
    static let crossingPeriod: Double = 96

    /// 开屏时鸟群已经飞到哪儿（0…1 的横渡进度）。
    ///
    /// 不是 0：0 是「刚从左边缘露头」，每次开屏都一样，看着像触发器而不是一群
    /// 恰好路过的鸟。
    static let startPhase: Double = 0.18

    /// 整群所在的高度（**相对整窗高**的比例，自上而下）：上三分之一带里。
    ///
    /// ⚠️ 与风筝 / 雁阵同一条纪律：那以下是树冠与关卡节点的地盘，鸟群压上去
    /// 就是挡住内容的贴纸。取 0.17 而不是更靠上：队形两翼还往外张，
    /// 加上 ±9pt 的慢漂，站在 0.30 时最下面那只已经顶出这条带了。
    static let altitude: Double = 0.17
    static let altitudeBand: ClosedRange<Double> = 0.08...0.26

    /// 慢速上下游移的幅度（pt）：肉眼可见，但不至于像在坐电梯。
    static let swayAmp: Double = 9

    /// 慢速上下游移的周期（秒）。
    ///
    /// ⚠️ 必须远长于扇翅周期（0.34~1.45s）、又远短于一趟横渡（96s）：
    /// 短于扇翅就成了抖，长于一趟就成了「这一趟都在爬升」。
    static let swayPeriod: Double = 26

    /// 折返趟走到可飞段的这个比例就回头。
    static let turnFraction: Double = 0.55

    /// 一趟里折返的概率（0…1）：剩下的是直穿整幅。
    static let turnChance: Double = 0.30

    /// 风位移增益：高空没有东西挡着，但鸟是**自己在飞**的 —— 风推得动草，
    /// 推不动一群赶路的鸟，所以比风筝小一档（沿用雁阵的 0.5）。
    static let windGain: CGFloat = 0.5

    /// 队形里「往后退多少倍翅展」/「往外挪多少倍翅展」。
    ///
    /// `wingGap / rankGap ≈ 0.54` → 两翼与航向成约 28°，是雁阵那个 V 的角度；
    /// 再张（比例接近 1）就成了一字横排，再收（比例接近 0）就成了纵队。
    static let rankGap: Double = 1.15
    static let wingGap: Double = 0.62

    /// 整群横渡途中上下那一小段（pt）：与 `sway` 是两件事。
    ///
    /// 这一段按**进度**走（一趟一个起伏）：负责「这一群整体在往上去一点」。
    /// `sway` 按**绝对时间**走：负责「飞行途中持续的慢漂」。两个叠起来才像活的。
    static let flockDrift: Double = 5

    // MARK: 一群鸟

    /// 造一群鸟（纯函数：同一种永远同一群 —— 重绘换一批 = 用户在看瞬移）。
    ///
    /// - `rank` / `wing` 由 index 定死（不是随机抽）：队形必须是**一个形状**，
    ///   随机出来的只会在大概对的位置上散成一团；
    /// - 会随机的只有翅展 / 节奏 / 起伏 / 慢漂初相这些「各只不同」的量。
    static func flock(_ kind: BirdKind) -> [ForestBird] {
        var rng = SeededRandom(seed: kind.seed)
        let total = max(kind.count, 0)
        return (0..<total).map { index in
            ForestBird(
                kind: kind,
                id: index,
                rank: (index + 1) / 2,
                wing: index == 0 ? 0 : (index % 2 == 1 ? -1 : 1),
                size: rng.next(in: kind.sizeRange),
                flapPeriod: rng.next(in: kind.flapPeriodRange),
                flapPhase: rng.next(),
                bob: rng.next(in: kind.bobRange),
                swayPhase: rng.next(in: 0...swayPeriod),
                drift: CGSize(
                    width: rng.next(in: -1.6...1.6),
                    height: rng.next(in: -1.4...1.4)
                )
            )
        }
    }

    // MARK: 趟次 / 方向 / 掉头

    /// 第几趟（`elapsed` 落在哪一段行程里）。一趟 = 一次完整的横渡或折返。
    static func cycle(_ elapsed: Double) -> Int {
        Int((elapsed / crossingPeriod + startPhase).rounded(.down))
    }

    /// 这一趟的方向（+1 左→右 / -1 右→左）。
    ///
    /// ⚠️ 按趟散列而不是 `cycle % 2`：交替的话用户能看出规律（左右左右），
    /// 而且两头永远对称。散列后同一趟永远同向（不跳变），趟与趟之间看不出规律。
    static func direction(_ cycle: Int) -> Double {
        var rng = SeededRandom(seed: 0x4244_4952 ^ UInt64(truncatingIfNeeded: Int64(cycle)))
        return rng.next() < 0.5 ? -1 : 1
    }

    /// 这一趟是不是「飞到一半掉头折返」。
    static func turnsBack(_ cycle: Int) -> Bool {
        var rng = SeededRandom(seed: 0x4252_4E44 ^ UInt64(truncatingIfNeeded: Int64(cycle)))
        return rng.next() < turnChance
    }

    /// 横渡进度（0…1）：0 = 整群刚出起点边界，1 = 整群刚出终点边界。
    static func crossingProgress(_ elapsed: Double) -> Double {
        let raw = elapsed / crossingPeriod + startPhase
        return raw - raw.rounded(.down)
    }

    /// 这一趟的「前进量」（0…1，含折返）：0 = 起点（画外），峰值 = 走到最远处。
    ///
    /// 折返趟走到 `turnFraction` 就回头 —— 鸟群进画面中段、掉头、原路飞出去，
    /// 而不是每次都横穿整幅（用户 2026-10-23：「甚至可以在贯穿的过程中掉头」）。
    static func forward(_ progress: Double, back: Bool) -> Double {
        guard back else { return progress }
        if progress < 0.5 {
            return progress / 0.5 * turnFraction
        }
        return (1 - progress) / 0.5 * turnFraction
    }

    /// 朝向（+1 朝右 / -1 朝左）：折返点前后各一段，整群同时翻面。
    ///
    /// ⚠️ 由**前进量的导数**决定而不是由 `dir` 决定：折返的后半程 `dir` 没变，
    /// 但鸟确实在往回飞 —— 朝向不跟着翻的话，会看到一只「倒着飞」的鸟。
    static func heading(_ progress: Double, back: Bool, dir: Double) -> Double {
        guard back else { return dir }
        return progress < 0.5 ? dir : -dir
    }

    /// 冻结档的时间（秒）：整群停在**最远点**（progress = 0.5）。
    ///
    /// ⚠️ 不是 0：`elapsed = 0` 时进度是 `startPhase`（0.18），整群**刚进场** ——
    /// 头鸟在左边缘内约 21pt，后面几只还在画外，静照里看不出是个群。
    /// 0.5 对直穿趟是画面正中、对折返趟正是折返点（最远处），两种趟整群都在画面里。
    static func frozenElapsed() -> Double {
        crossingPeriod * (0.5 - startPhase)
    }

    // MARK: 位置

    /// 进出画面要留的余量（pt）：整群**整群**进出画面的，不是一只只在边界上生出来。
    static func margin(_ kind: BirdKind) -> CGFloat {
        formationSpan(kind) + maxSize(kind)
    }

    /// 这群里最大的翅展（pt）。
    static func maxSize(_ kind: BirdKind) -> CGFloat {
        CGFloat(flock(kind).map(\.size).max() ?? 0)
    }

    /// 这只鸟相对**头鸟**的站位偏移（pt）：队形决定的部分。
    static func formationOffset(_ bird: ForestBird) -> CGSize {
        let step = Double(bird.rank)
        switch bird.kind.formation {
        case .vee:
            return CGSize(
                width: -step * rankGap * bird.size,
                height: Double(bird.wing) * step * wingGap * bird.size
            )
        case .line:
            // 斜线：沿航向排开，横向只错开一小截 —— 鹭与鹤是「一排」而不是一个 V。
            return CGSize(
                width: -step * rankGap * bird.size,
                height: Double(bird.wing) * step * wingGap * 0.28 * bird.size
            )
        case .scatter:
            // 散群：每只各有固定错位，没有整齐队形（家燕就是这么飞的）。
            return CGSize(
                width: -step * rankGap * 0.8 * bird.size + bird.drift.width * bird.size,
                height: bird.drift.height * bird.size
            )
        }
    }

    /// 队形从最外侧那只到头鸟的跨度（pt）。
    ///
    /// 进出画面要按它留余量（见 `margin`）：不留的话鸟群会在画面中间
    /// 「凭空出现 / 凭空消失」—— 那正是用户在风筝上最不能忍的那种穿帮。
    static func formationSpan(_ kind: BirdKind) -> CGFloat {
        flock(kind).reduce(0) { partial, bird in
            let off = formationOffset(bird)
            return max(partial, max(abs(off.width), abs(off.height)) + bird.size)
        }
    }

    /// 此刻**头鸟**的位置（面板坐标）。
    ///
    /// - `width` / `height` 是**整幅**的尺寸：中间栏与右栏合起来的幅宽、整窗高。
    ///   高度带的基准必须是整窗高（这一层的画布只有窗高的三分之一，
    ///   拿它当基准的话「上三分之一」会挤成窗口最顶上一条）。
    static func leadPosition(
        _ kind: BirdKind, width: CGFloat, height: CGFloat, elapsed: Double
    ) -> CGPoint {
        let progress = crossingProgress(elapsed)
        let cyc = cycle(elapsed)
        let dir = direction(cyc)
        let back = turnsBack(cyc)
        let step = forward(progress, back: back)
        let margin = margin(kind)
        let span = width + margin * 2
        let x = dir > 0
            ? -margin + step * span
            : width + margin - step * span
        return CGPoint(
            x: x,
            y: height * altitude + CGFloat(sin(progress * 2 * .pi) * flockDrift)
        )
    }

    /// 这只鸟此刻的位置（面板坐标）：头鸟位置 + 队形偏移 + 慢漂 + 扇翅起伏。
    static func position(
        _ bird: ForestBird, width: CGFloat, height: CGFloat, elapsed: Double
    ) -> CGPoint {
        let lead = leadPosition(bird.kind, width: width, height: height, elapsed: elapsed)
        let offset = formationOffset(bird)
        return CGPoint(
            x: lead.x + offset.width,
            y: lead.y + offset.height + sway(bird, elapsed: elapsed) + bobOffset(bird, elapsed: elapsed)
        )
    }

    /// 扇翅量（-1…1）：1 = 翅尖抡到最高，-1 压到最低。
    static func flap(_ bird: ForestBird, elapsed: Double) -> Double {
        sin(elapsed / bird.flapPeriod * 2 * .pi + bird.flapPhase * 2 * .pi)
    }

    /// 扇翅带起的上下起伏（pt）：翅膀压下时身子抬一点（与扇翅**同频同相**）。
    ///
    /// 为什么不另给一个周期：鸟在天上没有别的东西托着它，扇翅带出来的那一点
    /// 就是它唯一快的上下运动 —— 另起一个快周期就成了「一边飞一边抖」。
    static func bobOffset(_ bird: ForestBird, elapsed: Double) -> CGFloat {
        CGFloat(-bird.bob * flap(bird, elapsed: elapsed))
    }

    /// 慢速上下游移（pt）：一群鸟不会飞成一条笔直的线，但也不是在坐电梯。
    static func sway(_ bird: ForestBird, elapsed: Double) -> CGFloat {
        CGFloat(sin(elapsed / swayPeriod * 2 * .pi + bird.swayPhase) * swayAmp)
    }

    /// 整群此刻的朝向（+1 朝右 / -1 朝左）：折返时整群同时翻面。
    static func heading(_ kind: BirdKind, elapsed: Double) -> Double {
        let cyc = cycle(elapsed)
        let progress = crossingProgress(elapsed)
        return heading(progress, back: turnsBack(cyc), dir: direction(cyc))
    }
}

// MARK: - 羽色

/// 一只鸟的三色：身子 / 翼 / 点睛（喙、喉、翼尖）。
public struct BirdPlumage: Sendable {

    public let body: Color
    public let wing: Color
    public let accent: Color

    public init(body: Color, wing: Color, accent: Color) {
        self.body = body
        self.wing = wing
        self.accent = accent
    }
}

extension ForestTheme {

    /// 飞鸟群的羽色（2026-10-23，插画层专用）。
    ///
    /// 夜档一律压暗一档（与风筝 / 蝴蝶同一条纪律）：夜里不该有一群比星星还亮的鸟，
    /// 但也不能暗到看不见。白鹭与灰鹤的身子是白的，夜里改成月光白 ——
    /// 纸白在夜空上会「发光」，反而把天烧出一个洞。
    public func plumage(for kind: BirdKind) -> BirdPlumage {
        switch kind {
        case .egret:
            return BirdPlumage(
                body: isNight ? Color(hex: 0xC9D4DE) : Color(hex: 0xFFFFFF),
                wing: isNight ? Color(hex: 0x8E9EAC) : Color(hex: 0xE8EEF3),
                accent: isNight ? Color(hex: 0x8A7442) : Color(hex: 0xE8B23A)
            )
        case .swallow:
            return BirdPlumage(
                body: isNight ? Color(hex: 0x1A1E26) : Color(hex: 0x2A2E36),
                wing: isNight ? Color(hex: 0x22272F) : Color(hex: 0x363C46),
                accent: isNight ? Color(hex: 0x7E8894) : Color(hex: 0xF2F4F7)
            )
        case .goose:
            return BirdPlumage(
                body: isNight ? Color(hex: 0x5A6E82) : Color(hex: 0x38434E),
                wing: isNight ? Color(hex: 0x6E8296) : Color(hex: 0x4A5A66),
                accent: isNight ? Color(hex: 0x8A99A6) : Color(hex: 0xD8DEE4)
            )
        case .crane:
            return BirdPlumage(
                body: isNight ? Color(hex: 0xC2CCD6) : Color(hex: 0xF4F6F8),
                wing: isNight ? Color(hex: 0xA8B4C0) : Color(hex: 0xE6EAEE),
                accent: isNight ? Color(hex: 0x12151A) : Color(hex: 0x1E2228)
            )
        }
    }
}

// MARK: - 视图

/// 四季天空里的飞鸟群：一群缓缓横渡（或飞到一半掉头折返），翅膀按自己的节奏抡。
///
/// 三条既有约定（与 `ForestKites` / 原来的 `ForestGeese` 同一套）：
/// 1. **位置由时间算出来**（`FlockLayout` 的纯函数），不是 `withAnimation` 推 ——
///    重绘时相位不会跳，鸟群不会集体瞬移；
/// 2. **风读全局风钟**（`@Environment(\.forestWind)`）：鸟与地上的草、飘的落叶
///    处在**同一阵风**里。未注入风钟（离屏夹具、旧渲染测试）位移恒 0；
/// 3. **`reduceMotion` / 氛围隐藏档下冻结在最远点**，不是整层消失（关动效 ≠ 关内容）。
///
/// ⚠️ **画在最底层**（天空之上、内容之下，2026-10-23 用户选定）：鸟群要贯穿中间
/// 对话栏与右栏，而中间栏有真实的聊天文字 —— 压在文字上会挡住阅读。中间栏因此把
/// 那层底色改成半透明的季节色（`ForestTheme.chatBackdrop`），鸟从底下透出来。
struct ForestSeasonBirds: View {

    let theme: ForestTheme
    let kind: BirdKind
    /// 静态档（离屏出图 / 氛围隐藏）：冻结在最远点，不推进时间。
    var still: Bool = false
    /// 整窗高（pt）：高度带（上三分之一）的基准。
    ///
    /// ⚠️ 不能拿这一层自己的高度当基准 —— 它只有窗高的三分之一（画布就是裁剪区），
    /// 拿它当基准的话「上三分之一」会挤成窗口最顶上一条线。
    var windowHeight: CGFloat

    @Environment(\.appMotion) private var motion
    @Environment(\.forestWind) private var wind
    // ⚠️ 与地面带那几层同一条路：氛围隐藏档走环境值，将来挪位置也不会漏。
    @Environment(\.forestAmbientStill) private var ambientStill

    var body: some View {
        // ⚠️ 档位判在 body 里（不在 onAppear）：切档不重新 appear，
        // 判在 onAppear 里的话关掉动效后鸟还在飞（既有教训）。
        let frozen = still || ambientStill || motion.reduceMotion
        let birds = FlockLayout.flock(kind)
        return GeometryReader { proxy in
            // 时间源走统一氛围钟（`AmbientTicker`）：全场景只剩一颗 TimelineView
            // 在推时间，九层氛围装饰共享同一相位、同一帧。
            AmbientTicker(paused: frozen) { now in
                let elapsed = frozen ? FlockLayout.frozenElapsed() : now
                let heading = FlockLayout.heading(kind, elapsed: elapsed)
                ZStack(alignment: .topLeading) {
                    ForEach(birds) { bird in
                        let spot = FlockLayout.position(
                            bird, width: proxy.size.width,
                            height: windowHeight, elapsed: elapsed
                        )
                        // 风场要的是**场景横坐标**与**离地高度**（与草、落叶同一条口径）：
                        // 空中的鸟因此落在与它们同一条行波上，风来是一起偏的。
                        let push = (wind?.offset(
                            x: spot.x, height: max(0, windowHeight - spot.y)) ?? 0
                        ) * FlockLayout.windGain
                        BirdBody(kind: kind, theme: theme, flap: FlockLayout.flap(bird, elapsed: elapsed))
                            .frame(width: bird.size, height: bird.size * kind.aspect)
                            // 朝向：折返的后半程整群翻面。`position` 用的是中心点，
                            // 缩放不挪位置，只把鸟的脑袋掉向飞行方向。
                            .scaleEffect(x: heading, y: 1, anchor: .center)
                            .position(x: spot.x + push, y: spot.y)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
        .allowsHitTesting(false)
        // 纯氛围：读屏不该念「一群鸟」。
        .accessibilityHidden(true)
    }
}

/// 一只鸟：按鸟种分派造型（unit 画框，靠 frame 缩放）。
private struct BirdBody: View {

    let kind: BirdKind
    let theme: ForestTheme
    /// 扇翅量（-1…1，见 `FlockLayout.flap`）。
    let flap: Double

    var body: some View {
        let plumage = theme.plumage(for: kind)
        switch kind {
        case .goose:
            GooseBody(theme: theme, plumage: plumage, flap: flap)
        case .egret:
            EgretBody(theme: theme, plumage: plumage, flap: flap)
        case .swallow:
            SwallowBody(theme: theme, plumage: plumage, flap: flap)
        case .crane:
            CraneBody(theme: theme, plumage: plumage, flap: flap)
        }
    }
}

// MARK: - 雁（秋，沿用原有造型）

/// 一只雁：一对会扇的翅膀 + 身子与伸出去的脖颈（unit 画框）。
private struct GooseBody: View {

    let theme: ForestTheme
    let plumage: BirdPlumage
    let flap: Double

    var body: some View {
        ZStack {
            GooseWings(flap: flap)
                .fill(plumage.wing)
            GooseCore(flap: flap)
                .fill(plumage.body)
            GooseHead()
                .fill(plumage.accent)
        }
    }
}

/// 雁的头与白喉（unit 画框）：V 字阵里最靠前那一小点白，是「这是雁不是麻雀」的辨识点。
private struct GooseHead: Shape {

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let cx = rect.midX
        let shoulder = rect.minY + h * 0.50
        var path = Path()
        // 脖子：从肩头抻出去一小截
        path.move(to: CGPoint(x: cx + w * 0.06, y: shoulder - h * 0.08))
        path.addQuadCurve(to: CGPoint(x: cx + w * 0.18, y: shoulder - h * 0.16),
                          control: CGPoint(x: cx + w * 0.14, y: shoulder - h * 0.18))
        path.addLine(to: CGPoint(x: cx + w * 0.22, y: shoulder - h * 0.10))
        path.addQuadCurve(to: CGPoint(x: cx + w * 0.08, y: shoulder + h * 0.02),
                          control: CGPoint(x: cx + w * 0.16, y: shoulder - h * 0.02))
        path.closeSubpath()
        return path
    }
}

/// 一对翅膀：从肩上斜出去，翅尖随 `flap` 上下抡（unit 画框）。
///
/// ⚠️ 前后缘是**两条**二次曲线（不是一条线加个粗描边）：一片有厚度的薄翼，
/// 抡到最高时前缘绷直、后缘兜住 —— 单线描边在 14pt 上会糊成一横。
private struct GooseWings: Shape {

    var flap: Double

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let cx = rect.midX
        let shoulder = rect.minY + h * 0.50
        // 翅尖的抬升量：flap = 1 时抬到画框上沿，flap = -1 时压到画框下沿。
        let rise = h * 0.38 * flap
        var path = Path()
        // 左翼：肩 → 翅尖（前缘）→ 回收到翅根（后缘）
        path.move(to: CGPoint(x: cx - w * 0.07, y: shoulder - h * 0.04))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: shoulder - rise),
                          control: CGPoint(x: cx - w * 0.32, y: shoulder - rise * 0.62))
        path.addQuadCurve(to: CGPoint(x: cx - w * 0.03, y: shoulder + h * 0.16),
                          control: CGPoint(x: cx - w * 0.26,
                                           y: shoulder + h * 0.02 - rise * 0.30))
        path.closeSubpath()
        // 右翼（镜像）
        path.move(to: CGPoint(x: cx + w * 0.07, y: shoulder - h * 0.04))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: shoulder - rise),
                          control: CGPoint(x: cx + w * 0.32, y: shoulder - rise * 0.62))
        path.addQuadCurve(to: CGPoint(x: cx + w * 0.03, y: shoulder + h * 0.16),
                          control: CGPoint(x: cx + w * 0.26,
                                           y: shoulder + h * 0.02 - rise * 0.30))
        path.closeSubpath()
        return path
    }
}

/// 身子与脖颈：一枚细长的梭子 + 伸向飞行方向的头与喙（unit 画框）。
///
/// ⚠️ 雁在队形里是**抻着脖子**飞的（不是缩成一团的麻雀）：脖子那一小段是
/// 「这是雁不是燕子」的辨识点，14pt 上也得留出来。
private struct GooseCore: Shape {

    var flap: Double

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let cx = rect.midX
        let shoulder = rect.minY + h * 0.50
        // 身子随扇翅微微沉浮（与 `bobOffset` 反号：翅膀压下、身子抬起）
        let sink = h * 0.06 * flap
        var path = Path()
        path.move(to: CGPoint(x: cx - w * 0.10, y: shoulder - h * 0.02 + sink))
        // 背线：从尾根抻到头（脖子）
        path.addQuadCurve(to: CGPoint(x: cx + w * 0.13, y: shoulder - h * 0.12 + sink),
                          control: CGPoint(x: cx, y: shoulder - h * 0.15 + sink))
        // 腹线：收回到尾根（身子因此是前粗后细的梭子）
        path.addQuadCurve(to: CGPoint(x: cx - w * 0.10, y: shoulder + h * 0.10 + sink),
                          control: CGPoint(x: cx + w * 0.02, y: shoulder + h * 0.05 + sink))
        path.closeSubpath()
        return path
    }
}

// MARK: - 白鹭（春）

/// 一只白鹭：宽圆翼慢扇 + 细长白身 + 前伸的长颈与黄喙（unit 画框）。
///
/// 与雁的区别不只是颜色：翼更圆更宽（抡得慢）、脖子更长更直、
/// 身子更细 —— 14pt 上读得出「这是鹭」。
private struct EgretBody: View {

    let theme: ForestTheme
    let plumage: BirdPlumage
    let flap: Double

    var body: some View {
        ZStack {
            EgretWings(flap: flap)
                .fill(plumage.wing)
            EgretCore(flap: flap)
                .fill(plumage.body)
            EgretBeak()
                .fill(plumage.accent)
        }
    }
}

/// 白鹭的翼：比雁更圆更宽 —— 大幅慢扇的那种翼形。
private struct EgretWings: Shape {

    var flap: Double

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let cx = rect.midX
        let shoulder = rect.minY + h * 0.52
        let rise = h * 0.34 * flap
        var path = Path()
        // 左翼：前缘平缓地鼓出去（不是雁那种斜尖）
        path.move(to: CGPoint(x: cx - w * 0.06, y: shoulder - h * 0.06))
        path.addQuadCurve(to: CGPoint(x: rect.minX + w * 0.02, y: shoulder - rise),
                          control: CGPoint(x: cx - w * 0.34, y: shoulder - rise * 0.75))
        path.addQuadCurve(to: CGPoint(x: cx - w * 0.02, y: shoulder + h * 0.14),
                          control: CGPoint(x: cx - w * 0.28,
                                           y: shoulder + h * 0.04 - rise * 0.22))
        path.closeSubpath()
        // 右翼（镜像）
        path.move(to: CGPoint(x: cx + w * 0.06, y: shoulder - h * 0.06))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - w * 0.02, y: shoulder - rise),
                          control: CGPoint(x: cx + w * 0.34, y: shoulder - rise * 0.75))
        path.addQuadCurve(to: CGPoint(x: cx + w * 0.02, y: shoulder + h * 0.14),
                          control: CGPoint(x: cx + w * 0.28,
                                           y: shoulder + h * 0.04 - rise * 0.22))
        path.closeSubpath()
        return path
    }
}

/// 白鹭的身子与长颈：一枚细梭子 + 一段明显前伸的脖子（unit 画框）。
private struct EgretCore: Shape {

    var flap: Double

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let cx = rect.midX
        let shoulder = rect.minY + h * 0.50
        let sink = h * 0.05 * flap
        var path = Path()
        path.move(to: CGPoint(x: cx - w * 0.12, y: shoulder - h * 0.02 + sink))
        // 背线一路抻到头（脖子比雁长得多、也更直）
        path.addQuadCurve(to: CGPoint(x: cx + w * 0.20, y: shoulder - h * 0.22 + sink),
                          control: CGPoint(x: cx + w * 0.02, y: shoulder - h * 0.20 + sink))
        path.addQuadCurve(to: CGPoint(x: cx - w * 0.12, y: shoulder + h * 0.09 + sink),
                          control: CGPoint(x: cx + w * 0.04, y: shoulder + h * 0.04 + sink))
        path.closeSubpath()
        return path
    }
}

/// 白鹭的头与黄喙：长颈顶端那一小截（unit 画框）。
private struct EgretBeak: Shape {

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let cx = rect.midX
        let shoulder = rect.minY + h * 0.50
        var path = Path()
        path.move(to: CGPoint(x: cx + w * 0.14, y: shoulder - h * 0.24))
        path.addLine(to: CGPoint(x: cx + w * 0.30, y: shoulder - h * 0.19))
        path.addLine(to: CGPoint(x: cx + w * 0.14, y: shoulder - h * 0.15))
        path.closeSubpath()
        return path
    }
}

// MARK: - 家燕（夏）

/// 一只家燕：尖翼快扇 + 小黑身 + 剪刀尾（unit 画框）。
///
/// 燕子是四种里唯一「深色 + 小体型 + 快扇翅」的：夏天天上那一片黑点是它，
/// 不是被染黑的大雁。
private struct SwallowBody: View {

    let theme: ForestTheme
    let plumage: BirdPlumage
    let flap: Double

    var body: some View {
        ZStack {
            SwallowWings(flap: flap)
                .fill(plumage.wing)
            SwallowTail()
                .fill(plumage.wing)
            SwallowCore(flap: flap)
                .fill(plumage.body)
            SwallowThroat()
                .fill(plumage.accent)
        }
    }
}

/// 家燕的翼：尖、后掠 —— 翅尖指向**后方**（与航向相反），这是它和雁最大的区别。
private struct SwallowWings: Shape {

    var flap: Double

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let cx = rect.midX
        let shoulder = rect.minY + h * 0.50
        // 抬升幅度比雁小：燕子是「高频小幅度」地抖翅，不是大幅抡。
        let rise = h * 0.22 * flap
        var path = Path()
        // 左翼：肩 → 翅尖（向左后方掠出去）
        path.move(to: CGPoint(x: cx - w * 0.05, y: shoulder - h * 0.04))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: shoulder - rise),
                          control: CGPoint(x: cx - w * 0.22, y: shoulder - h * 0.10 - rise * 0.55))
        path.addLine(to: CGPoint(x: cx - w * 0.01, y: shoulder + h * 0.10))
        path.closeSubpath()
        // 右翼（镜像）
        path.move(to: CGPoint(x: cx + w * 0.05, y: shoulder - h * 0.04))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: shoulder - rise),
                          control: CGPoint(x: cx + w * 0.22, y: shoulder - h * 0.10 - rise * 0.55))
        path.addLine(to: CGPoint(x: cx + w * 0.01, y: shoulder + h * 0.10))
        path.closeSubpath()
        return path
    }
}

/// 家燕的身子：小梭子 + 探出去的小头（unit 画框）。
private struct SwallowCore: Shape {

    var flap: Double

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let cx = rect.midX
        let shoulder = rect.minY + h * 0.50
        let sink = h * 0.04 * flap
        var path = Path()
        path.move(to: CGPoint(x: cx - w * 0.10, y: shoulder - h * 0.02 + sink))
        path.addQuadCurve(to: CGPoint(x: cx + w * 0.14, y: shoulder - h * 0.10 + sink),
                          control: CGPoint(x: cx + w * 0.02, y: shoulder - h * 0.13 + sink))
        path.addLine(to: CGPoint(x: cx + w * 0.19, y: shoulder - h * 0.06 + sink))
        path.addQuadCurve(to: CGPoint(x: cx - w * 0.10, y: shoulder + h * 0.08 + sink),
                          control: CGPoint(x: cx + w * 0.02, y: shoulder + h * 0.04 + sink))
        path.closeSubpath()
        return path
    }
}

/// 家燕的剪刀尾：尾羽向两边岔开、中间一个缺口（unit 画框）。
///
/// ⚠️ 这个缺口是「这是燕子」唯一的辨识点：没有它，9pt 的一只深色小鸟
/// 与任何小鸟都分不出来。
private struct SwallowTail: Shape {

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let cx = rect.midX
        let shoulder = rect.minY + h * 0.50
        var path = Path()
        // 左半尾：从尾根向左后方掠出去，末端收尖
        path.move(to: CGPoint(x: cx - w * 0.10, y: shoulder - h * 0.02))
        path.addQuadCurve(to: CGPoint(x: cx - w * 0.26, y: shoulder + h * 0.16),
                          control: CGPoint(x: cx - w * 0.20, y: shoulder + h * 0.08))
        path.addLine(to: CGPoint(x: cx - w * 0.12, y: shoulder + h * 0.10))
        path.closeSubpath()
        // 右半尾（镜像）—— 中间留出的 V 形缺口就是剪刀口
        path.move(to: CGPoint(x: cx - w * 0.10, y: shoulder - h * 0.02))
        path.addQuadCurve(to: CGPoint(x: cx + w * 0.06, y: shoulder + h * 0.16),
                          control: CGPoint(x: cx, y: shoulder + h * 0.08))
        path.addLine(to: CGPoint(x: cx - w * 0.12, y: shoulder + h * 0.10))
        path.closeSubpath()
        return path
    }
}

/// 家燕的白喉（unit 画框）：深色身子上那一小点白。
private struct SwallowThroat: Shape {

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let cx = rect.midX
        let shoulder = rect.minY + h * 0.50
        var path = Path()
        path.move(to: CGPoint(x: cx + w * 0.08, y: shoulder - h * 0.10))
        path.addQuadCurve(to: CGPoint(x: cx + w * 0.16, y: shoulder - h * 0.04),
                          control: CGPoint(x: cx + w * 0.13, y: shoulder - h * 0.02))
        path.addQuadCurve(to: CGPoint(x: cx + w * 0.08, y: shoulder + h * 0.02),
                          control: CGPoint(x: cx + w * 0.11, y: shoulder + h * 0.04))
        path.closeSubpath()
        return path
    }
}

// MARK: - 灰鹤（冬）

/// 一只灰鹤：极宽翼慢抡 + 白身 + 黑翼尖 + 前伸的长颈（unit 画框）。
///
/// 与白鹭的区别在翼：鹤的翼明显更宽更长，且**翅尖是黑的**（初级飞羽）——
/// 冬天雪原上那一群白身黑翅尖，一眼就认得出。
private struct CraneBody: View {

    let theme: ForestTheme
    let plumage: BirdPlumage
    let flap: Double

    var body: some View {
        ZStack {
            CraneWings(flap: flap)
                .fill(plumage.wing)
            CraneWingTips(flap: flap)
                .fill(plumage.accent)
            CraneCore(flap: flap)
                .fill(plumage.body)
            CraneBeak()
                .fill(plumage.accent)
        }
    }
}

/// 灰鹤的翼：极宽，几乎占满画框 —— 大幅慢抡的那种翼形。
private struct CraneWings: Shape {

    var flap: Double

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let cx = rect.midX
        let shoulder = rect.minY + h * 0.50
        let rise = h * 0.40 * flap
        var path = Path()
        path.move(to: CGPoint(x: cx - w * 0.05, y: shoulder - h * 0.06))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: shoulder - rise),
                          control: CGPoint(x: cx - w * 0.30, y: shoulder - rise * 0.80))
        path.addQuadCurve(to: CGPoint(x: cx - w * 0.01, y: shoulder + h * 0.18),
                          control: CGPoint(x: cx - w * 0.26,
                                           y: shoulder + h * 0.06 - rise * 0.20))
        path.closeSubpath()
        path.move(to: CGPoint(x: cx + w * 0.05, y: shoulder - h * 0.06))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: shoulder - rise),
                          control: CGPoint(x: cx + w * 0.30, y: shoulder - rise * 0.80))
        path.addQuadCurve(to: CGPoint(x: cx + w * 0.01, y: shoulder + h * 0.18),
                          control: CGPoint(x: cx + w * 0.26,
                                           y: shoulder + h * 0.06 - rise * 0.20))
        path.closeSubpath()
        return path
    }
}

/// 灰鹤的黑翅尖（unit 画框）：翼最外那一段，随扇翅一起抬升。
private struct CraneWingTips: Shape {

    var flap: Double

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let cx = rect.midX
        let shoulder = rect.minY + h * 0.50
        let rise = h * 0.40 * flap
        var path = Path()
        // 左翅尖
        path.move(to: CGPoint(x: rect.minX + w * 0.16, y: shoulder - rise * 0.55))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: shoulder - rise),
                          control: CGPoint(x: rect.minX + w * 0.08, y: shoulder - rise * 0.85))
        path.addQuadCurve(to: CGPoint(x: cx - w * 0.01, y: shoulder + h * 0.10),
                          control: CGPoint(x: cx - w * 0.14,
                                           y: shoulder + h * 0.02 - rise * 0.10))
        path.closeSubpath()
        // 右翅尖（镜像）
        path.move(to: CGPoint(x: rect.maxX - w * 0.16, y: shoulder - rise * 0.55))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: shoulder - rise),
                          control: CGPoint(x: rect.maxX - w * 0.08, y: shoulder - rise * 0.85))
        path.addQuadCurve(to: CGPoint(x: cx + w * 0.01, y: shoulder + h * 0.10),
                          control: CGPoint(x: cx + w * 0.14,
                                           y: shoulder + h * 0.02 - rise * 0.10))
        path.closeSubpath()
        return path
    }
}

/// 灰鹤的身子与长颈：白梭子 + 一段笔直前伸的脖子（unit 画框）。
private struct CraneCore: Shape {

    var flap: Double

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let cx = rect.midX
        let shoulder = rect.minY + h * 0.50
        let sink = h * 0.06 * flap
        var path = Path()
        path.move(to: CGPoint(x: cx - w * 0.10, y: shoulder - h * 0.02 + sink))
        // 脖子几乎是直的（雁有一段明显的弯，鹤是探出去的）
        path.addLine(to: CGPoint(x: cx + w * 0.18, y: shoulder - h * 0.20 + sink))
        path.addLine(to: CGPoint(x: cx + w * 0.22, y: shoulder - h * 0.14 + sink))
        path.addQuadCurve(to: CGPoint(x: cx - w * 0.10, y: shoulder + h * 0.10 + sink),
                          control: CGPoint(x: cx + w * 0.04, y: shoulder + h * 0.04 + sink))
        path.closeSubpath()
        return path
    }
}

/// 灰鹤的头与喙（unit 画框）。
private struct CraneBeak: Shape {

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let cx = rect.midX
        let shoulder = rect.minY + h * 0.50
        var path = Path()
        path.move(to: CGPoint(x: cx + w * 0.16, y: shoulder - h * 0.22))
        path.addLine(to: CGPoint(x: cx + w * 0.30, y: shoulder - h * 0.18))
        path.addLine(to: CGPoint(x: cx + w * 0.16, y: shoulder - h * 0.13))
        path.closeSubpath()
        return path
    }
}
