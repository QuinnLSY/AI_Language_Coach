import AIDomain
import AppKit
import SwiftUI
@testable import AppUI
import XCTest

/// 无文本听力两张卡的**离屏渲染**回归（进阶 ④）。
///
/// 这组测试负责「看得见的东西到底画出来了没有」，而**不**负责「提交前不出现原文」——
/// 那件事由类型保证：提问态的 `ListeningDrillCard` 根本拿不到 `reference`
/// （它只收句序 / 遍数 / 语速档 / 用户自己写的字），原文只在 `ListeningAttempt`
/// 里、提交后才进得来；文案层的泄露由 `ListeningDictationTests` 的断言盯着。
///
/// ⚠️ 不比对绝对色值（离屏渲染过一道色彩空间换算），一律用**布局差**；
/// ⚠️ 不写 UserDefaults / 配置 / 数据库 —— 这两张卡是纯展示组件。
@MainActor
final class ListeningDrillCardRenderTests: XCTestCase {

    private var window: NSWindow?
    private let cardWidth: CGFloat = 520

    private struct Render {
        let rep: NSBitmapImageRep
        let size: CGSize
    }

    // MARK: - 造数据

    private func attempt(
        reference: String,
        typed: String,
        playCount: Int = 2,
        usedSlowRate: Bool = false
    ) -> ListeningAttempt {
        ListeningAttempt(
            drillID: "d0",
            reference: reference,
            translation: "这是译文",
            typed: typed,
            comparison: ShadowingScorer.compare(reference: reference, recognized: typed),
            playCount: playCount,
            usedSlowRate: usedSlowRate
        )
    }

    private func render(
        attempt: ListeningAttempt?,
        playCount: Int = 0,
        isPlaying: Bool = false,
        isSlow: Bool = false,
        typed: String = "",
        index: Int = 2,
        total: Int = 8,
        day: Bool = true
    ) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: day ? .day : .night, systemIsDark: !day)
        let backdrop: Color = day ? Color(hex: 0xF3F7EF) : Color(hex: 0x101B2E)
        let text = Binding(get: { typed }, set: { _ in })
        let host = NSHostingView(rootView: AnyView(
            ListeningDrillCard(
                index: index,
                total: total,
                attempt: attempt,
                playCount: playCount,
                isPlaying: isPlaying,
                isSlow: isSlow,
                isLast: index + 1 >= total,
                typed: text,
                onPlay: {},
                onToggleSlow: {},
                onSubmit: {},
                onAdvance: {},
                onCancel: {}
            )
            .forestTheme(theme)
            .frame(width: cardWidth)
            .background(backdrop)
        ))
        return try snapshot(host)
    }

    private func renderSummary(
        _ summary: ListeningSummary,
        day: Bool = true
    ) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: day ? .day : .night, systemIsDark: !day)
        let backdrop: Color = day ? Color(hex: 0xF3F7EF) : Color(hex: 0x101B2E)
        let host = NSHostingView(rootView: AnyView(
            ListeningSummaryCard(summary: summary, onCollectWords: {}, onRestart: {}, onClose: {})
                .forestTheme(theme)
                .frame(width: cardWidth)
                .background(backdrop)
        ))
        return try snapshot(host)
    }

    private func snapshot(_ host: NSHostingView<AnyView>) throws -> Render {
        host.frame = NSRect(x: 0, y: 0, width: cardWidth, height: 200)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        // 两趟：先问出自然高度，再按自然高度出图，避免把内容裁掉。
        let size = CGSize(width: cardWidth, height: max(60, ceil(host.fittingSize.height)))
        host.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep, size: size)
    }

    private func dump(_ rep: NSBitmapImageRep, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // RenderTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]), "PNG 编码失败")
        try png.write(to: directory.appendingPathComponent(name))
    }

    private func changedPixels(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Int {
        guard lhs.pixelsWide == rhs.pixelsWide, lhs.pixelsHigh == rhs.pixelsHigh else {
            return Int.max
        }
        var count = 0
        for x in 0..<lhs.pixelsWide {
            for y in 0..<lhs.pixelsHigh {
                guard let a = lhs.colorAt(x: x, y: y), let b = rhs.colorAt(x: x, y: y) else { continue }
                if abs(a.redComponent - b.redComponent)
                    + abs(a.greenComponent - b.greenComponent)
                    + abs(a.blueComponent - b.blueComponent) > 0.15 { count += 1 }
            }
        }
        return count
    }

    // MARK: - ① 提问态：只有听与写的入口，卡片要有实际高度

    func testPromptStateHasRealHeight() throws {
        let rendered = try render(attempt: nil)
        XCTAssertGreaterThan(rendered.size.height, 140, "播放按钮 + 输入框 + 提交按钮要有实际高度")
    }

    // MARK: - ② 交卷后多出「逐词 + 原文 + 译文」那一块

    func testFeedbackStateIsTallerThanPrompt() throws {
        let prompt = try render(attempt: nil)
        let feedback = try render(
            attempt: attempt(reference: "Can I have a receipt", typed: "Can I have receipt")
        )
        XCTAssertGreaterThan(
            feedback.size.height, prompt.size.height + 40,
            "对照块（逐词 + 原文 + 译文 + 建议 + 下一句）必须真的画出来"
        )
    }

    /// 逐词 chip 会换行：句子越长，对照块越高 —— 说明「每个词都画了」。
    func testLongerSentenceGrowsTheFeedbackBlock() throws {
        let short = try render(attempt: attempt(reference: "Thank you", typed: "Thank you"))
        let long = try render(attempt: attempt(
            reference: "I would like to check in my luggage and get a receipt",
            typed: "I would like check in luggage and get receipt"
        ))
        XCTAssertGreaterThan(long.size.height, short.size.height + 24)
    }

    // MARK: - ③ 结算卡

    func testSummaryCardRendersWithMissedWords() throws {
        let empty = try renderSummary(ListeningSummary.from([]))
        let full = try renderSummary(ListeningSummary.from([
            attempt(reference: "Can I have a receipt", typed: "Can I have receipt"),
            attempt(reference: "The flight is delayed", typed: "The flight is delay"),
        ]))
        XCTAssertGreaterThan(full.size.height, empty.size.height + 40, "漏词区必须真的画出来")
        XCTAssertGreaterThan(empty.size.height, 80, "一句都没交时也要有话说")
    }

    // MARK: - 出图（人眼复核）

    func testDumpsAllStates() throws {
        let promptDay = try render(attempt: nil, playCount: 0, typed: "")
        let promptNight = try render(attempt: nil, playCount: 3, isSlow: true, typed: "Can I have a", day: false)
        let feedbackDay = try render(attempt: attempt(
            reference: "Can I have a receipt please",
            typed: "Can I have receipt"
        ))
        let feedbackNight = try render(attempt: attempt(
            reference: "Can I have a receipt please",
            typed: "Can I have receipt"
        ), day: false)
        let summaryDay = try renderSummary(ListeningSummary.from([
            attempt(reference: "Can I have a receipt please", typed: "Can I have receipt"),
            attempt(reference: "Could you hold the line", typed: "Could you hold the line", playCount: 1),
        ]))

        XCTAssertGreaterThan(changedPixels(promptDay.rep, promptNight.rep), 500, "日夜两档必然不同")

        try dump(promptDay.rep, name: "listening-card-prompt-day.png")
        try dump(promptNight.rep, name: "listening-card-prompt-night.png")
        try dump(feedbackDay.rep, name: "listening-card-feedback-day.png")
        try dump(feedbackNight.rep, name: "listening-card-feedback-night.png")
        try dump(summaryDay.rep, name: "listening-summary-day.png")
    }
}
