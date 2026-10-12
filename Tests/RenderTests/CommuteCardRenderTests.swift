import AIDomain
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// ⑦-D 通勤连播卡的**离屏渲染**回归。
///
/// 钉的是三种形态：没有素材**不占地方**、入口卡画得出「共 N 句 · 约多久」、
/// 运行中换成「第 N / M 句 + 停止」。
///
/// ⚠️ 换字一律用逐像素 `difference`（`ink` 量的是覆盖面积，同一张卡换字它一分不差）。
/// ⚠️ `.help` 与合成点击测不了（技能 `macos-ui-verify` 的「测不了三样」）。
@MainActor
final class CommuteCardRenderTests: XCTestCase {

    private var window: NSWindow?
    private let canvas = CGSize(width: 460, height: 220)

    private struct Render {
        var rep: NSBitmapImageRep
    }

    // MARK: - ① 没有素材就不占地方

    func testNoQueueDrawsNothing() throws {
        let empty = try render(queue: nil, isRunning: false)
        XCTAssertLessThan(ink(empty), 40, "今天没有句子时不该留出任何装饰：实测 \(ink(empty))")
    }

    // MARK: - ② 入口卡

    func testIdleCardDrawsTheSummary() throws {
        let idle = try render(queue: Self.queue, isRunning: false)
        XCTAssertGreaterThan(ink(idle), 220, "入口卡至少要画得出来：实测 \(ink(idle))")
        try dump(idle, name: "round41-commute-idle.png")
    }

    /// 队列更长 → 卡上的「共 N 句 · 约多久」跟着换（数字是插出来的，不是写死的一句）。
    func testLongerQueueChangesTheSummary() throws {
        let short = try render(queue: Self.shortQueue, isRunning: false)
        let long = try render(queue: Self.queue, isRunning: false)
        XCTAssertGreaterThan(
            difference(short, long), 40,
            "「共 2 句」与「共 5 句」必须画出不同的字：实测差 \(difference(short, long)) 像素"
        )
    }

    // MARK: - ③ 运行中

    /// 运行中多出「第 N / M 句」那颗胶囊，且按钮从「开始」变成「停止」。
    func testRunningDiffersFromIdle() throws {
        let idle = try render(queue: Self.queue, isRunning: false)
        let running = try render(queue: Self.queue(at: 2), isRunning: true)
        XCTAssertGreaterThan(
            difference(idle, running), 200,
            "运行中那张脸换了整块内容（进度胶囊 + 当前句 + 停止）：实测差 \(difference(idle, running)) 像素"
        )
        try dump(running, name: "round41-commute-running.png")
    }

    /// 放到不同句子，卡上那句正文也要跟着换。
    func testDifferentSentenceDrawsDifferently() throws {
        let third = try render(queue: Self.queue(at: 2), isRunning: true)
        let fifth = try render(queue: Self.queue(at: 4), isRunning: true)
        XCTAssertGreaterThan(difference(third, fifth), 40, "当前句是插出来的，不是写死的一句")
    }

    // MARK: - 渲染

    private func render(queue: CommuteQueue?, isRunning: Bool) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let host = NSHostingView(rootView: AnyView(
            CommuteCard(queue: queue, isRunning: isRunning)
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

    private static let drills: [ShadowingDrill] = [
        ShadowingDrill(id: "d1", text: "Hi.", translation: "你好。", topic: "问候", difficulty: 1, focus: ""),
        ShadowingDrill(id: "d2", text: "How are you?", translation: "你好吗？", topic: "问候", difficulty: 1, focus: ""),
        ShadowingDrill(id: "d3", text: "Nice to meet you.", translation: "很高兴认识你。", topic: "问候", difficulty: 2, focus: ""),
        ShadowingDrill(id: "d4", text: "I would like a coffee please.", translation: "我要一杯咖啡。", topic: "点单", difficulty: 2, focus: ""),
        ShadowingDrill(id: "d5", text: "See you tomorrow.", translation: "明天见。", topic: "告别", difficulty: 1, focus: "")
    ]

    private static var queue: CommuteQueue { queue(at: 0) }
    private static var shortQueue: CommuteQueue { CommuteQueue(drills: Array(drills.prefix(2))) }

    private static func queue(at index: Int) -> CommuteQueue {
        CommuteQueue(drills: drills, index: index)
    }
}
