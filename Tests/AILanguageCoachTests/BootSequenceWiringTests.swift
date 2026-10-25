import XCTest

/// 开屏顺序的**接线哨兵**（#671）。
///
/// 这一组断言守的是「改快了、但改坏了顺序」—— 启动段里几条依赖是踩过坑才写进注释的：
/// - 进度要先于情景目录（`applyScenarioBindings` 会覆盖关卡的 `scenarioID`）；
/// - 会话恢复要先于引导卡（卡片要知道「有没有得续」），且必须在界面揭开之前算完；
/// - LLM 装配要先于状态刷新（刷新要读它注册的 Provider）。
///
/// 这些都是**源码级**事实：跑起来「看着正常」不代表顺序没乱（乱了的表现是偶发的
/// 少几个关卡 / 引导卡晚一拍 / 状态栏先空一下），渲染差分也照不出来。
final class BootSequenceWiringTests: XCTestCase {

    private let path = "Sources/AppUI/AppState.swift"

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: relativePath, encoding: .utf8)
    }

    /// 去掉整行注释后的 (行号, 文本) —— 注释里提到旧写法不该让哨兵报红。
    private func codeLines(_ source: String) -> [(number: Int, text: String)] {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, raw in
                let line = String(raw)
                guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { return nil }
                return (index + 1, line)
            }
    }

    /// `start()` 里的代码行（顺序断言一律只看开屏这一段 ——
    /// 同样的调用在别处还有，按全文件找会数到不止一处）。
    private func startLines() throws -> [(number: Int, text: String)] {
        let path = "Sources/AppUI/AppState.swift"
        return try startBody(of: try source(path), path: path)
    }

    private func line(of needle: String, in lines: [(number: Int, text: String)], _ path: String) throws -> Int {
        let hits = lines.filter { $0.text.contains(needle) }
        XCTAssertEqual(hits.count, 1, "\(path) 开屏段里「\(needle)」应当只出现一次（实际 \(hits.count) 次）")
        return try XCTUnwrap(hits.first?.number, "\(path) 开屏段里缺少「\(needle)」")
    }

    /// 顺序依赖：进度 → 情景目录。
    func testProgressLoadsBeforeScenarioCatalog() throws {
        let lines = try startLines()
        let progress = try line(of: "progress = await services.loadProgress()", in: lines, path)
        let catalog = try line(of: "await refreshScenarioCatalog()", in: lines, path)
        XCTAssertLessThan(progress, catalog, "情景目录会覆盖关卡的 scenarioID，必须先有进度")
    }

    /// 顺序依赖：会话恢复 → 引导卡 → 界面揭开。
    func testLaunchGuideFinishesBeforeTheWindowIsRevealed() throws {
        let lines = try startLines()
        let restore = try line(of: "await chat.restoreLastSessionIfNeeded()", in: lines, path)
        let guide = try line(of: "await prepareLaunchGuide()", in: lines, path)
        let revealed = try line(of: "isBooting = false", in: lines, path)
        XCTAssertLessThan(restore, guide, "引导卡要知道「有没有得续」，必须在会话恢复之后算")
        XCTAssertLessThan(guide, revealed, "引导卡必须在界面揭开之前算完，否则用户会看到它晚一拍才冒出来")
    }

    /// 并发段：LLM 装配放飞了，但**必须在状态刷新之前落地**。
    func testLLMBootstrapIsAwaitedBeforeStatusRefresh() throws {
        let lines = try startLines()
        // 正向断言：两种形态都得在（只断言「没有旧的串行写法」会恒绿）。
        let launched = try line(of: "async let llmBootstrap: Void = bootstrapLLMWithNotice()", in: lines, path)
        let awaited = try line(of: "await llmBootstrap", in: lines, path)
        let status = try line(of: "await refreshStatus()", in: lines, path)

        XCTAssertLessThan(launched, awaited, "先放飞、后收口")
        XCTAssertLessThan(awaited, status, "状态刷新要读装配好的 Provider，不能跑到收口前面去")
    }

    /// 启动段**只有一条**并发分支。
    ///
    /// 多放飞一条就可能让两处同时改 `product`（迎新记名 / 音色对齐都会回写配置）——
    /// 那是丢更新，表现是偶发且无法复现的「上次明明欢迎过」「音色改了又跳回去」。
    func testStartHasExactlyOneConcurrentBranch() throws {
        let path = "Sources/AppUI/AppState.swift"
        let text = try source(path)
        let body = try startBody(of: text, path: path)
        let branches = body.filter { $0.text.contains("async let") }
        XCTAssertEqual(branches.count, 1,
                       "开屏段只放飞 LLM 装配一条分支（实际 \(branches.count) 条：\(branches.map(\.number))）")
        XCTAssertTrue(branches[0].text.contains("llmBootstrap"),
                      "唯一放飞的那条应当是 LLM 装配，实际是：\(branches[0].text)")
    }

    /// 拉起本机语音服务排在**界面揭开之后**：它会起进程 / 装模型，抢在首屏前面会把后面每一步都拖慢。
    func testLocalServiceLaunchHappensAfterTheWindowIsRevealed() throws {
        let lines = try startLines()
        let revealed = try line(of: "isBooting = false", in: lines, path)
        let launch = try line(of: "ensureEdgeTTSProxyOnLaunch()", in: lines, path)
        XCTAssertGreaterThan(launch, revealed,
                             "拉起本机服务要起进程装模型，排在首屏之前会把开屏每一步都堵在它后面")
    }

    /// 坏库隔离目录的回收（#674）挂在**后台**，不能挡在开屏路径上。
    func testQuarantinePruneRunsInTheBackground() throws {
        let lines = try startLines()
        let hit = try line(of: "await self?.services.pruneQuarantine()", in: lines, path)
        let text = try XCTUnwrap(lines.first { $0.number == hit }?.text)
        XCTAssertTrue(text.contains("Task {"),
                      "它只是一次目录列举 + 可能的废纸篓操作，必须后台跑（不能 await 在开屏段里）：\(text)")
    }

    // MARK: - 内部

    /// `start()` 函数体（到第一个「顶格四空格的右花括号」为止）。
    private func startBody(of text: String, path: String) throws -> [(number: Int, text: String)] {
        let all = codeLines(text)
        guard let head = all.firstIndex(where: { $0.text.contains("public func start() async {") }) else {
            XCTFail("\(path) 里找不到 start()")
            return []
        }
        let tail = all[head...].firstIndex { $0.text == "    }" }
        let end = tail ?? all.index(before: all.endIndex)
        return Array(all[head...end])
    }
}
