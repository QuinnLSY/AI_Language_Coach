import AIDomain
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// ⑦-C③ 森林解锁预告的**离屏渲染**回归。
///
/// 钉的是「一排伙伴画得出来」与「满员 / 未满员是两种画法」。
///
/// ⚠️ 卡里有小动物：`.repeatForever` 的跳动与眨眼会让画面**永不静止**，
/// 逐像素对比必须先把 `CuteAnimalView.animationsEnabled` 关掉（同 `BubbleActionsRenderTests`）。
/// ⚠️ `ink` 在这类**自带底色**的组件上基本等于卡的面积（实测见 `AchievementWallCardRenderTests`）
/// → 它只证明「卡在」，内容差异一律看 `difference`。
@MainActor
final class ForestUnlockCardRenderTests: XCTestCase {

    private var window: NSWindow?
    private let canvas = CGSize(width: 700, height: 300)

    private struct Render {
        var rep: NSBitmapImageRep
    }

    // MARK: - ① 画得出来

    func testCardDrawsTheLineup() throws {
        let shot = try render(companions: 4, hasNext: true, preview: "再练 18 分钟，林子里多一位伙伴")
        XCTAssertGreaterThan(ink(shot), 700, "一排伙伴至少要画得出来：实测 \(ink(shot))")
        try dump(shot, name: "round42-forest-four.png")
    }

    // MARK: - ② 满员 / 未满员是两种画法

    /// 4 位 + 一个虚位 vs 8 位满员：画出来必须不一样（位子数不一样、预告那句也不一样）。
    func testFullForestLooksDifferent() throws {
        let half = try render(companions: 4, hasNext: true, preview: "再练 18 分钟，林子里多一位伙伴")
        let full = try render(companions: 8, hasNext: false, preview: "8 位伙伴都到齐了")
        XCTAssertGreaterThan(
            difference(half, full), 300,
            "满员与未满员必须是两种画法：实测差 \(difference(half, full)) 像素"
        )
        try dump(full, name: "round42-forest-full.png")
    }

    /// 预告那句是插出来的真值：差 18 分钟和差 3 分钟画出来不一样。
    func testPreviewTextIsInterpolatedNotHardcoded() throws {
        let a = try render(companions: 4, hasNext: true, preview: "再练 18 分钟，林子里多一位伙伴")
        let b = try render(companions: 4, hasNext: true, preview: "再练 3 分钟，林子里多一位伙伴")
        XCTAssertGreaterThan(difference(a, b), 15, "预告里的分钟数要跟着变（阈值小：它只是一行字）")
    }

    // MARK: - 渲染

    /// ⚠️ 动物动画总闸在**这里**开关（不写 `setUp`）：那个回调是非隔离的，
    /// 在那儿碰主 actor 隔离的静态属性会被编译器连坐出一条警告。
    private func render(companions: Int, hasNext: Bool, preview: String) throws -> Render {
        let savedAnimations = CuteAnimalView.animationsEnabled
        CuteAnimalView.animationsEnabled = false
        defer { CuteAnimalView.animationsEnabled = savedAnimations }
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let order = AnimalKind.unlockOrder
        let residents = Array(order.prefix(companions))
        let next = hasNext ? order[companions] : nil
        let host = NSHostingView(rootView: AnyView(
            ForestUnlockCard(
                companions: residents,
                next: next,
                headline: "林子里 \(companions) 位伙伴",
                preview: preview
            )
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
}
