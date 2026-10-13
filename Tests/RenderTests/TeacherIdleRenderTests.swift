import AIDomain
import AppUI
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 老师「平时不跳、庆祝才跳」的**离屏渲染**回归。
///
/// 为什么必须离屏跑：源码哨兵（`TeacherHopWiringTests`）只能证明「参数传对了」，
/// 证明不了**画面真的不动**。用户 2026-10-13 的报障原话是「老师从早跳到晚」——
/// 那是像素级的现象，只有把视图渲染出来、跨时间采样才算证到。
///
/// 两条断言各自钉一个失败模式，缺一不可：
/// ① `bobbing: false` 时**上下位置一动不动**（当年正是少了这个 false）；
/// ② 庆祝那一下**真抬起来、并且落回原位**（`hopLift` 卡住 = 老师永远浮在半空）。
///
/// ⚠️ 本文件**故意不关** `CuteAnimalView.animationsEnabled`：要验的就是「动画在跑时
/// 老师不动」。所以两条判据都只看**竖直位置**（墨迹最上一行），不看整帧差分——
/// 眨眼（3.2s 一次）只改眼睛那几像素，不会影响头顶墨迹行；挥教棍同理（本文件用
/// `accessory: .none` 把教棍排除掉，让度量只对着「跳」这一件事）。
///
/// ⚠️ 时间窗一律**短于眨眼周期**（采样总长 < 3s），否则眼睛一眨就可能落进采样里。
@MainActor
final class TeacherIdleRenderTests: XCTestCase {

    private var window: NSWindow?

    /// 底座边长：84pt 的老师 + 四周留白，浮起 0.22×84 ≈ 18.5pt 也出不了画。
    private let canvasSide: CGFloat = 160

    // MARK: - 探针

    /// `hopTick` 必须是**可变的**：`onChange(of: hopTick)` 只在同一个视图实例内
    /// 「值发生变化」时触发 —— 直接以 `hopTick: 1` 渲染一个新视图是**不会跳的**
    /// （那是初始值，不是变化），拿它写测试会得到一个永远绿的假闸。
    @Observable
    final class HopProbe {
        var tick = 0
    }

    private struct AnimalProbe: View {
        let bobbing: Bool
        let hop: HopProbe

        var body: some View {
            CuteAnimalView(
                kind: .panda,
                isSleeping: false,
                size: 84,
                // 教棍（.teacher）会一直挥 —— 它属于「该动」的部分，
                // 但会污染「头顶墨迹行」的度量，所以这里只渲染本体。
                accessory: .none,
                bobbing: bobbing,
                hopTick: hop.tick
            )
        }
    }

    // MARK: - 渲染工装

    private func makeHost(bobbing: Bool, hop: HopProbe) -> NSHostingView<AnyView> {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let host = NSHostingView(rootView: AnyView(
            AnimalProbe(bobbing: bobbing, hop: hop)
                .forestTheme(theme)
                .frame(width: canvasSide, height: canvasSide)
                .background(Color(hex: 0xE9EFE4))
        ))
        host.frame = NSRect(x: 0, y: 0, width: canvasSide, height: canvasSide)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        pump(host, seconds: 0.12)
        return host
    }

    /// 让 SwiftUI 提交 + 动画推进。用 `RunLoop.current.run`（同步用例里可以这么做；
    /// async 用例必须改用 `Task.sleep`）。
    private func pump(_ host: NSHostingView<AnyView>, seconds: Double) {
        host.layoutSubtreeIfNeeded()
        window?.layoutIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
        host.layoutSubtreeIfNeeded()
        window?.layoutIfNeeded()
    }

    private func snapshot(_ host: NSHostingView<AnyView>) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    // MARK: - 像素度量

    /// 墨迹（熊猫的黑毛）的**最上一行**，像素坐标；没量到返回 `nil`。
    ///
    /// 判据三件套（缺一就会把透明像素当墨迹 —— 见技能里「透明墨迹」那条）：
    /// 亮度够暗、alpha 够实、且**每行要有足够多的像素**（单个抗锯齿点不算）。
    private func topInkRow(_ rep: NSBitmapImageRep) -> Int? {
        let scale = Double(rep.pixelsWide) / Double(canvasSide)
        let minPerRow = Int(6 * scale)          // 一行至少这么多像素才算「头顶」
        for y in 0..<rep.pixelsHigh {
            var count = 0
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                guard color.alphaComponent > 0.5 else { continue }
                let luma = color.redComponent * 0.3 + color.greenComponent * 0.6 + color.blueComponent * 0.1
                if luma < 0.35 { count += 1 }
            }
            if count >= minPerRow { return y }
        }
        return nil
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

    // MARK: - ① 平时不跳：竖直位置一动不动

    /// 连续采样一串「头顶墨迹行」。整条序列都走一遍 —— 只看一帧是假闸：
    /// 浮动是个 1.5s 的往复，抽一次完全可能正好抽在两个极值之间。
    private func sampleTopRows(bobbing: Bool, frames: Int, step: Double) throws -> [Int] {
        let host = makeHost(bobbing: bobbing, hop: HopProbe())
        var rows: [Int] = []
        for _ in 0..<frames {
            pump(host, seconds: step)
            let rep = try snapshot(host)
            if let row = topInkRow(rep) { rows.append(row) }
        }
        return rows
    }

    func testIdleAnimalDoesNotBobButTheHarnessCanProveABobWhenItIsOn() throws {
        let saved = CuteAnimalView.animationsEnabled
        CuteAnimalView.animationsEnabled = true      // 要验的就是「动画真在跑时老师不动」
        defer { CuteAnimalView.animationsEnabled = saved }

        // 控制组：默认 `bobbing: true` 的同一份夹具。它**必须能被量出在动** ——
        // 量不出浮动，就说明这套度量看不见竖直位移，②③ 两条断言全是假闸。
        let bobbingRows = try sampleTopRows(bobbing: true, frames: 9, step: 0.2)
        let idleRows = try sampleTopRows(bobbing: false, frames: 9, step: 0.2)

        XCTAssertGreaterThanOrEqual(bobbingRows.count, 9, "控制组没量到墨迹 —— 夹具本身就坏了")
        XCTAssertGreaterThanOrEqual(idleRows.count, 9, "受试组没量到墨迹 —— 夹具本身就坏了")

        let bobbingSwing = (bobbingRows.max() ?? 0) - (bobbingRows.min() ?? 0)
        let idleSwing = (idleRows.max() ?? 0) - (idleRows.min() ?? 0)

        // 常驻浮动是 0.045 × 84pt ≈ 3.8pt，峰谷 7.6pt ≈ 15 像素（2x）。取 6 像素当门槛：
        // 远高于抗锯齿噪声，又远低于真实幅度，不至于因采样相位漏掉而假红。
        XCTAssertGreaterThan(
            bobbingSwing, 6,
            "控制组（bobbing: true）必须能看出上下浮动，实测 \(bobbingSwing)px —— 看不出就等于这套度量是假闸"
        )
        XCTAssertEqual(
            idleSwing, 0,
            "老师平时不许自己浮起来（bobbing: false），实测竖直位移 \(idleSwing)px = \(Double(idleSwing) / 2)pt"
        )
    }

    // MARK: - ② 庆祝才跳：抬起来、并且落回原位

    func testCelebrationHopLiftsAndLandsBackAtRest() throws {
        let saved = CuteAnimalView.animationsEnabled
        CuteAnimalView.animationsEnabled = true
        defer { CuteAnimalView.animationsEnabled = saved }

        let hop = HopProbe()
        let host = makeHost(bobbing: false, hop: hop)

        let restRep = try snapshot(host)
        let rest = try XCTUnwrap(topInkRow(restRep), "静止帧没量到老师本体")
        try dump(restRep, name: "teacher-idle-rest.png")

        // 触发庆祝跳，然后**把整条曲线走一遍**（起跳 0.55s 的 emphasis → 0.34s 后落回 0.55s）。
        // 单点采样会随机器负载落到曲线的任意相位，那才是真正的 flaky 来源。
        hop.tick += 1
        var rows: [Int] = []
        var peakRep: NSBitmapImageRep?
        for _ in 0..<20 {                       // 20 × 0.08s ≈ 1.6s，覆盖整条曲线
            pump(host, seconds: 0.08)
            let rep = try snapshot(host)
            if let row = topInkRow(rep) {
                rows.append(row)
                if row == rows.min() { peakRep = rep }
            }
        }

        let lowest = try XCTUnwrap(rows.min(), "跳的过程中一帧墨迹都没量到")
        let lifted = rest - lowest
        // 抬升量是 0.22 × 84pt ≈ 18.5pt ≈ 37 像素（2x）。门槛取 10 像素：
        // 只要「真的起来了」就过，不钉死曲线形状（那是动效 token 的事）。
        XCTAssertGreaterThan(
            lifted, 10,
            "庆祝那一下必须真抬起来，实测 \(lifted)px = \(Double(lifted) / 2)pt"
        )
        if let peakRep { try dump(peakRep, name: "teacher-hop-peak.png") }

        // 落点：末帧必须回到静止位置（±1px）。`hopLift` 一旦卡住，
        // 老师就永远悬在半空 —— 这正是「一次性动画」最容易出的错。
        let settled = try XCTUnwrap(rows.last, "采样序列是空的")
        XCTAssertEqual(
            settled, rest, accuracy: 1,
            "跳完必须落回原位，实测末帧 \(settled) vs 静止 \(rest)（差 \(settled - rest)px）"
        )

        let settledRep = try snapshot(host)
        try dump(settledRep, name: "teacher-idle-settled.png")
    }

    // MARK: - ③ 真实链路：座位上的老师本身不动

    /// 直接挂**用户真正看到的**那棵树：`TeacherCorner` 座位。
    ///
    /// 为什么非要这一条：①② 是手搓 `CuteAnimalView`，验的是「组件守不守规矩」；
    /// 而 2026-10-13 那个 bug 是**调用点没传 `bobbing: false`**（组件一点没错）。
    /// 只有把 `TeacherCorner` 整个渲染出来才抓得住它 —— 组件级用例当时也是绿的。
    private struct SeatPreview: View {
        let plan: DailyPlan
        @State private var isExpanded = true

        var body: some View {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                TeacherCorner(
                    kind: .fox,
                    isSleeping: false,
                    todayTokens: 12_345,
                    plan: plan,
                    streakDays: 5,
                    dueAtDayStart: 6,
                    reviewedOfDue: 2,
                    reviewedToday: 2,
                    bubblesAllowed: false,
                    isExpanded: $isExpanded
                )
            }
        }
    }

    private func seatPlan(doneCount: Int) -> DailyPlan {
        let specs: [(DailyTask.Kind, Int, String)] = [
            (.conversation, 4, "轮"),
            (.shadowing, 3, "次"),
            (.review, 8, "个词"),
        ]
        let tasks = specs.enumerated().map { index, spec in
            DailyTask(
                kind: spec.0,
                title: "做 \(spec.1) \(spec.2)",
                reason: "有 \(spec.1) \(spec.2) 到期",
                target: spec.1,
                progress: index < doneCount ? spec.1 : 0,
                unit: spec.2
            )
        }
        return DailyPlan(day: Date(), tasks: tasks)
    }

    private func makeSeatHost() -> NSHostingView<AnyView> {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let host = NSHostingView(rootView: AnyView(
            SeatPreview(plan: seatPlan(doneCount: 1))
                .forestTheme(theme)
                .frame(width: 196, height: 560)
                .background(Color(hex: 0xE9EFE4))
        ))
        host.frame = NSRect(x: 0, y: 0, width: 196, height: 560)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        // 黑板是「量出来 → 再定高」的两趟布局 + 一段弹簧，等它settle 再采样。
        pump(host, seconds: 0.12)
        return host
    }

    /// 狐狸老师橙色毛的**最高一行**（像素行号）。
    ///
    /// 只量**头顶**、不量整条墨迹带：教棍一直在挥，挥动会带着手臂（也是橙色）上下 ——
    /// 那属于「该动的部分」，量进去只会把这条断言变成噪声探测器。
    private func foxTopRow(_ rep: NSBitmapImageRep) -> Int? {
        for y in 0..<rep.pixelsHigh {
            var count = 0
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                guard c.alphaComponent > 0.5 else { continue }
                if c.redComponent > 0.55,
                   c.redComponent - c.greenComponent > 0.22,
                   c.greenComponent - c.blueComponent > 0.08 { count += 1 }
            }
            if count >= 4 { return y }
        }
        return nil
    }

    func testRealTeacherSeatStaysPutAcrossFrames() throws {
        let saved = CuteAnimalView.animationsEnabled
        CuteAnimalView.animationsEnabled = true
        defer { CuteAnimalView.animationsEnabled = saved }

        let host = makeSeatHost()
        var tops: [Int] = []
        var lastRep: NSBitmapImageRep?
        for _ in 0..<9 {                       // 9 × 0.2s = 1.8s > 一个 1.5s 浮动周期
            pump(host, seconds: 0.2)
            let rep = try snapshot(host)
            lastRep = rep
            if let top = foxTopRow(rep) { tops.append(top) }
        }
        if let lastRep { try dump(lastRep, name: "teacher-seat-nobob.png") }

        XCTAssertEqual(tops.count, 9, "没量到老师本体 —— 夹具本身就坏了")
        let swing = (tops.max() ?? 0) - (tops.min() ?? 0)
        // 判据与 ① 同源：常驻浮动是 3.8pt（≈7.6pt 峰谷 ≈ 15px @2x）。
        // 座位里的老师平时必须一动不动 —— 这正是用户报的「从早跳到晚」。
        XCTAssertEqual(
            swing, 0,
            "座位上的老师不许自己上下浮（实测 \(swing)px = \(Double(swing) / 2)pt）"
        )
    }
}
