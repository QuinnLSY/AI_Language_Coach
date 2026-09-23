@testable import AppUI
import SwiftUI
import XCTest

/// 展开块的出现方式（任务 #2）：复盘展开必须**原地淡入**，
/// 不许从卡片上方滑进来。`.move(edge: .top)` 的位移量等于内容自身高度 ——
/// 复盘很高时整块溢出卡片边界，用户看到「复盘内容穿透了卡片、
/// 从对话记录顶部冒出来」。
///
/// 确定性做法 —— **抓动画中途的那一帧**：
/// 给插入挂一个 5 秒的线性长动画、出图前**不做任何等待**，
/// 于是无论机器多忙，截到的那一帧进度都远不到 10%：
/// - 淡入（修复后）：内容 alpha 还接近 0，上边缘那一带**永远不会**有墨；
/// - 滑入（修复前）：内容还有 9 成高度悬在顶边之上，那一带被涂上墨。
///
/// 反证：把 `DisclosureBlockAppearance.transition` 临时改回 `.move(edge: .top)` →
/// 中途帧的上边缘带出现大量墨 → 变红。
///
/// 纯 SwiftUI 夹具：不碰真实数据、不碰 UserDefaults、没有动物动画要关。
@MainActor
final class RecordsDisclosureRenderTests: XCTestCase {

    private var window: NSWindow?

    /// 夹具几何（pt）：画布 300×220。
    /// 上边缘带 y ∈ [0, 40) —— 「这条记录上面的那一块」；
    /// 展开内容最终落位 y ∈ [40, 160) —— 标题行下面的展开段。
    private let canvas = CGSize(width: 300, height: 220)
    private let bandTop = 0
    private let bandBottom = 40
    private let background = (r: 242, g: 242, b: 242)   // 0.95 灰
    private let ink = (r: 0, g: 0, b: 0)                // 纯黑矩形

    /// 终态夹具：不做动画，直接是展开后的样子。
    private struct FinalFixture: View {
        var body: some View {
            ZStack {
                Rectangle().fill(Color(red: 0.95, green: 0.95, blue: 0.95))
                VStack(spacing: 0) {
                    Color.clear.frame(height: 40)
                    DisclosureBlock {
                        Rectangle().fill(Color.black).frame(height: 120)
                    }
                }
            }
        }
    }

    /// 动画夹具：`onAppear` 里用 **5 秒长动画**把内容插进来。
    /// ⚠️ 状态变更必须发生在 SwiftUI 自己的事务里（`onAppear` 的 `withAnimation`）——
    /// 在测试里改 `host.rootView` 是**不吃** `withAnimation` 事务的（实测直接跳终态）。
    private struct AnimatedFixture: View {
        @State private var show = false
        var body: some View {
            ZStack {
                Rectangle().fill(Color(red: 0.95, green: 0.95, blue: 0.95))
                VStack(spacing: 0) {
                    Color.clear.frame(height: 40)
                    if show {
                        DisclosureBlock {
                            Rectangle().fill(Color.black).frame(height: 120)
                        }
                    }
                }
            }
            .onAppear {
                withAnimation(.linear(duration: 5)) { show = true }
            }
        }
    }

    // MARK: - 出图（⚠️ 故意**不做**收敛等待 —— 要的就是中途帧）

    private func makeHost(animated: Bool) -> NSHostingView<AnyView> {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let fixture = animated ? AnyView(AnimatedFixture()) : AnyView(FinalFixture())
        let content = AnyView(
            fixture.forestTheme(theme)
                .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
                .clipped()
        )
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: canvas)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: canvas)
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        return host
    }

    private func capture(_ host: NSHostingView<AnyView>) throws -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        window?.layoutIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    // MARK: - 像素辅助（与 BubbleActionsRenderTests 同一把尺：逐通道容差 8）

    private func rgba(_ rep: NSBitmapImageRep) throws -> (bytes: [UInt8], width: Int, height: Int) {
        let width = rep.pixelsWide, height = rep.pixelsHigh
        let out = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        rep.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        let data = try XCTUnwrap(out.bitmapData)
        return (Array(UnsafeBufferPointer(start: data, count: width * height * 4)), width, height)
    }

    private func differs(_ pixel: (r: Int, g: Int, b: Int), from reference: (r: Int, g: Int, b: Int)) -> Bool {
        abs(pixel.r - reference.r) > 8 || abs(pixel.g - reference.g) > 8
            || abs(pixel.b - reference.b) > 8
    }

    /// 某个 y 带内与底色不同的像素数（y 用 pt 传入，内部按出图比例换算）。
    private func inkCount(
        _ rep: NSBitmapImageRep, yFrom: Int, yTo: Int, reference: (r: Int, g: Int, b: Int)
    ) throws -> Int {
        let image = try rgba(rep)
        let scale = image.height / Int(canvas.height)
        var count = 0
        for y in (yFrom * scale)..<(yTo * scale) where y < image.height {
            for x in 0..<image.width {
                let offset = (y * image.width + x) * 4
                let pixel = (
                    r: Int(image.bytes[offset]), g: Int(image.bytes[offset + 1]), b: Int(image.bytes[offset + 2])
                )
                if differs(pixel, from: reference) { count += 1 }
            }
        }
        return count
    }

    // MARK: - 断言

    func testDisclosureAppearsInPlaceNotFromAbove() throws {
        // 预热：首帧排版 / 着色器的一次性开销先付掉。
        _ = try capture(makeHost(animated: false))

        // 终态基线：内容真的落在标题行下方（夹具自检），上边缘带干净。
        let baseline = try capture(makeHost(animated: false))
        let baselineContent = try inkCount(baseline, yFrom: 60, yTo: 140, reference: background)
        XCTAssertGreaterThan(
            baselineContent, 1_000,
            "夹具自检失败：终态里展开内容没画出来（实测 \(baselineContent) 像素墨）"
        )
        let baselineBand = try inkCount(baseline, yFrom: bandTop, yTo: bandBottom, reference: background)
        XCTAssertLessThan(baselineBand, 50, "终态里上边缘带不该有墨 —— 夹具几何错了")

        // 中途帧：插入带 5 秒长动画（onAppear 事务）、立即出图（不做任何等待）。
        let midFlight = try capture(makeHost(animated: true))
        let midBand = try inkCount(midFlight, yFrom: bandTop, yTo: bandBottom, reference: background)
        XCTAssertLessThan(
            midBand, 1_000,
            "动画中途上边缘带出现了 \(midBand) 像素墨 —— 展开内容在从上方滑进来（穿透了卡片）"
        )
        try dump(midFlight, name: "round2-disclosure-midflight.png")
        try dump(baseline, name: "round2-disclosure-final.png")
    }

    // MARK: - 出图落盘

    private func dump(_ rep: NSBitmapImageRep, name: String) throws {
        let directory = URL(fileURLWithPath: ".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name))
    }
}
