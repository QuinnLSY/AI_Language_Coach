import AIDomain
import AIInfrastructure
import AIServices
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 打卡徽章悬浮卡**在侧栏内部的层级**回归（2026-09-24 第二轮报障）。
///
/// 用户口径：「浮卡要浮在界面最上方，不被任何东西遮挡」。第一轮只把**侧栏整体**
/// 抬到中间栏之上（`MainView` 那处 `.zIndex`），解决了「伸出侧栏那半截」；
/// 但浮卡下半截伸进的是**侧栏自己**的 navList 地盘，而 `header` 与 `navList`
/// 是同一个 `VStack` 的兄弟 —— **更晚的兄弟节点**会画在更早兄弟溢出的浮层之上，
/// 于是「练习」条目的圆角底色把浮卡下半截盖住了。
///
/// 这条用例钉的就是那半截：出图量「浮卡底边到底落到了哪儿」。
/// 断言的**症状**与用户描述完全一致 —— 修复前差异只到 y≈63（头栏底），
/// 导航条目覆盖区一条墨都没有。
///
/// ⚠️ hover 那台状态机在离屏搭不出来 → 走 `AppSidebar.previewShowsStreakTip` 钩子点亮。
/// ⚠️ 判据用**逐像素差异**（同一夹具、只差浮卡开关两帧），不比色值 ——
/// 离屏位图会过一次色彩空间换算。
/// ⚠️ 底部老师角落带 `CuteAnimalView`（`.repeatForever` 跳动），必须关动画，
/// 否则两帧在底部随机不同（详见 FEATURES「带动画的组件永远不稳定」）。
@MainActor
final class SidebarStreakTipLayerRenderTests: XCTestCase {

    private var window: NSWindow?
    /// 侧栏展开尺寸（与 `AppSidebar.expandedWidth` 一致）。
    private let canvas = CGSize(width: 220, height: 700)

    /// 头栏总高（`AppSidebar.body` 里定的 64pt）—— 浮卡从这里往下溢出。
    private let headerHeight = 64

    // MARK: - 离屏渲染

    private func render(showsTip: Bool) throws -> NSBitmapImageRep {
        let saved = CuteAnimalView.animationsEnabled
        CuteAnimalView.animationsEnabled = false
        defer { CuteAnimalView.animationsEnabled = saved }

        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("sidebar-tip-probe-\(UUID().uuidString).json")
        )
        let state = AppState(services: CoachServices(config: store, databasePath: ":memory:"))
        // 徽章只在「连续 ≥1 天」时出现（`TodayPanel.streakBadge` 的守卫），
        // 内存库跑不出连续天数 → 直接给快照（`progressSnapshot` 是 internal(set)，测试可写）。
        var snapshot = ProgressSnapshot.empty()
        snapshot.streakDays = 15
        state.progressSnapshot = snapshot

        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let host = NSHostingView(rootView: AnyView(
            AppSidebar(state: state, previewShowsStreakTip: showsTip)
                .forestTheme(theme)
                .frame(width: canvas.width, height: canvas.height)
        ))
        host.frame = NSRect(origin: .zero, size: canvas)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    // MARK: - 像素度量（一律换算回**点**，别让 Retina 缩放左右阈值）

    private func scale(of rep: NSBitmapImageRep) -> Double {
        Double(rep.pixelsHigh) / Double(canvas.height)
    }

    /// 两帧在一个扫描区（`rows`/`columns` 都用**点**给）里差多少个点。
    ///
    /// ⚠️ 横向也要限定：浮卡右端会伸出侧栏 220pt 之外，而导航条目只到 208 ——
    /// 那一小块**没被盖住**，于是「浮卡被遮」时窗口里仍残留 ~84 点差异（12pt×7pt），
    /// 足以让「差异延伸到导航区」这类判据恒真（反证时亲眼撞上）。
    private func differencePoints(
        _ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep,
        rows: Range<Int>, columns: Range<Int>? = nil
    ) -> Int {
        let width = lhs.pixelsWide, height = lhs.pixelsHigh
        guard let a = lhs.bitmapData, let b = rhs.bitmapData else { return 0 }
        let s = scale(of: lhs)
        // ⚠️ `rows`/`columns` 都是**点**，像素索引必须各乘一次 scale ——
        // 直接拿点值当像素下标的话，2x 下只扫到左半边（实测包围盒被截断在 x=109）。
        let cols = columns ?? 0..<width
        let colFirst = min(max(Int(Double(cols.lowerBound) * s), 0), width - 1)
        let colLast = min(max(Int(Double(cols.upperBound) * s), 0), width - 1)
        var count = 0
        for y in rows {
            let row = min(max(Int(Double(y) * s), 0), height - 1)
            for x in colFirst..<colLast {
                let o = (row * width + x) * 4
                if abs(Int(a[o]) - Int(b[o])) > 8
                    || abs(Int(a[o + 1]) - Int(b[o + 1])) > 8
                    || abs(Int(a[o + 2]) - Int(b[o + 2])) > 8 {
                    count += 1
                }
            }
        }
        return Int(Double(count) / (s * s))
    }

    /// 两帧差异像素的**包围盒**（点坐标，y 自上而下）。
    ///
    /// ⚠️ 必须限定 `rows` 窗口：整图包围盒的 `maxY` 会被侧栏底部老师角落那点
    /// 随机差异（气泡/动物的计时器）顶到最底下，于是「浮卡底边落点」这条判据**恒真**
    /// —— 撤掉 `.zIndex` 也照样绿（实测如此，是典型的「一条断言只对它自己的失效方式敏感」）。
    private func differenceBounds(
        _ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep,
        rows: Range<Int>, columns: Range<Int>
    ) -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        let width = lhs.pixelsWide, height = lhs.pixelsHigh
        guard let a = lhs.bitmapData, let b = rhs.bitmapData else { return nil }
        let s = scale(of: lhs)
        let first = min(max(Int(Double(rows.lowerBound) * s), 0), height - 1)
        let last = min(max(Int(Double(rows.upperBound) * s), 0), height - 1)
        let colFirst = min(max(Int(Double(columns.lowerBound) * s), 0), width - 1)
        let colLast = min(max(Int(Double(columns.upperBound) * s), 0), width - 1)
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in first..<last {
            for x in colFirst..<colLast {
                let o = (y * width + x) * 4
                guard abs(Int(a[o]) - Int(b[o])) > 8
                    || abs(Int(a[o + 1]) - Int(b[o + 1])) > 8
                    || abs(Int(a[o + 2]) - Int(b[o + 2])) > 8 else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxY >= 0 else { return nil }
        return (
            Int(Double(minX) / s), Int(Double(minY) / s),
            Int(Double(maxX) / s), Int(Double(maxY) / s)
        )
    }

    /// 浮卡所在的纵向窗口（点）：从徽章下方一直包到它底边之外一点。
    /// 取窗口是为了把侧栏底部的随机差异排除在包围盒之外（见 `differenceBounds` 的说明）。
    private var tipWindow: Range<Int> { 40..<120 }

    /// 导航条目覆盖区的横向范围（点）：条目铺 x 12..208，两端各让出圆角余量。
    private var navColumns: Range<Int> { 20..<200 }

    // MARK: - 用例

    /// 报障本体：浮卡下半截伸进导航区，必须**看得见**。
    ///
    /// 反证：撤掉 `AppSidebar.header` 上的 `.zIndex(1)` → 两条判据同时精确红
    /// （包围盒 maxY 63、导航带 0 点），因为浮卡下半截被「练习」条目盖住。
    func testStreakTipCardCoversTheNavListInsteadOfBeingCoveredByIt() throws {
        let plain = try render(showsTip: false)
        let withTip = try render(showsTip: true)

        // 自检①：两帧必须同尺寸，否则逐像素对比毫无意义。
        XCTAssertEqual(plain.pixelsWide, withTip.pixelsWide, "两帧宽度不一致")
        XCTAssertEqual(plain.pixelsHigh, withTip.pixelsHigh, "两帧高度不一致")

        // 自检②：浮卡确实点亮了 —— 头栏内（徽章下方那一段）必须有差异。
        // 没有这条的话，「浮卡根本没画出来」会被下面两条判据混过去（那样也「不遮挡」）。
        let inHeader = differencePoints(
            plain, withTip, rows: 46..<headerHeight - 2, columns: navColumns
        )
        XCTAssertGreaterThan(
            inHeader, 300,
            "夹具自检失败：头栏内没有浮卡的墨（实测 \(inHeader) 点）—— 钩子或徽章没生效"
        )

        // 判据①：浮卡底边必须越过「导航条目开始覆盖」的位置。
        // 实测浮卡占 y 43..90；navList 从 65 起、`.padding(.top, 10)` → 第一个条目
        // 75..113。抬层前差异止步于 y=74（正好卡在条目上沿），抬层后到 90。
        let bounds = try XCTUnwrap(
            differenceBounds(plain, withTip, rows: tipWindow, columns: navColumns),
            "浮卡窗口里两帧没有任何差异"
        )
        XCTAssertLessThan(bounds.minY, headerHeight, "浮卡起点应在头栏内（实测 y=\(bounds.minY)）")
        XCTAssertGreaterThan(
            bounds.maxY, 82,
            "浮卡下半截没画出来 —— 差异只到 y=\(bounds.maxY)（抬层后应为 90），"
                + "说明它止步于导航条目上沿、伸进导航区的那截被盖住了"
        )

        // 判据②：导航条目覆盖区（76..88）里必须真有浮卡的墨。
        // 抬层前这一段是把浮卡压掉的「练习」条目，差异为 0（实测）；抬层后 670 点。
        let inNavRow = differencePoints(plain, withTip, rows: 76..<88, columns: navColumns)
        XCTAssertGreaterThan(
            inNavRow, 400,
            "导航条目区里没有浮卡的墨（实测 \(inNavRow) 点）——"
                + "浮卡被更晚绘制的导航条目盖住了"
        )

        try dump(plain, name: "sidebar-streak-tip-plain.png")
        try dump(withTip, name: "sidebar-streak-tip-shown.png")
    }

    /// 落盘（人眼复核用）。
    private func dump(_ rep: NSBitmapImageRep, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // RenderTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]), "PNG 编码失败")
        try png.write(to: directory.appendingPathComponent(name))
    }
}
