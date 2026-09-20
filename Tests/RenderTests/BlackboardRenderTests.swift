import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 老师黑板三态的**离屏渲染**回归。
///
/// 为什么必须离屏跑一遍：纯函数只证明「规则对」，证明不了「真画出来了」——
/// 黑板那块板是**盖在座位之上的浮层**，布局稍有不慎就会被裁掉或压在下面。
/// 这里断言的都是用户真能看见的事：收起态有绿勾、展开态真的比收起态大一圈、
/// 侧栏端到端接上了（不是只有组件好看）。顺带把 PNG 落到 `.workbuddy/verify/`。
///
/// ⚠️ 断言用**相对基准**（同一批渲染里量出来），不写死绝对色值：
/// 离屏位图会经一次色彩空间换算，写死阈值会随显示器/色彩管理假失败。
@MainActor
final class BlackboardRenderTests: XCTestCase {

    private var window: NSWindow?
    private let seatWidth: CGFloat = 196
    // MARK: - 造计划

    private func plan(doneCount: Int, taskCount: Int = 3) -> DailyPlan {
        let specs: [(DailyTask.Kind, Int, String)] = [
            (.conversation, 4, "轮"),
            (.shadowing, 3, "次"),
            (.review, 8, "个词"),
        ]
        let list = specs.prefix(taskCount).enumerated().map { index, spec in
            DailyTask(
                kind: spec.0,
                title: "做 \(spec.1) \(spec.2)",
                reason: index == 0 ? "每日目标 15 分钟，今天还没开口" : "有 \(spec.1) \(spec.2) 到期",
                target: spec.1,
                progress: index < doneCount ? spec.1 : 0,
                unit: spec.2
            )
        }
        return DailyPlan(day: Date(), tasks: list)
    }

    // MARK: - 离屏渲染

    private struct Render {
        var rep: NSBitmapImageRep
    }

    /// 老师座位（带 `@State` 的展开开关，能同时测收起 / 展开两态）。
    private struct SeatPreview: View {
        let plan: DailyPlan
        let tokens: Int
        @State private var isExpanded: Bool

        init(plan: DailyPlan, tokens: Int, expanded: Bool) {
            self.plan = plan
            self.tokens = tokens
            self._isExpanded = State(initialValue: expanded)
        }

        var body: some View {
            // Spacer 把座位顶到底部 —— 黑板是往上长的浮层，座位不贴底就出图不全。
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                TeacherCorner(
                    kind: .fox,
                    isSleeping: false,
                    todayTokens: tokens,
                    plan: plan,
                    streakDays: 5,
                    due: 6,
                    reviewedToday: 2,
                    bubblesAllowed: false,
                    isExpanded: $isExpanded
                )
            }
        }
    }

    private func renderSeat(_ plan: DailyPlan, day: Bool, expanded: Bool, stageHeight: CGFloat = 520) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: day ? .day : .night, systemIsDark: !day)
        let backdrop: Color = day ? Color(hex: 0xE9EFE4) : Color(hex: 0x101B2E)
        let host = NSHostingView(rootView: AnyView(
            SeatPreview(plan: plan, tokens: 12_345, expanded: expanded)
                .forestTheme(theme)
                .frame(width: seatWidth, height: stageHeight)
                .background(backdrop)
        ))
        return try capture(host, size: NSSize(width: seatWidth, height: stageHeight))
    }

    /// 端到端：真的把侧栏挂起来（组件好看不代表接线通了）。
    private func renderSidebar(expanded: Bool, day: Bool) throws -> Render {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("blackboard-probe-\(UUID().uuidString).json")
        )
        let state = AppState(services: CoachServices(config: store, databasePath: ":memory:"))
        state.isSidebarExpanded = true
        state.isBlackboardExpanded = expanded

        let theme = ForestThemeResolver.resolve(mode: day ? .day : .night, systemIsDark: !day)
        let host = NSHostingView(rootView: AnyView(
            AppSidebar(state: state)
                .forestTheme(theme)
                .frame(width: AppSidebar.expandedWidth, height: 700)
        ))
        return try capture(host, size: NSSize(width: AppSidebar.expandedWidth, height: 700))
    }

    private func capture(_ host: NSHostingView<AnyView>, size: NSSize) throws -> Render {
        // ⚠️ `NSHostingView` 自己没有 frame 就出不了图（`bitmapImageRepForCachingDisplay` 返回 nil）——
        // SwiftUI 里那句 `.frame(width:height:)` 管的是内容，不是宿主视图。
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        // 板的高度是「量出来 → 再定高」的两趟布局（见 `BlackboardPanel`）：
        // 首趟只拿得到 0，必须让 Preference 走完一轮再出图，否则量到的是初值。
        //
        // ⚠️ 还得**等弹簧动画走完**：改高那一下带 `.spring(response: 0.34)`，
        // 早出图量到的是动画中途的尺寸/位置 —— 实测板底能飘 60pt，
        // 拿这种数字去量「板底到老师头顶的空隙」等于白量（还被断言当成回归）。
        for _ in 0..<12 {
            host.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
        }

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep)
    }

    // MARK: - 像素度量

    /// 板面墨迹：暗、偏绿、绿多于蓝（墨绿板 0x2F4A3C 的特征）。
    ///
    /// 侧栏底色（日档浅 / 夜档深蓝）都不满足「绿多于蓝」，所以不会混进来。
    private func boardInk(_ rep: NSBitmapImageRep) -> Int {
        var count = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
                let luma = r * 0.3 + g * 0.6 + b * 0.1
                if g - r > 0.05, g - b > 0.02, luma < 0.5 { count += 1 }
            }
        }
        return count
    }

    /// 亮绿墨迹（`theme.success` 的绿勾 / 完成关键字）：比板面绿得多。
    private func brightGreenInk(_ rep: NSBitmapImageRep, above baseline: Double) -> Int {
        var count = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                if color.greenComponent - color.redComponent > baseline { count += 1 }
            }
        }
        return count
    }

    /// 全图最大的「绿 − 红」差值（用来给亮绿定基准）。
    private func maxGreenDelta(_ rep: NSBitmapImageRep) -> Double {
        var best = -1.0
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                best = max(best, color.greenComponent - color.redComponent)
            }
        }
        return best
    }

    /// 亮绿（绿勾）墨迹的**最低一行**（像素坐标）。没量到返回 -1。
    private func brightGreenBottom(_ rep: NSBitmapImageRep) -> Int {
        let threshold = max(maxGreenDelta(rep) * 0.5, 0.08)
        var bottom = -1
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                if color.greenComponent - color.redComponent > threshold { bottom = max(bottom, y) }
            }
        }
        return bottom
    }

    /// **板面**（墨绿）的上沿：第一个「墨绿像素足够多」的行。
    ///
    /// ⚠️ 不能拿「任意一个墨绿像素」当板面：未完成圆圈那圈灰描边、老师名字的墨色
    /// 都满足「暗 + 偏绿」，它们会把上沿拉到圆圈那一行去（实测就是这么翻车的）。
    /// 板面一行有几百个像素，圆圈描边一行只有十几个 —— 用密度区分。
    private func boardSurfaceTop(_ rep: NSBitmapImageRep) -> Int {
        for y in 0..<rep.pixelsHigh {
            var count = 0
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
                let luma = r * 0.3 + g * 0.6 + b * 0.1
                if g - r > 0.05, g - b > 0.02, luma < 0.5 { count += 1 }
            }
            // 取样步长是 2，所以这里的计数是实际像素数的 1/4（2x 屏再翻一倍）。
            if count >= 50 { return y }
        }
        return -1
    }

    private func dump(_ rep: NSBitmapImageRep, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]), "PNG 编码失败")
        try png.write(to: directory.appendingPathComponent(name))
    }

    // MARK: - ① 收起态：做完一项就要有绿勾（不是靠文字说「已完成」）

    func testCollapsedSeatDrawsGreenChecksOnlyForDoneTasks() throws {
        let none = try renderSeat(plan(doneCount: 0), day: true, expanded: false)
        let one = try renderSeat(plan(doneCount: 1), day: true, expanded: false)
        let all = try renderSeat(plan(doneCount: 3), day: true, expanded: false)

        let baseline = maxGreenDelta(none.rep)
        XCTAssertLessThan(baseline, 0.2, "一项都没做时不该有亮绿（板面墨绿不算），实测 \(baseline)")

        let oneInk = brightGreenInk(one.rep, above: baseline + 0.06)
        let allInk = brightGreenInk(all.rep, above: baseline + 0.06)
        XCTAssertGreaterThan(oneInk, 8, "完成一项就该有绿勾的墨迹，实测 \(oneInk)")
        XCTAssertGreaterThan(allInk, oneInk, "三项都做完，绿勾要比只做完一项多（实测 \(allInk) vs \(oneInk)）")
    }

    /// 绿勾必须画在**板面之上**，不是掉进板里。
    ///
    /// ⚠️ 这条补的是一个真踩过的坑：圆圈最初是「另算一个 offset」摆上去的，
    /// 实测整排掉进了板面里 —— 而上面那条断言只查「有没有绿勾」，
    /// 掉进板里照样全绿（绿勾还是画出来了，只是位置错）。**只有量几何才拦得住。**
    func testGreenChecksSitAboveTheBoardNotInsideIt() throws {
        for day in [true, false] {
            let render = try renderSeat(plan(doneCount: 2), day: day, expanded: false)
            let greenBottom = brightGreenBottom(render.rep)
            let boardTop = boardSurfaceTop(render.rep)

            XCTAssertGreaterThan(greenBottom, 0, "\(day ? "日" : "夜")档没量到绿勾")
            XCTAssertGreaterThan(boardTop, 0, "\(day ? "日" : "夜")档没量到板面")
            XCTAssertLessThan(
                greenBottom, boardTop,
                """
                \(day ? "日" : "夜")档：绿勾最低 \(Double(greenBottom) / 2)pt，板面上沿 \(Double(boardTop) / 2)pt ——
                绿勾必须在板面之上（差 \(Double(boardTop - greenBottom) / 2)pt），掉进板里就是摆位错了
                """
            )
        }
    }

    // MARK: - ② 展开态：黑板真的抬起来、放大了

    func testExpandedBoardIsMuchBiggerThanTheCollapsedOne() throws {
        let collapsed = try renderSeat(plan(doneCount: 1), day: true, expanded: false)
        let expanded = try renderSeat(plan(doneCount: 1), day: true, expanded: true)

        let collapsedInk = boardInk(collapsed.rep)
        let expandedInk = boardInk(expanded.rep)
        XCTAssertGreaterThan(collapsedInk, 100, "收起态那块小板要画出来（实测 \(collapsedInk)）")
        XCTAssertGreaterThan(
            expandedInk, collapsedInk * 3,
            "展开后板面墨迹应远多于收起态（实测 \(expandedInk) vs \(collapsedInk)）—— 少了就说明浮层没画出来"
        )
    }

    // MARK: - ③ 任务少了板就矮（高度按实际内容来）

    func testFewerTasksMakeTheBoardShorter() throws {
        let three = try renderSeat(plan(doneCount: 0, taskCount: 3), day: true, expanded: true)
        let one = try renderSeat(plan(doneCount: 0, taskCount: 1), day: true, expanded: true)
        XCTAssertGreaterThan(
            boardInk(three.rep), boardInk(one.rep) + 200,
            "三项任务的板要比一项的高出一截（实测 \(boardInk(three.rep)) vs \(boardInk(one.rep))）"
        )
    }

    // MARK: - ④ 侧栏端到端：接线通了（并落盘供人眼复核）

    func testSidebarWiresTheBlackboardEndToEnd() throws {
        let collapsed = try renderSidebar(expanded: false, day: true)
        let expanded = try renderSidebar(expanded: true, day: true)

        let collapsedInk = boardInk(collapsed.rep)
        let expandedInk = boardInk(expanded.rep)
        XCTAssertGreaterThan(collapsedInk, 100, "收起态侧栏里也要看得到那块小板（实测 \(collapsedInk)）")
        XCTAssertGreaterThan(
            expandedInk, collapsedInk * 3,
            "置上 `isBlackboardExpanded` 后侧栏里要真的多出一大块板（实测 \(expandedInk) vs \(collapsedInk)）"
        )

        // ⚠️ 展开**不许盖遮罩**（用户实测：展开后侧栏整片被压暗，上面「设置」等入口点不动）。
        // 判据：展开前/后，**板盖不到的导航区**那几个像素必须一模一样 ——
        // 只要垫了一层半透明遮罩，这里就会整体变暗（日档 22% 的墨绿叠加，肉眼就是一片灰绿）。
        let dayTheme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let probes = [(x: 20, y: 143), (x: 20, y: 227), (x: 12, y: 520)]
        for probe in probes {
            let before = try XCTUnwrap(collapsed.rep.colorAt(x: probe.x, y: probe.y))
            let after = try XCTUnwrap(expanded.rep.colorAt(x: probe.x, y: probe.y))
            let delta = max(
                abs(before.redComponent - after.redComponent),
                abs(before.greenComponent - after.greenComponent),
                abs(before.blueComponent - after.blueComponent)
            )
            XCTAssertLessThan(
                delta, 0.02,
                "展开后侧栏 (\(probe.x), \(probe.y)) 这一点的颜色变了（\(delta)）—— 多半是又垫了一层遮罩"
            )
            // 敏感性自检：这条断言不是空转 —— 真把遮罩叠上去，变化必须远超上面的门槛。
            let masked = try blended(before, with: dayTheme.scrim)
            let maskedDelta = max(
                abs(before.redComponent - masked.redComponent),
                abs(before.greenComponent - masked.greenComponent),
                abs(before.blueComponent - masked.blueComponent)
            )
            XCTAssertGreaterThan(
                maskedDelta, 0.03,
                "自检：叠上遮罩后 (\(probe.x), \(probe.y)) 的颜色只变了 \(maskedDelta)，这条断言拦不住遮罩"
            )
        }

        try dump(collapsed.rep, name: "round48-sidebar-collapsed-day.png")
        try dump(expanded.rep, name: "round48-sidebar-expanded-day.png")
    }

    /// 按 `overlay` 的 alpha 把它叠在 `base` 上（只用于「断言拦不拦得住遮罩」的自检）。
    private func blended(_ base: NSColor, with overlay: Color) throws -> NSColor {
        let top = try XCTUnwrap(NSColor(overlay).usingColorSpace(.sRGB))
        let alpha = top.alphaComponent
        return NSColor(
            srgbRed: top.redComponent * alpha + base.redComponent * (1 - alpha),
            green: top.greenComponent * alpha + base.greenComponent * (1 - alpha),
            blue: top.blueComponent * alpha + base.blueComponent * (1 - alpha),
            alpha: 1
        )
    }

    // MARK: - ⑤ 日夜两版都出图

    func testDumpsBothThemes() throws {
        let day = try renderSeat(plan(doneCount: 1), day: true, expanded: true)
        let night = try renderSeat(plan(doneCount: 1), day: false, expanded: true)
        let daySeat = try renderSeat(plan(doneCount: 1), day: true, expanded: false)
        let nightSeat = try renderSeat(plan(doneCount: 1), day: false, expanded: false)

        XCTAssertGreaterThan(boardInk(day.rep), 100, "日间展开态要有板面")
        XCTAssertGreaterThan(boardInk(night.rep), 100, "夜间展开态要有板面（板不跟着主题变白）")

        try dump(day.rep, name: "round48-blackboard-expanded-day.png")
        try dump(night.rep, name: "round48-blackboard-expanded-night.png")
        try dump(daySeat.rep, name: "round48-blackboard-collapsed-day.png")
        try dump(nightSeat.rep, name: "round48-blackboard-collapsed-night.png")
    }

    // MARK: - ⑥ 空隙：板底紧贴老师头顶、老师紧贴名字、板底不留空板

    /// 老师本体（狐狸老师）的橙色毛：返回墨迹带的 (上沿, 下沿) 像素行号。
    private func foxBand(_ rep: NSBitmapImageRep) -> (top: Int, bottom: Int) {
        var top = -1, bottom = -1
        for y in 0..<rep.pixelsHigh {
            var count = 0
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if c.redComponent > 0.55,
                   c.redComponent - c.greenComponent > 0.22,
                   c.greenComponent - c.blueComponent > 0.08 { count += 1 }
            }
            if count >= 4 {
                if top < 0 { top = y }
                bottom = y
            }
        }
        return (top, bottom)
    }

    /// **板面**（墨绿）的上下沿。密度门槛用来把圆圈描边、名字墨色这类零星墨迹挡在外面。
    private func boardBand(_ rep: NSBitmapImageRep) -> (top: Int, bottom: Int) {
        var top = -1, bottom = -1
        for y in 0..<rep.pixelsHigh {
            var count = 0
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
                let luma = r * 0.3 + g * 0.6 + b * 0.1
                if g - r > 0.05, g - b > 0.02, luma < 0.5 { count += 1 }
            }
            if count >= 50 {
                if top < 0 { top = y }
                bottom = y
            }
        }
        return (top, bottom)
    }

    /// 板上粉笔字（白）的**最低一行** —— 量「板底那条空板有多宽」。
    ///
    /// ⚠️ 三道门槛都不能省：
    /// 1. `min > 0.45`：板子最后一行是 `chalkPending`（白 45% 叠在墨绿上，实测 0.53），
    ///    门槛给到 0.6 会把最后一行漏掉，量出来的留白凭空多 15pt；
    /// 2. `count >= 10`：板面下沿的抗锯齿、木框高光那几个像素也「够亮」；
    /// 3. 横向只取中间 3/4：板子圆角外的**浅色侧栏底**也够亮，会假装成粉笔字（实测差 19pt）。
    private func chalkBottom(_ rep: NSBitmapImageRep, from: Int, to: Int) -> Int {
        guard from >= 0, to > from else { return -1 }
        var bottom = -1
        for y in from..<min(to, rep.pixelsHigh) {
            var count = 0
            for x in stride(from: rep.pixelsWide / 8, to: rep.pixelsWide * 7 / 8, by: 2) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                if min(c.redComponent, c.greenComponent, c.blueComponent) > 0.45 { count += 1 }
            }
            if count >= 10 { bottom = y }
        }
        return bottom
    }

    /// 深色字（老师名字）的最高一行：从 `after` 往下找第一行有足够墨迹的。
    private func inkTop(_ rep: NSBitmapImageRep, after: Int, minCount: Int = 4) -> Int {        guard after >= 0 else { return -1 }
        for y in after..<rep.pixelsHigh {
            var count = 0
            for x in stride(from: rep.pixelsWide / 4, to: rep.pixelsWide * 3 / 4, by: 2) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let luma = c.redComponent * 0.3 + c.greenComponent * 0.6 + c.blueComponent * 0.1
                if luma < 0.55 { count += 1 }
            }
            if count >= minCount { return y }
        }
        return -1
    }

    /// 用户点名的两条空隙：「黑板与老师之间、老师与老师名称之间」。
    ///
    /// ⚠️ 这两条**只能用像素量**：它们是「看起来空了一大块」的观感问题，
    /// 常量对不对（`panelBottomOffset` 之类）证明不了画出来是紧的 ——
    /// 板底到老师头顶之间到底隔了多少，取决于老师画框在座位里怎么摆。
    ///
    /// ⚠️ 板**自身底部**那条留白不在这里量：展开后老师的气泡正好压在板底上
    /// （浅色气泡会被当成粉笔字，量出来是假绿），那条见 `testPanelKeepsOnlyABreathUnderTheLastChalkRow`。
    func testExpandedBoardSitsTightAgainstTheTeacher() throws {
        let render = try renderSeat(plan(doneCount: 1), day: true, expanded: true, stageHeight: 700)
        let board = boardBand(render.rep)
        let fox = foxBand(render.rep)
        // ⚠️ 从老师「脚底下」再往下找名字：老师自己的深色脚掌/爪尖就在名字上方，
        // 紧接着找会把脚掌当成名字（实测 nameGap 直接算成 0）。
        let name = inkTop(render.rep, after: fox.bottom + 24)

        XCTAssertGreaterThan(board.top, 0, "没量到板面")
        XCTAssertGreaterThan(board.bottom, 0, "没量到板面下沿")
        XCTAssertGreaterThan(fox.top, 0, "没量到老师本体")
        XCTAssertGreaterThan(name, 0, "没量到老师名字")

        let headGap = Double(fox.top - board.bottom) / 2
        // 橙色毛的下沿还在老师脚掌之上约 9pt；再加上老师一直在轻微蹦跳（±4pt），
        // 所以这条断言用橙色下沿量、留出余量，看的是「不是空出一大条」而不是精确值。
        let nameGap = Double(name - fox.bottom) / 2
        print("[黑板空隙] 板底→老师头顶 \(headGap)pt ｜ 老师脚下→名字 \(nameGap)pt")

        XCTAssertLessThanOrEqual(
            headGap, 20,
            "板底该贴着老师头顶（实测 \(headGap)pt）—— 空隙一大，整块板就被顶到侧栏上半部分去了"
        )
        XCTAssertLessThanOrEqual(
            nameGap, 24,
            "老师与名字之间不该空出一大条（实测 \(nameGap)pt，已含脚掌 9pt）"
        )

        try dump(render.rep, name: "round61-blackboard-tight-day.png")
    }

    /// 板**自身底部**那条留白：最后一排粉笔字到板面下沿的距离。
    ///
    /// ⚠️ 单独渲染黑板本体（不挂老师）：挂着老师时，展开后老师的气泡正好压在板底，
    /// 气泡的浅色像素会被当成「粉笔字」，把这条留白量成 2pt。
    func testPanelKeepsOnlyABreathUnderTheLastChalkRow() throws {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let panel = BlackboardPanel(
            theme: theme,
            plan: plan(doneCount: 1),
            streakDays: 5,
            due: 6,
            reviewedToday: 2,
            todayTokens: 12_345
        )
        let size = NSSize(width: BlackboardPanel.frameWidth, height: 420)
        let host = NSHostingView(rootView: AnyView(
            VStack(spacing: 0) {
                panel
                Spacer(minLength: 0)
            }
            .frame(width: size.width, height: size.height)
            .background(Color(hex: 0xE9EFE4))
        ))
        let render = try capture(host, size: size)

        let board = boardBand(render.rep)
        let chalk = chalkBottom(render.rep, from: board.top, to: board.bottom)
        XCTAssertGreaterThan(board.bottom, 0, "没量到板面下沿")
        XCTAssertGreaterThan(chalk, 0, "没量到板上的粉笔字")

        let slack = Double(board.bottom - chalk) / 2
        print("[板底留白] 最后一排粉笔字→板面下沿 \(slack)pt")
        // 门槛 26：改前是 22pt 追加高度（加上木框与内边距共 40pt，用户就是量着那条说的），
        // 现在是 8pt（实测 21pt）—— 留着余量但能拦住「又调回一大条」。
        XCTAssertLessThanOrEqual(
            slack, 26,
            "板底不该留一大条空板（实测 \(slack)pt）—— 用户量出来的那条"
        )

        try dump(render.rep, name: "round61-blackboard-bottom-breath-day.png")
    }

    /// 展开的板**不许顶出侧栏顶部**：可用高度得按「板底到侧栏顶」算，别漏掉座位底下那截。
    func testAvailableHeightKeepsTheBoardInsideTheSidebar() {
        // 侧栏 700 高、座位顶距底 142（109 座位 + 分隔线 + 收拉按钮）→ 板底在 138 处。
        let limit = BlackboardLayout.availableHeight(sidebarHeight: 700, seatTopFromBottom: 142)
        XCTAssertEqual(limit, 700 - 138 - BlackboardLayout.topBreathing, accuracy: 0.5)

        // 窗口再矮也不能给出负数高度。
        XCTAssertEqual(
            BlackboardLayout.availableHeight(sidebarHeight: 180, seatTopFromBottom: 142),
            BlackboardLayout.minimumPanelHeight,
            "窗口太矮时要退到最小高度，不能返回负数"
        )
    }
}
