import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 「今日任务」卡片（P1-1）的**离屏渲染**回归。
///
/// 与 `PhonemeBreakdownRenderTests` 同款理由：本次验证环境熄屏，走离屏出图；
/// 断言只钉「用户真能看见」这件事 —— 任务几项就画几行、完成态真有绿色对勾、
/// 「今天重点」真占一行、日夜两版都对。顺带把 PNG 落到 `.workbuddy/verify/`。
///
/// ⚠️ 这里**不做墨迹包围盒**断言：卡片自带全宽底色，包围盒恒等于卡宽，
/// 那种断言必然假通过。改成「高度」+「特定颜色像素数」。
@MainActor
final class DailyTasksCardRenderTests: XCTestCase {

    private var window: NSWindow?
    private let cardWidth: CGFloat = 520

    // MARK: - 造计划

    private func task(
        _ kind: DailyTask.Kind, title: String, reason: String, target: Int, progress: Int, unit: String
    ) -> DailyTask {
        DailyTask(kind: kind, title: title, reason: reason, target: target, progress: progress, unit: unit)
    }

    private func plan(doneConversation: Bool = false, tasks: Int = 3, focus: Bool = true) -> DailyPlan {
        var list = [
            task(.conversation, title: "和老师聊 10 轮",
                 reason: doneConversation ? "每日目标 15 分钟 · 今天已聊 10 轮" : "每日目标 15 分钟，今天还没开口",
                 target: 10, progress: doneConversation ? 10 : 0, unit: "轮"),
            task(.shadowing, title: "跟读 3 句，逐音素纠音",
                 reason: "今天已跟读 1 次 · 发音均分 78", target: 3, progress: 1, unit: "次"),
            task(.review, title: "复习 8 个到期单词",
                 reason: "有 12 个词到期，先做前 8 个", target: 8, progress: 2, unit: "个词"),
        ]
        if tasks < list.count { list = Array(list.prefix(tasks)) }
        return DailyPlan(
            day: Date(),
            tasks: list,
            focus: focus
                ? DailyPlan.Focus(title: "今天重点：时态",
                                  reason: "最近 12 处批注里有 5 处在时态上，其中 2 处反复出现")
                : nil
        )
    }

    // MARK: - 离屏渲染

    private struct Render {
        var rep: NSBitmapImageRep
        var size: CGSize
    }

    private func render(_ plan: DailyPlan, day: Bool) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: day ? .day : .night, systemIsDark: !day)
        let backdrop: Color = day ? Color(hex: 0xE9EFE4) : Color(hex: 0x101B2E)
        let host = NSHostingView(rootView: AnyView(
            DailyTasksCard(plan: plan)
                .forestTheme(theme)
                .frame(width: cardWidth)
                .background(backdrop)
        ))
        host.frame = NSRect(x: 0, y: 0, width: cardWidth, height: 160)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        // 两趟：先问自然高度，再按自然高度出图，避免把内容裁掉。
        let size = CGSize(width: cardWidth, height: max(80, ceil(host.fittingSize.height)))
        host.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep, size: size)
    }

    /// 全图最大的「绿 − 红」差值（不写死色值，见 `greenInk` 的说明）。
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

    /// 比 `baseline` 更绿的像素数。
    ///
    /// ⚠️ **不能写死绝对色值**：离屏渲染会经一次色彩空间换算，实测 sRGB 的
    /// `0x8FD694`（理论 0.56/0.84/0.58）落到位图上只有约 0.62/0.83/0.60，
    /// 饱和度被压掉约四分之一。写死阈值会随着显示器 / 系统色彩管理假失败。
    /// 改成「相对基准」：基准由同一批渲染里的待办版本量出来。
    private func greenInk(_ rep: NSBitmapImageRep, above baseline: Double) -> Int {
        var count = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let r = color.redComponent, g = color.greenComponent
                if g - r > baseline, g > 0.45 { count += 1 }
            }
        }
        return count
    }

    private func dump(_ rep: NSBitmapImageRep, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AILanguageCoachTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]), "PNG 编码失败")
        try png.write(to: directory.appendingPathComponent(name))
    }

    // MARK: - ① 几项任务就画几行

    func testMoreTasksMakeTheCardTaller() throws {
        let one = try render(plan(tasks: 1, focus: false), day: true)
        let three = try render(plan(tasks: 3, focus: false), day: true)
        XCTAssertGreaterThan(
            three.size.height, one.size.height + 60,
            "多两项任务至少要多出两行的高度（每行 ≈ 60pt）"
        )
    }

    // MARK: - ② 完成态必须有绿色对勾（不是靠文字说「已完成」）

    func testDoneTaskDrawsGreenInk() throws {
        let pending = try render(plan(doneConversation: false), day: true)
        let done = try render(plan(doneConversation: true), day: true)

        // 基准从「待办版」自己量出来：琥珀主色 + 底色都偏暖，不会有一点绿。
        let baseline = maxGreenDelta(pending.rep)
        let peak = maxGreenDelta(done.rep)

        XCTAssertLessThan(baseline, 0.06, "待办版不该有绿色墨迹，实测峰值差 \(baseline)")
        XCTAssertGreaterThan(peak, baseline + 0.05, "完成态的绿色必须明显超过待办态（实测 \(peak)）")
        XCTAssertGreaterThan(
            greenInk(done.rep, above: baseline + 0.02), 200,
            "完成一项后要有成片的绿色墨迹（对勾 + 进度条 + 行底色），实测 \(greenInk(done.rep, above: baseline + 0.02)) 像素"
        )
    }

    // MARK: - ③「今天重点」真的占一行

    func testFocusRowActuallyTakesSpace() throws {
        let withFocus = try render(plan(focus: true), day: true)
        let without = try render(plan(focus: false), day: true)
        XCTAssertGreaterThan(
            withFocus.size.height, without.size.height + 24,
            "「今天重点」是独立一块（标题 + 依据两行），必须真的占高度"
        )
    }

    // MARK: - ④ 日夜两版都要能看（并落盘供人眼复核）

    func testRendersInBothThemesAndDumpsPNG() throws {
        let plan = plan(doneConversation: true)
        let day = try render(plan, day: true)
        let night = try render(plan, day: false)

        // 两版都必须画出完成态的绿（阈值自校准，理由见 `greenInk`）。
        XCTAssertGreaterThan(maxGreenDelta(day.rep), 0.08, "日间版应有完成态绿色")
        XCTAssertGreaterThan(maxGreenDelta(night.rep), 0.08, "夜间版应有完成态绿色")
        XCTAssertGreaterThan(greenInk(day.rep, above: 0.06), 200, "日间版绿色墨迹应有面积")
        XCTAssertGreaterThan(greenInk(night.rep, above: 0.06), 200, "夜间版绿色墨迹应有面积")

        func luma(_ rep: NSBitmapImageRep) throws -> CGFloat {
            let color = try XCTUnwrap(rep.colorAt(x: 0, y: 0))
            return color.redComponent * 0.3 + color.greenComponent * 0.6 + color.blueComponent * 0.1
        }
        XCTAssertGreaterThan(try luma(day.rep), try luma(night.rep), "两版底色必须真的不同")

        try dump(day.rep, name: "round32-daily-tasks-day.png")
        try dump(night.rep, name: "round32-daily-tasks-night.png")
    }

    // MARK: - ⑤ 端到端：学习进度页里真的长出来了

    /// 走真实链路（`AppState(services:)` → `openProgress()` → `state.dailyPlan`），
    /// 确认计划真的接上了应用状态，而且页面里确实渲染了它。
    /// 组件好看不代表接线通了 —— 这条才是接线。
    func testProgressPageShowsDailyTasksEndToEnd() async throws {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("daily-tasks-probe-\(UUID().uuidString).json")
        )
        let state = AppState(services: CoachServices(config: store, databasePath: ":memory:"))
        await state.openProgress()

        let plan = state.dailyPlan
        XCTAssertFalse(plan.tasks.isEmpty, "刚装好的应用也该给出可做的任务（开口 + 跟读）")
        XCTAssertEqual(plan.tasks.first?.kind, .conversation)
        XCTAssertFalse(plan.isAllDone, "全新状态不该显示「今天都做完了」")

        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let host = NSHostingView(rootView: AnyView(
            LearningProgressView(state: state).forestTheme(theme)
        ))
        host.frame = NSRect(x: 0, y: 0, width: 860, height: 1500)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        XCTAssertGreaterThan(host.fittingSize.height, 400, "整页应能布局")
        try dump(rep, name: "round32-progress-page-with-daily-tasks.png")
    }
}
