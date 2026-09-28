import XCTest

/// 森林地基（批次一）的**接线哨兵**。
///
/// 这组盯的是「事件链有没有接上、接的顺序对不对」——它们断了不报错、不崩溃，
/// 只是森林回到「对学习聋了」的样子，编译器与运行时都发现不了，所以只能扫源码。
///
/// ⚠️ 被扫的**字符串不能出现在源码注释里**（注释里的同款字符串会让哨兵假绿）；
/// ⚠️ 反证必须**真删**，注释掉同样会被扫到。
/// ⚠️ `contains` 判据凡遇「多处同名」都要用 `body(of:)` 限定作用域（09-28 教训）。
final class ForestWiringTests: XCTestCase {

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
        if let end = ends.min() {
            return String(rest[..<end])
        }
        return String(rest)
    }

    // MARK: - ① 服务层在既有落库点发射

    /// 收词：只有**真的进了本子**（guard let saved）才发事件；落库失败森林保持安静。
    func testVocabularyAddEmitsOnlyAfterWordIsSaved() throws {
        let body = self.body(of: "public func add(word: String", in: try source("AIServices/VocabularyService.swift"))
        XCTAssertFalse(body.isEmpty, "找不到 VocabularyService.add")
        let lines = codeLines(body)
        guard let saveLine = firstLine("guard let saved", in: lines),
              let emitLine = firstLine("events.emit(.wordCollected", in: lines) else {
            return XCTFail("add 里缺「确认入库」或「发收词事件」")
        }
        XCTAssertGreaterThan(emitLine, saveLine, "收词事件必须在确认入库**之后**发")
    }

    /// 纠错：零条不发（没发生的事森林不回应）。
    func testPersistCorrectionsEmitsOnlyWhenNonEmpty() throws {
        let body = self.body(of: "private func persistCorrections", in: try source("AIServices/ChatService.swift"))
        XCTAssertFalse(body.isEmpty, "找不到 persistCorrections")
        XCTAssertTrue(body.contains("if !corrections.isEmpty {"), "纠错事件必须以「有纠错」为前提")
        XCTAssertTrue(body.contains("services.events.emit(.correctionsRecorded"), "纠错落库点必须发事件")
    }

    /// 练完一段：复盘落库了才飘叶。
    func testReviewPersistEmitsPracticeCompleted() throws {
        let body = self.body(of: "private func persist(_ review: SessionReview)", in: try source("AIServices/SessionReviewService.swift"))
        XCTAssertFalse(body.isEmpty, "找不到 SessionReviewService.persist")
        XCTAssertTrue(body.contains("events.emit(.practiceCompleted"), "复盘落库点必须发练习完成事件")
    }

    /// 装配中心必须持有唯一总线，并注入收词 / 复盘两个子服务。
    func testCoachServicesOwnsTheBusAndInjectsIt() throws {
        let services = try source("AIServices/CoachServices.swift")
        XCTAssertTrue(services.contains("public nonisolated let events = LearningEventBus()"),
                      "唯一的事件总线应声明在 CoachServices 上")
        XCTAssertTrue(services.contains("VocabularyService(llm: self.llm, learning: database, events: self.events)"),
                      "词汇服务没接总线")
        XCTAssertTrue(services.contains("SessionReviewService(llm: self.llm, learning: database, events: self.events)"),
                      "复盘服务没接总线")
    }

    // MARK: - ② AppState：订阅与直发

    /// init 里必须把森林舞台挂上总线（忘挂 = 森林永远聋，且无任何报错）。
    func testAppStateAttachesForestStageToBusOnInit() throws {
        let body = self.body(of: "init(services: CoachServices) {", in: try source("AppUI/AppState.swift"))
        XCTAssertTrue(body.contains("forest.attach(to: services.events)"), "init 必须订阅服务层事件总线")
        XCTAssertTrue(body.contains("self.forestSubscription ="), "订阅凭证必须存进属性（丢弃即退订）")
    }

    /// **通关仪式在 saveProgress 之后**：星星与解锁先落库，烟花再放——
    /// 顺序反了，仪式演完进度还没落库，一重启就像「什么都没发生」。
    func testCompleteLevelEmitsAfterPersisting() throws {
        let body = self.body(of: "public func completeLevel", in: try source("AppUI/AppState.swift"))
        XCTAssertFalse(body.isEmpty, "找不到 completeLevel")
        let lines = codeLines(body)
        guard let saveLine = firstLine("await services.saveProgress(progress)", in: lines),
              let emitLine = firstLine("forest.ingest(.levelCompleted(levelID: levelID))", in: lines) else {
            return XCTFail("completeLevel 缺落库或缺仪式事件")
        }
        XCTAssertGreaterThan(emitLine, saveLine, "仪式事件必须在进度落库之后发")
    }

    /// 攒星小回应只在「没通关」分支发——通关走 completeLevel 的全套仪式，
    /// 两处都发会让同一颗星放两遍烟花。
    func testSettleScenarioEmitsStarsOnlyWhenNotPassed() throws {
        let body = self.body(of: "func settleScenario(", in: try source("AppUI/AppState+ExamMode.swift"))
        XCTAssertFalse(body.isEmpty, "找不到 settleScenario")
        let lines = codeLines(body)
        guard let elseLine = firstLine("} else {", in: lines),
              let emitLine = firstLine("forest.ingest(.starsEarned(", in: lines) else {
            return XCTFail("settleScenario 缺攒星事件或分支结构变了")
        }
        XCTAssertGreaterThan(emitLine, elseLine, "攒星事件应只在未通关分支发（通关走 levelCompleted）")
        // 全文件只此一处 starsEarned 直发点
        let all = codeLines(try source("AppUI/AppState+ExamMode.swift"))
        XCTAssertEqual(all.filter { $0.text.contains("forest.ingest(.starsEarned(") }.count, 1,
                       "starsEarned 直发点必须恰好一处")
    }

    // MARK: - ③ 主界面装配

    /// 树的三个脉冲必须从 state.forest 来——不可以有第二条「顺手传个布尔」的路。
    func testMainViewWiresForestTicksIntoTree() throws {
        let main = codeLines(try source("AppUI/Views/MainView.swift"))
        XCTAssertTrue(main.contains { $0.text.contains("ceremonyTick: state.forest.ceremonyTick") },
                      "通关脉冲没接到树")
        XCTAssertTrue(main.contains { $0.text.contains("practiceTick: state.forest.practiceTick") },
                      "练习完成脉冲没接到树")
        XCTAssertTrue(main.contains { $0.text.contains("wordTick: state.forest.wordTick") },
                      "收词脉冲没接到树")
        XCTAssertTrue(main.contains { $0.text.contains("CeremonyFireworksLayer(theme: state.theme, tick: state.forest.ceremonyTick)") },
                      "通关烟花层没装配")
    }

    // MARK: - ④ 轮换自然化不许退化成传送带

    /// 轮换必须走节奏器：结伴分组 / 独立归期 / 错落间隔三样都在场。
    func testRotationUsesThePacingPlanner() throws {
        let body = self.body(of: "private func orchestrateRotation", in: try source("AppUI/Components/TreeCanvas.swift"))
        XCTAssertFalse(body.isEmpty, "找不到 orchestrateRotation")
        XCTAssertTrue(body.contains("ForestRotationPacing.groupSize"), "一批走几只要问节奏器（结伴概率）")
        XCTAssertTrue(body.contains("ForestRotationPacing.returnDelay"), "归期必须独立随机（错落回来）")
        XCTAssertTrue(body.contains("ForestRotationPacing.staggerDelay"), "结伴离场必须前后脚错落")
        XCTAssertTrue(body.contains("ForestRotationPacing.nextDepartureDelay"), "下一批告别前要有静默期")
        XCTAssertTrue(body.contains("away[index] = true"), "离场后槽位必须真的「暂离」")
        XCTAssertTrue(body.contains("leavers.shuffled()"), "回来顺序要与离开顺序无关（打乱）")
    }

    /// 在场判定：日常动作 / 庆祝 / 绘制三处都只认「没暂离」的居民。
    func testPresentOnlyParticipation() throws {
        let tree = try source("AppUI/Components/TreeCanvas.swift")
        XCTAssertTrue(tree.contains("index < visibleCount && !away[index]"),
                      "居民可见性必须含暂离判定")
        XCTAssertTrue(tree.contains("(0..<count).filter { !away[$0] }"),
                      "日常动作只能在在场居民里挑")
        XCTAssertTrue(tree.contains("let present = (0..<Self.maxResidents).filter { !away[$0] }"),
                      "庆祝只能点在场的居民")
        let home = self.body(of: "private func sendEveryoneHome", in: tree)
        XCTAssertTrue(home.contains("away[i] = false"), "全体回家必须清掉暂离态（否则有人卡在画外）")
    }

    private func firstLine(_ needle: String, in lines: [(number: Int, text: String)]) -> Int? {
        lines.first { $0.text.contains(needle) }?.number
    }
}
