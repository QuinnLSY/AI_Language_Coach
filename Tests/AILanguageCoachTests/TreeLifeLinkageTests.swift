import AIDomain
@testable import AppUI
import XCTest

/// C：动物与学习过程联动 —— 学员每往上一层，最近的一只小跳招呼一声。
///
/// 分三块：
/// - **纯函数**：`isRealAscent` 的判据（「算不算真爬升」是这次唯一有语义的地方，
///   开屏从库里读回进度时也会变，不演；往下走不演）；
/// - **台词纪律**：招呼词不庆祝（庆祝归 `ceremonyTick` / `celebrationTick` 两档）、
///   不评判、且不与任何既有台词池撞车；
/// - **接线哨兵**：`MainView` → `ForestGroundBand.climbFraction` → `onChange` →
///   `cheerAscent()` 这条链断了不报错也不崩溃，只是森林对进度聋了，只能扫源码。
///
/// ⚠️ 反证必须**真删**：源码哨兵扫的是原始文本，注释掉的代码行照样被扫到。
@MainActor
final class TreeLifeLinkageTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: "Sources/\(relativePath)", encoding: .utf8)
    }

    /// 源码的**非注释行**（`//` / `///` 开头的整行去掉），行号保留（第 1 行 = index 0）。
    private func codeLines(_ source: String) -> [(number: Int, text: String)] {
        source.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, raw in
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { return nil }
            return (index + 1, line)
        }
    }

    /// 取 `startMarker` 到 `endMarker` 之间的源码段（不含 endMarker）。
    private func section(from startMarker: String, to endMarker: String, in source: String) -> String {
        guard let start = source.range(of: startMarker) else { return "" }
        guard let end = source.range(of: endMarker, range: start.upperBound..<source.endIndex) else {
            return String(source[start.lowerBound...])
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    // MARK: - ① 「算不算真爬升」判据（纯函数）

    /// 正常向上：演。
    func testRealAscentAcceptsUpwardMovement() {
        XCTAssertTrue(ForestGroundBand.isRealAscent(old: 0.20, new: 0.25))
        XCTAssertTrue(ForestGroundBand.isRealAscent(old: 0.25, new: 1.00))
    }

    /// **开屏那一次不算**：进度刚从库里读回来（0 → 当前值），
    /// 那是一次「加载」不是「攀爬」。不挡住的话每次开屏都要演一遍「又上一层」。
    func testRealAscentRejectsInitialLoadFromZero() {
        XCTAssertFalse(ForestGroundBand.isRealAscent(old: 0, new: 0.30))
        XCTAssertFalse(ForestGroundBand.isRealAscent(old: 0, new: 1.00))
    }

    /// 原地不动与往下走都不算：进度回退（如重置闯关）时小动物不该跳起来叫好。
    func testRealAscentRejectsStillAndDownward() {
        XCTAssertFalse(ForestGroundBand.isRealAscent(old: 0.5, new: 0.5))
        XCTAssertFalse(ForestGroundBand.isRealAscent(old: 0.5, new: 0.4))
        XCTAssertFalse(ForestGroundBand.isRealAscent(old: 0.5, new: 0))
    }

    /// 极小位移不算（浮点噪声 / 重算抖动）。
    func testRealAscentRejectsNegligibleMovement() {
        XCTAssertFalse(ForestGroundBand.isRealAscent(old: 0.2000, new: 0.2001))
    }

    // MARK: - ② 台词纪律

    /// 招呼词得有几条，且条条不空（空的会在气泡里显示成一块空白）。
    func testAscentPhrasesArePresentAndNonEmpty() {
        XCTAssertGreaterThanOrEqual(ForestGroundBand.ascentPhrases.count, 3)
        for line in ForestGroundBand.ascentPhrases {
            XCTAssertFalse(line.trimmingCharacters(in: .whitespaces).isEmpty,
                           "招呼词里有空串：\(line)")
        }
    }

    /// **不庆祝**：里程碑有 `ceremonyTick` / `celebrationTick` 两档（会跳会放烟花），
    /// 「又上一层」只是日常进度，用庆祝腔会把这俩大场面稀释成日常。
    ///
    /// 反证：往池子里加「恭喜通关！」→ 红。
    func testAscentPhrasesNeverCelebrate() {
        let celebrationWords = ["恭喜", "通关", "太棒", "了不起", "冠军", "第一", "撒花", "烟花", "万岁"]
        for line in ForestGroundBand.ascentPhrases {
            for word in celebrationWords {
                XCTAssertFalse(line.contains(word),
                               "招呼词在庆祝（庆祝归 ceremony / celebration 两档）：\(line)")
            }
        }
    }

    /// **不评判**：学员爬得快慢是他自己的节奏，不许出现「才 / 慢 / 落后」这类数落。
    ///
    /// 反证：往池子里加「你怎么才爬上来」→ 红。
    func testAscentPhrasesNeverJudgeTheLearner() {
        let judgingWords = ["才爬", "才上来", "太慢", "落后", "别人"]
        for line in ForestGroundBand.ascentPhrases {
            for word in judgingWords {
                XCTAssertFalse(line.contains(word),
                               "招呼词在评判学员的节奏：\(line)")
            }
        }
    }

    /// **不许和别的池撞车**：同一句话出现在两个场景里，场景就串了
    ///（爬了一层却说出欢迎词 / 安慰话）。全部既有池一起比对。
    ///
    /// 反证：把 `welcomePhrases` 里任一条复制进 `ascentPhrases` → 红。
    func testAscentPhrasesDoNotCollideWithOtherPools() {
        let others: [String] = ForestGroundBand.comfortPhrases
            + ForestGroundBand.huddleComfortPhrases
            + ForestGroundBand.dozingPhrases
            + ForestGroundBand.fetchStartPhrases
            + ForestGroundBand.fetchDonePhrases
            + ForestGroundBand.welcomePhrases
        let duplicates = Set(ForestGroundBand.ascentPhrases).intersection(others)
        XCTAssertTrue(duplicates.isEmpty,
                      "招呼词和别的场景撞车了：\(duplicates.sorted()) —— 场景会串")
    }

    // MARK: - ③ 接线哨兵（源码）

    /// `MainView` 真的把进度喂进了林间地面带。
    ///
    /// 反证：删掉 `climbFraction: state.progress.climbFraction` 那一行 → 红。
    func testMainViewFeedsClimbFractionIntoGroundBand() throws {
        let main = try source("AppUI/Views/MainView.swift")
        let hits = codeLines(main).filter { $0.text.contains("climbFraction: state.progress.climbFraction") }
        XCTAssertEqual(hits.count, 1,
                       "MainView 没把 `state.progress.climbFraction` 喂进地面带（或喂了不止一处）")
    }

    /// 地面带真的在盯 `climbFraction` 的变化，且调用了 `cheerAscent()`。
    ///
    /// 反证：删掉 `.onChange(of: climbFraction)` 整段 → 两处断言一起红。
    func testGroundBandWatchesClimbFraction() throws {
        let canvas = try source("AppUI/Components/TreeCanvas.swift")
        let watches = codeLines(canvas).filter { $0.text.contains(".onChange(of: climbFraction)") }
        XCTAssertEqual(watches.count, 1,
                       "地面带没有在盯 `climbFraction`（C 整条链断在最外层）")
        // 判据必须走纯函数，不许在闭包里另写一份（两份迟早不一致）。
        let calls = codeLines(canvas).filter { $0.text.contains("Self.isRealAscent(old: old, new: new)") }
        XCTAssertEqual(calls.count, 1,
                       "onChange 里没有复用 `isRealAscent` 纯函数判据")
        let cheers = codeLines(canvas).filter { $0.text.contains("cheerAscent()") }
        XCTAssertFalse(cheers.isEmpty, "盯见了变化却没有 `cheerAscent()` —— 聋的")
    }

    /// `cheerAscent` 只到「一个小跳 + 一句话」为止：不点名整队、不演剧情、不放烟花。
    /// 点名（`welcomeParty`）是首次见面的排场，剧情（`performStoryAct`）是三幕连续剧，
    /// 烟花由 `state.celebrationTick` 在面板层放 —— 日常进度一律不配用。
    ///
    /// 反证：往 `cheerAscent` 里加一行 `welcomeParty()` → 红。
    func testAscentCheerStaysBelowCelebrationLevel() throws {
        let canvas = try source("AppUI/Components/TreeCanvas.swift")
        let body = section(from: "private func cheerAscent() {",
                           to: "// MARK: 边界状态",
                           in: canvas)
        XCTAssertFalse(body.isEmpty, "找不到 `cheerAscent` 的函数体")
        for forbidden in ["welcomeParty", "performStoryAct", "celebrationTick", "firework", "Firework"] {
            XCTAssertFalse(body.contains(forbidden),
                           "`cheerAscent` 动用了 \(forbidden) —— 那是里程碑的排场，不是「又上一层」的")
        }
    }
}
