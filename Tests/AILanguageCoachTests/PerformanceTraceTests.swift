import XCTest

@testable import AppCore

/// #668：耗时采集器与三处埋点的判据。
///
/// 改前全仓**一处耗时打点都没有** —— 「启动慢 / 切页卡 / 老师回得慢」只是体感。
/// 这一批判据要守两件事：
/// ① 采集器本身算得对（环形缓冲封顶、中位数、脏样本不进）；
/// ② 三处埋点**真的还在**（埋点被删，编译照过、单测照绿，只会在下次想看数字时才发现）。
///
/// ⚠️ 所有判据都用**喂进去的时刻**，不在用例里现取两次 `Date()`：
/// 那样测的是「机器此刻有多快」（时序型假闸），不是这段代码对不对。
final class PerformanceTraceTests: XCTestCase {

    // MARK: - 判据 1：环形缓冲到顶丢最旧

    /// 不封顶的话，聊一天、切几百次页，数组单调增长（不报错，只是慢慢吃掉内存）。
    func testRingBufferKeepsOnlyTheNewestSamples() {
        let trace = PerformanceTrace(capacity: 3)
        for index in 0..<5 {
            trace.record(name: "n\(index)", seconds: Double(index), at: Date(timeIntervalSince1970: 0))
        }
        XCTAssertEqual(trace.count, 3, "容量 3，记了 5 笔就该只剩 3 笔")
        let names = trace.recent().map(\.name)
        XCTAssertEqual(names, ["n2", "n3", "n4"], "丢的必须是最旧的（\(names)）")
        // 序号单调递增：同一毫秒内的两笔也能分出先后，面板上顺序才不会乱跳。
        let ids = trace.recent().map(\.id)
        XCTAssertEqual(ids, ids.sorted())
    }

    /// `recent(limit:)` 取的是尾部，且不会越界。
    func testRecentLimitRespectsWhatIsStored() {
        let trace = PerformanceTrace(capacity: 10)
        for index in 0..<4 { trace.record(name: "n\(index)", seconds: 0.1, at: Date(timeIntervalSince1970: 0)) }
        XCTAssertEqual(trace.recent(limit: 2).count, 2)
        XCTAssertEqual(trace.recent(limit: 99).count, 4, "limit 超过存量时返回全部，不该补空位")
    }

    // MARK: - 判据 2：耗时是按喂进去的时刻算的

    /// 判据里喂确定的 `start` / `now`：两次各取 `Date()` 的话，中间那点真实耗时
    /// 会叠进断言里（实测红过一次：30.770001025 vs 30.77）。
    func testRecordSinceMeasuresTheGivenInterval() {
        let trace = PerformanceTrace()
        let start = Date(timeIntervalSince1970: 1_000)
        trace.record(name: "x", since: start, now: start.addingTimeInterval(0.25))

        let sample = try? XCTUnwrap(trace.recent().first, "记了一笔就该读得到")
        XCTAssertEqual(sample?.seconds ?? -1, 0.25, accuracy: 1e-9)
    }

    // MARK: - 判据 3：脏样本不进

    /// 时钟回拨（`Date()` 会往前跳）与传错单位（毫秒当秒）都不许污染分布 ——
    /// 一条 -3s 会让中位数彻底失真，而「数字不对」比「没有数字」更危险。
    func testNegativeAndNonFiniteSamplesAreDropped() {
        let trace = PerformanceTrace()
        trace.record(name: "backwards", seconds: -3, at: Date(timeIntervalSince1970: 0))
        trace.record(name: "nan", seconds: Double.nan, at: Date(timeIntervalSince1970: 0))
        trace.record(name: "infinite", seconds: Double.infinity, at: Date(timeIntervalSince1970: 0))
        trace.record(name: "fine", seconds: 0.5, at: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(trace.count, 1, "负数 / NaN / ∞ 一律不收（\(trace.recent().map(\.name))）")
        XCTAssertEqual(trace.recent().first?.name, "fine")
    }

    // MARK: - 判据 4：汇总

    func testSummaryGroupsByNameAndComputesMedianAndMax() {
        let trace = PerformanceTrace()
        // 同一页切三次：次数 3、中位 0.20、最大 0.90（上中位：偶数样本取中间偏右那个）。
        let values: [Double] = [0.10, 0.20, 0.90]
        for value in values { trace.record(name: "section.progress", seconds: value, at: Date(timeIntervalSince1970: 0)) }
        trace.record(name: "launch", seconds: 4.5, at: Date(timeIntervalSince1970: 0))

        let rows = trace.summary()
        XCTAssertEqual(rows.map(\.name), ["section.progress", "launch"], "按首次出现排序，面板上不会重排")

        let section = try? XCTUnwrap(rows.first)
        XCTAssertEqual(section?.count, 3)
        XCTAssertEqual(section?.medianSeconds ?? -1, 0.20, accuracy: 1e-9)
        XCTAssertEqual(section?.maxSeconds ?? -1, 0.90, accuracy: 1e-9)
        XCTAssertEqual(section?.lastSeconds ?? -1, 0.90, accuracy: 1e-9)
        XCTAssertEqual(section?.mark, .section, "前缀要能解析回埋点")
        XCTAssertEqual(section?.subject, "progress")
        XCTAssertEqual(section?.title, "切页到就绪 · progress")

        let launch = rows.last
        XCTAssertEqual(launch?.mark, .launch)
        XCTAssertNil(launch?.subject, "没有细分维度时 subject 是 nil")
        XCTAssertEqual(launch?.title, "启动到可交互")
    }

    /// 汇总顺序按首次出现，不按耗时排 —— 每切一页重排一次，人眼追不住哪行是哪页。
    func testSummaryOrderFollowsFirstAppearanceNotDuration() {
        let trace = PerformanceTrace()
        trace.record(name: "slow", seconds: 9, at: Date(timeIntervalSince1970: 0))
        trace.record(name: "fast", seconds: 0.01, at: Date(timeIntervalSince1970: 0))
        trace.record(name: "slow", seconds: 9, at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(trace.summary().map(\.name), ["slow", "fast"])
    }

    // MARK: - 判据 5：冷启动起点

    /// 没打过起点就不记：那种情况下记出来的是「从这个对象被建起到现在」，
    /// 一条来历不明的耗时比没有更误导。
    func testRecordSinceLaunchSkipsWhenLaunchWasNeverMarked() {
        let trace = PerformanceTrace()
        trace.recordSinceLaunch(.launch, now: Date(timeIntervalSince1970: 5))
        XCTAssertEqual(trace.count, 0, "没 markLaunch 就不该有样本")

        let start = Date(timeIntervalSince1970: 1_000)
        trace.markLaunch(now: start)
        trace.recordSinceLaunch(.launch, now: start.addingTimeInterval(2.5))
        XCTAssertEqual(trace.count, 1)
        XCTAssertEqual(trace.recent().first?.seconds ?? -1, 2.5, accuracy: 1e-9)
        XCTAssertEqual(trace.recent().first?.name, PerfMark.launch.sampleName())
    }

    // MARK: - 判据 6：文案分档

    func testDurationTextSwitchesUnitAtOneSecond() {
        XCTAssertEqual(PerformanceText.seconds(0.0123), "12 ms", "不到 1 秒走毫秒")
        XCTAssertEqual(PerformanceText.seconds(1.234), "1.23 s", "超过 1 秒走秒（32000 ms 看不出量级）")
        XCTAssertEqual(PerformanceText.seconds(-1), "—")
        XCTAssertEqual(PerformanceText.seconds(Double.nan), "—")
    }

    // MARK: - 判据 7：三处埋点都还在（源码哨兵）

    /// 埋点被删 = 编译照过、单测照绿，只会在下次想看数字时才发现。
    ///
    /// ⚠️ 每条负面断言都配一条正向断言：只钉「不许有 X」时，X 因改名而消失照样恒绿。
    func testColdLaunchIsInstrumentedFromAppConstructionToReveal() throws {
        let appMain = try source("Sources/AppMain/AppMain.swift")
        XCTAssertTrue(
            appMain.contains("PerformanceTrace.shared.markLaunch()"),
            "AppMain 构造时要打下冷启动起点 —— 打在 AppState 之后会系统性偏小，盲区里全是真耗时"
        )

        let appState = try source("Sources/AppUI/AppState.swift")
        // 钉**相邻两行**：终点必须是「界面揭开」那一刻（`isBooting` 翻 false），
        // 挪到 `start()` 末尾（后台活都跑完）就会让这个数字失去意义。
        XCTAssertTrue(
            appState.contains("PerformanceTrace.shared.recordSinceLaunch(.launch)\n        isBooting = false"),
            "收口必须紧贴 isBooting = false —— 那是用户真正看到界面的时刻"
        )
    }

    func testSectionSwitchIsMeasuredWhereTheAwaitHappens() throws {
        let appState = try source("Sources/AppUI/AppState.swift")

        let goBody = try block("public func go(to section: AppSection) async", in: appState)
        XCTAssertTrue(
            goBody.contains("PerformanceTrace.shared.record("),
            "切页耗时打在 go(to:) 上（整段埋点被删也会让下面的负面断言恒绿）"
        )
        XCTAssertTrue(goBody.contains("let switchStartedAt = Date()"), "要有起点")
        // 钉调用形态整串：只钉 `since:` 的话，挪到别的函数里照样绿。
        XCTAssertTrue(
            goBody.contains("since: switchStartedAt"),
            "收口必须吃 `go(to:)` 自己那个起点"
        )
        XCTAssertTrue(
            goBody.contains("PerfMark.section.sampleName(subject: section.rawValue)"),
            "按目标页分名 —— 混成一个平均数会把「某一页特别慢」抹平"
        )
        XCTAssertTrue(goBody.contains("defer {"), "用 defer 收口：switch 里每个分支都不该各写一遍")

        // applySection 只写九个布尔量，把埋点打在这里会得出「切页 0.2ms」这种无用数字。
        let applyBody = try block("func applySection(_ section: AppSection)", in: appState)
        XCTAssertFalse(
            applyBody.contains("PerformanceTrace"),
            "埋点不该打在 applySection 上 —— 花钱的是后面那次 await"
        )
    }

    func testTeacherFirstTokenIsRecordedOnlyOncePerTurn() throws {
        let chat = try source("Sources/AIServices/ChatService.swift")
        XCTAssertTrue(chat.contains("let turnStartedAt = Date()"), "首字计时要从请求发出那一刻起算")
        XCTAssertTrue(
            chat.contains("PerfMark.firstToken.sampleName(), since: turnStartedAt"),
            "首字要吃 `turnStartedAt`（整段埋点被删也会让下面的断言恒绿）"
        )
        // 「只在第一个增量上记一次」：每个字都记的话环形缓冲会被这一轮占满，
        // 而「首字延迟」这个数字本身也没了 —— 所以必须落在 `accumulated.isEmpty` 里。
        let firstTokenBlock = try block("if accumulated.isEmpty {", in: chat)
        XCTAssertTrue(
            firstTokenBlock.contains("PerformanceTrace.shared.record("),
            "首字记录必须在『第一个增量』这个分支里，否则每来一个字都记一笔"
        )
    }

    // MARK: - 工具

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: relativePath, encoding: .utf8)
    }

    /// 从 `needle` 起截取到与它配平的那对大括号（用于「只看某个函数/分支里有没有…」）。
    ///
    /// 为什么要它而不是整文件 `contains`：埋点挪到别的方法里，整文件断言照样绿。
    private func block(_ needle: String, in source: String) throws -> String {
        guard let start = source.range(of: needle) else {
            XCTFail("找不到 \(needle)")
            return ""
        }
        // ⚠️ 从 needle 之后（含 needle 自己那个 `{`）遇到的**第一对**大括号起配平：
        // 直接跳过 needle 末尾的 `{` 会让深度第一下就变成 -1、一路扫到文件尾。
        let tail = source[start.lowerBound...]
        guard let brace = tail.firstIndex(of: "{"),
              brace >= start.lowerBound else {
            XCTFail("\(needle) 后面没有左括号")
            return ""
        }
        var depth = 0
        var index = brace
        while index < source.endIndex {
            let character = source[index]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return String(source[start.lowerBound...index]) }
            }
            index = source.index(after: index)
        }
        XCTFail("\(needle) 之后没有配平的大括号")
        return String(source[start.lowerBound...])
    }
}
