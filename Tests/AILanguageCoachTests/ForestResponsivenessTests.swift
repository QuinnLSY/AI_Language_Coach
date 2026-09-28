import AIDomain
@testable import AppUI
import XCTest

/// 批次四 · A「分模块回应」与 B「中间栏林间空地」的测试。
///
/// 分两块：
/// - **纯函数**：模块→戏码表、空地生长表、舞台翻译表（都能直接算，不必渲染）；
/// - **接线哨兵**：这些链条断了不报错也不崩溃，只是森林「对某个模块聋了」，
///   编译器发现不了，只能扫源码（同 ForestWiring 的做法）。
///
/// ⚠️ 反证必须**真删**：`body(of:)` 扫的是原始文本，注释掉的代码行照样被扫到。
@MainActor
final class ForestResponsivenessTests: XCTestCase {

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

    // MARK: - ① 模块 → 戏码（纯函数）

    /// 每个模块都有戏：动作、台词、送别话都不许为空。
    func testEveryModuleHasAnActionAndLines() {
        for module in PracticeModule.allCases {
            XCTAssertFalse(ForestModuleSkit.lines(for: module).isEmpty, "\(module) 没有台词")
            XCTAssertFalse(ForestModuleSkit.farewellLines(for: module).isEmpty, "\(module) 没有送别话")
            let size = ForestModuleSkit.castSize(for: module)
            XCTAssertTrue((1...2).contains(size), "\(module) 的参演数 \(size) 越界（只允许 1–2 只）")
        }
    }

    /// 动作要有**辨识度**：七个模块不能共用同一个动作（否则「分模块回应」名存实亡）。
    ///
    /// 反证：把任意两个模块的动作改成同一个 → 去重后数量减少 → 红。
    func testModuleActionsAreActuallyDistinguishable() {
        let actions = PracticeModule.allCases.map { ForestModuleSkit.action(for: $0) }
        XCTAssertEqual(Set(actions.map(\.rawValue)).count, PracticeModule.allCases.count,
                       "模块动作撞车了：\(actions.map(\.rawValue)) —— 分模块回应必须有辨识度")
    }

    /// 送别话**不许评判**：中途退出不是失败，说「可惜 / 怎么不练完」就是在责备学员。
    ///
    /// 反证：往任意一条送别话里加「可惜」→ 红。
    func testFarewellLinesNeverBlameTheLearner() {
        for module in PracticeModule.allCases {
            for line in ForestModuleSkit.farewellLines(for: module) {
                XCTAssertFalse(line.contains("可惜"), "\(module) 的送别话在评判学员：\(line)")
                XCTAssertFalse(line.contains("怎么不"), "\(module) 的送别话在责备学员：\(line)")
                XCTAssertFalse(line.contains("没做完"), "\(module) 的送别话在数落学员：\(line)")
            }
        }
    }

    // MARK: - ② 舞台翻译表（纯函数）

    /// 错一两条 = 一只安慰；错到门槛及以上 = 几只围过来。**两档互斥**。
    ///
    /// 反证：把 `huddleComfortThreshold` 判据去掉（一律走单人安慰）→ 簇拥通道恒为 0 → 红。
    func testComfortSplitsIntoTwoMutuallyExclusiveChannels() {
        let stage = ForestStage()
        stage.ingest(.correctionsRecorded(count: ForestStage.huddleComfortThreshold - 1))
        XCTAssertEqual(stage.comfortTick, 1, "错得少 → 单人安慰")
        XCTAssertEqual(stage.huddleComfortTick, 0, "错得少不该惊动簇拥通道")

        stage.ingest(.correctionsRecorded(count: ForestStage.huddleComfortThreshold))
        XCTAssertEqual(stage.comfortTick, 1, "簇拥那次不该再推单人通道")
        XCTAssertEqual(stage.huddleComfortTick, 1)
    }

    /// 模块完成 / 中途退出 / 对话陪伴各走各的通道，互不串台。
    func testNewChannelsDoNotBleedIntoEachOther() {
        let stage = ForestStage()
        stage.ingest(.moduleCompleted(module: .reading))
        XCTAssertEqual(stage.moduleTick, 1)
        XCTAssertEqual(stage.lastModule, .reading)
        XCTAssertEqual(stage.abandonTick, 0, "完成不该碰到退出通道")

        stage.ingest(.practiceAbandoned(module: .exam))
        XCTAssertEqual(stage.abandonTick, 1)
        XCTAssertEqual(stage.lastAbandonedModule, .exam)
        XCTAssertEqual(stage.moduleTick, 1, "退出不该再算一次完成")

        stage.ingest(.learnerTurn)
        XCTAssertEqual(stage.learnerTurnTick, 1)
        XCTAssertEqual(stage.teacherTurnTick, 0)

        stage.ingest(.teacherTurn)
        XCTAssertEqual(stage.teacherTurnTick, 1)
        XCTAssertEqual(stage.learnerTurnTick, 1)
    }

    /// 任何一条事件都算「学习上发生了点什么」——安静判据据此刷新。
    ///
    /// 反证：把 `ingest` 开头那行 `lastActivityAt = Date()` 删掉 → 时刻停在初始化 → 红。
    func testEveryEventRefreshesTheActivityClock() {
        let stage = ForestStage()
        let start = stage.lastActivityAt
        Thread.sleep(forTimeInterval: 0.02)
        stage.ingest(.learnerTurn)
        XCTAssertGreaterThan(stage.lastActivityAt, start, "事件必须刷新活动时刻（否则打盹判定永远过期）")
    }

    // MARK: - ③ 中间栏空地（纯函数）

    /// 轮次 → 株数：钳到 0…上限，负数当 0。
    func testGladePlantCountClampsToTheCeiling() {
        XCTAssertTrue(GladeGrowth.plants(rounds: 0).isEmpty)
        XCTAssertTrue(GladeGrowth.plants(rounds: -3).isEmpty, "负数不许长出负株")
        XCTAssertEqual(GladeGrowth.plants(rounds: 4).count, 4)
        XCTAssertEqual(GladeGrowth.plants(rounds: GladeGrowth.maxPlants + 20).count,
                       GladeGrowth.maxPlants, "超上限停在上限：再多就糊成一片")
    }

    /// 同一轮次必须长成**同一片**空地（视图会随滚动重绘，随机一抖就是花在跳位置）。
    func testGladeLayoutIsDeterministic() {
        let a = GladeGrowth.plants(rounds: 7)
        let b = GladeGrowth.plants(rounds: 7)
        XCTAssertEqual(a, b, "空地布局必须确定：重绘时不许换位置")
        XCTAssertEqual(Set(a.map(\.id)).count, a.count, "id 必须唯一（ForEach 会用到）")
    }

    /// 只在空地范围内长（两端留出边，别贴着气泡边缘）。
    func testGladePlantsStayInsideTheFloor() {
        for plant in GladeGrowth.plants(rounds: GladeGrowth.maxPlants) {
            XCTAssertTrue((0.05...0.95).contains(plant.x), "横向出界：\(plant.x)")
            XCTAssertTrue((0.7...1.25).contains(plant.scale), "缩放出界：\(plant.scale)")
        }
    }

    // MARK: - ④ 接线哨兵

    /// 老师说了一句：三处落库点**共用一处**发射（发射点一多就查不清「森林为什么没反应」）。
    ///
    /// 反证：把 `noteTeacherTurn()` 里的 emit 删掉 → 计数为 0 → 红。
    func testTeacherTurnIsEmittedFromExactlyOnePlace() throws {
        let chat = try source("AIServices/ChatService.swift")
        let emitLines = codeLines(chat).filter { $0.text.contains("emit(.teacherTurn") }
        XCTAssertEqual(emitLines.count, 1, "老师开口事件只允许一处发射（收口在 noteTeacherTurn）")
        let callSites = codeLines(chat).filter { $0.text.contains("noteTeacherTurn()") }
        // 定义 1 处 + 三处落库点调用
        XCTAssertEqual(callSites.count, 4, "三处老师落库点都要通知森林（含本地兜底那处）")
    }

    /// 学员开口：挂在 `send` 的既有落库点（`persist` 之后）。
    ///
    /// 反证：删掉 emit 那行 → 红。
    func testLearnerTurnIsEmittedAfterTheMessageIsPersisted() throws {
        let body = self.body(of: "public func send(_ text: String", in: try source("AIServices/ChatService.swift"))
        XCTAssertFalse(body.isEmpty, "找不到 ChatService.send")
        let lines = codeLines(body)
        guard let persistLine = lines.first(where: { $0.text.contains("persist(message)") })?.number,
              let emitLine = lines.first(where: { $0.text.contains("emit(.learnerTurn") })?.number else {
            return XCTFail("send 里缺落库或学员开口事件")
        }
        XCTAssertGreaterThan(emitLine, persistLine, "学员开口事件必须在消息落库**之后**发")
    }

    /// 五个模块的完成点都接上了（少一个就是森林对这个模块聋了）。
    ///
    /// 反证：删掉任意一个发射点 → 红。
    func testEveryModuleCompletionPointEmits() throws {
        let reading = self.body(of: "public func submitReading()", in: try source("AppUI/AppState+WritingReading.swift"))
        XCTAssertTrue(reading.contains("forest.ingest(.moduleCompleted(module: .reading))"))

        let writing = self.body(of: "public func submitWriting()", in: try source("AppUI/AppState+WritingReading.swift"))
        XCTAssertTrue(writing.contains("forest.ingest(.moduleCompleted(module: .writing))"))

        let listening = self.body(of: "public func finishListeningRound()", in: try source("AppUI/AppState+Listening.swift"))
        XCTAssertTrue(listening.contains("forest.ingest(.moduleCompleted(module: .listening))"))

        let shadowing = self.body(of: "public func finishShadowingRecording()", in: try source("AppUI/AppState+Shadowing.swift"))
        XCTAssertTrue(shadowing.contains("forest.ingest(.moduleCompleted(module: .shadowing))"))

        let vocabulary = self.body(of: "public func gradeVocabularyReviewCard", in: try source("AppUI/AppState+Vocabulary.swift"))
        XCTAssertTrue(vocabulary.contains("forest.ingest(.moduleCompleted(module: .vocabulary))"))

        let exam = self.body(of: "func settleExam(_ runner: ExamRunner", in: try source("AppUI/AppState+ExamMode.swift"))
        XCTAssertTrue(exam.contains("forest.ingest(abandoned"))

        let drill = self.body(of: "public func finishErrorDrill()", in: try source("AppUI/AppState+ErrorDrill.swift"))
        XCTAssertTrue(drill.contains("forest.ingest(session.isFinished"))
    }

    /// 退出判据：**完成与退出互斥**，同一个收场不许两边都发。
    ///
    /// 词汇复习是典型的双入口（判完最后一张 = 完成；还有没判的就收起 = 退出），
    /// 两处的判据必须互为反面，否则同一轮复习森林会演两遍。
    ///
    /// 反证：把 `finishVocabularyReview` 的判据改成恒真 → 与 grade 处重复 → 哨兵红。
    func testVocabularyCompletionAndAbandonmentAreMutuallyExclusive() throws {
        let grade = self.body(of: "public func gradeVocabularyReviewCard", in: try source("AppUI/AppState+Vocabulary.swift"))
        XCTAssertTrue(grade.contains("vocabularyReview?.current == nil"),
                      "完成判据：队列判空才算做完")

        let finish = self.body(of: "public func finishVocabularyReview()", in: try source("AppUI/AppState+Vocabulary.swift"))
        XCTAssertTrue(finish.contains("vocabularyReview?.current != nil"),
                      "退出判据：还有没判完的词才算提前退出（与完成互为反面）")
    }

    /// 地面把新通道都接上了戏码（接了脉冲却没戏 = 事件白发了）。
    ///
    /// 反证：删掉任意一个 onChange → 红。
    func testGroundBandPlaysEveryNewChannel() throws {
        let ground = try source("AppUI/Components/TreeCanvas.swift")
        for (tick, handler) in [("moduleTick", "playModuleSkit(module)"),
                                ("abandonTick", "waveGoodbye(module)"),
                                ("learnerTurnTick", "acknowledgeLearner()"),
                                ("teacherTurnTick", "listenUp()"),
                                ("huddleComfortTick", "huddleComfort()")] {
            let block = self.body(of: ".onChange(of: \(tick))", in: ground)
            XCTAssertFalse(block.isEmpty, "\(tick) 没有接线")
            XCTAssertTrue(block.contains(handler), "\(tick) 接了但没演戏")
        }
        XCTAssertTrue(ground.contains("dozeOffIfQuiet()"), "安静打盹必须挂在既有心跳上")
    }

    /// 主界面把新通道都装配进地面带（漏一个 = 这个通道永远不动）。
    ///
    /// 反证：删掉任意一行装配 → 红。
    func testMainViewWiresTheNewChannelsIntoGroundBand() throws {
        let main = try source("AppUI/Views/MainView.swift")
        for key in ["huddleComfortTick", "moduleTick", "lastModule", "abandonTick",
                    "lastAbandonedModule", "learnerTurnTick", "teacherTurnTick", "lastActivityAt"] {
            XCTAssertTrue(main.contains("\(key): state.forest.\(key)"), "主界面没装配 \(key)")
        }
    }

    /// 中间栏空地的动效预算：**没有**循环动画（阅读区不许有东西一直在动）。
    ///
    /// 反证：在 GladeFloor 里加一句 `repeatForever` → 红。
    func testGladeFloorHasNoLoopingAnimation() throws {
        let glade = try source("AppUI/Components/GladeFloor.swift")
        for line in codeLines(glade) {
            XCTAssertFalse(line.text.contains("repeatForever"), "林间空地不许有循环动画")
            XCTAssertFalse(line.text.contains("Timer.publish"), "林间空地不许挂常驻定时器")
        }
    }

    /// 空地挂在对话区底部（不是垫在消息流里随滚动跑）。
    ///
    /// 反证：删掉 ChatView 里那句 `.background(alignment: .bottom)` → 红。
    func testChatViewPinsTheGladeToTheBottom() throws {
        let chat = try source("AppUI/Views/ChatView.swift")
        XCTAssertTrue(chat.contains("GladeFloor(theme: theme, rounds: gladeRounds)"), "对话区必须挂上林间空地")
        XCTAssertTrue(chat.contains("alignment: .bottom"), "空地必须贴底（它是地面，不是内容）")
        let body = self.body(of: "private var gladeRounds", in: chat)
        XCTAssertTrue(body.contains("role == .user"), "空地长的是「你说过的话」——只数学员开口")
    }
}
