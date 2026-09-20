import AIDomain
import AIInfrastructure
import XCTest

/// 考试模式（雅思口语 / 面试问答）的领域层。
///
/// 这里钉住三类事：
/// 1. **流程状态机**（答一问进一问、跳过不卡住、题号不因跳过而错位）；
/// 2. **评分是纯函数且可核对** —— 分数曲线走锚点插值，报告必须带原始指标；
/// 3. **与课程 / 闯关体系彻底分开** —— 不引用 `Quest` / `Curriculum`，不产星星。
final class ExamModeTests: XCTestCase {

    // MARK: - 夹具

    private func stage(
        id: String = "s1",
        prompts: [String] = ["Q1", "Q2"],
        seconds: Int = 30,
        minimumWords: Int = 5
    ) -> ExamStage {
        ExamStage(
            id: id, title: "T", instructions: "i",
            prompts: prompts, timeLimitSeconds: seconds, minimumWords: minimumWords
        )
    }

    private func blueprint(stages: [ExamStage]? = nil) -> ExamBlueprint {
        ExamBlueprint(
            id: "test", format: .ieltsSpeaking, title: "测试卷", summary: "s",
            stages: stages ?? [stage()]
        )
    }

    /// 一句「够长且有从句」的作答。
    private let richAnswer =
        "I live in a small apartment near the river because it is quiet in the evening, "
        + "although the rent is quite high and the neighbours practise music quite often."

    // MARK: - 题库

    func testBundledBlueprintsLoad() {
        let blueprints = ExamCatalog.bundled()
        XCTAssertFalse(blueprints.isEmpty, "随包考卷资源必须读得到（Resources/Exams/*.json）")

        let formats = Set(blueprints.map(\.format))
        XCTAssertTrue(formats.contains(.ieltsSpeaking), "缺雅思口语考卷")
        XCTAssertTrue(formats.contains(.jobInterview), "缺面试考卷")

        for blueprint in blueprints {
            XCTAssertGreaterThan(blueprint.questionCount, 0, "\(blueprint.id) 一题都没有")
            XCTAssertFalse(blueprint.stages.isEmpty)
            for stage in blueprint.stages {
                XCTAssertFalse(stage.prompts.isEmpty, "\(blueprint.id)/\(stage.id) 没有问句")
                XCTAssertGreaterThanOrEqual(stage.timeLimitSeconds, 10)
                XCTAssertGreaterThanOrEqual(stage.minimumWords, 5)
                XCTAssertFalse(stage.instructions.isEmpty, "环节要有一句话的作答要求")
            }
        }
    }

    func testGroupedKeepsFormatsWithContentAndSkipsEmpty() {
        let grouped = ExamCatalog.grouped([
            blueprint(),
            ExamBlueprint(id: "empty", format: .jobInterview, title: "空", summary: "", stages: []),
        ])
        XCTAssertEqual(grouped.count, 1, "没有题目的考卷不该出现在列表里（进去就结束）")
        XCTAssertEqual(grouped.first?.format, .ieltsSpeaking)
    }

    // MARK: - 流程状态机

    func testSessionWalksPromptsThenStages() {
        var session = ExamSession(blueprint: blueprint(stages: [
            stage(id: "a", prompts: ["a1", "a2"]),
            stage(id: "b", prompts: ["b1"]),
        ]))
        XCTAssertEqual(session.questionNumber, 1)
        XCTAssertEqual(session.currentPrompt, "a1")
        XCTAssertEqual(session.totalQuestions, 3)
        XCTAssertFalse(session.isFinished)
        XCTAssertEqual(session.currentTimeLimitSeconds, 30)

        session.recordAnswer(text: richAnswer, seconds: 20)
        XCTAssertEqual(session.currentStage?.id, "a")
        XCTAssertEqual(session.currentPrompt, "a2")
        XCTAssertEqual(session.questionNumber, 2)

        session.recordAnswer(text: richAnswer, seconds: 20)
        XCTAssertEqual(session.currentStage?.id, "b", "本环节问完要进下一环节")
        XCTAssertEqual(session.questionNumber, 3)

        session.recordAnswer(text: richAnswer, seconds: 20)
        XCTAssertTrue(session.isFinished)
        XCTAssertNil(session.currentPrompt)
        XCTAssertEqual(session.currentTimeLimitSeconds, 0)
        XCTAssertEqual(session.answers.count, 3)
    }

    /// 跳过一题不该把整场卡住，也不该被记成一次作答。
    func testSkippingAdvancesWithoutRecording() {
        var session = ExamSession(blueprint: blueprint(stages: [stage(prompts: ["a1", "a2"])]))
        session.skipCurrentPrompt()
        XCTAssertEqual(session.currentPrompt, "a2")
        XCTAssertTrue(session.answers.isEmpty, "跳过不是作答")
        XCTAssertEqual(session.questionNumber, 2)
    }

    /// 空白作答不记录，但仍然推进（否则学员点发送空消息就把考试卡死）。
    func testBlankAnswerAdvancesWithoutRecording() {
        var session = ExamSession(blueprint: blueprint())
        let recorded = session.recordAnswer(text: "   \n ", seconds: 5)
        XCTAssertNil(recorded)
        XCTAssertTrue(session.answers.isEmpty)
        XCTAssertEqual(session.questionNumber, 2, "空作答也要推进，不能卡在原地")
    }

    /// ⚠️ 回归：题号必须在**作答当时**记下来。
    ///
    /// 曾经用 `answers` 的下标推题号 —— 中间跳过一题之后下标就与题号错位，
    /// 报告会写着「第 2 题只说了 3 词」，而第 2 题根本没答、被指的是答得最好的第 3 题。
    func testQuestionNumberSurvivesSkippedQuestions() {
        var session = ExamSession(blueprint: blueprint(stages: [stage(prompts: ["a1", "a2", "a3"])]))
        session.recordAnswer(text: richAnswer, seconds: 20)
        session.skipCurrentPrompt()
        session.recordAnswer(text: "ok", seconds: 3)

        XCTAssertEqual(session.answers.map(\.questionNumber), [1, 3], "跳过的第 2 题不该占掉第 3 题的号")

        let report = ExamScoring.report(for: session)
        XCTAssertEqual(report.metrics.shortestAnswer?.questionNumber, 3)
        XCTAssertEqual(report.metrics.undersizedQuestions, [3], "短答的是第 3 题，不是第 2 题")
        XCTAssertTrue(report.improvements.contains { $0.contains("第 3 题") })
    }

    func testFinishEarlyEndsSession() {
        var session = ExamSession(blueprint: blueprint(stages: [stage(prompts: ["a1", "a2"])]))
        session.finishEarly()
        XCTAssertTrue(session.isFinished)
        XCTAssertNil(session.recordAnswer(text: richAnswer, seconds: 10), "已结束就不再收作答")
    }

    // MARK: - 文本指标

    func testTokenizationAndSentences() {
        XCTAssertEqual(ExamScoring.wordCount(of: "I don't like it."), 4, "词内撇号算一个词")
        XCTAssertEqual(ExamScoring.sentences("One. Two? Three!").count, 3)
        XCTAssertEqual(ExamScoring.sentences("no terminator").count, 1)
        XCTAssertEqual(ExamScoring.sentences("   ").count, 0)
        // 虚词被剔掉，`river` 这类内容词留着
        let content = ExamScoring.contentWords("I live in a small apartment near the river")
        XCTAssertTrue(content.contains("river"))
        XCTAssertFalse(content.contains("the"))
        XCTAssertFalse(content.contains("in"))
    }

    func testFillerCountingExcludesLegitimateWords() {
        XCTAssertEqual(ExamScoring.fillerCount("Um, I uh think so."), 2)
        XCTAssertEqual(ExamScoring.fillerCount("You know, I mean it."), 2, "多词填充语也要数到")
        XCTAssertEqual(ExamScoring.fillerCount("I like it."), 0, "`like` 是正经单词，不该被算成填充词")
    }

    func testMetricsComputeFromRawAnswers() {
        var session = ExamSession(blueprint: blueprint(stages: [stage(prompts: ["a1", "a2"])]))
        session.recordAnswer(text: richAnswer, seconds: 30, errorCount: 2)
        session.recordAnswer(text: "Um, I do not know.", seconds: 30, errorCount: nil)

        let metrics = ExamScoring.metrics(for: session)
        XCTAssertEqual(metrics.answeredCount, 2)
        XCTAssertEqual(metrics.questionCount, 2)
        XCTAssertEqual(metrics.speakingSeconds, 60)
        XCTAssertEqual(metrics.totalWords, session.answers.reduce(0) { $0 + $1.wordCount })
        XCTAssertEqual(metrics.wordsPerMinute, Double(metrics.totalWords), accuracy: 0.001,
                       "60 秒说 N 词 → 就是 N 词/分")
        XCTAssertGreaterThan(metrics.fillerRatio, 0)
        XCTAssertGreaterThan(metrics.contentTypeTokenRatio, 0)
        XCTAssertGreaterThan(metrics.averageSentenceWords, 0)
        XCTAssertGreaterThan(metrics.clauseSentenceRatio, 0, "because / although 要能被认出来")
    }

    /// ⚠️ 「没有纠错数据」与「零错误」必须分得开 —— 混用会让语法分凭空变高。
    func testErrorRateDistinguishesNoDataFromZeroErrors() {
        var noData = ExamSession(blueprint: blueprint(stages: [stage(prompts: ["a1"], minimumWords: 5)]))
        noData.recordAnswer(text: richAnswer, seconds: 20, errorCount: nil)
        XCTAssertNil(ExamScoring.metrics(for: noData).errorsPerAnswer, "没数据就是 nil")

        var zeroErrors = ExamSession(blueprint: blueprint(stages: [stage(prompts: ["a1"], minimumWords: 5)]))
        zeroErrors.recordAnswer(text: richAnswer, seconds: 20, errorCount: 0)
        XCTAssertEqual(ExamScoring.metrics(for: zeroErrors).errorsPerAnswer, 0)

        let withData = ExamScoring.report(for: zeroErrors)
        let without = ExamScoring.report(for: noData)
        XCTAssertGreaterThan(
            withData.score(for: .grammar)!.band, without.score(for: .grammar)!.band,
            "零错误该比「没数据」高 —— 否则就是把「没测到」当成了「没问题」"
        )
        XCTAssertLessThanOrEqual(
            without.score(for: .grammar)!.band.value, 7.0,
            "拿不到纠错数据时语法分要封顶：句子够复杂不等于句子对"
        )
        XCTAssertTrue(without.score(for: .grammar)!.evidence.contains("封顶"))
    }

    func testWordsPerMinuteIsZeroWhenNoTimeRecorded() {
        var session = ExamSession(blueprint: blueprint())
        session.recordAnswer(text: richAnswer, seconds: 0)
        XCTAssertEqual(ExamScoring.metrics(for: session).wordsPerMinute, 0, "没有时长就不编语速")
    }

    // MARK: - 曲线与刻度

    func testBandClampsAndSnapsToHalfSteps() {
        XCTAssertEqual(ExamBand(7.24).value, 7.0)
        XCTAssertEqual(ExamBand(7.3).value, 7.5)
        XCTAssertEqual(ExamBand(-3).value, 0)
        XCTAssertEqual(ExamBand(99).value, 9)
        XCTAssertEqual(ExamBand(7).displayName, "7")
        XCTAssertEqual(ExamBand(7.5).displayName, "7.5")
    }

    func testRampInterpolatesAndDoesNotExtrapolate() {
        let anchors: [(value: Double, band: Double)] = [(0, 4), (10, 6), (20, 8)]
        XCTAssertEqual(ExamScoring.ramp(-5, anchors), 4, "低于首个锚点取下界")
        XCTAssertEqual(ExamScoring.ramp(5, anchors), 5, accuracy: 0.0001)
        XCTAssertEqual(ExamScoring.ramp(15, anchors), 7, accuracy: 0.0001)
        XCTAssertEqual(ExamScoring.ramp(999, anchors), 8, "高于末个锚点取上界，不外推")
    }

    // MARK: - 报告

    func testEmptyReportHasNoScoreInsteadOfZero() {
        var session = ExamSession(blueprint: blueprint())
        session.finishEarly()
        let report = ExamScoring.report(for: session)
        XCTAssertTrue(report.scores.isEmpty, "没作答就不该有维度分（给 0 分是在编排用户）")
        XCTAssertNil(report.overall)
        XCTAssertFalse(report.isComplete)
        XCTAssertTrue(report.improvements.contains { $0.contains("没有记录到任何作答") })
        XCTAssertTrue(report.highlights.isEmpty, "一条都没做到就别硬夸")
    }

    func testCompleteSessionProducesFourDimensionsWithoutPronunciation() {
        var session = ExamSession(blueprint: blueprint(stages: [
            stage(prompts: ["a1"], seconds: 60, minimumWords: 10)
        ]))
        session.recordAnswer(text: richAnswer, seconds: 40, errorCount: 0)

        let report = ExamScoring.report(for: session)
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(
            report.scores.map(\.dimension),
            [.fluency, .lexical, .grammar, .taskCompletion],
            "没有发音评测数据时，发音这一项就该缺席"
        )
        XCTAssertNil(report.score(for: .pronunciation))
        XCTAssertNotNil(report.overall)
        for score in report.scores {
            XCTAssertFalse(score.evidence.isEmpty, "\(score.dimension) 必须给出依据")
            XCTAssertGreaterThanOrEqual(score.band.value, 0)
            XCTAssertLessThanOrEqual(score.band.value, 9)
        }
        // 报告要用真实数字说话：依据里必须出现数字。
        for score in report.scores {
            XCTAssertTrue(
                score.evidence.contains { $0.isNumber },
                "\(score.dimension) 的依据里没有数字，等于空话：\(score.evidence)"
            )
        }
    }

    /// 发音只来自真实评测结果：传了才出现，且参与总分。
    func testPronunciationOnlyAppearsWhenSupplied() {
        var session = ExamSession(blueprint: blueprint(stages: [
            stage(prompts: ["a1"], seconds: 60, minimumWords: 10)
        ]))
        session.recordAnswer(text: richAnswer, seconds: 40, errorCount: 0)

        let without = ExamScoring.report(for: session)
        let with = ExamScoring.report(for: session, pronunciation: ExamBand(9))
        XCTAssertEqual(with.scores.map(\.dimension), ExamDimension.allCases,
                       "给了发音数据就该排进维度里（顺序按 allCases）")
        XCTAssertGreaterThan(with.overall!.value, without.overall!.value)
        XCTAssertTrue(with.score(for: .pronunciation)!.evidence.contains("音素级"))
    }

    func testUndersizedAnswersAreFlaggedWithRealNumbers() {
        var session = ExamSession(blueprint: blueprint(stages: [
            stage(prompts: ["a1", "a2"], seconds: 60, minimumWords: 25)
        ]))
        session.recordAnswer(text: "Yes, I do.", seconds: 40, errorCount: 0)
        session.recordAnswer(text: richAnswer, seconds: 40, errorCount: 0)

        let report = ExamScoring.report(for: session)
        XCTAssertEqual(report.metrics.undersizedQuestions, [1])
        XCTAssertTrue(
            report.improvements.contains { $0.contains("第 1 问") },
            "短答要具体指出是哪一问：\(report.improvements)"
        )
        // 任务完成度被拉低，但仍有分（不是 0）
        let completion = report.score(for: .taskCompletion)!
        XCTAssertGreaterThan(completion.band.value, 0)
        XCTAssertLessThan(completion.band.value, 8)
    }

    // MARK: - 与课程 / 闯关体系分开

    /// `ExamMode.swift` / `ExamScoring.swift` 只能依赖自己与 Foundation：
    /// 一旦引用了 `Quest` / `Curriculum` / 星星，两套评价就会互相污染，
    /// 而那种污染在界面上表现为「过期判定卡」这类很难查的怪象。
    func testExamDomainDoesNotTouchCourseOrQuestTypes() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/AILanguageCoachTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
        let forbidden = [
            "QuestPlan", "QuestStep", "QuestRule", "RewardToast", "ScenarioRewardRule",
            "Curriculum", "CEFRLevel", "stars",
        ]
        for name in ["ExamMode.swift", "ExamScoring.swift"] {
            let url = root.appendingPathComponent("Sources/AIDomain/\(name)")
            let text = try String(contentsOf: url, encoding: .utf8)
            // 注释里说明「为什么分开」是允许的，这里只看代码行。
            let code = text
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for token in forbidden {
                XCTAssertFalse(code.contains(token), "\(name) 不该引用课程/闯关体系的「\(token)」")
            }
        }
    }
}
