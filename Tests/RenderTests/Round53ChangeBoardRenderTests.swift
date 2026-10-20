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

    // MARK: - ④ 快捷键中心：一行三个的紧凑版式（#286）

    /// 版式由「一行一个」改为「一行三个」之后，卡片高度必须真的**掉下来**。
    ///
    /// 断言方式刻意**不写死阈值**：先量出「同样一批动作一行一个」的**下界**高度
    /// （只算标题行与行距，连键面、复位箭头、分组标题都不算），再要求卡片真身比这个下界还矮 ——
    /// 那等价于「肯定不是一行一个」。写死阈值的版本会随字号漂移，下界不会。
    ///
    /// 撤掉改动（`LazyVGrid` 改回 `ForEach { row(...) }`）时这条会红。
    ///
    /// ⚠️ 比值阈值 0.85 是随动作数**重新校准**过的（2026-10-20，#617 加了「对话」组）：
    /// 20 个动作时三列实测 410pt / 下界 508pt = 0.81；临时把网格改成两列实测 486pt = 0.96。
    /// 阈值取在两者中间 —— 每加一个**分组**（组头 + 不满一行的残余）比值会往上爬一小截，
    /// 0.85 给这个爬升留了余量，同时两列（0.96）照旧被挡死。
    func testShortcutRowsArePackagedThreePerLine() throws {
        let state = makeState()
        let card = try render(AnyView(ShortcutCenterCard(state: state)), width: 560)
        let oneColumnLowerBound = try oneColumnLowerBoundHeight()

        XCTAssertGreaterThan(card.size.height, 120, "前提：卡片真的画出了东西")
        XCTAssertLessThan(
            card.size.height, oneColumnLowerBound * 0.85,
            "卡片（\(card.size.height)pt）必须明显矮于「一行一个」的下界"
            + "（\(oneColumnLowerBound)pt），否则说明没按三列铺"
        )
        try dump(card.rep, name: "round53-shortcuts-three-per-row-day.png")
    }

    // MARK: - ⑤ 快捷键中心：三列之间的竖线（#293）

    /// 每个分组各自一条，长度只跟「右边那一列有几行格子」走。
    ///
    /// 这一版的事实：复习卡组 4 个动作（第二行只有 1 个格子）、页面跳转组 9 个（排满 3 行）。
    /// 所以前者的两条线**都只有一行高** —— 第二行左边没有相邻的列，画线就是凭空的一截。
    ///
    /// 撤掉 `itemCount > column` 那个保护（悬空线照画）时这条会红。
    func testColumnRulesSpanOnlyRowsThatExist() {
        XCTAssertEqual(ShortcutColumnRules.rows(itemCount: 4, columnCount: 3), [1, 1], "4 项：两行里第二行只有一个格子")
        XCTAssertEqual(ShortcutColumnRules.rows(itemCount: 5, columnCount: 3), [2, 1], "5 项：中间列两行、右列一行")
        XCTAssertEqual(ShortcutColumnRules.rows(itemCount: 9, columnCount: 3), [3, 3], "9 项：排满，两条都到底")
        XCTAssertEqual(ShortcutColumnRules.rows(itemCount: 2, columnCount: 3), [1, 0], "2 项：不该画第二条（右边没有格子）")
        XCTAssertEqual(ShortcutColumnRules.rows(itemCount: 1, columnCount: 3), [0, 0], "1 项：一条都不该画")
        XCTAssertEqual(ShortcutColumnRules.rows(itemCount: 0, columnCount: 3), [0, 0])
    }

    /// x 落在**列间距正中间**，高度按实际行高换算 —— 两者都错的话，线不是在格子正中
    /// 就是在某一行上凭空多出一截。
    func testColumnRulesGeometry() {
        let rules = ShortcutColumnRules(
            itemCount: 9, columnCount: 3, spacing: 12, rowSpacing: 8, color: .clear
        )
        // 宽 324 → 列宽 (324 - 24) / 3 = 100；行高：grid 高 88 = 3 行 × 24 + 2 × 8。
        let items = rules.rules(in: CGSize(width: 324, height: 88))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map(\.x), [106, 218], "列间距正中：100+6 / 200+12+6")
        XCTAssertEqual(items.map(\.height), [88, 88], "9 项排满时两条线都与网格等高")
    }

    /// 竖线**不许贯穿整卡** —— 用户 2026-09-21 特意点出的就是这一条：
    /// 连成一条会让人把两个分组的动作看成一整套。
    ///
    /// 量法：取两条竖线各自的列，数「明显深于卡底」的像素占整条列高的比例。
    /// 实测 0.43（= 两组各 1 行 + 3 行网格 / 224pt 高的卡）；若一路贯穿，比例会到 ≈ 1.0。
    /// 阈值 0.7 两边都留了余量，下限 0.15 挡住「线其实没画出来」这种假绿。
    ///
    /// ⚠️ **底色必须从另一列取样**（这里取最右边缘那条），不能拿「本列最大值」当底色 ——
    /// 整列都是线时本列最大值就是线本身，判据会自指、把「一路贯穿」判成 0（踩过这个坑）。
    func testColumnRulesDoNotRunThroughWholeCard() throws {
        let state = makeState()
        let card = try render(AnyView(ShortcutCenterCard(state: state)), day: true)
        let columnWidth = (card.size.width - 24) / 3
        let scale = Double(card.rep.pixelsWide) / Double(card.size.width)

        func luminance(_ x: Int) -> [Double] {
            (0..<card.rep.pixelsHigh).compactMap { y in
                guard let pixel = card.rep.colorAt(x: x, y: y) else { return nil }
                return 0.299 * pixel.redComponent + 0.587 * pixel.greenComponent
                    + 0.114 * pixel.blueComponent
            }
        }

        let baseline = luminance(card.rep.pixelsWide - 3).max() ?? 1
        for index in 0..<2 {
            let x = columnWidth * Double(index + 1) + 12 * Double(index) + 6
            let values = luminance(Int((x * scale).rounded()))
            let ratio = Double(values.filter { $0 < baseline - 0.10 }.count) / Double(values.count)
            XCTAssertGreaterThan(ratio, 0.15, "第 \(index + 1) 条竖线几乎没画出来（占列高 \(ratio)）")
            XCTAssertLessThan(
                ratio, 0.7,
                "第 \(index + 1) 条竖线贯穿了整卡（占列高 \(ratio)）—— 两个分组会被看成一整套"
            )
        }
    }

    /// 出图：白天 / 夜晚各一张。**线够不够看得见、有没有画歪，只能人眼看** ——
    /// 离屏过色彩空间换算，绝对色值断言不了，能断言的只有它不该顶开布局。
    func testDumpsShortcutColumnRules() throws {
        let state = makeState()
        let lowerBound = try oneColumnLowerBoundHeight()
        let day = try render(AnyView(ShortcutCenterCard(state: state)), day: true)
        let night = try render(AnyView(ShortcutCenterCard(state: state)), day: false)

        // 竖线挂在 `.background` 上、不参与布局：加了它卡片不许长高。
        // （比值 0.85 的校准见 `testShortcutRowsArePackagedThreePerLine` 的注释。）
        XCTAssertLessThan(
            day.size.height, lowerBound * 0.85,
            "加了两列分隔线之后卡片反倒变高（\(day.size.height)pt）—— 线不该参与布局"
        )
        try dump(day.rep, name: "round53-shortcuts-column-rules-day.png")
        try dump(night.rep, name: "round53-shortcuts-column-rules-night.png")
    }

    /// 「13 个动作一行一个」的**下界**高度：只堆标题与行距，别的什么都不加。
    ///
    /// 真·旧版式的每一行还有键面胶囊与复位箭头，所以旧版式只会比它更高 ——
    /// 拿它当下界是安全的（不会出现「旧版式反而比下界矮」这种误判）。
    private func oneColumnLowerBoundHeight() throws -> CGFloat {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let host = NSHostingView(rootView: AnyView(
            VStack(alignment: .leading, spacing: 12) {
                ForEach(ShortcutAction.allCases) { action in
                    Text(action.title).font(.system(size: 11, design: .rounded))
                }
            }
            .forestTheme(theme)
        ))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 100)
        host.layoutSubtreeIfNeeded()
        let height = ceil(host.fittingSize.height)
        XCTAssertGreaterThan(height, 200, "前提：这个下界本身要足够高，否则这条断言没有意义")
        return height
    }
}
