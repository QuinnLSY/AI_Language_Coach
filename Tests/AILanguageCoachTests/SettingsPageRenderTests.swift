import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 设置页整页离屏出图 + 「学习语言 / 母语」确实是下拉。
///
/// 为什么不用真机滚动截图：本机合成滚轮事件投不进目标窗口（辅助功能权限），
/// 而整页离屏渲染**不碰真实数据**（临时 `ConfigStore` + `:memory:` 库），可复现、
/// 也能直接断言「那两个控件是下拉」这件事 —— 截图上只能靠肉眼猜。
///
/// ⚠️ 只拍第一帧就够：`SettingsView` 的 `.task` 会去刷新隐私 / 备份 / 能力信息
/// （会读真实目录），而这里要看的是**布局**，不等那些异步动作。
@MainActor
final class SettingsPageRenderTests: XCTestCase {

    private var window: NSWindow?

    private func state() -> AppState {
        AppState(services: CoachServices(
            config: ConfigStore(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("alc-settings-\(UUID().uuidString).json")),
            databasePath: ":memory:"
        ))
    }

    /// 递归数某种 AppKit 视图的实例数。
    private func count<T: NSView>(_ type: T.Type, in view: NSView) -> Int {
        var total = view is T ? 1 : 0
        for sub in view.subviews { total += count(type, in: sub) }
        return total
    }

    /// 所有下拉命中区在 host 坐标里的位置（自上而下）。
    private func popUpFrames(in host: NSView) -> [NSRect] {
        var result: [NSRect] = []
        func walk(_ view: NSView) {
            if view is PopUpHitView { result.append(view.convert(view.bounds, to: host)) }
            for sub in view.subviews { walk(sub) }
        }
        walk(host)
        return result.sorted { $0.minY < $1.minY }
    }

    /// 「学习语言 / 母语」这一对：**同一张卡里上下相邻、左边缘对齐**的两个下拉。
    ///
    /// ⚠️ 不要求宽度相同：两个下拉的宽度是按各自文字量出来的（「英语（美国）」比
    /// 「简体中文」宽），实测 170 vs 144。不写死行号是因为设置页别处也有下拉
    /// （供应商、音色），靠布局特征认出来才稳。
    private func learningPair(_ frames: [NSRect]) -> (NSRect, NSRect)? {
        for i in frames.indices {
            for j in frames.indices where j > i {
                let a = frames[i], b = frames[j]
                guard abs(a.minX - b.minX) < 1 else { continue }
                let gap = b.minY - a.minY
                if gap > 10, gap < 60 { return (a, b) }
            }
        }
        return nil
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews { if let found = firstScrollView(in: sub) { return found } }
        return nil
    }

    private func renderPage(day: Bool, viewportHeight: CGFloat) throws -> (NSHostingView<AnyView>, NSBitmapImageRep) {
        let theme = ForestThemeResolver.resolve(mode: day ? .day : .night, systemIsDark: !day)
        let host = NSHostingView(rootView: AnyView(
            SettingsView(state: state())
                .forestTheme(theme)
                .frame(width: 780)
        ))
        let size = CGSize(width: 780, height: viewportHeight)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return (host, rep)
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

    /// 只缓存视图的某一块（`cacheDisplay(in:)` 收的是**视图自身坐标**，
    /// 与 `popUpFrames` 量出来的同源，不必手算像素与翻转）。
    private func capture(_ host: NSHostingView<AnyView>, rect: NSRect) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: rect))
        host.cacheDisplay(in: rect, to: rep)
        return rep
    }

    /// 「学习语言 / 母语」是 `ForestSelect`（一个真 `NSView` 命中区），不是裸文本框。
    ///
    /// 光看图只能看出「像下拉」；这里数的是**真实存在的下拉命中区**。
    /// 旧版那两个是 `TextField`（`NSTextField`），根本不会有 `PopUpHitView`。
    ///
    /// ⚠️ 出的是**局部缓存图**而不是滚一屏：`NSScrollView.contentView.scroll(to:)`
    /// 在 SwiftUI 的 ScrollView 上滚到的位置与 host 坐标对不上（实测偏了一张卡），
    /// 而 `cacheDisplay(in:)` 与量位置的坐标系完全同源。
    func testLearningLanguageRowsAreRealDropDowns() throws {
        let (host, fullRep) = try renderPage(day: true, viewportHeight: 3200)
        let popUps = count(PopUpHitView.self, in: host)
        // 学习卡里的三个下拉：学习语言 / 母语 / 老师性格 —— 少一个就红，
        // 免得「新增了一个设置项但没画出来」这种事只靠人眼发现。
        XCTAssertGreaterThanOrEqual(popUps, 3, "学习卡至少该有三个下拉命中区（学习语言、母语、老师性格），实测 \(popUps)")

        let frames = popUpFrames(in: host)
        let pair = try XCTUnwrap(learningPair(frames),
                                 "没找到「上下相邻、左边缘对齐的一对下拉」；实测各下拉位置：" +
                                 frames.map { "x=\(Int($0.minX)) y=\(Int($0.minY)) w=\(Int($0.width))" }
                                     .joined(separator: " | "))

        try dump(fullRep, name: "round48-settings-full-day.png")
        let cardRect = NSRect(x: 0, y: max(pair.0.minY - 120, 0),
                              width: host.bounds.width, height: 280)
        try dump(try capture(host, rect: cardRect), name: "round48-settings-learning-day.png")
    }

    func testLearningCardRendersInNightThemeToo() throws {
        let (host, _) = try renderPage(day: false, viewportHeight: 3200)
        let pair = try XCTUnwrap(learningPair(popUpFrames(in: host)), "夜间版没找到学习卡的两个下拉")
        let cardRect = NSRect(x: 0, y: max(pair.0.minY - 120, 0), width: host.bounds.width, height: 280)
        try dump(try capture(host, rect: cardRect), name: "round48-settings-learning-night.png")
    }

    func testPageRendersInBothThemes() throws {
        let (_, day) = try renderPage(day: true, viewportHeight: 3200)
        let (_, night) = try renderPage(day: false, viewportHeight: 3200)
        func luma(_ rep: NSBitmapImageRep) throws -> CGFloat {
            let color = try XCTUnwrap(rep.colorAt(x: 4, y: 4))
            return color.redComponent * 0.3 + color.greenComponent * 0.6 + color.blueComponent * 0.1
        }
        XCTAssertGreaterThan(try luma(day), try luma(night), "日夜两版底色必须真的不同")
        try dump(night, name: "round48-settings-full-night.png")
    }
}
