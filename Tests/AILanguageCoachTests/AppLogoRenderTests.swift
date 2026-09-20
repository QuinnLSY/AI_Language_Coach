import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 品牌位图（app 图标 / 侧边栏 logo）的离屏渲染回归。
///
/// 为什么需要它：`AppLogo` 在位图读不到时会**静默**退回内置矢量图 ——
/// 界面照样能看，只是品牌图标没了。这类「降级成功」的故障肉眼很难发现，
/// 必须由断言钉住「包里确实有图，而且画出来的就是它」。
///
/// ⚠️ 断言方式是**对照渲染**而不是比对写死的色值：离屏渲染会过一次色彩空间换算
/// （sRGB 落到位图上饱和度要掉四分之一），绝对色值换台机器就不成立。
/// 同批渲染一张「直接贴位图」的参考图，再要求两者像素几乎一致 —— 自校准。
@MainActor
final class AppLogoRenderTests: XCTestCase {

    private var window: NSWindow?

    // MARK: - 资源真的打进包了

    func testBrandLogoAssetIsInsideTheAppUIBundle() throws {
        let url = try XCTUnwrap(
            UIAssetBundle.brandAssetURL("brand-logo"),
            "资源包里没有 brand-logo.png —— 侧栏会静默退回旧矢量图，打包漏带资源"
        )
        XCTAssertTrue(
            url.path.contains("AILanguageCoach_AppUI.bundle"),
            "品牌位图必须来自 AppUI 资源包，实际路径: \(url.path)"
        )
        let image = try XCTUnwrap(BrandLogo.image, "位图读到了路径却解不出图像")
        XCTAssertGreaterThan(image.size.width, 64, "位图边长太小，36pt @3x 会发糊")
    }

    // MARK: - 画出来的就是位图，不是降级矢量图

    func testLogoDrawsTheBrandBitmapNotTheFallback() throws {
        let image = try XCTUnwrap(BrandLogo.image)
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let side: CGFloat = 96

        let drawn = try render(AnyView(AppLogo(size: side)), theme: theme)
        let reference = try render(AnyView(bitmapReference(image, side: side, theme: theme)), theme: theme)

        let total = drawn.rep.pixelsWide * drawn.rep.pixelsHigh
        let mismatch = differingPixels(drawn.rep, reference.rep)
        XCTAssertGreaterThan(inkCount(drawn.rep), 500, "logo 区域必须真画出东西")
        XCTAssertLessThan(
            Double(mismatch) / Double(total), 0.02,
            "AppLogo 画的应当是品牌位图本身（与直接贴位图的参考图差异 \(mismatch)/\(total)）"
        )
        try dump(drawn.rep, name: "round44-applogo-bitmap-day.png")
    }

    /// 负对照：证明上面那条「差异很小」的判据**真的能把矢量图区分出来**。
    /// 没有这一步，判据退化成「随便画什么都过」。
    func testTheMetricActuallySeparatesTheFallbackVector() throws {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let bitmap = try render(AnyView(AppLogo(size: 96)), theme: theme)
        let vectorish = try render(
            AnyView(
                RoundedRectangle(cornerRadius: 96 * 0.30, style: .continuous)
                    .fill(theme.foliageDeep)
                    .frame(width: 96, height: 96)
            ),
            theme: theme
        )
        let total = bitmap.rep.pixelsWide * bitmap.rep.pixelsHigh
        let mismatch = differingPixels(bitmap.rep, vectorish.rep)
        XCTAssertGreaterThan(
            Double(mismatch) / Double(total), 0.20,
            "负对照差异太小，说明判据分不出品牌位图与旧矢量图，前面的用例等于没测"
        )
    }

    // MARK: - 夜色下同样成立（位图不随主题换色，但阴影要换）

    func testLogoAlsoRendersUnderNightTheme() throws {
        let image = try XCTUnwrap(BrandLogo.image)
        let theme = ForestThemeResolver.resolve(mode: .night, systemIsDark: true)
        let side: CGFloat = 96
        let drawn = try render(AnyView(AppLogo(size: side)), theme: theme)
        let reference = try render(AnyView(bitmapReference(image, side: side, theme: theme)), theme: theme)
        let total = drawn.rep.pixelsWide * drawn.rep.pixelsHigh
        XCTAssertLessThan(
            Double(differingPixels(drawn.rep, reference.rep)) / Double(total), 0.02,
            "夜色下 AppLogo 也应当就是品牌位图本身"
        )
        try dump(drawn.rep, name: "round44-applogo-bitmap-night.png")
    }

    /// 参考图：与 `AppLogo` 位图分支逐字相同的修饰符，只把 Group 换成裸 Image。
    private func bitmapReference(_ image: NSImage, side: CGFloat, theme: ForestTheme) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: side, height: side)
            .shadow(color: theme.shadow, radius: side * 0.12, x: 0, y: side * 0.05)
            .frame(width: side, height: side)
    }

    // MARK: - 离屏渲染脚手架

    private struct Render { var rep: NSBitmapImageRep }

    private func render(_ view: AnyView, theme: ForestTheme) throws -> Render {
        let side: CGFloat = 160
        let backdrop: Color = theme.isNight ? Color(hex: 0x101B2E) : Color(hex: 0xE9EFE4)
        let host = NSHostingView(rootView: AnyView(
            view.forestTheme(theme).frame(width: side, height: side).background(backdrop)
        ))
        host.frame = NSRect(x: 0, y: 0, width: side, height: side)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep)
    }

    /// 与左上角底色不同的像素数（「确实画了东西」）。
    private func inkCount(_ rep: NSBitmapImageRep) -> Int {
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

    private func differingPixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else {
            return a.pixelsWide * a.pixelsHigh
        }
        var count = 0
        for x in 0..<a.pixelsWide {
            for y in 0..<a.pixelsHigh {
                guard let ca = a.colorAt(x: x, y: y), let cb = b.colorAt(x: x, y: y) else { continue }
                let delta = abs(ca.redComponent - cb.redComponent)
                    + abs(ca.greenComponent - cb.greenComponent)
                    + abs(ca.blueComponent - cb.blueComponent)
                if delta > 0.15 { count += 1 }
            }
        }
        return count
    }

    private func dump(_ rep: NSBitmapImageRep, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AILanguageCoachTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]), "PNG 编码失败")
        try png.write(to: directory.appendingPathComponent(name))
    }
}
