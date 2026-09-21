import AIDomain
import AppKit
import SwiftUI
@testable import AppUI
import XCTest

/// 顽固音素卡的**离屏渲染**回归（进阶 ③）。
///
/// 只钉三件用户真能看见的事：① 卡片有实际高度（不是空的）；② 名单变长卡片跟着变高
/// （说明每一行都真画出来了）；③ 专项激活时会多出「回到今日跟读」那一行。
/// 顺带把 PNG 落到 `.workbuddy/verify/` 供人眼复核。
///
/// ⚠️ 不比对绝对色值 —— 离屏渲染过一道色彩空间换算，绝对值不可靠；一律用**布局差**。
/// ⚠️ 全程不写 UserDefaults / 配置 / 数据库，卡片是纯展示组件，不需要 AppState。
@MainActor
final class PhonemeWeaknessCardRenderTests: XCTestCase {

    private var window: NSWindow?
    private let cardWidth: CGFloat = 460

    private struct Render {
        let rep: NSBitmapImageRep
        let size: CGSize
    }

    // MARK: - 造数据

    private func weaknesses(_ count: Int) -> [PhonemeWeakness] {
        let all = [
            PhonemeWeakness(phoneme: "TH", missCount: 7, sampleCount: 12, averageScore: 0.31),
            PhonemeWeakness(phoneme: "R", missCount: 5, sampleCount: 9, averageScore: 0.42),
            PhonemeWeakness(phoneme: "IY", missCount: 3, sampleCount: 8, averageScore: 0.55),
        ]
        return Array(all.prefix(count))
    }

    private func render(
        weaknesses: [PhonemeWeakness],
        isDrillActive: Bool = false,
        activePhoneme: String? = nil,
        day: Bool
    ) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: day ? .day : .night, systemIsDark: !day)
        let backdrop: Color = day ? Color(hex: 0xF3F7EF) : Color(hex: 0x101B2E)
        let host = NSHostingView(rootView: AnyView(
            PhonemeWeaknessCard(
                weaknesses: weaknesses,
                isDrillActive: isDrillActive,
                activePhoneme: activePhoneme,
                onStart: { _ in },
                onExit: {}
            )
            .forestTheme(theme)
            .frame(width: cardWidth)
            .background(backdrop)
        ))
        host.frame = NSRect(x: 0, y: 0, width: cardWidth, height: 160)
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

    /// 数出与左上角底色不同的像素（位图是 2x，返回点数已换算成点数）。
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

    // MARK: - ① 卡片不是空的

    func testCardHasRealHeight() throws {
        let rendered = try render(weaknesses: weaknesses(3), day: true)
        XCTAssertGreaterThan(rendered.size.height, 110, "三个音素的卡片要有实际高度")
    }

    // MARK: - ② 名单变长，卡片跟着变高

    func testMoreWeaknessesGrowTheCard() throws {
        let one = try render(weaknesses: weaknesses(1), day: true)
        let three = try render(weaknesses: weaknesses(3), day: true)
        XCTAssertGreaterThan(
            three.size.height, one.size.height + 40,
            "每多一个音素就多一行 —— 卡没跟着长高说明行没画出来"
        )
    }

    // MARK: - ③ 专项激活时多出「回到今日跟读」

    func testDrillActiveAddsTheExitRow() throws {
        let idle = try render(weaknesses: weaknesses(2), day: true)
        let active = try render(weaknesses: weaknesses(2), isDrillActive: true, activePhoneme: "TH", day: true)
        XCTAssertGreaterThan(
            active.size.height, idle.size.height + 12,
            "进入专项后要给一条退路，否则用户被困在四句词对里"
        )
    }

    // MARK: - 出图

    func testDumpsDayAndNight() throws {
        let day = try render(weaknesses: weaknesses(3), day: true)
        let night = try render(weaknesses: weaknesses(3), day: false)
        XCTAssertGreaterThan(changedPixels(day.rep, night.rep), 500, "日夜两档必然不同（这条只是防漏 refresher）")

        let active = try render(
            weaknesses: weaknesses(3), isDrillActive: true, activePhoneme: "TH", day: true
        )
        try dump(day.rep, name: "phoneme-weakness-card-day.png")
        try dump(night.rep, name: "phoneme-weakness-card-night.png")
        try dump(active.rep, name: "phoneme-weakness-card-drilling-day.png")
    }
}
