import CoreGraphics
@testable import AppUI
import XCTest

/// 四季飞鸟群的布局纯函数（2026-10-23）。
///
/// 每条判据都配一句「反证」——把实现换回错写法，断言必须红在**这一条**上。
final class ForestBirdsTests: XCTestCase {

    private let width: CGFloat = 900      // 中间栏 + 右栏合起来的幅宽
    private let height: CGFloat = 760     // 整窗高（高度带的基准）

    private func flock(_ kind: BirdKind) -> [ForestBird] { FlockLayout.flock(kind) }

    /// 让横渡进度正好落在 `p`、且落在第 `cyc` 趟的那个时刻。
    ///
    /// ⚠️ **必须能指定趟次**：方向与是否折返都按趟定（`direction(cyc)` /
    /// `turnsBack(cyc)`），只反解进度的话永远落在第 1 趟 —— 万一那一趟折返，
    /// 「整群出右边界」这类判据就会偶发假红（换一个散列种子就红）。
    private func elapsed(atProgress p: Double, cycle cyc: Int = 1) -> Double {
        FlockLayout.crossingPeriod * (p - FlockLayout.startPhase + Double(cyc))
    }

    /// 前 `limit` 趟里第一个**直穿**趟（不折返）—— 「贯穿整幅」那几条判据要的就是它。
    private func firstStraightCycle(limit: Int = 24) -> Int {
        for cyc in 0..<limit where !FlockLayout.turnsBack(cyc) { return cyc }
        return 0
    }

    /// 某一时刻每只鸟的横向跨度与高度。
    private func spans(_ kind: BirdKind, atProgress p: Double, cycle cyc: Int = 1)
        -> [(minX: CGFloat, maxX: CGFloat, y: CGFloat)] {
        let now = elapsed(atProgress: p, cycle: cyc)
        return flock(kind).map { bird in
            let spot = FlockLayout.position(bird, width: width, height: height, elapsed: now)
            let half = CGFloat(bird.size) / 2
            return (minX: spot.x - half, maxX: spot.x + half, y: spot.y)
        }
    }

    /// 一段行程里**出现过**的方向集合（+1 / -1）与是否折返。
    private func behaviours(over elapsed: Double) -> (dirs: Set<Double>, turned: Bool) {
        var dirs: Set<Double> = []
        var turned = false
        var t = 0.0
        while t < elapsed {
            let cyc = FlockLayout.cycle(t)
            dirs.insert(FlockLayout.direction(cyc))
            if FlockLayout.turnsBack(cyc) { turned = true }
            t += FlockLayout.crossingPeriod / 8
        }
        return (dirs, turned)
    }

    // MARK: - 四季各一种鸟

    /// 四个季节必须是**四种不同的鸟**，且都是鸟而不是同一种换色。
    ///
    /// 反证：把 `forSeason` 里三季都返回 `.goose` → 红在「四种不同」。
    func testEachSeasonGetsItsOwnKindOfBird() {
        let kinds = ForestSeason.allCases.map { BirdKind.forSeason($0) }
        XCTAssertEqual(Set(kinds).count, 4, "四季必须是四种鸟，不能是同一种染四色")
        XCTAssertEqual(BirdKind.allCases.count, 4)
    }

    /// 四种鸟的**造型参数**必须真的不同（体型 / 翼扇快慢 / 队形）。
    ///
    /// 反证：把 swallow 的 `flapPeriodRange` 改成与 goose 相同 → 红在「快慢」。
    func testTheFourKindsDifferInShapeAndRhythm() {
        // 体型：灰鹤最大、家燕最小
        let spans = BirdKind.allCases.map { $0.sizeRange }
        XCTAssertEqual(spans.filter { $0 == BirdKind.crane.sizeRange }.count, 1)
        XCTAssertGreaterThan(BirdKind.crane.sizeRange.lowerBound,
                             BirdKind.swallow.sizeRange.upperBound,
                           "灰鹤该比家燕大一号（不然只是同一种鸟的大小差）")
        // 扇翅快慢：家燕抖翅、灰鹤慢抡，差一倍以上
        XCTAssertLessThan(BirdKind.swallow.flapPeriodRange.upperBound,
                          BirdKind.crane.flapPeriodRange.lowerBound,
                          "家燕该明显比灰鹤扇得快（快慢分不出 = 是同一种鸟）")
        // 队形：雁是 V 字，燕子是散群，鹭与鹤是斜线 —— 三种队形都要出现
        XCTAssertEqual(Set(BirdKind.allCases.map { $0.formation }).count, 3,
                       "队形至少该有三种，不然四季只是排队形不同")
    }

    /// 同一种永远同一群：重绘不许换一批（换一批 = 用户在看瞬移）。
    /// 不同种子必须是不同的一群。
    func testLayoutIsDeterministic() {
        for kind in BirdKind.allCases {
            XCTAssertEqual(FlockLayout.flock(kind), FlockLayout.flock(kind),
                           "\(kind.rawValue)：同一种两次造的群不一样")
            XCTAssertEqual(FlockLayout.flock(kind).count, kind.count)
        }
        XCTAssertNotEqual(FlockLayout.flock(.goose), FlockLayout.flock(.crane),
                          "雁与鹤不该是同一群鸟")
    }

    // MARK: - 方向（随机左右）

    /// 方向**按趟随机**，但同一趟内恒定（不会飞到一半集体变向）。
    ///
    /// 反证 1：把 `direction` 改成 `cycle % 2 == 0 ? 1 : -1`（交替）→ 红在「看不出规律」。
    /// 反证 2：把 `direction` 改成读 `elapsed` 而不是 `cycle` → 红在「同一趟恒定」。
    func testDirectionIsRandomPerLapButStableWithinALap() {
        // 同一趟里采样十几个时刻，方向必须一模一样
        for cyc in 0..<12 {
            let dir = FlockLayout.direction(cyc)
            XCTAssertEqual(dir, FlockLayout.direction(cyc))
            XCTAssertTrue(dir == 1 || dir == -1, "方向只能是 ±1")
        }
        // 24 趟里两个方向都出现过（「随机左右」这条要求的唯一判据）
        let (dirs, _) = behaviours(over: 24 * FlockLayout.crossingPeriod)
        XCTAssertEqual(dirs.count, 2, "只朝一个方向飞，就不是「随机左右」了")
        // 看不出「左右交替」的规律：相邻两趟同向的次数该有一半上下
        var same = 0
        for cyc in 1..<24 {
            if FlockLayout.direction(cyc) == FlockLayout.direction(cyc - 1) { same += 1 }
        }
        XCTAssertGreaterThan(same, 2, "方向在严格交替（用户看得出规律）")
        XCTAssertLessThan(same, 22, "方向从来不交替（同向概率过高）")
    }

    /// 折返真的会发生（用户点名「甚至可以掉头」），但不是每一趟都折返。
    ///
    /// 反证：把 `turnsBack` 改成 `return true`（趟趟折返）→ 红在「不是每一趟」。
    func testTurningBackHappensButNotEveryLap() {
        let (_, turned) = behaviours(over: 24 * FlockLayout.crossingPeriod)
        XCTAssertTrue(turned, "从来没折返过 —— 用户点名的「掉头」没实现")
        var laps = 0, backs = 0
        for cyc in 0..<24 {
            laps += 1
            if FlockLayout.turnsBack(cyc) { backs += 1 }
        }
        XCTAssertGreaterThan(backs, 0)
        XCTAssertLessThan(backs, laps, "趟趟折返：横渡整幅这种行为没有了")
    }

    // MARK: - 折返行程

    /// 折返趟：前进量先涨到 `turnFraction`、再退回 0（出去了**还回来**）。
    ///
    /// 反证：把 `forward` 的折返分支改成 `return progress`（不掉头）→ 红在峰值与回落。
    func testATurningLapGoesOutAndComesBack() {
        let peak = FlockLayout.forward(0.5, back: true)
        XCTAssertEqual(peak, FlockLayout.turnFraction, accuracy: 1e-9,
                       "折返点该停在 turnFraction 处（不是画面正中、也不是飞出去）")
        // 折返趟**最远也只走到 turnFraction**（0.55），而直穿趟会飞到 1.0 ——
        // 少了这一条，把折返分支整个删掉（趟趟直穿）也能绿。
        XCTAssertLessThan(peak, FlockLayout.forward(0.999, back: false) + 1e-9,
                          "折返趟飞得比直穿趟还远了（等于没折返）")
        XCTAssertLessThan(FlockLayout.forward(0.5, back: true), 1.0,
                          "折返趟不该飞出画面（turnFraction 必须小于 1）")
        XCTAssertEqual(FlockLayout.forward(0.0, back: true), 0, accuracy: 1e-9)
        XCTAssertEqual(FlockLayout.forward(0.999, back: true), 0, accuracy: 1e-2,
                       "折返趟结尾该回到起点（出去了还回来）")
        // 前半程一路涨、后半程一路落
        var rising = true
        var previous = -1.0
        for step in 0...40 {
            let p = Double(step) / 40
            let f = FlockLayout.forward(p, back: true)
            if rising {
                XCTAssertGreaterThanOrEqual(f, previous - 1e-9, "前半程该一路往外飞")
                if f > FlockLayout.turnFraction - 1e-9 { rising = false }
            } else {
                XCTAssertLessThanOrEqual(f, previous + 1e-9, "后半程该一路往回飞")
            }
            previous = f
        }
    }

    /// 掉头时**朝向跟着翻**：折返后半程鸟是往回飞的，脑袋不能还朝前。
    ///
    /// 反证：把 `heading` 的折返分支改成 `return dir`（不翻面）→ 红。
    func testHeadingFlipsAtTheTurn() {
        for dir in [1.0, -1.0] {
            XCTAssertEqual(FlockLayout.heading(0.2, back: true, dir: dir), dir, accuracy: 1e-9,
                           "折返前半程朝出发方向")
            XCTAssertEqual(FlockLayout.heading(0.8, back: true, dir: dir), -dir, accuracy: 1e-9,
                           "折返后半程该翻面（不然是一只倒着飞的鸟）")
            // 直穿趟全程不翻
            XCTAssertEqual(FlockLayout.heading(0.2, back: false, dir: dir), dir, accuracy: 1e-9)
            XCTAssertEqual(FlockLayout.heading(0.8, back: false, dir: dir), dir, accuracy: 1e-9)
        }
    }

    /// 整群同时翻面（`heading(_ kind:elapsed:)` 与逐只判据同源）。
    ///
    /// ⚠️ 时刻必须落在**指定趟**里（`elapsed(atProgress:cycle:)`）：方向与折返都按趟定，
    /// 只反解进度的话时刻会漂到另一趟，判据就在测别的趟了。
    ///
    /// 反证：把 `heading(_ kind:elapsed:)` 里的 `turnsBack(cyc)` 改成 `false` → 红。
    func testWholeFlockTurnsTogether() {
        var found = false
        for cyc in 0..<40 where FlockLayout.turnsBack(cyc) {
            found = true
            let dir = FlockLayout.direction(cyc)
            let early = elapsed(atProgress: 0.25, cycle: cyc)
            let late = elapsed(atProgress: 0.75, cycle: cyc)
            XCTAssertEqual(FlockLayout.cycle(early), cyc, "构造出的时刻没落在目标趟里")
            XCTAssertEqual(FlockLayout.heading(.goose, elapsed: early), dir, accuracy: 1e-9)
            XCTAssertEqual(FlockLayout.heading(.goose, elapsed: late), -dir, accuracy: 1e-9)
            break
        }
        XCTAssertTrue(found, "40 趟里该至少有一趟折返（不然这条判据在空转）")
    }

    // MARK: - 贯穿整幅

    /// 整群**整进整出**：一头一尾两个时刻，画面上一只鸟也没有。
    ///
    /// ⚠️ 走**直穿趟**（不折返）：折返趟是「出去还回来」，它的终点在起点而不在
    /// 右边界外 —— 拿折返趟套这条判据会假红（2026-10-23 实测踩到）。
    ///
    /// ⚠️ 这是「鸟群凭空出现 / 凭空消失」那类穿帮的唯一判据 —— 只测「中间
    /// 在画面里」是测不出来的（留不留余量中间都在）。
    ///
    /// 反证：把 `leadPosition` 里 `margin` 改成 0（起终点贴着边界）→ 红。
    func testFlockEntersAndLeavesAsAWhole() {
        let cyc = firstStraightCycle()
        XCTAssertFalse(FlockLayout.turnsBack(cyc), "该找到一趟直穿的")
        for kind in BirdKind.allCases {
            XCTAssertTrue(spans(kind, atProgress: 0, cycle: cyc).allSatisfy { $0.maxX < 0 },
                          "\(kind.rawValue)：进度 0 时整群该还在左边界之外（不该凭空出现）")
            XCTAssertTrue(spans(kind, atProgress: 0.999, cycle: cyc).allSatisfy { $0.minX > width },
                          "\(kind.rawValue)：进度 1 时整群该已经出了右边界（不该凭空消失）")
        }
    }

    /// 直穿趟真的**贯穿整幅**：从最左一路飞到最右，中间扫过全宽。
    ///
    /// ⚠️ 同样只走直穿趟：折返趟最远只到 `turnFraction`，扫不满整幅。
    ///
    /// 反证：把 `turnFraction` 改成 0.2（只飞一小段）→ 红在「扫过的宽度」。
    func testAStraightLapSpansTheWholeWidth() {
        let cyc = firstStraightCycle()
        var seen = Set<Int>()
        for step in 0..<60 {
            let p = Double(step) / 60
            for span in spans(.goose, atProgress: p, cycle: cyc) {
                // 夹回 0…9：起终点整群在画外（留了余量），不夹会把「画外那两截」
                // 也算成额外的段，seen 会变成 12 段。
                let mid = (span.minX + span.maxX) / 2
                let bucket = min(max(Int(mid / (width / 10)), 0), 9)
                seen.insert(bucket)
            }
        }
        XCTAssertEqual(seen.count, 10, "一个直穿趟该把整幅（10 段）都扫到")
    }

    /// 半渡时整群在画面里（冻结档就停在这儿）。
    ///
    /// 反证：把 `frozenElapsed` 改成 `return 0` → 红。
    func testFrozenFlockIsFullyVisible() {
        let frozen = FlockLayout.frozenElapsed()
        XCTAssertGreaterThan(frozen, 0, "冻结档不能停在 0（那是刚出左边界）")
        XCTAssertEqual(FlockLayout.crossingProgress(frozen), 0.5, accuracy: 1e-9)
        for kind in BirdKind.allCases {
            for span in spans(kind, atProgress: 0.5) {
                XCTAssertGreaterThan(span.minX, 0, "\(kind.rawValue)：半渡时不该露在左边界外")
                XCTAssertLessThan(span.maxX, width, "\(kind.rawValue)：半渡时不该露在右边界外")
            }
        }
    }

    /// 横渡的**进度**是周期的（一趟一趟地来），且慢到能读出「缓缓」。
    ///
    /// ⚠️ 位置不再周期：方向按趟随机（`direction(cyc)`），隔一趟可能就朝另一侧飞了。
    /// 所以这里钉的是进度周期，不是位置周期（雁阵原来方向固定，那条判据迁不过来）。
    ///
    /// 反证：把 `crossingPeriod` 里的 `+ startPhase` 删掉 → 红在「进度周期」。
    func testCrossingIsPeriodicAndSlow() {
        let start = FlockLayout.crossingProgress(4.2)
        let nextLap = FlockLayout.crossingProgress(4.2 + FlockLayout.crossingPeriod)
        XCTAssertEqual(start, nextLap, accuracy: 1e-9, "一趟之后进度该回到同一处")
        let speed = Double(width + FlockLayout.margin(.goose) * 2) / FlockLayout.crossingPeriod
        XCTAssertLessThan(speed, 12, "鸟群飞太快了（那是掠过镜头，不是缓缓掠过）")
    }

    // MARK: - 高度带（上三分之一）

    /// 每只鸟始终待在上三分之一带里（下面是树冠与关卡节点的地盘）。
    ///
    /// ⚠️ 基准是**整窗高**：这一层的画布只有窗高的三分之一，拿它当基准的话
    /// 「上三分之一」会挤成窗口最顶上一条线（`windowHeight` 那个坑的判据）。
    ///
    /// 反证：把 `altitude` 改成 0.6 → 红。
    func testEveryBirdStaysInTheTopThird() {
        for kind in BirdKind.allCases {
            for step in 0..<60 {
                let p = Double(step) / 60
                for span in spans(kind, atProgress: p) {
                    let fraction = span.y / height
                    XCTAssertGreaterThanOrEqual(fraction, FlockLayout.altitudeBand.lowerBound,
                                                "\(kind.rawValue)：有鸟飞到树冠那一带去了")
                    XCTAssertLessThanOrEqual(fraction, FlockLayout.altitudeBand.upperBound,
                                             "\(kind.rawValue)：有鸟顶出了上三分之一")
                }
            }
        }
    }

    /// 高度带的基准必须是**整窗高**而不是画布高（画布只有窗高的 1/3）。
    ///
    /// 反证：把 `position` 里的 `height:` 实参从 `windowHeight` 改成画布高 → 红。
    func testAltitudeIsMeasuredAgainstTheWindowNotTheCanvas() {
        // 传入窗高 760 时，头鸟高度 ≈ 0.17 × 760 = 129
        let lead = FlockLayout.leadPosition(.goose, width: width, height: height,
                                            elapsed: FlockLayout.frozenElapsed())
        XCTAssertEqual(lead.y / height, FlockLayout.altitude, accuracy: 0.02)
        // 若拿画布高（760/3 ≈ 253）当基准，头鸟高度会掉到 43 —— 差三倍
        let canvasBased = FlockLayout.leadPosition(.goose, width: width, height: height / 3,
                                                   elapsed: FlockLayout.frozenElapsed())
        XCTAssertLessThan(canvasBased.y, lead.y / 2,
                          "拿画布高当基准的话鸟群会挤到窗口最顶上一条")
    }

    // MARK: - 上下位移（较慢 / 微小 / 肉眼可见）

    /// 慢漂：幅度微小、周期远长于扇翅、且**肉眼可见**。
    ///
    /// ⚠️ 「肉眼可见」与「较慢」都用**整周期统计**判，不拿「相隔 1 秒的位移」
    /// 当尺：那一尺在慢漂的波峰 / 波谷附近会趋近 0（相位变化最小），
    /// 实测 egret 与 goose 各有一只鸟栽在那儿（0.20 / 0.26pt），
    /// 是判据选错了位置，不是实现有问题。
    ///
    /// 反证 1：把 `swayAmp` 改成 0 → 红在「摆幅」。
    /// 反证 2：把 `swayPeriod` 改成 0.5（与扇翅同档）→ 红在「远慢于扇翅」。
    func testSwayIsSlowSmallAndVisible() {
        for kind in BirdKind.allCases {
            for bird in flock(kind) {
                // 幅度：微小 —— 一个周期里从不超过 swayAmp
                var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
                for step in 0..<200 {
                    let t = Double(step) * FlockLayout.swayPeriod / 200
                    let v = Double(FlockLayout.sway(bird, elapsed: t))
                    lo = min(lo, v); hi = max(hi, v)
                }
                XCTAssertLessThanOrEqual(hi, FlockLayout.swayAmp + 1e-9,
                                         "\(kind.rawValue)：慢漂幅度超了")
                XCTAssertGreaterThanOrEqual(lo, -FlockLayout.swayAmp - 1e-9,
                                            "\(kind.rawValue)：慢漂幅度超了")
                // 肉眼可见：整周期摆幅至少是单边幅度的 4/3（峰到峰 18pt 的 2/3 以上）
                XCTAssertGreaterThan(hi - lo, FlockLayout.swayAmp * 1.3,
                                     "\(kind.rawValue)：摆幅太小，用户看不见")
                // 较慢：一个周期里的**平均速率**远低于同一条鸟的扇翅起伏（后者是「抖」）。
                // ⚠️ 用平均而不是峰值：峰值在参数最保守的那只鸟上会与慢漂贴太近
                // （实测 bob 峰值 10.5 vs 慢漂峰值 2.17×5 = 10.9，倍率 5 直接假红）。
                let swayAvg = 4 * FlockLayout.swayAmp / FlockLayout.swayPeriod   // ≈ 1.38 pt/s
                let bobAvg = 4 * bird.bob / bird.flapPeriod                      // ≥ 3.8 pt/s
                XCTAssertLessThan(swayAvg * 2, bobAvg,
                                  "\(kind.rawValue)：慢漂的平均速率和扇翅一个量级了（不够「较慢」）")
            }
        }
    }

    /// 慢漂是**绝对时间**驱动的连续慢漂，不是按趟打拍子。
    ///
    /// ⚠️ 判据不能是「跨趟界不跳」：`sin` 是 2π 周期的，进度驱动下 progress 从
    /// 0.9999 跳到 0 时相位几乎没变（差 ≈ 2π），那一尺对错写法不敏感（实测过）。
    /// 改判「**同一进度、不同趟**下的慢漂必须不同」—— 那正是两种写法的分水岭。
    ///
    /// 反证：把 `sway` 的 `elapsed / swayPeriod` 换成 `crossingProgress` → 红。
    func testSwayIsTimeDrivenNotProgressDriven() {
        let bird = flock(.goose)[0]
        let a = Double(FlockLayout.sway(bird, elapsed: 30))
        let b = Double(FlockLayout.sway(bird, elapsed: 30 + FlockLayout.crossingPeriod))
        XCTAssertEqual(FlockLayout.crossingProgress(30), FlockLayout.crossingProgress(126),
                       accuracy: 1e-9, "这两个时刻该是同一个横渡进度（判据的前提）")
        XCTAssertNotEqual(a, b, accuracy: 1e-6,
                          "同一进度下慢漂该不同 —— 它是绝对时间驱动的连续慢漂，"
                            + "不是按趟打拍子（那样来回两趟各起伏一次）")
        // 且同一个绝对时刻永远同一个值（纯函数）
        XCTAssertEqual(FlockLayout.sway(bird, elapsed: 30), FlockLayout.sway(bird, elapsed: 30),
                       accuracy: 1e-12)
    }

    /// 一群鸟**不同相**地慢漂（同相 = 整群挂在同一根线上一起坐电梯）。
    ///
    /// 反证：把 `make` 里 `swayPhase` 改成常量 0 → 红。
    func testSwayIsOutOfPhaseAcrossTheFlock() {
        for kind in BirdKind.allCases {
            let phases = flock(kind).map {
                String(format: "%.6f", Double(FlockLayout.sway($0, elapsed: 7.3)))
            }
            XCTAssertEqual(Set(phases).count, phases.count,
                           "\(kind.rawValue)：整群慢漂同相了（一起坐电梯）")
        }
    }

    // MARK: - 扇翅

    /// 扇翅是周期的、落在 -1…1，且一群**不同相**。
    ///
    /// 反证：把 `flap` 里的 `+ bird.flapPhase * 2 * .pi` 删掉 → 红在「不同相」。
    func testFlapIsPeriodicAndOutOfPhase() {
        for kind in BirdKind.allCases {
            for bird in flock(kind) {
                let first = FlockLayout.flap(bird, elapsed: 2.3)
                let afterCycle = FlockLayout.flap(bird, elapsed: 2.3 + bird.flapPeriod)
                XCTAssertEqual(first, afterCycle, accuracy: 1e-9, "一个扇翅周期后该回到同一姿态")
                XCTAssertLessThanOrEqual(abs(first), 1 + 1e-9, "扇翅量必须落在 -1…1")
            }
            let angles = flock(kind).map { String(format: "%.6f", FlockLayout.flap($0, elapsed: 2.3)) }
            XCTAssertEqual(Set(angles).count, angles.count, "\(kind.rawValue)：整群扇翅同相了")
        }
    }

    /// 四种鸟的扇翅快慢真的不同（家燕最快、灰鹤最慢）。
    ///
    /// 反证：把 crane 的 `flapPeriodRange` 改成与 swallow 相同 → 红。
    func testFlapRhythmDiffersByKind() {
        func meanPeriod(_ kind: BirdKind) -> Double {
            flock(kind).map(\.flapPeriod).reduce(0, +) / Double(flock(kind).count)
        }
        XCTAssertLessThan(meanPeriod(.swallow), meanPeriod(.goose))
        XCTAssertLessThan(meanPeriod(.goose), meanPeriod(.egret))
        XCTAssertLessThan(meanPeriod(.egret), meanPeriod(.crane))
    }

    /// 身子随扇翅沉浮（与扇翅同频同相），不是另坐一部电梯。
    ///
    /// 反证：给 `bobOffset` 另起一个周期 → 红。
    func testBobFollowsTheWingbeat() {
        for bird in flock(.goose) {
            for step in 0..<12 {
                let elapsed = Double(step) * 0.21
                let expected = -bird.bob * FlockLayout.flap(bird, elapsed: elapsed)
                XCTAssertEqual(FlockLayout.bobOffset(bird, elapsed: elapsed),
                               expected, accuracy: 1e-9)
            }
        }
    }

    // MARK: - 队形

    /// 雁是 V 字：越靠后越往后退、越往外张（`#634` 的原判据，迁到这里）。
    ///
    /// 反证：把 `formationOffset` 里 `wingGap` 改成 0（只退不张）→ 红在 `|dy|`。
    func testGooseFormationOpensBackwardsIntoAV() {
        let flock = flock(.goose)
        for bird in flock where bird.rank > 0 {
            XCTAssertLessThan(FlockLayout.formationOffset(bird).width, 0,
                              "第 \(bird.rank) 排不该飞在头鸟前面")
        }
        let upper = flock.filter { $0.wing == -1 }.sorted { $0.rank < $1.rank }
        for index in 1..<upper.count {
            let previous = abs(FlockLayout.formationOffset(upper[index - 1]).height)
            let current = abs(FlockLayout.formationOffset(upper[index]).height)
            XCTAssertGreaterThan(current, previous, "越靠后该越往外张（V 才张得开）")
        }
    }

    /// 白鹭 / 灰鹤是**斜线**：沿航向排开，横向只错开一小截（不是 V 的两翼张开）。
    ///
    /// 反证：把 `line` 分支的 0.28 改成 0.62（与雁一样）→ 红在「错开更小」。
    func testEgretsAndCranesFlyALineNotAVee() {
        for kind in [BirdKind.egret, .crane] {
            let spread = flock(kind).map { abs(FlockLayout.formationOffset($0).height) }.max() ?? 0
            let gooseSpread = flock(.goose).map { abs(FlockLayout.formationOffset($0).height) }.max() ?? 0
            XCTAssertLessThan(spread, gooseSpread,
                              "\(kind.rawValue)：斜线该比雁阵的 V 收得窄")
            // 同一排（rank 相同）的两只，一上一下 —— 斜线是「一排」而不是一条线
            let wings = Set(flock(kind).map(\.wing))
            XCTAssertEqual(wings, [-1, 0, 1], "\(kind.rawValue)：斜线也该有上有下")
        }
    }

    /// 家燕是**散群**：每只各有固定错位，没有整齐队形。
    ///
    /// 反证：把 `scatter` 分支的 drift 项去掉 → 红在「错位各不相同」。
    func testSwallowsScatterInsteadOfFormingUp() {
        let flock = flock(.swallow)
        XCTAssertEqual(flock.count, 9)
        let offsets = Set(flock.map { String(format: "%.4f,%.4f",
                                             Double(FlockLayout.formationOffset($0).width),
                                             Double(FlockLayout.formationOffset($0).height)) })
        XCTAssertEqual(offsets.count, flock.count, "散群里九只的错位必须各不相同")
    }
}
