import AIDomain
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// ⑦-C② 成就墙的**离屏渲染**回归。
///
/// 钉的是「墙上那几格画得出来」与「达成 / 未达成是两种画法」。
///
/// ⚠️ `ink` 量的是覆盖面积不是字：格数一样时换字它一分不差 → 一律用逐像素 `difference`。
/// ⚠️ 更硬的一条实测：这个组件自己带底色，`ink` 于是在四档进度下**完全相同**（都是 80323
/// = 卡的面积）—— 带底色组件上的 `ink` 只证明「卡在」，别拿它当内容判据。
@MainActor
final class AchievementWallCardRenderTests: XCTestCase {

    private var window: NSWindow?
    private let canvas = CGSize(width: 700, height: 420)

    private struct Render {
        var rep: NSBitmapImageRep
    }

    // MARK: - ① 画得出来

    func testWallDrawsItsTiles() throws {
        let shot = try render(items: Self.mixed, headline: Self.headline)
        XCTAssertGreaterThan(ink(shot), 900, "成就墙至少要画得出来：实测 \(ink(shot))")
        try dump(shot, name: "round42-wall-mixed.png")
    }

    /// 一条都没达成（新用户）：只摆最接近的三条，也不能塌成一张空卡。
    func testWallStillDrawsWhenNothingIsUnlocked() throws {
        let shot = try render(items: Self.allLocked, headline: "0/9 项已解锁 · 下一个 开口 50 句，还差 50 句")
        XCTAssertGreaterThan(ink(shot), 700, "全灰的墙也要画得出来：实测 \(ink(shot))")
        try dump(shot, name: "round42-wall-locked.png")
    }

    // MARK: - ② 达成与未达成是两种画法

    /// 同一条成就，达成前后必须画得不一样（勾 / 底色 / 「还差 N」→「已达成」）。
    func testUnlockedTileLooksDifferentFromLocked() throws {
        let locked = try render(items: Self.allLocked, headline: Self.headline)
        let unlocked = try render(items: Self.allUnlocked, headline: Self.headline)
        XCTAssertGreaterThan(
            difference(locked, unlocked), 300,
            "亮着的格子和灰着的格子必须是两种画法：实测差 \(difference(locked, unlocked)) 像素"
        )
        try dump(unlocked, name: "round42-wall-unlocked.png")
    }

    /// 「还差 N」是插出来的真值：差 12 句和差 2 句画出来不一样。
    func testRemainingIsInterpolatedNotHardcoded() throws {
        let a = try render(items: Self.almostThere(12), headline: Self.headline)
        let b = try render(items: Self.almostThere(2), headline: Self.headline)
        XCTAssertGreaterThan(difference(a, b), 25, "差多少要跟着数字变（阈值小：它只是格子里的一行）")
    }

    /// **进度条真的按比例画**：差 1 句（98%）那几条比差 45 句（10%）那几条长得多。
    ///
    /// ⚠️ 这里只能用 `difference`，**不能用 `ink`**：这个组件自己带底色，
    /// 于是「每一点卡面」都算墨迹 —— 实测四档进度（0 / 0.25 / 0.5 / 0.98）的 `ink`
    /// **一模一样都是 80323**（等于卡的面积）。差分才量得到条本身。
    /// 反证：把 `item.progress` 从宽度里撤掉（写死满格），这条必红。
    func testProgressBarLengthFollowsTheNumber() throws {
        let almostDone = try render(items: Self.almostThere(1), headline: Self.headline)
        let justStarted = try render(items: Self.almostThere(45), headline: Self.headline)
        XCTAssertGreaterThan(
            difference(almostDone, justStarted), 250,
            "进度条要按 current/target 画：实测差 \(difference(almostDone, justStarted)) 像素"
        )
    }

    // MARK: - 渲染

    private func render(items: [Achievement], headline: String) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let host = NSHostingView(rootView: AnyView(
            AchievementWallCard(headline: headline, items: items)
                .frame(width: canvas.width - 40, alignment: .topLeading)
                .frame(width: canvas.width, height: canvas.height, alignment: .top)
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

    private static let headline = "3/9 项已解锁 · 下一个 开口 500 句，还差 380 句"

    /// 三条已达成 + 三条最接近的（墙上真实的样子）。
    private static var mixed: [Achievement] {
        [
            Achievement(id: "talk.50", title: "开口 50 句", unit: "句", current: 80, target: 50),
            Achievement(id: "time.60", title: "练满 1 小时", unit: "分钟", current: 73, target: 60),
            Achievement(id: "mastered.30", title: "掌握 30 个词", unit: "个词", current: 31, target: 30),
            Achievement(id: "talk.500", title: "开口 500 句", unit: "句", current: 120, target: 500),
            Achievement(id: "shadow.50", title: "跟读 50 次", unit: "次", current: 21, target: 50),
            Achievement(id: "star.30", title: "拿到 30 颗星", unit: "颗星", current: 4, target: 30)
        ]
    }

    private static var allLocked: [Achievement] {
        mixed.map { Achievement(id: $0.id, title: $0.title, unit: $0.unit, current: 0, target: $0.target) }
    }

    private static var allUnlocked: [Achievement] {
        mixed.map { Achievement(id: $0.id, title: $0.title, unit: $0.unit,
                                current: $0.target, target: $0.target) }
    }

    /// 只差 `remaining` 的那两条（同一个格数，只换「还差 N」里的数字）。
    private static func almostThere(_ remaining: Int) -> [Achievement] {
        [
            Achievement(id: "talk.50", title: "开口 50 句", unit: "句",
                        current: 50 - remaining, target: 50),
            Achievement(id: "talk.500", title: "开口 500 句", unit: "句",
                        current: 500 - remaining, target: 500),
            Achievement(id: "shadow.50", title: "跟读 50 次", unit: "次",
                        current: 50 - remaining, target: 50)
        ]
    }
}
