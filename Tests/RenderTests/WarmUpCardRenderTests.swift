import AIDomain
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// ⑦-B② 碎片热身卡的**离屏渲染**回归。
///
/// 钉的是三张脸各自真的画得出来、且各不相同：
/// - **没得练就不占地方**：空计划渲染出来必须是一张干净的图；
/// - **入口卡画得出构成与预估**；
/// - **流程卡比入口卡多一块**（多出「第 N / M 步」与两颗判分键）；
/// - **结算卡与流程卡不同**（换了一整块内容，不是同一张卡换行字）。
///
/// ⚠️ 不比色值：离屏渲染会过一次色彩空间转换（同一条教训，见 `KickoffRowRenderTests`）。
/// ⚠️ `.help` 与合成点击测不了（技能 `macos-ui-verify` 的「测不了三样」）。
@MainActor
final class WarmUpCardRenderTests: XCTestCase {

    private var window: NSWindow?
    private let canvas = CGSize(width: 440, height: 360)

    private struct Render {
        var rep: NSBitmapImageRep
        var scale: CGFloat
    }

    // MARK: - ① 没得练就不占地方

    func testNothingToDoDrawsNothing() throws {
        let empty = try render(plan: nil, progress: nil)
        let again = try render(plan: nil, progress: nil)
        XCTAssertLessThan(ink(empty), 40, "没有依据时不该留出任何装饰：实测 \(ink(empty)) 像素墨迹")
        XCTAssertLessThan(abs(ink(empty) - ink(again)), 20, "同一份空输入两次渲染应当完全一致")
    }

    func testEmptyPlanDrawsNothing() throws {
        let empty = try render(plan: WarmUpPlan(steps: []), progress: nil)
        XCTAssertLessThan(ink(empty), 40, "空计划同样不占地方（入口卡判空用的是 isEmpty）")
    }

    // MARK: - ② 入口卡

    func testEntryCardDrawsCompositionAndEstimate() throws {
        let entry = try render(plan: Self.plan, progress: nil)
        XCTAssertGreaterThan(ink(entry), 600, "入口卡至少要画得出来：实测 \(ink(entry))")
        try dump(entry, name: "round38-warmup-entry.png")
    }

    /// 窄聊天区（`chatMinWidth` = 340）里卡片不许溢出：与 `KickoffRow` 同一条纪律，
    /// 两摞卡在空态里对齐，窄容器里必须一起收起来。
    ///
    /// 反证：把 `WarmUpCard` 里的 `.frame(maxWidth:)` 改回定宽 `.frame(width:)`
    /// → 卡探出 340 的提案宽，右侧留白条上出现卡面底色，这条红。
    func testNarrowContainerDoesNotOverflow() throws {
        let narrow = try render(plan: Self.plan, progress: nil, proposalWidth: AppLayoutMetrics.chatMinWidth)
        XCTAssertEqual(
            stripInk(narrow, from: 350, to: canvas.width - 5), 0,
            "提案宽只有 \(AppLayoutMetrics.chatMinWidth) 时，350pt 以右必须是留白 —— 卡片探出来了"
        )
    }

    /// 步骤多一轮，卡上的字就换一截 —— 构成文案与预估都是插出来的，不是写死的一句。
    ///
    /// ⚠️ 这里**不能比墨迹**：`ink` 量的是「覆盖面积」，而这两张卡的卡面一样大，
    /// 换掉的字都在卡面之内（实测两张的墨迹都是 18188，一分不差）。
    /// 同一张卡里换字，只有逐像素差分看得见。
    func testRicherPlanChangesTheCopy() throws {
        let small = try render(plan: WarmUpPlan(steps: [.word(entryID: UUID(), word: "resilient")]), progress: nil)
        let full = try render(plan: Self.plan, progress: nil)
        XCTAssertGreaterThan(
            difference(small, full), 400,
            "「3 个到期词 · 1 句跟读 · 1 句开口」与「1 个到期词」必须画出不同的字：实测差 \(difference(small, full)) 像素"
        )
        try dump(small, name: "round38-warmup-entry-one-word.png")
    }

    // MARK: - ③ 流程卡 / 结算卡

    func testRunningCardDrawsMoreThanEntry() throws {
        let entry = try render(plan: Self.plan, progress: nil)
        let running = try render(plan: Self.plan, progress: Self.running)
        XCTAssertGreaterThan(
            ink(running), Int(Double(ink(entry)) * 1.15),
            "流程卡多出「第 N / M 步」与判分键：实测 \(ink(running)) vs \(ink(entry))"
        )
        try dump(running, name: "round38-warmup-running.png")
    }

    func testSettlementDiffersFromRunning() throws {
        let running = try render(plan: Self.plan, progress: Self.running)
        let done = try render(plan: Self.plan, progress: Self.settled)
        let changed = difference(running, done)
        XCTAssertGreaterThan(changed, 300, "结算卡换的是一整块内容，不是同一张卡换行字：实测差 \(changed) 像素")
        try dump(done, name: "round38-warmup-settlement.png")
    }

    /// 结算卡上的「记得 2/3 · 用时 1 分 12 秒」是插出来的真数字：
    /// 换一轮（1/1）就得换一行字。
    func testDifferentSummariesDrawDifferently() throws {
        let twoOfThree = try render(plan: Self.plan, progress: Self.settled)
        var other = WarmUpProgress(plan: Self.plan, now: Self.start)
        _ = other.gradeCurrentWord(remembered: true)
        _ = other.skipCurrent()
        _ = other.skipCurrent()
        other.finish(now: Self.start.addingTimeInterval(30))
        let oneOfThree = try render(plan: Self.plan, progress: other)
        XCTAssertGreaterThan(
            difference(twoOfThree, oneOfThree), 120,
            "两轮成绩不同，卡上那行字必须跟着变"
        )
    }

    // MARK: - 渲染与度量

    private func render(
        plan: WarmUpPlan?,
        progress: WarmUpProgress?,
        notice: AppNotice? = nil,
        stepScore: Double? = nil,
        heardText: String? = nil,
        proposalWidth: CGFloat? = nil
    ) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let inner = proposalWidth ?? (canvas.width - 40)
        let host = NSHostingView(rootView: AnyView(
            WarmUpCard(
                plan: plan,
                progress: progress,
                notice: notice,
                stepScore: stepScore,
                heardText: heardText,
                onStart: {}, onGrade: { _ in }, onPlaySentence: {},
                onToggleRecording: {}, onContinue: {}, onSkip: {},
                onSendSpoken: {}, onDismiss: {}, onDismissNotice: {}
            )
            .frame(width: inner, alignment: .topLeading)
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
            // 与 MainView 根上那一行一致：按压反馈是外部注入的，组件自己不写样式。
            .buttonStyle(.appPressable)
            .forestTheme(theme)
        ))
        host.frame = NSRect(origin: .zero, size: canvas)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep, scale: CGFloat(rep.pixelsHigh) / max(canvas.height, 1))
    }

    /// 两张图逐像素的差异数（`ink` 只对「多了东西」敏感，这张专量「换了内容」）。
    private func difference(_ a: Render, _ b: Render) -> Int {
        let height = min(a.rep.pixelsHigh, b.rep.pixelsHigh)
        let width = min(a.rep.pixelsWide, b.rep.pixelsWide)
        var count = 0
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                guard let left = a.rep.colorAt(x: x, y: y), let right = b.rep.colorAt(x: x, y: y) else { continue }
                let delta = abs(left.redComponent - right.redComponent)
                    + abs(left.greenComponent - right.greenComponent)
                    + abs(left.blueComponent - right.blueComponent)
                if delta > 0.08 { count += 1 }
            }
        }
        return count
    }

    /// 全图「与底色不同」的像素数（背景取左上角，那里永远是留白）。
    private func ink(_ render: Render) -> Int {
        let rep = render.rep
        guard let background = rep.colorAt(x: 1, y: 1) else { return 0 }
        var count = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let delta = abs(color.redComponent - background.redComponent)
                    + abs(color.greenComponent - background.greenComponent)
                    + abs(color.blueComponent - background.blueComponent)
                if delta > 0.08 { count += 1 }
            }
        }
        return count
    }

    /// 只数某一条竖带（pt 区间）里的「与底色不同」的像素数 ——
    /// `testNarrowContainerDoesNotOverflow` 专用：卡探出提案宽时会在右侧留白带上
    /// 留下卡面底色，整图墨迹度量对这点宽度不敏感，竖带一量就露出来。
    private func stripInk(_ render: Render, from fromPt: CGFloat, to toPt: CGFloat) -> Int {
        let rep = render.rep
        guard let background = rep.colorAt(x: 1, y: 1) else { return 0 }
        let scale = render.scale
        let from = Int((fromPt * scale).rounded())
        let to = min(Int((toPt * scale).rounded()), rep.pixelsWide - 1)
        var count = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: from, to: to, by: 2) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let delta = abs(color.redComponent - background.redComponent)
                    + abs(color.greenComponent - background.greenComponent)
                    + abs(color.blueComponent - background.blueComponent)
                if delta > 0.08 { count += 1 }
            }
        }
        return count
    }

    private func dump(_ render: Render, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(render.rep.representation(using: .png, properties: [:]), "PNG 编码失败")
        try png.write(to: directory.appendingPathComponent(name))
    }

    // MARK: - 工装

    private static let start = Date(timeIntervalSince1970: 1_700_000_000)

    private static let plan = WarmUpPlan(steps: [
        .word(entryID: UUID(), word: "resilient"),
        .word(entryID: UUID(), word: "fragile"),
        .word(entryID: UUID(), word: "lucid"),
        .shadow(sentence: "Practice makes progress."),
        .speak(prompt: "How was your day?")
    ])

    /// 走到第 1 步（认词）的那一轮。
    private static var running: WarmUpProgress {
        WarmUpProgress(plan: plan, now: start)
    }

    /// 走完：记得 2/3，用时 1 分 12 秒，跟读 82 分，开口一句。
    private static var settled: WarmUpProgress {
        var progress = WarmUpProgress(plan: plan, now: start)
        _ = progress.gradeCurrentWord(remembered: true)
        _ = progress.gradeCurrentWord(remembered: true)
        _ = progress.gradeCurrentWord(remembered: false)
        _ = progress.markShadow(score: 82.4)
        _ = progress.markSpoken("I had a good day.")
        progress.finish(now: start.addingTimeInterval(72))
        return progress
    }
}
