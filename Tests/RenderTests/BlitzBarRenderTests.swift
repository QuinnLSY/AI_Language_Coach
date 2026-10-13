import AIDomain
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// ⑦-C① 连击条的**离屏渲染**回归。
///
/// 钉两件事：跑着的那副脸（倒计时条 + 连击）画得出来、到点那副脸（成绩 + 再来一轮）也画得出来，
/// 且两副脸**画的不一样**（不是同一块牌子换了个透明度）。
///
/// ⚠️ `ink` 量的是覆盖面积不是字：两副脸版面差不多大，换字它一分不差
/// → 一律用逐像素 `difference`。
/// ⚠️ 更要紧的一层：这个组件**自己带底色**，于是卡面上每一点都算墨迹 ——
/// 这里的 `ink` 基本只等于卡的面积（实测见 `AchievementWallCardRenderTests`），
/// 断言它只是证明「卡在」，内容的差异一律看 `difference`。
@MainActor
final class BlitzBarRenderTests: XCTestCase {

    private var window: NSWindow?
    private let canvas = CGSize(width: 420, height: 150)

    private struct Render {
        var rep: NSBitmapImageRep
    }

    // MARK: - ① 画得出来

    func testRunningBarDrawsTheCountdownAndTheCombo() throws {
        let shot = try render(Self.running)
        XCTAssertGreaterThan(ink(shot), 150, "跑着那副脸至少要画得出来：实测 \(ink(shot))")
        try dump(shot, name: "round42-blitz-running.png")
    }

    func testSettledBarDrawsTheResultAndTheRestart() throws {
        let shot = try render(Self.settled)
        XCTAssertGreaterThan(ink(shot), 150, "到点那副脸至少要画得出来：实测 \(ink(shot))")
        try dump(shot, name: "round42-blitz-settled.png")
    }

    // MARK: - ② 两副脸不一样

    func testSettledFaceDiffersFromRunning() throws {
        let running = try render(Self.running)
        let settled = try render(Self.settled)
        XCTAssertGreaterThan(
            difference(running, settled), 150,
            "到点之后是另一副脸（成绩 + 再来一轮），不是同一块牌子：实测差 \(difference(running, settled)) 像素"
        )
    }

    /// 倒计时是**画出来的**：还剩 42 秒和还剩 9 秒必须不一样。
    func testCountdownIsReallyDrawn() throws {
        let early = try render(Self.running)
        let late = try render(Self.almostUp)
        XCTAssertGreaterThan(difference(early, late), 60, "时间条越走越短，这两张该不一样")
    }

    /// 破纪录那枚徽章：撤掉它就该少一块（反证点）。
    func testNewRecordBadgeDrawsSomething() throws {
        let with = try render(Self.settled)
        let without = try render(Self.settledWithoutRecord)
        XCTAssertGreaterThan(difference(with, without), 40, "「新纪录」那枚徽章要真的画出来")
    }

    // MARK: - 渲染

    private func render(_ input: Input) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let host = NSHostingView(rootView: AnyView(
            BlitzBar(
                blitz: input.blitz,
                remaining: input.remaining,
                record: input.record,
                isNewRecord: input.isNewRecord,
                onRestart: {}
            )
            .frame(width: canvas.width - 30, alignment: .topLeading)
            .frame(width: canvas.width, height: canvas.height, alignment: .top)
            // 与所在页面根上那一行一致：按压反馈是外部注入的，组件自己不写样式。
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

    private struct Input {
        var blitz: ReviewBlitz
        var remaining: Int
        var record: Int
        var isNewRecord: Bool
    }

    private static let start = Date(timeIntervalSince1970: 1_700_000_000)

    private static func blitz(remembered: Int, forgotten: Int) -> ReviewBlitz {
        var b = ReviewBlitz(startedAt: start)
        for _ in 0..<remembered { _ = b.grade(remembered: true, now: start.addingTimeInterval(1)) }
        for _ in 0..<forgotten { _ = b.grade(remembered: false, now: start.addingTimeInterval(2)) }
        return b
    }

    /// 跑着：还剩 42 秒、连对 3 个。
    private static var running: Input {
        Input(blitz: blitz(remembered: 3, forgotten: 0), remaining: 42, record: 5, isNewRecord: false)
    }

    /// 同一轮，只是时间快到了（时间条该短一截）。
    private static var almostUp: Input {
        Input(blitz: blitz(remembered: 3, forgotten: 0), remaining: 9, record: 5, isNewRecord: false)
    }

    /// 到点了：成绩 + 新纪录 + 再来一轮。
    private static var settled: Input {
        Input(blitz: blitz(remembered: 6, forgotten: 2), remaining: 0, record: 6, isNewRecord: true)
    }

    /// 与 `settled` 唯一的区别：没破纪录（那枚徽章不该出现）。
    private static var settledWithoutRecord: Input {
        Input(blitz: blitz(remembered: 6, forgotten: 2), remaining: 0, record: 6, isNewRecord: false)
    }
}
