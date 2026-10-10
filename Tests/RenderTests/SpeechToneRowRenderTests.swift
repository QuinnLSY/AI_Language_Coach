import AppCore
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// `SpeechToneRow`（语速 / 调门共用的档位行）的**离屏渲染**回归。
///
/// 断言只钉「用户真能看见」这件事：档位是不是真画出来了、选中态是不是真的变了样子、
/// 加了长标签行会不会跟着变宽。**不比色值** —— 离屏渲染过色彩空间换算，
/// 比色值必然假红；只看「像素变没变」与「尺寸对不对」。
///
/// 阈值先自校准（同一状态连抓两趟取噪声基准），固定阈值在整行重排时会假通过。
@MainActor
final class SpeechToneRowRenderTests: XCTestCase {

    private var window: NSWindow?

    private struct Render {
        let rep: NSBitmapImageRep
        let size: CGSize
    }

    // MARK: - 造数据

    /// 调门档位（真实取值来自 `SpeechPitch`，不手抄一遍）。
    private func pitchOptions(selected: SpeechPitch) -> [SpeechToneRow.Option] {
        SpeechPitch.allCases.map { option in
            SpeechToneRow.Option(
                value: option.rawValue,
                label: option.label,
                help: "以\(option.detail)朗读（只改音高、不改快慢）",
                isSelected: option == selected
            )
        }
    }

    private func row(
        title: String = "朗读调门",
        options: [SpeechToneRow.Option],
        onSelect: @escaping (SpeechToneRow.Option) -> Void = { _ in }
    ) -> SpeechToneRow {
        SpeechToneRow(title: title, options: options, onSelect: onSelect)
    }

    // MARK: - 渲染

    /// `width` 为 nil 时**不约束宽度**，用 `fittingSize` 量自然尺寸 —— 量宽度的用例
    /// 必须走这条路：套上 `.frame(width:)` 再量宽度，量到的永远是那个固定值。
    private func render(_ view: SpeechToneRow, width: CGFloat? = nil, day: Bool = true) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: day ? .day : .night, systemIsDark: !day)
        let backdrop: Color = day ? Color(hex: 0xE9EFE4) : Color(hex: 0x101B2E)
        var content = AnyView(view.forestTheme(theme))
        if let width { content = AnyView(content.frame(width: width)) }
        let host = NSHostingView(rootView: AnyView(content.background(backdrop)))
        host.frame = NSRect(x: 0, y: 0, width: width ?? 640, height: 60)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        // 两趟：先问出自然尺寸，再按自然尺寸出图，否则内容会被裁掉。
        let size = CGSize(
            width: max(60, ceil(host.fittingSize.width)),
            height: max(24, ceil(host.fittingSize.height))
        )
        host.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep, size: size)
    }

    private func diff(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> (mean: Double, count: Int) {
        let width = min(a.pixelsWide, b.pixelsWide)
        let height = min(a.pixelsHigh, b.pixelsHigh)
        var sum = 0.0
        var count = 0
        for x in 0..<width {
            for y in 0..<height {
                guard let ca = a.colorAt(x: x, y: y), let cb = b.colorAt(x: x, y: y) else { continue }
                let delta = abs(ca.redComponent - cb.redComponent)
                    + abs(ca.greenComponent - cb.greenComponent)
                    + abs(ca.blueComponent - cb.blueComponent)
                guard delta > 0.12 else { continue }
                sum += delta
                count += 1
            }
        }
        return (count == 0 ? 0 : sum / Double(count), count)
    }

    private func dump(_ rep: NSBitmapImageRep, name: String) {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".workbuddy/verify")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: directory.appendingPathComponent("\(name).png"))
    }

    // MARK: - 用例

    /// 抓图必须是确定的：同一状态连抓两趟应当几乎无差异。
    /// 这条不过，后面的差分断言全都没有意义。
    func testRenderingIsDeterministic() throws {
        let first = try render(row(options: pitchOptions(selected: .natural)), width: 520)
        let second = try render(row(options: pitchOptions(selected: .natural)), width: 520)
        let noise = diff(first.rep, second.rep)
        XCTAssertLessThanOrEqual(noise.count, 100, "同一状态两趟出图差异应接近 0，实测 \(noise.count)")
    }

    /// 选中态必须**看得出**：换一档，画面要真的变了。
    ///
    /// 反证：把 `isSelected` 写死成 false，这一条立刻报红 —— 而人眼看截图时
    /// 「五档里哪一档亮着」在一张静态图上是看不出来的（要连点才知道）。
    func testSelectionChangesWhatIsDrawn() throws {
        let natural = try render(row(options: pitchOptions(selected: .natural)), width: 520)
        let higher2 = try render(row(options: pitchOptions(selected: .higher2)), width: 520)
        let signal = diff(natural.rep, higher2.rep)
        XCTAssertGreaterThan(signal.count, 100, "选中档位变化必须改变画面，实测变化像素 \(signal.count)")
    }

    /// 换档**不该改变整行高度** —— 档位胶囊只在底色与描边上变，几何不变。
    ///
    /// 反证：把 `strokeBorder` 换成 `stroke`（描边画在边界外侧），选中那一档会
    /// 多占 1pt 高度，整行高度随选中档漂移；症状是「点一下档位，下面所有内容
    /// 跳一下」，很难归因到这颗胶囊上。
    func testSelectionDoesNotChangeRowHeight() throws {
        let natural = try render(row(options: pitchOptions(selected: .natural)), width: 520)
        let lower1 = try render(row(options: pitchOptions(selected: .lower1)), width: 520)
        XCTAssertEqual(
            natural.size.height, lower1.size.height, accuracy: 1,
            "换档不该改变行高，实测 \(natural.size.height) vs \(lower1.size.height)"
        )
    }

    /// 五档必须**都排得下**：档位越多行越宽。
    ///
    /// 反证：给行套一个固定宽度（或把档位塞进不可换行的固定宽度容器），
    /// 五档会被压成同一宽度、靠省略号遮住 —— 而省略号在离屏图里看着像「档位本来就短」。
    func testAllFivePitchOptionsAreLaidOut() throws {
        let five = try render(row(options: pitchOptions(selected: .natural)))
        let one = try render(row(options: [pitchOptions(selected: .natural)[2]]))
        XCTAssertGreaterThan(
            five.size.width, one.size.width + 60,
            "五档应明显比一档宽，实测 \(one.size.width) vs \(five.size.width)"
        )
    }

    /// 标题与档位文案更长 → 行更宽（自然尺寸）。
    ///
    /// 反证：把行宽写死，这一条报红 —— 而写死宽度在真机上表现为「档位标签被截成
    /// 省略号」，截断发生在控件的几何空档里，不刻意量宽度看不出来（2026-09-14 的
    /// 「语速不显示」就是这么来的）。
    func testLongerLabelsWidenTheRow() throws {
        let short = try render(row(title: "调门", options: [
            SpeechToneRow.Option(value: 0, label: "原声", help: "原声", isSelected: true),
        ]))
        let long = try render(row(title: "朗读调门", options: [
            SpeechToneRow.Option(value: 0, label: "原声（不变调）", help: "原声", isSelected: true),
        ]))
        XCTAssertGreaterThan(
            long.size.width, short.size.width + 20,
            "更长的标签应让行更宽，实测 \(short.size.width) vs \(long.size.width)"
        )
    }

    /// 空档位不该崩、也不该画成一条线：仍然是标题那一行的高度。
    func testEmptyOptionsStillRendersTheTitle() throws {
        let empty = try render(row(options: []), width: 520)
        XCTAssertGreaterThan(empty.size.height, 10, "空档位也应有标题高度，实测 \(empty.size.height)")
    }

    func testRendersInBothThemesAndDumpsPNG() throws {
        let day = try render(row(options: pitchOptions(selected: .higher1)), width: 520, day: true)
        let night = try render(row(options: pitchOptions(selected: .higher1)), width: 520, day: false)
        XCTAssertGreaterThan(day.size.height, 10)
        XCTAssertGreaterThan(night.size.height, 10)
        dump(day.rep, name: "round42-speech-tone-row-day")
        dump(night.rep, name: "round42-speech-tone-row-night")
    }
}
