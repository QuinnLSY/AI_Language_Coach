import AIDomain
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// ⑦-A 菜单栏面板的**离屏渲染**回归。
///
/// 这块面板活在 `NSPopover` 里，**没有**主窗口那一层「打开看一眼」的常规验证路径 ——
/// 所以它是全应用里最该做离屏渲染的视图之一。
///
/// ⚠️ 不比色值（离屏渲染会过一次色彩空间转换）。
/// ⚠️ 同一张卡里只换字时 `ink` 是**假闸**（它量的是覆盖面积，实测两张卡的墨迹一分不差），
/// 换文案一律用逐像素 `difference`；只有「多画一块 / 多一整行」才用 `ink`。
@MainActor
final class MenuBarPanelRenderTests: XCTestCase {

    private var window: NSWindow?
    private let canvas = CGSize(width: 340, height: 430)

    private struct Render {
        var rep: NSBitmapImageRep
    }

    // MARK: - ① 面板画得出来

    func testPanelDraws() throws {
        let shot = try render(snapshot: Self.busy)
        XCTAssertGreaterThan(ink(shot), 500, "面板本身要画得出来：实测 \(ink(shot)) 像素墨迹")
        try dump(shot, name: "round40-menubar-busy.png")
    }

    // MARK: - ② 今天的状态换了，字要跟着换

    /// 未完成 → 全部完成：换的是「今日 X/Y 项」与整排建议，必须逐像素看得出来。
    func testTodayStateChangesTheCopy() throws {
        let busy = try render(snapshot: Self.busy)
        let done = try render(snapshot: Self.done)
        XCTAssertGreaterThan(
            difference(busy, done), 300,
            "未完成与全部完成必须画出不同的内容：实测差 \(difference(busy, done)) 像素"
        )
        try dump(done, name: "round40-menubar-done.png")
    }

    /// 断签警示与普通状态差的是**一行字的颜色**；差分仍能看见（同位置、不同灰度）。
    func testStreakAtRiskIsVisible() throws {
        let safe = try render(snapshot: Self.busy)
        let atRisk = try render(snapshot: Self.atRisk)
        XCTAssertGreaterThan(
            difference(safe, atRisk), 20,
            "连续纪录今天就到头时那一行要看得出来：实测差 \(difference(safe, atRisk)) 像素"
        )
    }

    // MARK: - ③ 备选 / Dock 那一行

    /// 备选整排少了：那是「少画两块」，用墨迹量。
    func testSecondaryRowsAddInk() throws {
        let withRows = try render(snapshot: Self.busy)
        let without = try render(snapshot: Self.noSecondary)
        XCTAssertGreaterThan(
            ink(withRows), Int(Double(ink(without)) * 1.12),
            "多两条备选就该多画两块：\(ink(withRows)) vs \(ink(without))"
        )
    }

    /// Dock 图标收没收起，那一行写的是不同的话（「收起…」/「显示…」）。
    func testDockRowReflectsThePreference() throws {
        let hidden = try render(snapshot: Self.busy, dockIconHidden: true)
        let shown = try render(snapshot: Self.busy, dockIconHidden: false)
        XCTAssertGreaterThan(
            difference(hidden, shown), 20,
            "收起之后那一行要变成「收起来之后到这里恢复」的那句：实测差 \(difference(hidden, shown)) 像素"
        )
        try dump(hidden, name: "round40-menubar-dock-hidden.png")
    }

    // MARK: - 渲染与度量

    private func render(snapshot: MenuBarAssistant.Snapshot, dockIconHidden: Bool = false) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let host = NSHostingView(rootView: AnyView(
            MenuBarPanel(
                snapshot: snapshot,
                dockIconHidden: dockIconHidden,
                onGo: { _ in },
                onOpenMainWindow: {},
                onToggleDockIcon: {},
                onQuit: {}
            )
            .frame(width: MenuBarPanel.width)
            .frame(width: canvas.width, height: canvas.height, alignment: .top)
            // 与 Popover 里的 Host 一致：按压反馈是外部注入的，组件自己不写样式。
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

    /// 两张图逐像素的差异数。
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

    private func dump(_ render: Render, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(render.rep.representation(using: .png, properties: [:]), "PNG 编码失败")
        try png.write(to: directory.appendingPathComponent(name))
    }

    // MARK: - 工装

    /// 今天还剩两件：主按钮是排在最前那一件，再加两条备选。
    private static var busy: MenuBarAssistant.Snapshot {
        MenuBarAssistant.Snapshot(
            headline: "今日 1 / 3 项",
            detail: "连续 5 天 · 12 分钟",
            primary: MenuBarAssistant.Action(section: .shadowing, title: "跟读 3 句，逐音素纠音", detail: "0 / 3 次"),
            secondary: [
                MenuBarAssistant.Action(section: .practice, title: "和老师聊 4 轮", detail: "1 / 4 轮"),
                MenuBarAssistant.Action(section: .vocabulary, title: "复习 8 个到期单词", detail: "3 / 8 个词"),
            ],
            isAllDone: false,
            isStreakAtRisk: false
        )
    }

    private static var atRisk: MenuBarAssistant.Snapshot {
        MenuBarAssistant.Snapshot(
            headline: "今日 1 / 3 项",
            detail: "连续 5 天 · 12 分钟",
            primary: busy.primary!,
            secondary: busy.secondary,
            isAllDone: false,
            isStreakAtRisk: true
        )
    }

    /// 今天全做完：换成「再多聊两句」+ 一条看战绩。
    private static var done: MenuBarAssistant.Snapshot {
        MenuBarAssistant.Snapshot(
            headline: "今日 全部完成",
            detail: "连续 6 天 · 25 分钟",
            primary: MenuBarAssistant.Action(section: .practice, title: "再多聊两句", detail: ""),
            secondary: [MenuBarAssistant.Action(section: .progress, title: "看今天练了多少", detail: "25 分钟")],
            isAllDone: true,
            isStreakAtRisk: false
        )
    }

    /// 只有主按钮（今天只剩一件）。
    private static var noSecondary: MenuBarAssistant.Snapshot {
        MenuBarAssistant.Snapshot(
            headline: "今日 2 / 3 项",
            detail: "连续 5 天 · 12 分钟",
            primary: MenuBarAssistant.Action(section: .shadowing, title: "跟读 3 句，逐音素纠音", detail: "0 / 3 次"),
            secondary: [],
            isAllDone: false,
            isStreakAtRisk: false
        )
    }
}
