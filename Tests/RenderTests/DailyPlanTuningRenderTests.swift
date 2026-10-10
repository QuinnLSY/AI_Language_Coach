import AIDomain
import AppCore
@testable import AppUI
import SwiftUI
import XCTest

/// ⑥-A「stance 回灌每日安排」的**离屏渲染**回归。
///
/// 领域层（`DailyPlanTuningTests`）能证明 target 算对了，但看不出三件事：
/// ① 微调理由那行**真的画出来了**；② **没微调时那一行不出现**（`.observing` 是默认档，
/// 每屏都挂一句「今天按你的状态微调过」就是噪声）；③ 日夜两版都清楚。
@MainActor
final class DailyPlanTuningRenderTests: XCTestCase {

    private var window: NSWindow?
    private let cardWidth: CGFloat = 460

    // MARK: - 造数据

    private let calendar = Calendar(identifier: .gregorian)

    /// ⚠️ 到期数要**明显大于**复习 cap（8）：复习目标是 `min(due, cap)`，
    /// 到期数卡在 cap 附近的话，加 cap 的那几档会被 `min` 夹住看不出差别。
    private func makeSnapshot(goalMinutes: Int = 15, dueAtDayStart: Int = 30) -> ProgressSnapshot {
        let now = calendar.date(from: DateComponents(
            year: 2026, month: 10, day: 11, hour: 20, minute: 0
        ))!
        return ProgressSnapshot(
            skills: [],
            today: DailyActivity(
                day: calendar.startOfDay(for: now), seconds: 300, messages: 2, shadowingAttempts: 1
            ),
            vocabulary: VocabularyStats(
                total: 30, due: dueAtDayStart, mastered: 4, defined: 30,
                dueAtDayStart: dueAtDayStart, dueAtDayStartReviewed: 2
            ),
            vocabularyReviewedToday: 2,
            shadowing: ShadowingStats(
                attempts: 12, bestAccuracy: 0.9, averageAccuracy: 0.82, lastAccuracy: 0.85,
                bestPronunciation: 88, averagePronunciation: 78
            ),
            recentMistakes: [],
            goalMinutes: goalMinutes
        )
    }

    private func plan(stance: AdaptivePathStance, goalMinutes: Int = 15, due: Int = 30) -> DailyPlan {
        DailyPlanner.plan(
            snapshot: makeSnapshot(goalMinutes: goalMinutes, dueAtDayStart: due),
            mode: .advanced,
            stance: stance
        )
    }

    // MARK: - 离屏渲染

    private struct Render {
        var rep: NSBitmapImageRep
        var size: CGSize
    }

    /// ⚠️ 冷启动那一次排版缓存没热，同一份输入两次出图能差几百像素 —— 先出一张废图捂热。
    private func render(_ plan: DailyPlan, day: Bool) throws -> Render {
        _ = try? draw(plan, day: day)
        return try draw(plan, day: day)
    }

    private func draw(_ plan: DailyPlan, day: Bool) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: day ? .day : .night, systemIsDark: !day)
        let backdrop: Color = day ? Color(hex: 0xF3F7EF) : Color(hex: 0x101B2E)
        let host = NSHostingView(rootView: AnyView(
            ZStack(alignment: .top) {
                backdrop
                DailyTasksCard(plan: plan)
                    .frame(width: cardWidth)
            }
            .frame(width: cardWidth)
            .forestTheme(theme)
        ))
        host.frame = NSRect(x: 0, y: 0, width: cardWidth, height: 400)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let size = CGSize(width: cardWidth, height: max(1, ceil(host.fittingSize.height)))
        host.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep, size: size)
    }

    private func ink(_ rep: NSBitmapImageRep) -> Int {
        guard let background = rep.colorAt(x: 0, y: 0) else { return 0 }
        var count = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let delta = abs(color.redComponent - background.redComponent)
                    + abs(color.greenComponent - background.greenComponent)
                    + abs(color.blueComponent - background.blueComponent)
                if delta > 0.15 { count += 1 }
            }
        }
        return count
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

    // MARK: - ① 微调的那一行真的画出来了

    /// `.reinforce` 会同时**加**跟读与复习量 → `tuningNote` 非 nil → 卡片要多出那一行。
    /// 判**高度**：理由行追加在任务列表之后，差分会被「按较矮那张裁齐」裁掉（④ 踩过）。
    func testTuningNoteRowIsDrawn() throws {
        let reinforce = try render(plan(stance: .reinforce), day: true)
        let observing = try render(plan(stance: .observing), day: true)
        XCTAssertGreaterThan(reinforce.size.height, observing.size.height + 20,
                             "微调理由必须真的画出来（实测 \(observing.size.height) vs \(reinforce.size.height)）")
        try dump(reinforce.rep, name: "round46-daily-tasks-tuned.png")
    }

    // MARK: - ② 没微调时那一行不出现

    /// `.observing` 是**默认档**（样本不足时的常态）：每屏都挂一句「今天微调过」是噪声。
    func testUntunedPlanHasNoNoteRow() throws {
        XCTAssertNil(plan(stance: .observing).tuningNote, "默认档不该有微调理由")
        XCTAssertNotNil(plan(stance: .reinforce).tuningNote, "真改了量就该说清为什么")
        XCTAssertNotNil(plan(stance: .advance).tuningNote, "进步档也改了量")
    }

    /// 理由必须带**可核对的量**（「加 4 个词」而不是「多留时间给复习」）。
    func testNoteCarriesNumbers() throws {
        for stance in [AdaptivePathStance.reinforce, .consolidate, .advance] {
            let note = try XCTUnwrap(plan(stance: stance).tuningNote, "\(stance) 改了量就该有理由")
            XCTAssertFalse(note.filter(\.isNumber).isEmpty, "\(stance) 的理由必须带数字：「\(note)」")
        }
    }

    /// ⚠️ 文案里的数字必须与**实际生效的 delta 一致**。
    ///
    /// 这条是被真 bug 逼出来的：曾把 `reviewCapDelta` 错接到 `reinforceReviewBonus`（8），
    /// 而真正的 cap 增量是 4 —— 上限被抬到 16，文案还写着「加 4 个词」。
    /// **数字对不上比不说数字更糟**：用户会照着文案安排复习，然后发现少复习了 8 个。
    func testNoteNumbersMatchTheDeltasActuallyApplied() throws {
        for stance in [AdaptivePathStance.reinforce, .consolidate, .advance] {
            let tuning = DailyPlanTuningRule.tuning(for: stance)
            let note = try XCTUnwrap(tuning.note)
            // 复习上限：文案里的数字必须等于真正用上的 reviewCapDelta。
            if tuning.reviewCapDelta != 0 {
                let cap = abs(tuning.reviewCapDelta)
                XCTAssertTrue(note.contains("\(cap) 个词"),
                              "\(stance)：复习上限实际 \(tuning.reviewCapDelta)，文案却是「\(note)」")
            }
            // 新量：文案里出现的轮数/句数必须与 delta 的绝对值一致。
            let conversation = abs(tuning.conversationDelta)
            if conversation > 0 {
                XCTAssertTrue(note.contains("\(conversation) 轮"),
                              "\(stance)：对话实际 \(tuning.conversationDelta)，文案却是「\(note)」")
            }
            let shadowing = abs(tuning.shadowingDelta)
            if shadowing > 0 {
                XCTAssertTrue(note.contains("\(shadowing) 句"),
                              "\(stance)：跟读实际 \(tuning.shadowingDelta)，文案却是「\(note)」")
            }
        }
    }

    // MARK: - ③ 日夜两版

    func testRendersInBothThemes() throws {
        let day = try render(plan(stance: .reinforce), day: true)
        let night = try render(plan(stance: .reinforce), day: false)
        XCTAssertGreaterThan(ink(day.rep), 300, "日间版应有内容")
        XCTAssertGreaterThan(ink(night.rep), 300, "夜间版应有内容")

        func luma(_ rep: NSBitmapImageRep) throws -> CGFloat {
            let color = try XCTUnwrap(rep.colorAt(x: 0, y: 0))
            return color.redComponent * 0.3 + color.greenComponent * 0.6 + color.blueComponent * 0.1
        }
        XCTAssertGreaterThan(try luma(day.rep), 0.5, "日间底色应偏亮")
        XCTAssertLessThan(try luma(night.rep), 0.3, "夜间底色应偏暗")
        try dump(day.rep, name: "round46-daily-tasks-day.png")
        try dump(night.rep, name: "round46-daily-tasks-night.png")
    }
}