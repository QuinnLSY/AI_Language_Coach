import AIDomain
import AppCore
import AppKit
import SwiftUI

/// 学习报告导出（#210）：把年度学习记录卡离屏渲染成 PNG，供用户分享 / 留档。
///
/// 渲染套路与 `*RenderTests` 的 `dump()` 同源（NSHostingView + `cacheDisplay`），
/// 但这里是**产品能力**不是测试件：渲染的是用户真实数据，走当前主题（日夜跟随界面），
/// 不带任何调试水印。导出成图片而不是 PDF：微信 / 朋友圈直接发，无需再转一道。
/// 渲染与保存面板都必须在主线程（AppKit 约束 + Swift 6 严格并发）。
@MainActor
enum ReportExporter {

    /// 默认导出宽度：年度卡在进度页里约 640–720pt，取 760 留一点呼吸位。
    static let defaultWidth: CGFloat = 760

    /// 把年度学习记录卡渲染成 PNG 数据。失败返回 nil（调用方如实报错）。
    static func annualRecapPNG(recap: AnnualRecap, theme: ForestTheme, width: CGFloat = defaultWidth) -> Data? {
        let card = AnnualRecapCard(recap: recap)
            .forestTheme(theme)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color.clear)
        return renderPNG(view: card, width: width)
    }

    /// 离屏渲染任意视图为 PNG：两趟布局（先量自然高度，再按最终尺寸出图）。
    private static func renderPNG(view: some View, width: CGFloat) -> Data? {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 100)
        host.layoutSubtreeIfNeeded()

        let height = max(60, ceil(host.fittingSize.height))
        let size = CGSize(width: width, height: height)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        // 2x 出图：分享出去在小屏上也清晰（fittingSize 量出的是 pt，出图按像素）。
        rep.size = size
        return rep.representation(using: .png, properties: [:])
    }

    /// 弹保存面板导出年度卡 PNG。返回 false = 用户取消。
    @discardableResult
    static func exportAnnualRecapPanel(
        recap: AnnualRecap,
        theme: ForestTheme
    ) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "学习报告_\(Self.fileStamp(Date())).png"
        panel.message = "把年度学习记录导出成图片（跟随当前日夜主题）"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            guard let data = annualRecapPNG(recap: recap, theme: theme) else {
                throw AppError.configuration("渲染学习报告失败，请重试")
            }
            try data.write(to: url)
            return true
        } catch {
            NSSound.beep()
            return false
        }
    }

    private static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
