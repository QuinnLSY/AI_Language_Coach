import XCTest

/// 「今天」卡片 / 「今日任务」/ 年度记录**三处必须同口径**的接线哨兵。
///
/// 这几条链断了既不报错也不崩：只是同一张页面上两个数字打架，用户看得见、编译器看不见。
/// 2026-09-29 的两条报障（对话轮数不一致、连续天数不一致）都是这一类。
///
/// ⚠️ 反证必须**真删**：`body(of:)` 扫的是原始文本，注释掉的代码行照样被扫到。
final class ProgressConsistencyTests: XCTestCase {

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

    /// 取出函数体：从 `needle` 起到下一个函数声明 / 存储属性 / 类型边界为止。
    private func body(of needle: String, in source: String) -> String {
        guard let range = source.range(of: needle) else { return "" }
        let rest = source[range.lowerBound...]
        let tail = rest.dropFirst(needle.count)
        let terminators = ["\n    public func ", "\n    private func ", "\n    func ",
                           "\n    public nonisolated ", "\n    private struct", "\n    public var "]
        let ends = terminators.compactMap { tail.range(of: $0)?.lowerBound }
        if let end = ends.min() { return String(rest[..<end]) }
        return String(rest)
    }

    // MARK: - ① 年度记录与窗口快照同一批实参

    /// 年度记录的取数必须与窗口快照**同一批实参**：漏传 `vocabulary`（收词）会让
    /// 「只收了新词、没开口」的那天在年度口径里算「没练」，连续天数比侧栏徽章少一天。
    ///
    /// ⚠️ 漏传时 `dailyActivity` 的形参有默认空数组 —— **编译器一声不响**，
    /// 所以只能这样扫源码钉住（口径本身的判据在 `AnnualRecapTests` 里）。
    ///
    /// 反证：删掉 `annualRecap` 里的 `vocabulary: vocabulary` → 红。
    func testAnnualRecapFeedsTheSameRawRecordsAsTheWindowSnapshot() throws {
        let service = try source("AIServices/ProgressService.swift")
        let recap = body(of: "public func annualRecap", in: service)
        XCTAssertFalse(recap.isEmpty, "找不到 annualRecap（结构变了就改这条判据）")
        XCTAssertTrue(recap.contains("let vocabulary = (try? await learning.allVocabulary())"),
                      "年度记录必须取词汇 —— 收词也算练过")
        XCTAssertTrue(recap.contains("vocabulary: vocabulary"),
                      "取到了还要真的喂给 dailyActivity（漏传时它有默认空数组）")
        XCTAssertTrue(recap.contains("corrections: corrections"),
                      "年度与窗口共用同一份实参，不许各写一套")

        // 窗口那一侧也一直在传 —— 两处必须都在（一处漏了就是两个答案）。
        let window = body(of: "public func snapshot(", in: service)
        XCTAssertTrue(window.contains("vocabulary: vocabulary"), "窗口快照那一侧也要一直喂着词汇")
    }

    // MARK: - ② 「今天」这一格抬到当天水位

    /// 「今天」卡片读的是 `progressSnapshot.today`，它必须**先抬水位、再上屏**；
    /// 而且抬水位用的必须是**原始**快照（拿抬过的去抬就是自我循环）。
    ///
    /// 反证：把 `progressSnapshot = snapshot.raisingToday(` 那行删掉 → 红。
    func testReloadRaisesTheFloorBeforePaintingToday() throws {
        let state = try source("AppUI/AppState+Progress.swift")
        let reload = body(of: "public func reloadProgress", in: state)
        XCTAssertFalse(reload.isEmpty, "找不到 reloadProgress（结构变了就改这条判据）")
        let raiseAt = try XCTUnwrap(
            reload.range(of: "raiseDailyTaskFloor(using: snapshot"), "没看到用原始快照抬水位"
        ).lowerBound
        let paintAt = try XCTUnwrap(
            reload.range(of: "progressSnapshot = snapshot.raisingToday("),
            "「今天」这一格没有被抬到当天水位 —— 它会与「今日任务」各说一个数"
        ).lowerBound
        XCTAssertLessThan(raiseAt, paintAt, "先抬水位、再画「今天」—— 顺序反了就是自我循环")
    }

    /// 抬水位只有**一个**入口，且拿的一定是原始快照。
    ///
    /// 反证：在 `refreshTodayPanel` 里再加一句 `raiseDailyTaskFloor(using: progressSnapshot` → 红。
    func testFloorIsRaisedFromRawSnapshotInOnePlace() throws {
        let state = try source("AppUI/AppState+Progress.swift")
        let blackboard = try source("AppUI/AppState+Blackboard.swift")
        let all = codeLines(state) + codeLines(blackboard)

        // 只看**调用**（声明行是 `raiseDailyTaskFloor(using raw:`，不含这个前缀）。
        let callers = all.filter { $0.text.contains("raiseDailyTaskFloor(using:") }
        XCTAssertEqual(callers.count, 1, "抬水位的调用点只允许一处（两处会互相打架）")
        for line in callers {
            XCTAssertTrue(line.text.contains("using: snapshot"),
                          "抬水位必须用原始快照，实际：\(line.text)")
        }
    }
}
