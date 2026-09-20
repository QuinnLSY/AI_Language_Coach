import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 空查询页那排「试试这些词」的**排版与悬停**回归。
///
/// 用户口径三条硬要求：
/// ① 铺满一行（不是左边挤一小撮、右边留一大片）；
/// ② 每 10 秒看得出来在换（错落翻牌）；
/// ③ 鼠标悬停要**边缘高亮**表示选中。
///
/// 实机截图还暴露过一个更基础的问题：**胶囊会叠在一起**，最后一颗还会跑出卡片右边缘。
/// 这里用离屏渲染把这一排单独扣出来量，不受实机窗口 / 鼠标位置干扰。
///
/// ⚠️ 判据是「画了东西的像素」：离屏位图里空白是**全透明**，白底是**纯白**，其余都算墨。
///    别用「比白暗」判（会把整幅图和白底都算成墨），也别猜通道顺序（实测 4 通道）。
@MainActor
final class DictionarySampleRowRenderTests: XCTestCase {

    /// 与词典页卡片内部等宽（卡片 620 − 左右各 16 的内边距）。
    private let rowWidth: CGFloat = 588

    private let pool = [
        "erosion", "technology", "arrival", "restoration", "heave",
        "specification", "illusion", "bend", "crank", "talented",
        "fuss", "puzzle", "texture", "dancer", "whitewash", "utterance"
    ]

    private struct Ink {
        let rep: NSBitmapImageRep
        /// 每一列有没有墨。
        let columns: [Bool]
        /// 每一行上「明显比胶囊底色深」的像素数。
        let darkByRow: [Int]

        var firstInked: Int? { columns.firstIndex(of: true) }
        var lastInked: Int? { columns.lastIndexSet(of: true) }
        /// 深色内容占据的纵向范围。
        var darkRows: ClosedRange<Int>? {
            guard let low = darkByRow.firstIndex(where: { $0 > 0 }),
                  let high = darkByRow.lastIndex(where: { $0 > 0 }), low <= high
            else { return nil }
            return low...high
        }
    }

    // MARK: - 出图

    private func ink(_ rep: NSBitmapImageRep) throws -> Ink {
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        let samples = rep.samplesPerPixel
        let rowBytes = rep.bytesPerRow
        let data = try XCTUnwrap(rep.bitmapData)

        /// 空白 = 全透明（没进图的地方）或纯白（进图的白底）。
        func isInk(x: Int, y: Int) -> Bool {
            let offset = y * rowBytes + x * samples
            var allZero = true
            var allMax = true
            for channel in 0..<samples {
                let value = data[offset + channel]
                if value != 0 { allZero = false }
                if value != 255 { allMax = false }
            }
            return !allZero && !allMax
        }

        /// ⚠️ 必须先过 `isInk`：空白处是全透明的 (0,0,0,0)，只按亮度判会把它算成最深的一档。
        ///
        /// ⚠️ 取亮度时**要跳过 alpha 通道**：通道顺序可能是 ARGB（alpha 在首），
        ///    把 alpha 当分量算进去会让每一格都亮到 255，于是「深色」一个都量不出来
        ///    （实测：描边明明画了，暗行分布却和没悬停时一模一样）。
        let alphaFirst = rep.bitmapFormat.contains(.alphaFirst)
        let base = alphaFirst ? 1 : 0
        let accentLuma = 150.0
        func isDark(x: Int, y: Int) -> Bool {
            guard isInk(x: x, y: y) else { return false }
            let offset = y * rowBytes + x * samples
            let r = Double(data[offset + base])
            let g = Double(data[offset + base + 1])
            let b = Double(data[offset + base + 2])
            return (r + g + b) / 3 < accentLuma
        }

        var columns = [Bool](repeating: false, count: width)
        var darkByRow = [Int](repeating: 0, count: height)
        for x in 0..<width {
            var dyed = 0
            for y in 0..<height {
                if isInk(x: x, y: y) { dyed += 1 }
                if isDark(x: x, y: y) {
                    darkByRow[y] += 1
                }
            }
            columns[x] = dyed > 2
        }
        return Ink(rep: rep, columns: columns, darkByRow: darkByRow)
    }

    private func capture(_ content: AnyView, width: CGFloat, height: CGFloat) throws -> Ink {
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try ink(rep)
    }

    private func renderRow() throws -> Ink {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        return try capture(
            AnyView(
                DictionarySampleWordsRow(words: pool, onPick: { _ in })
                    .forestTheme(theme)
                    .padding(16)
                    .frame(width: rowWidth + 32)
                    .background(Color(hex: 0xFFFFFF))
            ),
            width: rowWidth + 32, height: 120
        )
    }

    private func renderChip(hovered: Bool) throws -> Ink {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        return try capture(
            AnyView(
                SampleWordChip(word: "erosion", hovered: hovered, onTap: {})
                    .forestTheme(theme)
                    .padding(10)
                    .background(Color(hex: 0xFFFFFF))
            ),
            width: 110, height: 56
        )
    }

    private func dump(_ ink: Ink, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(ink.rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name))
    }

    // MARK: - ① 一整排放得进可用宽度

    /// 最左不越界、最右也不越界（不许跑出卡片）。
    func testRowStaysInsideAvailableWidth() throws {
        let ink = try renderRow()
        try dump(ink, name: "sample-row.png")
        let left = try XCTUnwrap(ink.firstInked, "一排胶囊一个像素都没画出来")
        let right = try XCTUnwrap(ink.lastInked, "一排胶囊一个像素都没画出来")
        // 留有 1px 的取整余量。
        XCTAssertGreaterThanOrEqual(left, 1, "左边越界")
        XCTAssertLessThanOrEqual(right, ink.rep.pixelsWide - 2, "右边越界：有胶囊跑出了可用宽度")
    }

    // MARK: - ② 不许叠印

    /// 叠印会让几颗并成一块墨 —— 数「墨块」就能看出来。
    ///
    /// 背景知识：`Layout` 允许只摆放一部分子视图，但没被摆放的那些会被 SwiftUI
    /// 默认堆在容器正中（14 颗只摆 7 颗时，另外 7 颗就在正中间叠成一团黑）。
    /// 这条断言正是钉住那件事。
    func testChipsDoNotOverlap() throws {
        let ink = try renderRow()
        var blocks = 0
        var previous = false
        for hasInk in ink.columns {
            if hasInk, !previous { blocks += 1 }
            previous = hasInk
        }
        // 588pt 一行至少放得下 5 颗（最长的 "specification" 也放得下四五颗），
        // 墨块数却少于 4，说明有胶囊叠在一起被并成了同一块。
        XCTAssertGreaterThanOrEqual(blocks, 4, "只数出 \(blocks) 个墨块，胶囊疑似叠印")
    }

    // MARK: - ③ 悬停要有边缘高亮

    /// 用户口径：鼠标悬停时**边缘高亮**表示选中。
    ///
    /// 只翻 `hovered` 这一个开关，别的字段一个不动：
    /// 深色像素（描边 + 文字）的纵向范围应当**上下各撑开一截** ——
    /// 描边画在胶囊内侧的一圈，文字在中间，所以只有描边会出现在文字之上 / 之下。
    func testHoverAddsEdgeHighlight() throws {
        let idle = try renderChip(hovered: false)
        let hovered = try renderChip(hovered: true)
        try dump(idle, name: "sample-chip-idle.png")
        try dump(hovered, name: "sample-chip-hovered.png")

        let idleRows = try XCTUnwrap(idle.darkRows, "未悬停时连文字都没画出来")
        let hoveredRows = try XCTUnwrap(hovered.darkRows, "悬停时什么都没画出来")

        XCTAssertLessThanOrEqual(
            hoveredRows.lowerBound, idleRows.lowerBound - 2,
            "悬停后上边缘没有出现描边（深色内容没有往上撑开）"
        )
        XCTAssertGreaterThanOrEqual(
            hoveredRows.upperBound, idleRows.upperBound + 2,
            "悬停后下边缘没有出现描边（深色内容没有往下撑开）"
        )

        let idleDark = idle.darkByRow.reduce(0, +)
        let hoveredDark = hovered.darkByRow.reduce(0, +)
        XCTAssertGreaterThan(
            hoveredDark, idleDark, "悬停后的描边应当让深色像素变多"
        )
    }

    /// 不悬停时**不许**有描边：描边的透明度得是 0，不能留一圈淡边。
    func testIdleChipHasNoEdgeLine() throws {
        let idle = try renderChip(hovered: false)
        let hovered = try renderChip(hovered: true)
        // 描边那一圈（悬停时才有的深色像素）在未悬停时应当基本不存在。
        let ringRows = Set(
            (try XCTUnwrap(hovered.darkRows)).filter { row in
                row < (try? XCTUnwrap(idle.darkRows).lowerBound) ?? 0
            }
        )
        var ringDark = 0
        for row in ringRows { ringDark += hovered.darkByRow[row] }
        // 上边缘那一圈的总墨量应当远少于整颗胶囊的深色总量 —— 未悬停时它一条都没有。
        XCTAssertGreaterThan(ringDark, 0, "悬停时上边缘本该有描边")
        var idleRingDark = 0
        for row in ringRows where row < idle.darkByRow.count { idleRingDark += idle.darkByRow[row] }
        XCTAssertEqual(idleRingDark, 0, "未悬停时上边缘不该有任何深色像素（描边应当是透明的）")
    }
}

private extension Array where Element == Bool {
    func lastIndexSet(of value: Bool) -> Int? {
        for index in indices.reversed() where self[index] == value { return index }
        return nil
    }
}
