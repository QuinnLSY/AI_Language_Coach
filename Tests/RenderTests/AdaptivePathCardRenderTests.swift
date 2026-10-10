import AIDomain
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 学习建议卡（⑤ 自适应学习路径）的**离屏渲染**回归。
///
/// 断言只钉「用户真能看见」这件事：同一张卡只切一个输入，看画面到底变没变。
/// 档位色 / 图标 / 文案三处差异里，色值在离屏过后会被色彩空间换算吃掉，所以一律比**差分与高度**。
@MainActor
final class AdaptivePathCardRenderTests: XCTestCase {

    private var window: NSWindow?
    private let cardWidth: CGFloat = 620

    private struct Render {
        let rep: NSBitmapImageRep
        let size: CGSize
    }

    // MARK: - 造数据

    private func path(
        stance: AdaptivePathStance,
        reasons: [String] = [
            "学习记忆里有 3 处反复错还没练掉",
            "最近 8 轮每轮平均被纠 0.62 次，比之前的 0.31 多了",
        ],
        actions: [LearningPlanFocus.Action] = [.errorDrill, .phonemeDrill]
    ) -> AdaptivePath {
        AdaptivePath(stance: stance, reasons: reasons, nextActions: actions)
    }

    // MARK: - 渲染

    private func render(_ path: AdaptivePath, day: Bool = true) throws -> Render {
        try render(AnyView(AdaptivePathCard(path: path) { _ in }), day: day)
    }

    private func render(_ view: AnyView, day: Bool) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: day ? .day : .night, systemIsDark: !day)
        let backdrop: Color = day ? Color(hex: 0xE9EFE4) : Color(hex: 0x101B2E)
        let host = NSHostingView(rootView: AnyView(
            view.forestTheme(theme).frame(width: cardWidth).background(backdrop)
        ))
        host.frame = NSRect(x: 0, y: 0, width: cardWidth, height: 200)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        // 两趟：先问出自然高度，再按自然高度出图，否则内容会被裁掉。
        let size = CGSize(width: cardWidth, height: max(60, ceil(host.fittingSize.height)))
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
        let first = try render(path(stance: .reinforce))
        let second = try render(path(stance: .reinforce))
        XCTAssertLessThanOrEqual(diff(first.rep, second.rep).count, 100,
                                 "同一状态两趟出图差异应接近 0")
    }

    /// 换档位必须看得出来：图标、结论、配色三处一起变。
    /// ⚠️ 只比差分不比高度 —— 两种档位的行数可能一样，高度差为 0 不代表画对了。
    func testStanceChangesThePicture() throws {
        let reinforce = try render(path(stance: .reinforce))
        let advance = try render(path(stance: .advance))
        XCTAssertGreaterThan(diff(reinforce.rep, advance.rep).count, 200,
                             "换档位必须连画面一起换，实测变化像素 \(diff(reinforce.rep, advance.rep).count)")
    }

    /// 依据行必须真的画出来：撤掉理由 → 明显变矮 + 有差分。
    func testReasonLinesAreActuallyDrawn() throws {
        let withReasons = try render(path(stance: .consolidate))
        let without = try render(path(stance: .consolidate, reasons: []))
        XCTAssertGreaterThan(diff(withReasons.rep, without.rep).count, 200,
                             "依据必须画出来，实测 \(diff(withReasons.rep, without.rep).count)")
        XCTAssertGreaterThan(withReasons.size.height, without.size.height + 12,
                             "少两行依据应明显变矮，实测 \(without.size.height) vs \(withReasons.size.height)")
    }

    /// 只有**一个**下一步时不画那排小胶囊：多一个动作 → 多出一行。
    ///
    /// ⚠️ 这条**只能用高度**，不能用差分：多出来的胶囊在图片**最下方**，
    /// 而逐像素比对是按两张图里较矮的那份裁齐的 —— 那几行正好被裁掉，
    /// 差分恒 0（本轮实测踩到：110 → 137 明显更高，差分却是 0）。
    func testExtraActionsAddAChipRow() throws {
        let single = try render(path(stance: .reinforce, actions: [.errorDrill]))
        let multiple = try render(path(stance: .reinforce, actions: [.errorDrill, .phonemeDrill]))
        XCTAssertGreaterThan(multiple.size.height, single.size.height + 15,
                             "多一枚动作胶囊应多出一行，实测 \(single.size.height) → \(multiple.size.height)")
    }

    /// 主按钮必须真的在：撤掉下一步（空数组）后画面要变 —— 否则「接着做」是画着玩的。
    func testPrimaryActionIsActuallyDrawn() throws {
        let withAction = try render(path(stance: .advance, actions: [.conversation]))
        let without = try render(path(stance: .advance, actions: []))
        XCTAssertGreaterThan(diff(withAction.rep, without.rep).count, 300,
                             "「接着做」那一行必须真的画出来，实测 \(diff(withAction.rep, without.rep).count)")
        XCTAssertGreaterThan(withAction.size.height, without.size.height + 20,
                             "少了主按钮应明显变矮，实测 \(without.size.height) vs \(withAction.size.height)")
    }

    /// 四种档位都得画得出来（防止某个 case 落进空视图）。
    func testEveryStanceRenders() throws {
        for stance in AdaptivePathStance.allCases {
            let rendered = try render(path(stance: stance))
            XCTAssertGreaterThan(rendered.size.height, 60, "\(stance.rawValue) 实测高度 \(rendered.size.height)")
        }
    }

    func testRendersInBothThemesAndDumpsPNG() throws {
        let day = try render(path(stance: .reinforce), day: true)
        let night = try render(path(stance: .reinforce), day: false)
        XCTAssertGreaterThan(day.size.height, 100)
        XCTAssertGreaterThan(night.size.height, 100)
        dump(day.rep, name: "round45-adaptive-path-day")
        dump(night.rep, name: "round45-adaptive-path-night")
    }
}
