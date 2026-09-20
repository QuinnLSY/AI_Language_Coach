import AIDomain
import AIInfrastructure
import XCTest

/// 考试模式的**进行时**：计时口径与题号口径。
///
/// `ExamModeTests` 钉的是考卷流程与评分；这里钉的是「一场考试在跑的时候
/// 什么时候起表、答了多久、纠错补记到哪一题」—— 这些是最容易悄悄算错、
/// 而且算错以后**看起来仍然很正常**的地方（倒计时照走、分数照出）。
///
/// 全部用注入的时间点（`now:`），测试里没有任何 `sleep`。
final class ExamRunnerTests: XCTestCase {

    // MARK: - 夹具

    /// 一个确定的时间原点，避免用例被「现在几点」影响。
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func stage(
        id: String = "s1",
        prompts: [String] = ["Q1", "Q2"],
        seconds: Int = 30,
        minimumWords: Int = 8
    ) -> ExamStage {
        ExamStage(
            id: id, title: "环节 \(id)", instructions: "按这个环节的要求答",
            prompts: prompts, timeLimitSeconds: seconds, minimumWords: minimumWords
        )
    }

    private func blueprint(stages: [ExamStage]? = nil) -> ExamBlueprint {
        ExamBlueprint(
            id: "test.exam", format: .ieltsSpeaking, title: "测试考卷", summary: "用于单测",
            stages: stages ?? [stage()]
        )
    }

    /// 一段「够长」的作答（8 词以上，满足默认期望长度）。
    private let goodAnswer =
        "I live in a small apartment near the river because it is quiet at night."

    // MARK: - 计时

    func testClockRunsOnlyAfterTheQuestionIsShown() {
        var runner = ExamRunner(blueprint: blueprint(), startedAt: t0)

        XCTAssertFalse(runner.isArmed, "考官还没开口时不该起表")
        XCTAssertNil(runner.questionDeadline)
        XCTAssertNil(runner.remainingSeconds(now: t0.addingTimeInterval(5)))
        XCTAssertFalse(runner.isTimedOut(now: t0.addingTimeInterval(600)), "没起表的题不该被判超时")

        runner.arm(now: t0)
        XCTAssertTrue(runner.isArmed)
        XCTAssertEqual(
            runner.questionDeadline, t0.addingTimeInterval(30),
            "截止时刻 = 起表 + 这一环节的限时"
        )
        XCTAssertEqual(runner.remainingSeconds(now: t0.addingTimeInterval(10)), 20)
        XCTAssertFalse(runner.isTimedOut(now: t0.addingTimeInterval(29)))
        XCTAssertTrue(runner.isTimedOut(now: t0.addingTimeInterval(31)))
    }

    /// 重复起表只认第一次：后到的会凭空给学员加时间。
    func testSecondArmIsIgnored() {
        var runner = ExamRunner(blueprint: blueprint(), startedAt: t0)
        runner.arm(now: t0)
        runner.arm(now: t0.addingTimeInterval(20))
        XCTAssertEqual(
            runner.questionDeadline, t0.addingTimeInterval(30),
            "老师分两条消息说完同一问，也不该把倒计时重置"
        )
    }

    /// 作答时长从**起表**算起，不把老师生成下一问的耗时算进学员头上。
    func testSubmitMeasuresFromArmTimeNotFromAdvance() {
        var runner = ExamRunner(blueprint: blueprint(), startedAt: t0)
        // 上一问答完 → 老师想了 40 秒才开口 → 题目出现 → 学员说了 12 秒
        let armedAt = t0.addingTimeInterval(40)
        runner.arm(now: armedAt)

        let answer = runner.submit(text: goodAnswer, now: armedAt.addingTimeInterval(12))
        XCTAssertEqual(answer?.seconds, 12, "40 秒的等待不是学员的说话时间")
        XCTAssertEqual(answer?.questionNumber, 1)
        XCTAssertEqual(runner.questionNumber, 2, "答完自动进下一问")
        XCTAssertFalse(runner.isArmed, "下一问要等考官开口才起表")
        XCTAssertNil(runner.questionDeadline)
    }

    /// 老师一直没开口（没起表）时退化为「从切到这一问算起」，**不能记成 0 秒** ——
    /// 0 秒会被评分当成「没有这一路数据」，语速分直接掉到最低档。
    func testSubmitWithoutArmFallsBackToAdvanceTime() {
        var runner = ExamRunner(blueprint: blueprint(), startedAt: t0)
        let answer = runner.submit(text: goodAnswer, now: t0.addingTimeInterval(7))
        XCTAssertEqual(answer?.seconds, 7)
    }

    func testBlankAnswerIsNotRecordedButStillAdvances() {
        var runner = ExamRunner(blueprint: blueprint(), startedAt: t0)
        runner.arm(now: t0)
        XCTAssertNil(runner.submit(text: "   \n ", now: t0.addingTimeInterval(3)))
        XCTAssertTrue(runner.answers.isEmpty)
        XCTAssertEqual(runner.questionNumber, 2, "空白作答不记录，但不能把整场卡住")
    }

    func testSkipAdvancesWithoutRecording() {
        var runner = ExamRunner(blueprint: blueprint(), startedAt: t0)
        runner.arm(now: t0)
        runner.skip(now: t0.addingTimeInterval(31))
        XCTAssertTrue(runner.answers.isEmpty, "跳过不产生作答记录")
        XCTAssertEqual(runner.questionNumber, 2)
        XCTAssertFalse(runner.isArmed)
        XCTAssertFalse(
            runner.isTimedOut(now: t0.addingTimeInterval(999)),
            "跳过之后就不该再被判超时（否则一题会连跳好几问）"
        )
    }

    // MARK: - 题号口径

    /// 跳过一题之后，后面的题号**不许错位**：
    /// 错位的题号会在报告里指着「第 3 题只说了 8 词」，而那可能是答得最好的一题。
    func testQuestionNumbersSurviveSkips() {
        let stages = [
            stage(id: "a", prompts: ["A1", "A2"]),
            stage(id: "b", prompts: ["B1", "B2"]),
        ]
        var runner = ExamRunner(blueprint: blueprint(stages: stages), startedAt: t0)

        runner.arm(now: t0)
        runner.submit(text: goodAnswer, now: t0.addingTimeInterval(5))   // 第 1 问
        runner.arm(now: t0.addingTimeInterval(10))
        runner.skip(now: t0.addingTimeInterval(12))                       // 第 2 问：跳过
        runner.arm(now: t0.addingTimeInterval(20))
        runner.submit(text: goodAnswer, now: t0.addingTimeInterval(25))   // 第 3 问
        runner.arm(now: t0.addingTimeInterval(30))
        runner.submit(text: goodAnswer, now: t0.addingTimeInterval(33))   // 第 4 问

        XCTAssertEqual(runner.answers.map(\.questionNumber), [1, 3, 4])
        XCTAssertEqual(runner.answers.map(\.stageID), ["a", "b", "b"])
        XCTAssertTrue(runner.isFinished)
        XCTAssertEqual(runner.answeredCountForTest, 3)
    }

    func testTurnContextPointsAtTheQuestionToAskNow() throws {
        var runner = ExamRunner(blueprint: blueprint(), startedAt: t0)
        let opener = try XCTUnwrap(runner.turnContext)
        XCTAssertEqual(opener.questionNumber, 1)
        XCTAssertEqual(opener.answeredQuestionNumber, 0, "还没答过 = 这是开场")
        XCTAssertEqual(opener.prompt, "Q1")
        XCTAssertEqual(opener.isClosing, false)
        XCTAssertEqual(opener.minimumWords, 8)
        XCTAssertEqual(opener.timeLimitSeconds, 30)

        runner.arm(now: t0)
        runner.submit(text: goodAnswer, now: t0.addingTimeInterval(6))
        let second = runner.turnContext
        XCTAssertEqual(second?.questionNumber, 2, "老师这一轮该问第 2 问")
        XCTAssertEqual(second?.answeredQuestionNumber, 1, "学员刚答完第 1 问")
        XCTAssertEqual(second?.prompt, "Q2")
    }

    func testFinishEarlyGivesClosingContextAndNoNextQuestion() {
        var runner = ExamRunner(blueprint: blueprint(), startedAt: t0)
        runner.arm(now: t0)
        runner.submit(text: goodAnswer, now: t0.addingTimeInterval(6))
        runner.finishEarly(now: t0.addingTimeInterval(20))

        XCTAssertTrue(runner.isFinished)
        XCTAssertNil(runner.turnContext, "考完了就没有「下一问」")
        XCTAssertNil(runner.questionDeadline)
        let closing = runner.closingContext
        XCTAssertEqual(closing?.isClosing, true)
        XCTAssertEqual(closing?.answeredQuestionNumber, 1)
        XCTAssertFalse(closing?.prompt.isEmpty ?? true, "收场也要有上下文可依")
    }

    // MARK: - 纠错补记（语法分的依据）

    func testErrorCountIsAttachedOnceAndNeverOverwritten() {
        var runner = ExamRunner(blueprint: blueprint(), startedAt: t0)
        runner.arm(now: t0)
        runner.submit(text: goodAnswer, now: t0.addingTimeInterval(6))
        XCTAssertNil(runner.answers.first?.errorCount, "作答当时还没有纠错数据")

        XCTAssertTrue(runner.attachErrorCount(3, toQuestion: 1))
        XCTAssertEqual(runner.answers.first?.errorCount, 3)
        XCTAssertFalse(runner.attachErrorCount(0, toQuestion: 1), "已有数据不该被覆盖")
        XCTAssertEqual(runner.answers.first?.errorCount, 3)
        XCTAssertFalse(runner.attachErrorCount(1, toQuestion: 9), "没有这一题")
    }

    // MARK: - 示范答案：挑题与解析

    /// 跳过的题优先、答得太短的次之。
    func testSampleAnswerTargetsPutSkippedFirstThenShort() {
        let stages = [stage(id: "a", prompts: ["Q1", "Q2", "Q3", "Q4", "Q5"], minimumWords: 12)]
        var runner = ExamRunner(blueprint: blueprint(stages: stages), startedAt: t0)
        runner.arm(now: t0)
        runner.submit(text: goodAnswer, now: t0.addingTimeInterval(5))        // Q1 够长
        runner.skip(now: t0.addingTimeInterval(6))                            // Q2 跳过
        runner.arm(now: t0.addingTimeInterval(10))
        runner.submit(text: "It is fine.", now: t0.addingTimeInterval(12))    // Q3 太短
        runner.arm(now: t0.addingTimeInterval(20))
        runner.submit(text: goodAnswer, now: t0.addingTimeInterval(25))       // Q4 够长
        runner.arm(now: t0.addingTimeInterval(30))
        runner.submit(text: goodAnswer, now: t0.addingTimeInterval(33))       // Q5 够长

        XCTAssertTrue(runner.isFinished)
        let report = runner.report()
        let targets = ExamSampleAnswerRule.targets(session: runner.session, report: report)
        XCTAssertEqual(targets, [2, 3], "跳过的最该补，其次是答得太短的")

        let items = ExamSampleAnswerRule.items(for: targets, in: runner.session)
        XCTAssertEqual(items.map(\.questionNumber), [2, 3])
        XCTAssertEqual(items[0].prompt, "Q2")
        XCTAssertEqual(items[0].answer, "", "跳过的题没有原答")
        XCTAssertEqual(items[1].answer, "It is fine.")
    }

    /// 上限三问：整场一道没答（提前交卷）时也不该把八道题都写一遍。
    func testSampleAnswerTargetsAreCappedAtThree() {
        let stages = [stage(id: "a", prompts: ["Q1", "Q2", "Q3", "Q4", "Q5"], minimumWords: 12)]
        var runner = ExamRunner(blueprint: blueprint(stages: stages), startedAt: t0)
        runner.finishEarly(now: t0.addingTimeInterval(3))

        let report = runner.report()
        XCTAssertTrue(report.scores.isEmpty, "没有任何作答就没有分（不编一个 0 出来）")
        let targets = ExamSampleAnswerRule.targets(session: runner.session, report: report)
        XCTAssertEqual(targets, [1, 2, 3])
        XCTAssertEqual(targets.count, ExamSampleAnswerRule.maxTargets)
    }

    func testSampleAnswerTargetsAreEmptyWhenEverythingWasAnsweredWell() {
        let stages = [stage(id: "a", prompts: ["Q1", "Q2"], minimumWords: 5)]
        var runner = ExamRunner(blueprint: blueprint(stages: stages), startedAt: t0)
        for _ in 0..<2 {
            runner.arm(now: t0)
            runner.submit(text: goodAnswer, now: t0.addingTimeInterval(5))
        }
        let report = runner.report()
        XCTAssertTrue(report.isComplete)
        XCTAssertTrue(
            ExamSampleAnswerRule.targets(session: runner.session, report: report).isEmpty,
            "每题都答够了就不该硬凑示范答案（也不该为它发一次请求）"
        )
    }

    func testSampleAnswerParsingKeepsOnlyMarkedLines() {
        let text = """
        好的，下面是示范答案：

        [[SAMPLE]] 2 || I would say that living near a river is a mixed blessing.
        [[SAMPLE]] 5 || Although some people prefer cities, I find small towns calmer.
        希望这些对你有帮助。
        [[SAMPLE]] abc || not a number
        [[SAMPLE]] 3
        [[SAMPLE]] 2 || duplicate line, ignored
        """
        let parsed = ExamSampleAnswerRule.parse(text)
        XCTAssertEqual(parsed.count, 2, "只认标记行，杂音一律丢掉")
        XCTAssertEqual(parsed[2], "I would say that living near a river is a mixed blessing.")
        XCTAssertEqual(parsed[5], "Although some people prefer cities, I find small towns calmer.")
        XCTAssertNil(parsed[3], "缺正文的行不算答案")
    }

    // MARK: - Prompt 组装（考官口径）

    func testExaminerBlockCarriesTheQuestionAndTheAskNote() throws {
        var runner = ExamRunner(blueprint: blueprint(), startedAt: t0)
        let opener = try XCTUnwrap(runner.turnContext)
        let opening = PromptBuilder.examExaminerBlock(
            opener, learningLanguage: "English", nativeLanguage: "简体中文"
        )
        XCTAssertTrue(opening.contains("Q1"), "考官必须知道要问哪一句")
        XCTAssertTrue(opening.contains("测试考卷"))
        XCTAssertTrue(opening.contains("Nobody has answered yet"), "开场与答完一问的口径必须不同")
        XCTAssertFalse(opening.contains("{prompt}"), "占位符必须全部被替换掉")

        runner.arm(now: t0)
        runner.submit(text: goodAnswer, now: t0.addingTimeInterval(6))
        let afterAnswer = try XCTUnwrap(runner.turnContext)
        let block = PromptBuilder.examExaminerBlock(
            afterAnswer, learningLanguage: "English", nativeLanguage: "简体中文"
        )
        XCTAssertTrue(block.contains("Q2"))
        XCTAssertTrue(block.contains("just answered question 1"), "要承接上一问的题号")
        XCTAssertFalse(block.contains("{answered}"))

        let prompt = PromptBuilder.examSampleAnswerPrompt(
            examTitle: "测试考卷",
            targets: [ExamSampleTarget(questionNumber: 2, prompt: "Q2", answer: "")],
            learningLanguage: "English",
            nativeLanguage: "简体中文"
        )
        XCTAssertTrue(prompt.contains("[[SAMPLE]]"), "输出格式必须写清楚，解析才有依据")
        XCTAssertTrue(prompt.contains("2. Q2"))
        XCTAssertFalse(prompt.contains("{questions}"))
    }

    /// 收场口径：不能再提问、不能评分。
    func testClosingNoteForbidsQuestionsAndScores() throws {
        var runner = ExamRunner(blueprint: blueprint(), startedAt: t0)
        runner.arm(now: t0)
        runner.submit(text: goodAnswer, now: t0.addingTimeInterval(6))
        runner.finishEarly(now: t0.addingTimeInterval(10))
        let closing = try XCTUnwrap(runner.closingContext)
        let block = PromptBuilder.examExaminerBlock(
            closing, learningLanguage: "English", nativeLanguage: "简体中文"
        )
        XCTAssertTrue(block.contains("has ended"))
        XCTAssertTrue(block.contains("do not give any score"))
        XCTAssertFalse(block.contains("Q2"), "收场不该再把下一问抛出去")
    }
}

private extension ExamRunner {
    /// 单测读数用：答了几问（生产代码里这个数由 `ExamMetrics` 从作答里数）。
    var answeredCountForTest: Int { answers.count }
}
