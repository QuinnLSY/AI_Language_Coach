import AIDomain
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// ⑦-D 今日战绩海报的**离屏渲染**回归。
///
/// 这张卡既要摆在进度页里看、也要离屏渲染成 PNG（`ReportExporter.dailyPosterPNG`），
/// 所以这里钉的是「画得出来」与「数字换了图就换」两件事。
///
/// ⚠️ `ink` 量的是覆盖面积不是字：同一张卡里换字它一分不差（实测见 `WarmUpCardRenderTests`），
/// 因此**换内容一律用逐像素 `difference`**。
/// ⚠️ `.help` 与合成点击测不了（技能 `macos-ui-verify` 的「测不了三样」）。
@MainActor
final class DailyPosterCardRenderTests: XCTestCase {

    private var window: NSWindow?
    private let canvas = CGSize(width: 700, height: 420)

    private struct Render {
        var rep: NSBitmapImageRep
    }

    // MARK: - ① 画得出来

    func testPosterCardDrawsEverything() throws {
        let rich = try render(Self.rich)
        XCTAssertGreaterThan(ink(rich), 1500, "海报至少要画得出来：实测 \(ink(rich))")
        try dump(rich, name: "round41-poster-rich.png")
    }

    /// 只练了一件事的海报（一行数据）：也要画得出来，不能因为行数少就塌掉。
    func testOneMetricStillDraws() throws {
        let one = try render(Self.oneMetric)
        XCTAssertGreaterThan(ink(one), 900, "一行数据也要占得住版面：实测 \(ink(one))")
        try dump(one, name: "round41-poster-one.png")
    }

    // MARK: - ② 数字换了图就换

    func testDifferentNumbersDrawDifferently() throws {
        let one = try render(Self.oneMetric)
        let rich = try render(Self.rich)
        XCTAssertGreaterThan(
            difference(one, rich), 400,
            "「今天练了 12 分 30 秒」与「今天复习 6 个词」必须画出不同的字：实测差 \(difference(one, rich)) 像素"
        )
    }

    /// 连续天数那行**只在有连胜时**出现（0 天不该替用户承认断签）。
    func testSubheadAppearsOnlyWithAStreak() throws {
        let withStreak = try render(Self.rich)
        let noStreak = try render(Self.noStreak)
        XCTAssertGreaterThan(
            difference(withStreak, noStreak), 60,
            "「连续练习 5 天」那颗胶囊必须真的画出来（阈值给得小：它只是卡里的一小块）"
        )
        try dump(noStreak, name: "round41-poster-no-streak.png")
    }

    /// 收尾那句话跟着达标与否变。
    func testClosingChangesWithTheGoal() throws {
        let reached = try render(Self.rich)
        let missed = try render(Self.goalMissed)
        XCTAssertGreaterThan(difference(reached, missed), 30, "收尾那句话是插出来的，不是写死的一句")
    }

    // MARK: - 渲染

    private func render(_ poster: DailyPoster) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let host = NSHostingView(rootView: AnyView(
            DailyPosterCard(poster: poster)
                .frame(width: canvas.width - 40, alignment: .topLeading)
                .frame(width: canvas.width, height: canvas.height, alignment: .top)
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
        return Render(rep: rep)
    }

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

    private func dump(_ render: Render, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(render.rep.representation(using: .png, properties: [:]), "PNG 编码失败")
        try png.write(to: directory.appendingPathComponent(name))
    }

    // MARK: - 工装

    private static var day: Date { Date(timeIntervalSince1970: 1_700_000_000) }

    /// 练了 12 分半、四行数据、连续 5 天（目标已达成）。
    private static var rich: DailyPoster {
        poster(
            DailyActivity(day: day, seconds: 750, messages: 8, shadowingAttempts: 5,
                          vocabularyAdded: 3, vocabularyReviewed: 6),
            streakDays: 5, goalMinutes: 10, goalReached: true
        )
    }

    /// 只复习了 6 个词（不足一分钟 → headline 说做了什么）。
    private static var oneMetric: DailyPoster {
        poster(DailyActivity(day: day, vocabularyReviewed: 6), streakDays: 1)
    }

    /// 与 `rich` 唯一的区别：连续 0 天（副标那颗胶囊不该出现）。
    private static var noStreak: DailyPoster {
        poster(
            DailyActivity(day: day, seconds: 750, messages: 8, shadowingAttempts: 5,
                          vocabularyAdded: 3, vocabularyReviewed: 6),
            streakDays: 0, goalMinutes: 10, goalReached: true
        )
    }

    /// 与 `rich` 唯一的区别：目标没达成。
    private static var goalMissed: DailyPoster {
        poster(
            DailyActivity(day: day, seconds: 750, messages: 8, shadowingAttempts: 5,
                          vocabularyAdded: 3, vocabularyReviewed: 6),
            streakDays: 5, goalMinutes: 30, goalReached: false
        )
    }

    private static func poster(
        _ activity: DailyActivity,
        streakDays: Int = 1,
        goalMinutes: Int = 10,
        goalReached: Bool = false
    ) -> DailyPoster {
        // 这些入参都保证有练习记录，`make` 一定给得出海报。
        DailyPoster.make(
            date: day, activity: activity,
            streakDays: streakDays, goalMinutes: goalMinutes, goalReached: goalReached
        )!
    }
}
