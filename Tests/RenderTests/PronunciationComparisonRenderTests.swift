import AIDomain
import AIInfrastructure
import AIServices
import AppCore
@testable import AppUI
import SwiftUI
import XCTest

/// 发音「最近 vs 之前」对比卡（④ 的纵向那一半）的**离屏渲染**回归。
///
/// 四条判据：① 卡片真有内容；② 多一行就高一点（证明行真被画出来）；
/// ③ 日夜两版都看得清（并落盘供人眼复核）；④ 端到端：跟读页真的把它挂上了
/// （撤掉挂载 → 墨迹差归零 → 立刻红）。
@MainActor
final class PronunciationComparisonRenderTests: XCTestCase {

    private var window: NSWindow?
    private let cardWidth: CGFloat = 460
    private let pageWidth: CGFloat = 900
    private let pageHeight: CGFloat = 2000

    // MARK: - 造数据

    /// 四行齐全（总分 + 重音 + 连读 + 语调）。
    private func full() -> PronunciationComparison {
        PronunciationComparison(
            rows: [
                .init(title: "总分", before: 72, after: 84, unit: "分"),
                .init(title: "重音层次", before: 0.2, after: 0.5, unit: "%", isPercent: true),
                .init(title: "连读", before: 0.3, after: 0.7, unit: "%", isPercent: true),
                .init(title: "语调起伏", before: 0, after: 1, unit: "%", isPercent: true),
            ],
            sampleCount: 20,
            recentCount: 10
        )
    }

    /// 只有总分那一行（老记录没量过韵律）。
    private func scoreOnly() -> PronunciationComparison {
        PronunciationComparison(
            rows: [.init(title: "总分", before: 72, after: 84, unit: "分")],
            sampleCount: 20,
            recentCount: 10
        )
    }

    // MARK: - 离屏渲染

    private struct Render {
        var rep: NSBitmapImageRep
        var size: CGSize
    }

    /// ⚠️ 冷启动那一次排版缓存没热，同一份输入两次出图能差几百像素 —— 先出一张废图捂热。
    private func render(_ comparison: PronunciationComparison, day: Bool, container: Bool = true) throws -> Render {
        _ = try? draw(comparison, day: day, container: container)
        return try draw(comparison, day: day, container: container)
    }

    private func draw(_ comparison: PronunciationComparison, day: Bool, container: Bool) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: day ? .day : .night, systemIsDark: !day)
        let backdrop: Color = day ? Color(hex: 0xF3F7EF) : Color(hex: 0x101B2E)
        let host = NSHostingView(rootView: AnyView(
            ZStack(alignment: .top) {
                backdrop
                PronunciationComparisonCard(comparison: comparison, showsContainer: container)
                    .frame(width: cardWidth)
            }
            .frame(width: cardWidth)
            .forestTheme(theme)
        ))
        host.frame = NSRect(x: 0, y: 0, width: cardWidth, height: 200)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let size = CGSize(width: cardWidth, height: max(1, ceil(host.fittingSize.height)))
        host.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep, size: size)
    }

    private func renderPage(_ state: AppState) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let host = NSHostingView(rootView: AnyView(
            ZStack(alignment: .top) {
                Color(hex: 0xF3F7EF)
                ShadowingView(state: state)
            }
            .frame(width: pageWidth)
            .forestTheme(theme)
        ))
        host.frame = NSRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep, size: host.frame.size)
    }

    /// 墨迹统计：以左上角像素为底色，数出「不一样」的像素。
    private func ink(_ rep: NSBitmapImageRep) -> Int {
        guard let background = rep.colorAt(x: 0, y: 0) else { return 0 }
        var count = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let delta = abs(color.redComponent - background.redComponent)
                    + abs(color.greenComponent - background.greenComponent)
                    + abs(color.blueComponent - background.blueComponent)
                if delta > 0.15 { count += 1 }
            }
        }
        return count
    }

    private func dump(_ rep: NSBitmapImageRep, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]), "PNG 编码失败")
        try png.write(to: directory.appendingPathComponent(name))
    }

    // MARK: - ① 卡片真有内容

    func testCardDrawsSomething() throws {
        let drawn = try render(full(), day: true)
        XCTAssertGreaterThan(ink(drawn.rep), 300, "对比卡必须有内容（标题 + 结论 + 几行）")
        XCTAssertGreaterThan(drawn.size.height, 80)
    }

    // MARK: - ② 多一行就高一点

    /// ⚠️ 判**高度**不判墨迹：追加在图片最下方的内容正好会被「按较矮那张裁齐」的差分裁掉
    /// （④ 里踩过一次 —— 卡片 110 → 137，差分却是 0）。
    func testExtraRowsMakeTheCardTaller() throws {
        let four = try render(full(), day: true)
        let one = try render(scoreOnly(), day: true)
        XCTAssertGreaterThan(four.size.height, one.size.height + 30,
                             "四行必须明显比一行高（实测 \(one.size.height) vs \(four.size.height)）")
    }

    // MARK: - ③ 日夜两版

    func testRendersInBothThemesAndDumpsPNG() throws {
        let night = try render(full(), day: false)
        let day = try render(full(), day: true)

        XCTAssertGreaterThan(ink(day.rep), 300, "日间版应有内容")
        XCTAssertGreaterThan(ink(night.rep), 300, "夜间版应有内容")

        func luma(_ rep: NSBitmapImageRep) throws -> CGFloat {
            let color = try XCTUnwrap(rep.colorAt(x: 0, y: 0))
            return color.redComponent * 0.3 + color.greenComponent * 0.6 + color.blueComponent * 0.1
        }
        let dayLuma = try luma(day.rep)
        let nightLuma = try luma(night.rep)
        XCTAssertGreaterThan(dayLuma, 0.5, "日间底色应偏亮")
        XCTAssertLessThan(nightLuma, 0.3, "夜间底色应偏暗")

        try dump(day.rep, name: "round46-pronunciation-compare-day.png")
        try dump(night.rep, name: "round46-pronunciation-compare-night.png")
    }

    // MARK: - ④ 端到端：跟读页真的挂上了

    /// 撤掉挂载 → 两版墨迹相等 → 立刻红。
    ///
    /// ⚠️ 比**墨迹**不比高度：整页在 `ScrollView` 里，加一块内容不改变页面高度（量高度永远绿）。
    func testShadowingPageDrawsTheCardEndToEnd() async throws {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("compare-page-probe-\(UUID().uuidString).json")
        )
        let state = AppState(services: CoachServices(config: store, databasePath: ":memory:"))
        await state.loadShadowing()

        let drill = try XCTUnwrap(state.currentShadowingDrill, "跟读素材应随包发布")
        await state.previewShadowingResult(drill.text)
        XCTAssertNotNil(state.shadowingComparison, "预览一条跟读结果（发音卡只在有对齐结果时出现）")

        state.pronunciationComparison = nil
        let without = try renderPage(state)
        state.pronunciationComparison = full()
        let with = try renderPage(state)

        let withInk = ink(with.rep)
        let withoutInk = ink(without.rep)
        // 阈值要明显高过页面里那只动来动去的动物带来的抖动（实测撤掉时差值是 0，
        // 同样输入的自身抖动在 500 像素上下 —— 贴着 500 会误判）。
        XCTAssertGreaterThan(withInk, withoutInk + 2_000,
                             "带对比卡的页面必须明显多出墨迹（差值 \(withInk - withoutInk)）—— 说明卡片真的挂在页面上")

        try dump(with.rep, name: "round46-shadowing-page-with-comparison.png")
    }
}
