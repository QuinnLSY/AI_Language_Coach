import AIDomain
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 快捷键提示行 + 「重试」按钮的**离屏渲染**回归（#279–#283 的界面部分）。
///
/// 与同目录另几支渲染测试同款理由：验证环境熄屏，一律离屏出图；断言只钉
/// 「用户真能看见」—— 布局高度差 + 逐像素差分，不钉具体色值
/// （离屏过一次色彩空间换算，绝对色值本来也不可靠）。
///
/// 两条断言各自对应一个「看不见就等于没做」的点：
/// ① 复习卡上的按键提示行真的画出来了（改了键还显示旧键 = 界面在撒谎，前提是先画出来）；
/// ② 失败提示上的「重试」那颗胶囊真的画出来了（只给文案不给按钮，等于让用户自己找原按钮）。
@MainActor
final class ShortcutUIRenderTests: XCTestCase {

    private var window: NSWindow?
    private let cardWidth: CGFloat = 620
    private let now = Date(timeIntervalSince1970: 1_789_000_000)

    // MARK: - 造数据

    private func entries() -> [VocabularyEntry] {
        [
            VocabularyEntry(word: "coffee", meaning: "咖啡", mastery: 1, reviewCount: 2),
            VocabularyEntry(word: "sustainable", meaning: "可持续的", mastery: 0)
        ]
    }

    // MARK: - 离屏渲染

    private struct Render {
        var rep: NSBitmapImageRep
        var size: CGSize
    }

    private func render(_ view: AnyView, day: Bool = true, width: CGFloat? = nil) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: day ? .day : .night, systemIsDark: !day)
        let backdrop: Color = day ? Color(hex: 0xE9EFE4) : Color(hex: 0x101B2E)
        let target = width ?? cardWidth
        let host = NSHostingView(rootView: AnyView(
            view.forestTheme(theme).frame(width: target).background(backdrop)
        ))
        host.frame = NSRect(x: 0, y: 0, width: target, height: 200)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        // 两趟：先问出自然高度，再按自然高度出图，避免把内容裁掉。
        let size = CGSize(width: target, height: max(80, ceil(host.fittingSize.height)))
        host.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep, size: size)
    }

    /// 两版之间真的变了的像素数（阈值内的小数差异不算）。
    private func changedPixels(_ rep: NSBitmapImageRep, _ baseline: NSBitmapImageRep) -> Int {
        let width = min(rep.pixelsWide, baseline.pixelsWide)
        let height = min(rep.pixelsHigh, baseline.pixelsHigh)
        var count = 0
        for x in 0..<width {
            for y in 0..<height {
                guard let a = rep.colorAt(x: x, y: y), let b = baseline.colorAt(x: x, y: y) else { continue }
                let delta = abs(a.redComponent - b.redComponent)
                    + abs(a.greenComponent - b.greenComponent)
                    + abs(a.blueComponent - b.blueComponent)
                if delta > 0.12 { count += 1 }
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

    // MARK: - ① 复习卡的按键提示行

    /// 给了提示就得多出一行 —— 否则「改过键、卡上跟着变」这件事用户根本看不到。
    ///
    /// 提示读的是**当前绑定**（出厂：空格 / 1 / 2 / R），这里按出厂键出图。
    func testReviewCardDrawsTheHotkeyRow() throws {
        let session = VocabularyReviewSession(entries: entries(), now: now)
        let plain = try render(AnyView(VocabularyReviewCard(session: session)))
        let hinted = try render(AnyView(
            VocabularyReviewCard(
                session: session,
                hints: ReviewShortcutHints(bindings: ShortcutBindingArchive.defaults())
            )
        ))

        XCTAssertGreaterThan(
            hinted.size.height, plain.size.height + 10,
            "按键提示行必须真的占一块高度（差 \(hinted.size.height - plain.size.height)pt）"
        )
        XCTAssertGreaterThan(
            changedPixels(hinted.rep, plain.rep), 300,
            "提示行不能只是「占了位置」—— 得真有内容被画出来"
        )

        try dump(plain.rep, name: "shortcut-review-card-plain.png")
        try dump(hinted.rep, name: "shortcut-review-card-hints.png")
    }

    // MARK: - ② 失败提示上的「重试」

    /// 同一句话，带动作与不带动作长得**明显不一样**（多一颗黄底胶囊）。
    func testNoticeBannerDrawsTheRetryButton() throws {
        let text = "「coffee」释义失败：AI 大脑还没启动，先在设置里点绿色的「启动」。"
        let plain = try render(AnyView(NoticeBanner(notice: AppNotice(text: text))), width: 520)
        let retry = try render(AnyView(
            NoticeBanner(notice: AppNotice(text: text, action: .retry {}))
        ), width: 520)

        XCTAssertGreaterThan(
            changedPixels(retry.rep, plain.rep), 400,
            "「重试」那颗胶囊必须真的画出来：只给一句「失败了」用户得自己去找原按钮"
        )

        try dump(plain.rep, name: "shortcut-notice-plain.png")
        try dump(retry.rep, name: "shortcut-notice-retry.png")
    }

    /// 带动作的提示要换成**警示图标**（一眼分得出「要我做点什么」和「只是说一声」）。
    func testRetryableNoticeLooksDifferentFromPlainNotice() throws {
        let plain = try render(AnyView(
            NoticeBanner(notice: AppNotice(text: "「coffee」已加入复习列表。"))
        ), width: 520)
        let retryable = try render(AnyView(
            NoticeBanner(notice: AppNotice(text: "「coffee」释义失败：连接不上。", action: .retry {}))
        ), width: 520)
        XCTAssertGreaterThan(changedPixels(retryable.rep, plain.rep), 400)
    }
}
