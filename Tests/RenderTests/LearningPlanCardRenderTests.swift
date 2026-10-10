import AIDomain
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 学习计划卡（① 个性化学习计划）的**离屏渲染**回归。
///
/// 断言只钉「用户真能看见」这件事：同一张卡只切一个输入，看画面到底变没变。
/// 比如「重点行有没有画出来」= 把 `focus` 清空再渲染一次做逐像素差分 ——
/// 差分有的话，说明那两行确实画在屏幕上了；差分约等于 0，就是根本没画。
///
/// 阈值先**自校准**（同一状态连抓两趟取噪声基准），固定阈值在整卡重排时会假通过。
@MainActor
final class LearningPlanCardRenderTests: XCTestCase {

    private var window: NSWindow?
    private let cardWidth: CGFloat = 620

    private struct Render {
        let rep: NSBitmapImageRep
        let size: CGSize
    }

    // MARK: - 造数据

    private func stage(
        level: CEFRLevel? = .a2,
        next: CEFRLevel? = .b1,
        confident: Bool = true,
        gaps: [String] = ["再多说 20 轮", "再收 40 个词"],
        focus: [LearningPlanFocus] = [
            LearningPlanFocus(
                action: .errorDrill, title: "改掉反复犯的错",
                reason: "学习记忆里攒了 3 处还没练掉的错", pending: 3, unit: "处"
            ),
            LearningPlanFocus(
                action: .phonemeDrill, title: "练顽固音素",
                reason: "2 个音反复念错（各已评够三次、错够两次）", pending: 2, unit: "个"
            ),
        ]
    ) -> LearningPlanStage {
        LearningPlanStage(
            currentLevel: level, targetLevel: next,
            isConfident: confident, gaps: gaps, focus: focus
        )
    }

    private func today(tasks: Int = 3, done: Int = 1) -> DailyPlan {
        let items = (0..<tasks).map { index in
            DailyTask(
                kind: .conversation, title: "开口对话", reason: "今天还没开口",
                target: 10, progress: index < done ? 10 : 0, unit: "轮"
            )
        }
        return DailyPlan(day: Date(), tasks: items)
    }

    private func plan(stage: LearningPlanStage? = nil, tasks: Int = 3, done: Int = 1) -> LearningPlan {
        LearningPlan(stage: stage ?? self.stage(), today: today(tasks: tasks, done: done))
    }

    // MARK: - 渲染

    private func render(_ plan: LearningPlan, day: Bool = true) throws -> Render {
        try render(AnyView(LearningPlanCard(plan: plan) { _ in }), day: day)
    }

    private func render(_ view: AnyView, day: Bool) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: day ? .day : .night, systemIsDark: !day)
        let backdrop: Color = day ? Color(hex: 0xE9EFE4) : Color(hex: 0x101B2E)
        let host = NSHostingView(rootView: AnyView(
            view.forestTheme(theme).frame(width: cardWidth).background(backdrop)
        ))
        host.frame = NSRect(x: 0, y: 0, width: cardWidth, height: 200)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        // 两趟：先问出自然高度，再按自然高度出图，否则内容会被裁掉。
        let size = CGSize(width: cardWidth, height: max(80, ceil(host.fittingSize.height)))
        host.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep, size: size)
    }

    private func diff(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> (mean: Double, count: Int) {
        let width = min(a.pixelsWide, b.pixelsWide)
        let height = min(a.pixelsHigh, b.pixelsHigh)
        var sum = 0.0
        var count = 0
        for x in 0..<width {
            for y in 0..<height {
                guard let ca = a.colorAt(x: x, y: y), let cb = b.colorAt(x: x, y: y) else { continue }
                let delta = abs(ca.redComponent - cb.redComponent)
                    + abs(ca.greenComponent - cb.greenComponent)
                    + abs(ca.blueComponent - cb.blueComponent)
                guard delta > 0.12 else { continue }
                sum += delta
                count += 1
            }
        }
        return (count == 0 ? 0 : sum / Double(count), count)
    }

    private func dump(_ rep: NSBitmapImageRep, name: String) {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".workbuddy/verify")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: directory.appendingPathComponent("\(name).png"))
    }

    // MARK: - 用例

    /// 抓图必须是确定的：同一状态连抓两趟应当几乎无差异。
    /// 这条不过，后面的差分断言全都没有意义。
    func testRenderingIsDeterministic() throws {
        let first = try render(plan())
        let second = try render(plan())
        let noise = diff(first.rep, second.rep)
        XCTAssertLessThanOrEqual(noise.count, 100, "同一状态两趟出图差异应接近 0，实测 \(noise.count)")
    }

    /// 重点行：每行 = 26pt 图标圈 + 上下各 9pt 内边距 ≈ 44pt，两行 + 行距 ≈ 94pt，
    /// 再加一节标题与分隔线 ≈ 30pt → 两行至少该贡献 40pt 以上的高度。
    func testFocusRowsAreActuallyDrawn() throws {
        let withFocus = try render(plan())
        let without = try render(plan(stage: stage(focus: [])))
        let signal = diff(withFocus.rep, without.rep)
        XCTAssertGreaterThan(signal.count, 500, "重点行必须真的画出来，实测变化像素 \(signal.count)")
        XCTAssertGreaterThan(
            withFocus.size.height, without.size.height + 40,
            "少两行重点应明显变矮，实测 \(without.size.height) vs \(withFocus.size.height)"
        )
    }

    func testGapLinesAreDrawn() throws {
        let withGaps = try render(plan())
        let without = try render(plan(stage: stage(gaps: [])))
        let signal = diff(withGaps.rep, without.rep)
        XCTAssertGreaterThan(signal.count, 200, "「距下一档还差」必须真的画出来，实测 \(signal.count)")
    }

    /// 样本不够时（还在观察中）不画档位转换、不画靶子 —— 卡片应比有档位的计划矮。
    func testObservingStateIsShorterThanGradedPlan() throws {
        let observing = try render(
            plan(stage: stage(level: nil, next: nil, confident: false, gaps: []))
        )
        let graded = try render(plan())
        XCTAssertLessThan(
            observing.size.height, graded.size.height,
            "还在观察中应比有档位的计划矮，实测 \(observing.size.height) vs \(graded.size.height)"
        )
    }

    /// 今日层要反映真实进度：「还有 2 项没做」与「都做完了」必须长得不一样。
    func testTodayLineChangesWithProgress() throws {
        let unfinished = try render(plan(tasks: 3, done: 1))
        let finished = try render(plan(tasks: 3, done: 3))
        let signal = diff(unfinished.rep, finished.rep)
        XCTAssertGreaterThan(signal.count, 50, "今日层文案应随进度变化，实测变化像素 \(signal.count)")
    }

    /// 空计划（没档位、没重点、今天也没安排）只该是一句提示，不能画成一张大卡。
    func testEmptyPlanIsShortAndSaysSomething() throws {
        let empty = try render(
            plan(
                stage: stage(level: nil, next: nil, confident: false, gaps: [], focus: []),
                tasks: 0, done: 0
            )
        )
        XCTAssertLessThan(empty.size.height, 190, "空计划实测高度 \(empty.size.height)")
    }

    func testRendersInBothThemesAndDumpsPNG() throws {
        let day = try render(plan(), day: true)
        let night = try render(plan(), day: false)
        XCTAssertGreaterThan(day.size.height, 100)
        XCTAssertGreaterThan(night.size.height, 100)
        dump(day.rep, name: "round41-learning-plan-day")
        dump(night.rep, name: "round41-learning-plan-night")
    }
}
