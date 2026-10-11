import AIDomain
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// ⑦-B③ 盲盒那一行的**离屏渲染**回归。
///
/// 钉的是这一行真的画得出来、且两副样子各不相同：
/// - 没抽过：标题 + 「从 N 个情景里随手挑一个」+「随机来一个」；
/// - 抽过了：换成「开出《X》」+ 多一颗「就练这个」。
///
/// ⚠️ 换字一律比**逐像素差分**：`ink` 量的是覆盖面积，同一行里换一句文案它一分不差
///（同一条教训，见 `WarmUpCardRenderTests`）。
/// ⚠️ 不比色值：离屏渲染会过一次色彩空间转换。
/// ⚠️ `.help` 与合成点击测不了（技能 `macos-ui-verify` 的「测不了三样」）。
@MainActor
final class BlindBoxRowRenderTests: XCTestCase {

    private var window: NSWindow?
    private let canvas = CGSize(width: 720, height: 120)

    private struct Render {
        var rep: NSBitmapImageRep
        var scale: CGFloat
    }

    // MARK: - ① 这一行画得出来

    func testRowDrawsItself() throws {
        let plain = try render(poolCount: 12, revealed: nil)
        XCTAssertGreaterThan(ink(plain), 600, "这一行至少要画得出来：实测 \(ink(plain)) 像素墨迹")
        try dump(plain, name: "round39-blindbox-plain.png")
    }

    /// 副标上的「从 N 个…」是插出来的真数字：换个数就得换一行字。
    func testPoolCountIsInterpolated() throws {
        let twelve = try render(poolCount: 12, revealed: nil)
        let three = try render(poolCount: 3, revealed: nil)
        XCTAssertGreaterThan(
            difference(twelve, three), 60,
            "池子从 12 个变成 3 个，副标上的数字必须跟着变：实测差 \(difference(twelve, three)) 像素"
        )
    }

    // MARK: - ② 抽过之后换一副样子

    func testRevealedRowDiffersFromPlain() throws {
        let plain = try render(poolCount: 12, revealed: nil)
        let revealed = try render(poolCount: 12, revealed: Self.checkIn)
        XCTAssertGreaterThan(
            difference(plain, revealed), 300,
            "开出之后要换文案、还要多一颗「就练这个」：实测差 \(difference(plain, revealed)) 像素"
        )
        try dump(revealed, name: "round39-blindbox-revealed.png")
    }

    /// 开出的不是同一个情景 → 这一行画的也不是同一行字。
    func testDifferentRevealsDrawDifferently() throws {
        let checkIn = try render(poolCount: 12, revealed: Self.checkIn)
        let interview = try render(poolCount: 12, revealed: Self.interview)
        XCTAssertGreaterThan(
            difference(checkIn, interview), 120,
            "开出《机场值机》与《面试问答》必须画成两行不同的字：实测差 \(difference(checkIn, interview)) 像素"
        )
        try dump(interview, name: "round39-blindbox-revealed-interview.png")
    }

    // MARK: - 渲染与度量

    private func render(poolCount: Int, revealed: BlindBoxEntry?) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let host = NSHostingView(rootView: AnyView(
            BlindBoxRow(
                poolCount: poolCount,
                revealed: revealed,
                onReveal: {},
                onStart: {}
            )
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

    /// 两张图逐像素的差异数（`ink` 只对「多了东西」敏感，这张专量「换了内容」）。
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

    private static let checkIn = BlindBoxEntry(
        id: "airport_checkin",
        title: "机场值机",
        subtitle: "Airport Check-in",
        category: "旅行"
    )

    private static let interview = BlindBoxEntry(
        id: "job_interview",
        title: "面试问答",
        subtitle: "Job Interview",
        category: "职场"
    )
}
