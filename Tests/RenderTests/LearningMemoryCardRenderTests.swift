import AIDomain
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 学习记忆卡（第 15 步「记忆可见可控」）的**离屏渲染**回归。
///
/// 断言只钉「用户真能看见」这件事：**同一张卡只切一个开关，看画面到底变没变**。
/// 比如「话题行有没有画出来」= 把 `recentTopics` 清空再渲染一次做逐像素差分 ——
/// 差分有的话，说明那一行确实画在屏幕上了；差分约等于 0，就是根本没画。
///
/// 阈值先**自校准**（同一状态连抓两趟取噪声基准），固定阈值在整卡重排时会假通过。
@MainActor
final class LearningMemoryCardRenderTests: XCTestCase {

    private var window: NSWindow?
    private let cardWidth: CGFloat = 620
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Render {
        let rep: NSBitmapImageRep
        let size: CGSize
    }

    // MARK: - 造数据

    private func fullMemory() -> LearningMemory {
        let memory = LearningMemory(
            recurringErrors: [
                RecurringError(
                    original: "I go to school yesterday",
                    corrected: "I went to school yesterday",
                    explanation: "过去的事情要用过去式",
                    count: 3,
                    lastSeen: now
                )
            ],
            focusWords: ["luggage", "sustainable", "receipt"],
            weakDimensions: [
                WeakDimension(dimension: .fluency, averageScore: 61, sampleCount: 4)
            ],
            sessionsPracticed: 12,
            totalCorrections: 30,
            recentTopics: ["点咖啡", "问路", "看医生"],
            practiceTrend: PracticeTrend(direction: .slipping, recentRate: 0.42,
                                         earlierRate: 0.18, sessionCount: 12)
        )
        return memory
    }

    // MARK: - 渲染

    private func render(_ memory: LearningMemory, notice: String? = nil) throws -> Render {
        let card = LearningMemoryCard(memory: memory, notice: notice) {}
        return try render(AnyView(card), day: true)
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
        let first = try render(fullMemory())
        let second = try render(fullMemory())
        let noise = diff(first.rep, second.rep)
        XCTAssertLessThanOrEqual(noise.count, 100, "同一状态两趟出图差异应接近 0，实测 \(noise.count)")
    }

    func testMemoryContentIsActuallyDrawn() throws {
        let empty = try render(LearningMemory())
        let full = try render(fullMemory())
        let signal = diff(empty.rep, full.rep)
        XCTAssertGreaterThan(signal.count, 500, "有记忆时必须真的画出内容，实测变化像素 \(signal.count)")
        XCTAssertGreaterThan(full.size.height, empty.size.height + 30, "内容多了卡片就该长高")
    }

    func testTopicsRowIsDrawn() throws {
        let withTopics = try render(fullMemory())
        var without = fullMemory()
        without.recentTopics = []
        let removed = try render(without)
        let signal = diff(withTopics.rep, removed.rep)
        XCTAssertGreaterThan(signal.count, 300, "话题行必须真的画出来，实测变化像素 \(signal.count)")
        XCTAssertGreaterThan(withTopics.size.height, removed.size.height, "少了话题行卡片应变矮")
    }

    func testTrendLineIsDrawn() throws {
        let withTrend = try render(fullMemory())
        var unknown = fullMemory()
        unknown.practiceTrend = .unknown
        let removed = try render(unknown)
        let signal = diff(withTrend.rep, removed.rep)
        XCTAssertGreaterThan(signal.count, 300, "趋势行必须真的画出来，实测变化像素 \(signal.count)")
    }

    func testRecurringErrorRowIsDrawn() throws {
        let withErrors = try render(fullMemory())
        var without = fullMemory()
        without.recurringErrors = []
        let removed = try render(without)
        let signal = diff(withErrors.rep, removed.rep)
        XCTAssertGreaterThan(signal.count, 300, "「反复犯的错」必须真的画出来")
    }

    func testEmptyStateShowsHonestHint() throws {
        let empty = try render(LearningMemory())
        // 空态不该把卡片撑成一张大卡 —— 那意味着画了不该画的东西。
        XCTAssertLessThan(empty.size.height, 160, "空态就是一句提示 + 标题，实测高度 \(empty.size.height)")
    }

    func testRendersInBothThemesAndDumpsPNG() throws {
        let day = try render(AnyView(LearningMemoryCard(memory: fullMemory()) {}), day: true)
        let night = try render(AnyView(LearningMemoryCard(memory: fullMemory()) {}), day: false)
        XCTAssertGreaterThan(day.size.height, 100)
        XCTAssertGreaterThan(night.size.height, 100)
        dump(day.rep, name: "round37-learning-memory-day")
        dump(night.rep, name: "round37-learning-memory-night")
    }
}
