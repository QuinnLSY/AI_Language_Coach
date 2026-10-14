import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 冷启动等待态的**离屏渲染**回归。
///
/// 只钉两件用户真能看见的事：
/// 1. 等久了（≥8 秒）那张卡上真的**多出一行解释**，不是只改了字符串；
/// 2. 装配期对话区里进的是**引导卡**；「老师正在准备…」只在老师真被叫来时出现
///    （2026-10-14 报障反转：那张卡与老师的消息气泡同形，装配期挂上去等于无中生有
///    一条老师发言）。引导卡是**垂直居中**的，等待卡贴在顶部，两者在图上位置完全不同。
///
/// ⚠️ 不做「文字内容」断言：离屏图上读不出字。所以全部用**几何**证明 ——
/// 「图里有没有那句话」是证明不了的。
/// ⚠️ 坐标必须换算：离屏位图的像素尺寸受 backing scale 影响（实测约 1.2×），
/// 直接拿 pt 当像素用会量错区域，所以统一走 `scale`。
/// ⚠️ 比「两帧一致」时必须先关掉动物动画（`CuteAnimalView.animationsEnabled`），
/// 否则相位差会算成差异点、把假红当成回归。
@MainActor
final class TeacherPreparingCardRenderTests: XCTestCase {

    private var window: NSWindow?

    // MARK: - 渲染

    private struct Render {
        var rep: NSBitmapImageRep
        /// 位图像素 / 视图点 的比例（写断言时一律按 pt 给区间）。
        var scale: CGFloat
        var size: CGSize
    }

    private func makeHost(_ view: some View, size: CGSize) throws -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        // `TimelineView` 要靠一次 runloop 才会把内容吐出来（离屏时尤其如此）。
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        return host
    }

    private func capture(_ host: NSHostingView<AnyView>) throws -> Render {
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let size = host.bounds.size
        return Render(rep: rep, scale: CGFloat(rep.pixelsHigh) / max(size.height, 1), size: size)
    }

    /// 卡片：固定 120pt 高的画布（不依赖 `fittingSize` —— `TimelineView` 报不出自然高度）。
    private func renderCard(secondsAgo: TimeInterval, day: Bool) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: day ? .day : .night, systemIsDark: !day)
        let backdrop: Color = day ? Color(hex: 0xE9EFE4) : Color(hex: 0x101B2E)
        let content = TeacherPreparingCard(
            teacherKind: .panda,
            startedAt: Date().addingTimeInterval(-secondsAgo)
        )
        .forestTheme(theme)
        .frame(width: 560, height: 120, alignment: .topLeading)
        .background(backdrop)
        let host = try makeHost(content, size: CGSize(width: 560, height: 120))
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        return try capture(host)
    }

    /// 真实 `ChatView`（消息区在顶部 64pt 顶栏之下）。
    private func renderChat(_ view: ChatView, size: CGSize = CGSize(width: 900, height: 640)) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let host = try makeHost(view.forestTheme(theme), size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        return try capture(host)
    }

    /// 纵向上 `fromPt..<toPt`（按 pt 给，内部换算成像素）之间「明显不是背景」的像素数。
    ///
    /// 背景基准取**同一张图里紧挨下沿的一行**（必然的空白区），不写死色值 ——
    /// 离屏渲染会过一次色彩空间转换，写死必然假失败。
    private func ink(_ render: Render, fromPt: CGFloat, toPt: CGFloat) -> Int {
        let rep = render.rep
        let fromY = max(Int(fromPt * render.scale), 0)
        let toY = min(Int(toPt * render.scale), rep.pixelsHigh)
        guard fromY < toY else { return 0 }
        let baseY = min(toY + Int(8 * render.scale), rep.pixelsHigh - 1)
        guard let background = rep.colorAt(x: rep.pixelsWide - 3, y: baseY) else { return 0 }

        var count = 0
        for y in fromY..<toY {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let diff = abs(color.redComponent - background.redComponent)
                    + abs(color.greenComponent - background.greenComponent)
                    + abs(color.blueComponent - background.blueComponent)
                if diff > 0.08 { count += 1 }
            }
        }
        return count
    }

    /// 两张图逐像素的**差异点数**（2 像素步长采样）。
    ///
    /// 与 `ink` 的分工：`ink` 量「这一带有没有东西」，这一张量「两帧画的是不是同一件事」——
    /// 「装配期不再换卡」只有靠它才证得了（同一块地方换没换内容）。
    private func difference(_ a: Render, _ b: Render) -> Int {
        let height = min(a.rep.pixelsHigh, b.rep.pixelsHigh)
        let width = min(a.rep.pixelsWide, b.rep.pixelsWide)
        var count = 0
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                guard let left = a.rep.colorAt(x: x, y: y),
                      let right = b.rep.colorAt(x: x, y: y) else { continue }
                let delta = abs(left.redComponent - right.redComponent)
                    + abs(left.greenComponent - right.greenComponent)
                    + abs(left.blueComponent - right.blueComponent)
                if delta > 0.08 { count += 1 }
            }
        }
        return count
    }

    private func dump(_ render: Render, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(render.rep.representation(using: .png, properties: [:]), "PNG 编码失败")
        try png.write(to: directory.appendingPathComponent(name))
    }

    // MARK: - ① 等久了真的多出一行

    /// 卡片布局（2026-09-27 加阶段条后）：`[0, 30]` 主标题行（动物头像 30pt 高）；
    /// 阶段条常驻在 `[~34, ~48]`；解释行（≥8 秒才有）在它下面。
    /// 带区起点取「标题行下沿到解释行上沿之间」的中间带，判据用 early/late **差值**
    /// —— 阶段条两帧都有墨，在差值里自然抵消，不依赖对行高的精确估计。
    func testDetailLineOnlyAppearsAfterWaitingLongEnough() throws {
        let early = try renderCard(secondsAgo: 1, day: true)
        let late = try renderCard(secondsAgo: 20, day: true)

        let earlyTitle = ink(early, fromPt: 0, toPt: 32)
        let lateTitle = ink(late, fromPt: 0, toPt: 32)
        XCTAssertGreaterThan(earlyTitle, 300, "主标题行就该有墨迹")
        XCTAssertGreaterThan(lateTitle, 300, "主标题行就该有墨迹")

        // 阶段条（#359）常驻：两个阶段的点 + 标签，刚等 1 秒也要画出来。
        XCTAssertGreaterThan(ink(early, fromPt: 33, toPt: 50), 100,
                             "阶段条常驻，刚等 1 秒也该有墨迹")
        XCTAssertGreaterThan(ink(late, fromPt: 33, toPt: 50), 100)

        // 解释行只在等久了出现：early/late 在标题以下的墨差值就是那一行的量。
        let earlyBelow = ink(early, fromPt: 50, toPt: 70)
        let lateBelow = ink(late, fromPt: 50, toPt: 70)
        XCTAssertLessThan(earlyBelow, 60,
                          "只等 1 秒不该有解释行（实测 \(earlyBelow) 像素）")
        XCTAssertGreaterThan(lateBelow, 200,
                             "等到 20 秒必须真的多出一行解释（实测 \(lateBelow) 像素）")
    }

    // MARK: - ② 日夜两版都能看（并落盘供人眼复核）

    func testRendersInBothThemesAndDumpsPNG() throws {
        let dayEarly = try renderCard(secondsAgo: 1, day: true)
        let dayLate = try renderCard(secondsAgo: 20, day: true)
        let nightLate = try renderCard(secondsAgo: 20, day: false)

        for (name, render) in [("day-early", dayEarly), ("day-late", dayLate), ("night-late", nightLate)] {
            XCTAssertGreaterThan(ink(render, fromPt: 0, toPt: 60), 600, "\(name) 版几乎没画出东西")
        }

        try dump(dayEarly, name: "round33-wait-card-day-early.png")
        try dump(dayLate, name: "round33-wait-card-day-late.png")
        try dump(nightLate, name: "round33-wait-card-night-late.png")
    }

    // MARK: - ③ 端到端：装配期进的是**引导卡**（2026-10-14 报障反转）

    /// 装配那几秒对话区里是**引导卡**，不是「老师正在准备…」。
    ///
    /// ⚠️ 这条用例原来是反过来的（钉「装配期挂等待卡、不显示引导卡」）—— 那会儿开屏会
    /// 自动开场，引导卡说「和老师打个招呼」而老师马上自己就开口了，确实在说谎。
    /// 现在开屏不再自动开场：老师在装配期**根本没被叫来**，而「老师正在准备…」那张卡
    /// 与老师的消息气泡同形（圆头像 + 名字 + 三个跳动的点）—— 用户看到的就是
    /// 「一打开老师先发起对话、过一会儿又被引导卡顶掉」（报障原话）。
    func testBootingNoLongerSwapsTheGuideCardForAWaitCard() async throws {
        let saved = CuteAnimalView.animationsEnabled
        CuteAnimalView.animationsEnabled = false
        defer { CuteAnimalView.animationsEnabled = saved }

        let state = AppState(services: CoachServices(
            config: ConfigStore(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("alc-wait-\(UUID().uuidString).json")),
            databasePath: ":memory:"
        ))

        // 构造期漏赋值同样是静默失效（见 ModelControlTests 同款注释）：
        // 漏了 `isBooting`，自动朗读那道守卫就失效（揭历史时把旧消息念出来）。
        let booting = ChatView(chat: state.chat, modelName: nil, health: state.health, isBooting: true)
        XCTAssertTrue(booting.isBooting, "isBooting 必须被 init 存入")
        let idle = ChatView(chat: state.chat, modelName: nil, health: state.health, isBooting: false)
        XCTAssertFalse(idle.isBooting)

        let boot = try renderChat(booting)
        let idleRender = try renderChat(idle)

        // ① 装配期与空闲期必须画成**同一件事**：`isBooting` 不再是空态的输入。
        //    有人把它加回判据的话，这里立刻红（这是本用例的核心）。
        let drift = difference(boot, idleRender)
        XCTAssertLessThan(drift, 120, "装配期不该因为 isBooting 而换卡（实测差异 \(drift) 点）")

        // ② 装配期那张引导卡必须**在场**：它是垂直居中的（取纵向 38%–62% 这段）。
        let bootMid = ink(boot, fromPt: boot.size.height * 0.38, toPt: boot.size.height * 0.62)
        XCTAssertGreaterThan(bootMid, 4000, "装配期就该直接显示引导卡（实测 \(bootMid) 像素）")

        // ③ 反证的另一半：真的有老师要说话时，等待卡照样出现、引导卡照样让位
        //    —— 不然「把等待卡整个删掉」也能骗过上面两条。
        let preparing = ChatView(
            chat: state.chat, modelName: nil, health: state.health,
            isBooting: false, isPreparingOpening: true
        )
        let preparingRender = try renderChat(preparing)
        // 等待卡贴在消息区顶部（顶栏 64pt 之下那一段）。
        let prepTop = ink(preparingRender, fromPt: 82, toPt: 118)
        XCTAssertGreaterThan(prepTop, 300, "老师真被叫来时，等待卡要贴在消息区顶部（实测 \(prepTop) 像素）")
        let prepMid = ink(
            preparingRender,
            fromPt: preparingRender.size.height * 0.38,
            toPt: preparingRender.size.height * 0.62
        )
        XCTAssertLessThan(prepMid, bootMid / 3, "老师在准备时引导卡必须让位（实测 \(prepMid) 像素）")

        try dump(boot, name: "round58-chat-booting-invitation.png")
        try dump(preparingRender, name: "round58-chat-teacher-preparing.png")
    }
}
