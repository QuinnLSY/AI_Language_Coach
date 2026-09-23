import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 对话区顶部那条「上一段练习已自动复盘」回执的**离屏渲染**回归（用户 2026-09-23 需求 2）。
///
/// 只钉用户真能看见的那一件事：**带动作的回执在右端多出一颗胶囊**，
/// 而只说一句的提示右端是空的。
///
/// ⚠️ 不做文字断言：离屏图上读不出字，所以走**几何**——
/// 比较「有动作 / 没动作」两张图，差异必须落在横条的右端一小块里。
/// ⚠️ `.help` 与合成点击测不了（见技能 `macos-ui-verify` 的「测不了三样」），
/// 「点了跳去哪一条」由 `PracticeNoticeTests` 钉数据、`AnnualRecapRenderTests` 钉落点。
@MainActor
final class PracticeNoticeRenderTests: XCTestCase {

    private var window: NSWindow?

    private let canvas = CGSize(width: 900, height: 640)
    private let text = "上一段练习已自动复盘，内容已收进学习记录。"

    // MARK: - 渲染

    private struct Render {
        var rep: NSBitmapImageRep
        /// 位图像素 / 视图点（按 pt 写断言时必须过这一道）。
        var scale: CGFloat
    }

    private func renderStrip(_ notice: AppNotice) throws -> Render {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("alc-notice-render-\(UUID().uuidString).json")
        )
        let state = AppState(services: CoachServices(config: store, databasePath: ":memory:"))
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let host = NSHostingView(rootView: AnyView(
            ChatView(
                chat: state.chat,
                modelName: "stub-model",
                health: state.health,
                practiceNotice: notice,
                onDismissPracticeNotice: {}
            )
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

    private func dump(_ render: Render, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(render.rep.representation(using: .png, properties: [:]), "PNG 编码失败")
        try png.write(to: directory.appendingPathComponent(name))
    }

    // MARK: - ① 带动作的回执，右端多一颗胶囊

    /// 反证：把 `ChatView.practiceNoticeBanner` 里 `if let action` 那一段删掉 → 右端墨迹不变 → 变红。
    func testReceiptWithActionDrawsTheCapsuleOnTheRight() throws {
        let plain = try renderStrip(AppNotice(text: text))
        let plainAgain = try renderStrip(AppNotice(text: text))
        let actioned = try renderStrip(
            AppNotice(text: text, action: NoticeAction(title: "去看复盘") {})
        )

        // 噪声地板：同一份输入两次之间，右端**任何**一带都不该多出墨迹。
        XCTAssertLessThan(
            widestRightChange(plain, plainAgain), 300,
            "同一份输入的两次渲染之间，右端不该出现墨迹变化（只允许零星散点）"
        )

        let delta = widestRightChange(plain, actioned)
        XCTAssertGreaterThan(
            delta, 800,
            "带动作的回执必须在横条右端多画出一颗胶囊；实测最多只差 \(delta) 像素"
        )
        try dump(plain, name: "round34-notice-strip-without-action.png")
        try dump(actioned, name: "round34-notice-strip-with-action.png")
    }

    /// 扫遍整页，找「加了动作之后右端墨迹多出最多」的那一带，返回那个差值（像素）。
    ///
    /// ⚠️ 不写死横条的纵坐标：它是对话区 `VStack` 里的一块，位置随窗口高度走。
    /// 也不能只看「差异像素的包围盒」——胶囊比一行字高，横条会长高几 pt，
    /// 上面那块弹性消息区跟着让位、内容整体挪动，包围盒会横跨大半页，
    /// 「在不在右端」就判不出来了（实测包围盒 226–526pt，而横条在 496–540pt）。
    private func widestRightChange(_ plain: Render, _ actioned: Render) -> Int {
        var widest = 0
        for top in stride(from: CGFloat(0), to: canvas.height - 20, by: 10) {
            let before = ink(plain, fromPt: top, toPt: top + 10, xFromRatio: 0.72)
            let after = ink(actioned, fromPt: top, toPt: top + 10, xFromRatio: 0.72)
            widest = max(widest, after - before)
        }
        return widest
    }

    /// `fromPt..<toPt` 这一带里、横向 `xFromRatio` 往右那一段「与底色不同」的像素数。
    ///
    /// 底色取**同一带最左侧两像素处**（横条自己的底色）——不写死色值：
    /// 离屏渲染会过一次色彩空间转换，而且这条横条用的是 `surfaceAlt` 的半透明叠色。
    private func ink(_ render: Render, fromPt: CGFloat, toPt: CGFloat, xFromRatio: CGFloat) -> Int {
        let rep = render.rep
        let scale = max(render.scale, 1)
        let fromY = max(Int(fromPt * scale), 0)
        let toY = min(Int(toPt * scale), rep.pixelsHigh)
        guard fromY < toY else { return 0 }
        let fromX = min(Int(CGFloat(rep.pixelsWide) * xFromRatio), rep.pixelsWide - 1)
        guard let background = rep.colorAt(x: 1, y: fromY + 1) else { return 0 }
        var count = 0
        for y in fromY..<toY {
            for x in fromX..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let delta = abs(color.redComponent - background.redComponent)
                    + abs(color.greenComponent - background.greenComponent)
                    + abs(color.blueComponent - background.blueComponent)
                if delta > 0.08 { count += 1 }
            }
        }
        return count
    }
}
