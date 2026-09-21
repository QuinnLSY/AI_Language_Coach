import AIDomain
import AIInfrastructure
import AppCore
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 黑板右上角两个小按钮的回归：**提示说的是自己的事、收起箭头朝下**。
///
/// 用户报的两条（2026-09-19）：
/// 1. 鼠标停在「跳转今日任务」上，弹的是「AI 老师 · 小熊猫（可在设置中更换）」；
/// 2. 点它会收起板，箭头却朝上（`chevron.up`），应该是下三角。
///
/// ⚠️ **笼统的 `.help` 盖住子视图提示这件事，离屏拦不住**：实测 SwiftUI 的 `.help`
/// 在 AppKit 视图树里**不产生任何 `toolTip` 视图**（把整条侧栏的视图树挖了一遍，0 个），
/// 所以没有可断言的宿主对象 —— 这条只能靠人眼悬停复核，顺带靠代码纪律：
/// **不要在任何"包着黑板"的祖先上写 `.help`**（消息已写进 `AppSidebar.teacherOverlay`
/// 与 `TeacherCorner.seatLayer` 的注释）。这里测的是**能测的那半**：
/// 按钮自己的文案有没有说清「跳哪儿 / 收起」，以及收起箭头的朝向。
@MainActor
final class BlackboardHeaderAffordanceTests: XCTestCase {

    private var window: NSWindow?

    // MARK: - 造计划

    private func plan() -> DailyPlan {
        let specs: [(DailyTask.Kind, Int, String)] = [
            (.conversation, 4, "轮"), (.shadowing, 3, "次"), (.review, 8, "个词"),
        ]
        return DailyPlan(
            day: Date(),
            tasks: specs.enumerated().map { index, spec in
                DailyTask(
                    kind: spec.0, title: "做 \(spec.1) \(spec.2)",
                    reason: index == 0 ? "每日目标 15 分钟，今天还没开口" : "有 \(spec.1) \(spec.2) 到期",
                    target: spec.1, progress: 0, unit: spec.2
                )
            }
        )
    }

    // MARK: - 渲染

    /// 把面板单独挂在舞台顶上（不挂老师：老师的气泡会压在板底，干扰取样）。
    private func renderPanel() throws -> (rep: NSBitmapImageRep, scale: CGFloat) {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let panel = BlackboardPanel(
            theme: theme,
            plan: plan(),
            streakDays: 5,
            dueAtDayStart: 6,
            reviewedOfDue: 2,
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
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        self.window = window
        // 板高是「量出来 → 再定高 + 弹簧」的两趟布局，等它走完再出图（见黑板渲染测试的注释）。
        for _ in 0..<12 {
            host.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
        }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return (rep, CGFloat(rep.pixelsWide) / size.width)
    }

    /// 右上一个字符的范围：板面内容区右端那个按钮。
    ///
    /// 摆位是算出来的，不是试出来的（`BlackboardPanel` 的几何）：
    /// 木框 5pt + 内容内边距 11pt，内容区右边界 = `frameWidth - 5 - 11 = 180`；
    /// 收起按钮宽 16pt，紧贴右边界 → x ∈ [164, 180]；跳转按钮在它左边 6pt 间距外
    /// （x ∈ [140, 158]），所以取样从 160 起就只框到收起按钮。
    private let chevronCrop = CGRect(x: 160, y: 12, width: 24, height: 28)

    /// 一行墨迹的横向跨度（最右 − 最左，单位：像素）。
    private func inkSpan(_ rep: NSBitmapImageRep, row: Int, crop: CGRect, scale: CGFloat) -> Int {
        var left = -1, right = -1
        let x0 = Int(crop.minX * scale), x1 = Int(crop.maxX * scale)
        for x in x0..<min(x1, rep.pixelsWide) {
            guard let c = rep.colorAt(x: x, y: row) else { continue }
            // 粉笔淡灰（白 62% 压在墨绿板上）三通道都很亮；板面 0x2F4A3C 的蓝通道只有 0.24。
            if min(c.redComponent, c.greenComponent, c.blueComponent) > 0.5 {
                if left < 0 { left = x }
                right = x
            }
        }
        return right < 0 ? -1 : right - left
    }

    /// 把一块区域里的墨迹按行取跨度，回报「最上两行 / 最下两行」的跨度。
    ///
    /// ⚠️ 只比较**单行跨度**（不是墨迹总量）：`chevron.down` 是「⌄」——顶上一行是两个
    /// 离得最开的笔端（跨最大）、底下收成一个尖；`chevron.up` 是「^」，正好反过来。
    private func chevronProfile(
        _ rep: NSBitmapImageRep, crop: CGRect, scale: CGFloat
    ) -> (rows: Int, top: Int, bottom: Int) {
        var spans: [(row: Int, span: Int)] = []
        for y in Int(crop.minY * scale)..<min(Int(crop.maxY * scale), rep.pixelsHigh) {
            let span = inkSpan(rep, row: y, crop: crop, scale: scale)
            if span >= 0 { spans.append((y, span)) }
        }
        guard spans.count >= 3 else { return (spans.count, -1, -1) }
        let top = spans.prefix(2).map(\.span).max() ?? -1
        let bottom = spans.suffix(2).map(\.span).max() ?? -1
        return (spans.count, top, bottom)
    }

    // MARK: - ① 度量本身可信：拿两个箭头直接量一遍

    /// 敏感性自检：同一套取样法量**原样的两个符号**，必须一个朝上一个朝下。
    ///
    /// 没有这条，下面那条断言可能只是「随便量到了什么东西」——它证明的是取样法真的
    /// 分得出方向，而不是我在自说自话。
    ///
    /// ⚠️ 背景必须铺**板面墨绿**：浅色底（`0xE9EFE4`）的三通道都过得了「亮」的门槛，
    /// 会被当成粉笔字 —— 取样框里整片都算墨迹，两个箭头量出来一模一样（踩过）。
    func testChevronMetricTellsUpFromDown() throws {
        let probe = CGRect(x: 92, y: 53, width: 16, height: 14)
        func render(_ symbol: String) throws -> (rep: NSBitmapImageRep, scale: CGFloat) {
            let size = NSSize(width: BlackboardPanel.frameWidth, height: 420)
            let host = NSHostingView(rootView: AnyView(
                ZStack(alignment: .topLeading) {
                    BlackboardPalette.board
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(BlackboardPalette.chalkSoft)
                        .frame(width: 16, height: 18)
                        .position(x: probe.midX, y: probe.midY)
                }
                .frame(width: size.width, height: size.height)
            ))
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            self.window = window
            for _ in 0..<8 {
                host.layoutSubtreeIfNeeded()
                window.layoutIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            }
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return (rep, CGFloat(rep.pixelsWide) / size.width)
        }

        let down = try render("chevron.down")
        let up = try render("chevron.up")
        let downProfile = chevronProfile(down.rep, crop: probe, scale: down.scale)
        let upProfile = chevronProfile(up.rep, crop: probe, scale: up.scale)
        print("[箭头] 取样法自检 down=\(downProfile) up=\(upProfile)")

        XCTAssertGreaterThan(downProfile.rows, 2, "没量到 chevron.down 的墨迹")
        XCTAssertGreaterThan(upProfile.rows, 2, "没量到 chevron.up 的墨迹")
        XCTAssertGreaterThan(
            downProfile.top, downProfile.bottom,
            "自检失败：chevron.down 该是「上宽下尖」，实测上 \(downProfile.top) 下 \(downProfile.bottom)"
        )
        XCTAssertGreaterThan(
            upProfile.bottom, upProfile.top,
            "自检失败：chevron.up 该是「上尖下宽」，实测上 \(upProfile.top) 下 \(upProfile.bottom)"
        )
    }

    // MARK: - ② 板上那个收起箭头必须朝下

    /// 收起 = 把板**往下收回去**，箭头就该朝下（用户点名：现在是上三角，反了）。
    func testCollapseChevronPointsDownOnTheBoard() throws {
        let (rep, scale) = try renderPanel()
        let profile = chevronProfile(rep, crop: chevronCrop, scale: scale)
        print("[箭头] 板上收起按钮：行数 \(profile.rows) 上跨度 \(profile.top) 下跨度 \(profile.bottom)")

        XCTAssertGreaterThan(profile.rows, 2, "板右上角没量到箭头墨迹（取样框 \(chevronCrop) 对不上就说明按钮挪位了）")
        XCTAssertLessThan(profile.rows, 40, "取样框里墨迹行太多（\(profile.rows)），多半框进了文字或图标，量化就不准了")
        XCTAssertGreaterThan(
            profile.top, profile.bottom,
            """
            收起箭头朝上了：实测上跨度 \(profile.top) < 下跨度 \(profile.bottom)。
            板是往上长出来的，收起该用「下三角」（`BlackboardPanel.collapseIcon`）。
            """
        )
    }

    // MARK: - ③ 两句提示各说各的事

    /// 提示文案：跳转要说「跳哪儿」，收起要说「收起」，别互相串。
    func testHeaderHelpTextsSayTheirOwnThing() {
        XCTAssertTrue(
            BlackboardPanel.jumpHelp.contains("跳转") && BlackboardPanel.jumpHelp.contains("今日任务"),
            "跳转按钮的提示要说清是跳到「今日任务卡片」，现在是「\(BlackboardPanel.jumpHelp)」"
        )
        XCTAssertFalse(
            BlackboardPanel.jumpHelp.contains("老师"),
            "跳转按钮的提示里不该出现老师介绍 —— 那正是用户报的「弹错提示」"
        )
        XCTAssertEqual(BlackboardPanel.collapseHelp, "收起今日作业")
        XCTAssertEqual(
            BlackboardPanel.collapseIcon, "chevron.down",
            "收起按钮必须是下三角（用户点名要改的那条）"
        )
        XCTAssertNotEqual(
            BlackboardPanel.jumpHelp, BlackboardPanel.collapseHelp,
            "两个按钮挨在一起，提示不能一样"
        )
    }
}
