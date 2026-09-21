import AIDomain
import AIInfrastructure
import AIServices
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 09-21 这一轮改动的**离屏出图 + 回归**（#277 火苗全红 / #281 快捷键中心）。
///
/// 与同目录另几支渲染测试同款口径：验证环境熄屏，一律离屏出图；断言只钉
/// 「用户真能看见」—— 逐像素差分 + 布局高度差，**不比对绝对色值**
/// （离屏过一次色彩空间换算，色值本来就不可靠）。
///
/// 三件事各一条，每一条对应一个「只改状态、界面没跟着变」会漏掉的点：
/// ① 徽章两态必须**看得出不同**（安全=红 / 断签风险=橘警告）——
///    一样的话「今天还没练」这件事在界面上等于没说；
/// ② 录制中键面必须**变了样**（换成「按下新的键…」+ 实心底）——
///    不变的话用户不知道自己已经进了录制态，按下去只当是没反应；
/// ③ 撞键必须**标出来**—— 不标就是「配着键却按不动」。
@MainActor
final class Round53ChangeBoardRenderTests: XCTestCase {

    private var window: NSWindow?

    private struct Render {
        let rep: NSBitmapImageRep
        let size: CGSize
    }

    // MARK: - 造状态

    /// 一份临时目录里的 AppState。绑定表落在 `UserDefaults.standard`（进程内共享），
    /// 所以每次都从出厂键起步，用例之间才不互相牵连。
    private func makeState() -> AppState {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("round53-probe-\(UUID().uuidString)", isDirectory: true)
        let dictionaryBase = directory.appendingPathComponent("dict", isDirectory: true)
        let state = AppState(services: CoachServices(
            config: ConfigStore(fileURL: directory.appendingPathComponent("config.json")),
            databasePath: ":memory:",
            dictionaryStore: DictionaryBookStore(
                fileURL: dictionaryBase.appendingPathComponent("dictionaries.json"),
                booksDirectory: dictionaryBase.appendingPathComponent("books", isDirectory: true)
            )
        ))
        state.resetAllShortcutBindings()
        return state
    }

    // MARK: - 离屏渲染

    private func render(_ view: AnyView, day: Bool = true, width: CGFloat = 560) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: day ? .day : .night, systemIsDark: !day)
        let backdrop: Color = day ? Color(hex: 0xE9EFE4) : Color(hex: 0x101B2E)
        let host = NSHostingView(rootView: AnyView(
            view.forestTheme(theme).frame(width: width).background(backdrop)
        ))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 200)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        // 两趟：先问出自然高度，再按自然高度出图，避免把内容裁掉。
        let size = CGSize(width: width, height: max(60, ceil(host.fittingSize.height)))
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
                if delta > 0.10 { count += 1 }
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

    // MARK: - ① 火苗徽章（#277：整枚全红）

    private struct StreakBoard: View {
        var atRisk: Bool
        var body: some View {
            HStack(spacing: 10) {
                StreakBadgeView(badge: TodayPanel.StreakBadge(days: 12, isAtRisk: atRisk))
                StreakBadgeView(badge: TodayPanel.StreakBadge(days: 7, isAtRisk: atRisk))
            }
            .padding(14)
        }
    }

    /// 两态必须看得出不同 —— 否则「今天还没练、连续纪录要断了」在界面上等于没说。
    func testStreakBadgeLooksDifferentWhenAtRisk() throws {
        let safeDay = try render(AnyView(StreakBoard(atRisk: false)), day: true)
        let riskyDay = try render(AnyView(StreakBoard(atRisk: true)), day: true)
        let safeNight = try render(AnyView(StreakBoard(atRisk: false)), day: false)
        let riskyNight = try render(AnyView(StreakBoard(atRisk: true)), day: false)

        XCTAssertGreaterThan(
            changedPixels(riskyDay.rep, safeDay.rep), 80,
            "安全态与断签风险态必须画得不一样（实测差分 \(changedPixels(riskyDay.rep, safeDay.rep)) 像素）"
        )
        XCTAssertGreaterThan(
            changedPixels(riskyNight.rep, safeNight.rep), 80,
            "夜档同样要分得开"
        )

        try dump(safeDay.rep, name: "round53-streak-safe-day.png")
        try dump(riskyDay.rep, name: "round53-streak-risk-day.png")
        try dump(safeNight.rep, name: "round53-streak-safe-night.png")
        try dump(riskyNight.rep, name: "round53-streak-risk-night.png")
    }

    // MARK: - ② 快捷键中心：录制态（#281）

    /// 进了录制态，那一行的键面必须明显变了样 —— 否则用户不知道自己已经在录制，
    /// 会以为「点了没反应」接着照原样按键，键就被静默改掉了。
    func testCapturingKeyLooksDifferent() throws {
        let state = makeState()
        let idle = try render(AnyView(ShortcutCenterCard(state: state)), width: 560)

        state.beginShortcutCapture(for: .reviewReveal)
        let capturing = try render(AnyView(ShortcutCenterCard(state: state)), width: 560)

        XCTAssertGreaterThan(
            changedPixels(capturing.rep, idle.rep), 150,
            "录制中键面必须换样（实心底 + 「按下新的键…」）"
        )
        try dump(idle.rep, name: "round53-shortcuts-idle-day.png")
        try dump(capturing.rep, name: "round53-shortcuts-capturing-day.png")

        let night = try render(AnyView(ShortcutCenterCard(state: state)), day: false, width: 560)
        try dump(night.rep, name: "round53-shortcuts-capturing-night.png")
    }

    // MARK: - ③ 快捷键中心：撞键标记

    /// 两个动作绑同一个键时，设置页必须把那一行标出来 ——
    /// 因为真正按下时只有 `allCases` 里靠前那个会响，另一个从界面上看不出任何异常。
    func testConflictMarkerAppears() throws {
        let state = makeState()
        let clean = try render(AnyView(ShortcutCenterCard(state: state)), width: 560)

        // 直接往绑定表里塞一个撞键组合（正常路径会被 `setShortcutBinding` 挡下来，
        // 但历史配置、或以后放宽规则，都可能出现这种表 —— 界面必须能如实标出来）。
        state.shortcutBindings[.reviewRemembered] = state.shortcutBinding(for: .reviewForgotten)
        XCTAssertFalse(
            state.shortcutConflicts(for: .reviewForgotten).isEmpty,
            "前提：这两个动作现在确实撞了"
        )
        let conflicting = try render(AnyView(ShortcutCenterCard(state: state)), width: 560)

        XCTAssertGreaterThan(
            changedPixels(conflicting.rep, clean.rep), 20,
            "撞键必须标出来（警示图标），否则这一行看着好端端的、按下去没反应"
        )
        try dump(conflicting.rep, name: "round53-shortcuts-conflict-day.png")
    }

    /// 反证：不撞键时不该有那个标记 —— 否则上面那条「差分 > 20」可能只是噪声。
    func testNoConflictMarkerOnFactoryBindings() {
        let state = makeState()
        for action in ShortcutAction.allCases {
            XCTAssertTrue(
                state.shortcutConflicts(for: action).isEmpty,
                "出厂状态下 \(action.title) 不该报撞键"
            )
        }
    }
}
