import AIDomain
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// ⑦-B① 开屏话题卡的**离屏渲染**回归。
///
/// 钉的是三件用户真看得见的事：
/// - **没依据就不占地方**：空数组渲染出来必须是一张干净的图；
/// - **给了几张就画几张**：三张比一张明显多墨迹（整张组件比高度差比不出来，
///   这里直接比墨迹总量 —— 组件外面没有其他内容会稀释它）；
/// - **hover 有反馈、且不换构局**：注入悬停后差异不为零，但远小于「多画一张卡」的差异。
///
/// ⚠️ 不比色值：离屏渲染会过一次色彩空间转换（见回合记录里的同一条教训）。
/// ⚠️ `.help` 与合成点击测不了（技能 `macos-ui-verify` 的「测不了三样」），
/// 点击后的去向由 `TopicKickoffTests` 钉数据、`ModelControlTests` 钉装载。
@MainActor
final class KickoffRowRenderTests: XCTestCase {

    private var window: NSWindow?
    private let canvas = CGSize(width: 440, height: 320)

    private struct Render {
        var rep: NSBitmapImageRep
        var scale: CGFloat
    }

    // MARK: - ① 空列表不占地方

    func testEmptySuggestionsDrawNothing() throws {
        let empty = try renderRow([])
        let emptyAgain = try renderRow([])
        XCTAssertLessThan(
            ink(empty), 40,
            "没有依据时不该留出任何装饰：实测 \(ink(empty)) 像素墨迹"
        )
        XCTAssertLessThan(
            abs(ink(empty) - ink(emptyAgain)), 20,
            "同一份空输入两次渲染应当完全一致（噪声地板）"
        )
    }

    // MARK: - ② 三张比一张多

    func testMoreCardsDrawMoreInk() throws {
        let one = try renderRow([Self.resume])
        let three = try renderRow(Self.allThree)
        XCTAssertGreaterThan(ink(one), 400, "一张卡至少要画得出来")
        XCTAssertGreaterThan(
            ink(three), Int(Double(ink(one)) * 1.8),
            "三张卡的墨迹应当远多于一张（实测 \(ink(three)) vs \(ink(one))）"
        )
        try dump(one, name: "round37-kickoff-one-card.png")
        try dump(three, name: "round37-kickoff-three-cards.png")
    }

    // MARK: - ③ 悬停有反馈但不重排

    func testHoverChangesFillWithoutAddingStructure() throws {
        let idle = try renderRow(Self.allThree)
        let hovered = try renderRow(Self.allThree, hovered: "todayWord")
        // ⚠️ 这里不能拿「与背景的差异」当度量：卡片底色换成另一种颜色后，
        // 它依旧不等于页面底色，各自的墨迹数一分不差 —— 差分必须图对图比。
        let changed = difference(idle, hovered)
        XCTAssertGreaterThan(changed, 200, "悬停必须看得出来：实测只差 \(changed) 像素")
        XCTAssertLessThan(
            changed, ink(idle) * 4 / 5,
            "悬停只是换底色，不会多画出一整张卡：差异 \(changed)、整块墨迹 \(ink(idle))"
        )
        try dump(hovered, name: "round37-kickoff-hovered.png")
    }

    // MARK: - 渲染与度量

    private func renderRow(_ suggestions: [KickoffSuggestion], hovered: String? = nil) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let host = NSHostingView(rootView: AnyView(
            KickoffRow(suggestions: suggestions, onPick: { _ in }, forcedHoveredID: hovered)
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
        return Render(rep: rep, scale: CGFloat(rep.pixelsHigh) / max(canvas.height, 1))
    }

    /// 两张图逐像素的差异数 —— 与 `ink` 不同，`ink` 只对「多了东西」敏感，
    /// 这张专量「同一块地方换了种底色」。
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

    private static let resume = KickoffSuggestion(
        kind: .resume,
        title: "接着练《咖啡店点单》",
        detail: "上次练到 2/3 步 · 昨天",
        action: .openScenario(id: "s1")
    )

    private static let wordCard = KickoffSuggestion(
        kind: .todayWord,
        title: "用今天这个词开口",
        detail: "resilient",
        action: .send(text: "Can you help me use the word \"resilient\" in a sentence?")
    )

    private static let smallTalk = KickoffSuggestion(
        kind: .smallTalk,
        title: "不知道说什么？来这句",
        detail: "Can you help me order a coffee like a local?",
        action: .send(text: "Can you help me order a coffee like a local?")
    )

    private static var allThree: [KickoffSuggestion] { [resume, wordCard, smallTalk] }
}
