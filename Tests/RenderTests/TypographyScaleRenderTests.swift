import AppCore
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 探针的两分支修饰（文件内私有，不属于被测代码）。
private extension View {
    @ViewBuilder func horizontalPadding(tokens: Bool, _ length: CGFloat) -> some View {
        if tokens { self.appPadding(.horizontal, length) } else { self.padding(.horizontal, length) }
    }

    @ViewBuilder func verticalPadding(tokens: Bool, _ length: CGFloat) -> some View {
        if tokens { self.appPadding(.vertical, length) } else { self.padding(.vertical, length) }
    }
}

/// 排版档位（#416）离屏回归。
///
/// 两条判据，各盯一种失效方式：
/// ①**等价性**：标准档渲染与旧写法（裸 `.font` / `.padding`）**逐像素一致** ——
///   1154 处 `.appFont` + 320 处 `.appPadding` 是机械替换，替换错一处（参数错位、
///   默认值漂移）都会在这里炸出差异。单测钉了 `Font` 相等，这里钉最终成像。
/// ②**档位真的生效**：宽松 > 标准 > 紧凑（纵向留白）、大 > 小（字号）——
///   断言用**布局高度差**（量墨的行范围），不比色值（离屏过色彩空间换算）。
@MainActor
final class TypographyScaleRenderTests: XCTestCase {

    private var window: NSWindow?

    // MARK: - 探针

    /// 同一份内容的两种写法：`tokens: true` 走新令牌，`false` 走旧字面量。
    /// 内容、布局结构完全一致 —— 差异只允许来自「档位换算」本身。
    private struct ProbeView: View {
        let tokens: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                if tokens {
                    Text("字号与密度探针 Title")
                        .appFont(17, weight: .semibold, design: .rounded)
                    Text("正文用来量高度：the quick brown fox jumps over the lazy dog 0123456789。")
                        .appFont(12)
                } else {
                    Text("字号与密度探针 Title")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text("正文用来量高度：the quick brown fox jumps over the lazy dog 0123456789。")
                        .font(.system(size: 12))
                }
            }
            .horizontalPadding(tokens: tokens, 28)
            .verticalPadding(tokens: tokens, 18)
            .frame(width: 240, alignment: .leading)
            .background(Color.white)
            // 底缘贴一条 2pt 黑线：padding 是白底、量墨量不到，
            // 有了它「墨的范围 = 探针的范围」，密度档的高度差才可断言。
            // 两分支同样画线，不影响等价性对比。
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.black).frame(height: 2)
            }
        }
    }

    // MARK: - 出图与量墨

    /// 渲染探针，返回位图。
    ///
    /// 探针包进一整幅 240×300 的白底容器：量墨时「白」才有唯一含义 ——
    /// 直接用宿主的话，探针之外的画布是窗口底色（不是纯白），会把量墨范围污染到
    /// 探针本体之外（实测紧凑档反而量出更高，就是被它坑的）。
    private func capture(tokens: Bool,
                         typeSize: FontSizeMode = .regular,
                         density: DensityMode = .regular,
                         dump name: String? = nil) throws -> NSBitmapImageRep {
        let probe = ProbeView(tokens: tokens)
        let inner: AnyView = tokens
            ? AnyView(probe.appTypographyRoot(typeSize: typeSize, density: density))
            : AnyView(probe)
        let root = AnyView(
            ZStack(alignment: .top) {
                Color.white
                inner
            }
            .frame(width: 240, height: 300)
        )
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: CGSize(width: 240, height: 300))
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        // 多趟布局：弹簧/淡入要跑完，否则量到中途尺寸（实测能飘几十 pt）。
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let name {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: directory.appendingPathComponent(name))
            }
        }
        return rep
    }

    /// 白底上「有墨」的行范围（pt）。探针贴顶，量到的就是内容高度。
    private func inkExtent(of rep: NSBitmapImageRep) throws -> (top: CGFloat, bottom: CGFloat) {
        let width = rep.pixelsWide, height = rep.pixelsHigh
        let scale = Double(height) / 300.0
        guard let data = rep.bitmapData else { throw XCTSkip("拿不到位图数据") }
        var top = CGFloat.greatestFiniteMagnitude, bottom = CGFloat(-1)
        for y in 0..<height {
            var hasInk = false
            var x = 0
            while x < width {
                let o = (y * width + x) * 4
                // 白底 (255,255,255)；任何明显偏离都算墨。
                if abs(Int(data[o]) - 255) > 12
                    || abs(Int(data[o + 1]) - 255) > 12
                    || abs(Int(data[o + 2]) - 255) > 12 {
                    hasInk = true
                    break
                }
                x += 2
            }
            if hasInk {
                top = min(top, CGFloat(y) / scale)
                bottom = max(bottom, CGFloat(y) / scale)
            }
        }
        XCTAssertTrue(bottom >= 0, "探针一帧墨都没有：夹具坏了")
        return (top, bottom)
    }

    private func pixelDiffCount(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        guard let da = a.bitmapData, let db = b.bitmapData else { return Int.max }
        let width = min(a.pixelsWide, b.pixelsWide), height = min(a.pixelsHigh, b.pixelsHigh)
        var count = 0
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                if abs(Int(da[o]) - Int(db[o])) > 8
                    || abs(Int(da[o + 1]) - Int(db[o + 1])) > 8
                    || abs(Int(da[o + 2]) - Int(db[o + 2])) > 8 {
                    count += 1
                }
            }
        }
        return count
    }

    // MARK: - 用例

    /// 等价性：标准档令牌渲染 == 旧写法渲染（逐像素）。
    ///
    /// 反证：把 `AppTypography.standard` 的 `verticalScale` 改成 1.05 → 探针变高，
    /// 差异点数暴涨，本用例精确红。
    func testStandardTierRendersIdenticallyToLegacy() throws {
        let tokenFrame = try capture(tokens: true, dump: "typography-token-standard.png")
        let legacyFrame = try capture(tokens: false, dump: "typography-legacy.png")
        let diff = pixelDiffCount(tokenFrame, legacyFrame)
        XCTAssertEqual(diff, 0, "标准档与旧写法差 \(diff) 个像素：批量替换引入了可见回归")
    }

    /// 密度档：纵向留白三档必须单调（宽松 > 标准 > 紧凑）。
    func testDensityTiersMonotonicallyChangeHeight() throws {
        let compact = try inkExtent(of: capture(tokens: true, density: .compact, dump: "typography-compact.png"))
        let regular = try inkExtent(of: capture(tokens: true, density: .regular, dump: "typography-regular.png"))
        let spacious = try inkExtent(of: capture(tokens: true, density: .spacious, dump: "typography-spacious.png"))
        let compactHeight = compact.bottom - compact.top
        let regularHeight = regular.bottom - regular.top
        let spaciousHeight = spacious.bottom - spacious.top
        XCTAssertGreaterThan(
            spaciousHeight, regularHeight,
            "宽松档 (\(spaciousHeight)) 必须比标准档 (\(regularHeight)) 高"
        )
        XCTAssertGreaterThan(
            regularHeight, compactHeight,
            "标准档 (\(regularHeight)) 必须比紧凑档 (\(compactHeight)) 高"
        )
    }

    /// 字号档：大字的文本块必须比小字高（同宽 → 换行更多/行更高）。
    func testTypeSizeTiersChangeTextHeight() throws {
        let small = try inkExtent(of: capture(tokens: true, typeSize: .small))
        let large = try inkExtent(of: capture(tokens: true, typeSize: .large))
        let smallHeight = small.bottom - small.top
        let largeHeight = large.bottom - large.top
        XCTAssertGreaterThan(largeHeight, smallHeight, "大字档 (\(largeHeight)) 必须比小字档 (\(smallHeight)) 高")
    }
}
