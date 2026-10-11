import AIDomain
import XCTest

/// ⑦-B② 碎片热身的**纯逻辑**：步骤编排、推进判据、结算文案。
///
/// 钉的三件事：
/// - 每一步都得有真依据（到期的词、真句子），凑不出的步骤不排；
/// - 推进只认当前这一步的种类（认词的键推不动跟读的步）；
/// - 结算上的每一个数字都来自真数据，不写死。
final class WarmUpTests: XCTestCase {

    // MARK: - 步骤编排

    func testPlanTakesAtMostThreeDueWords() {
        let plan = WarmUpPlan.plan(
            dueEntries: Self.entries(count: 5),
            shadowSentence: "Practice makes progress.",
            speakPrompt: "How was your day?"
        )
        XCTAssertEqual(plan.wordCount, WarmUpPlan.defaultWordCount,
                       "到期词再多也只走三个：热身是为了动起来，不是把待复习清干净")
        XCTAssertEqual(plan.total, 5, "3 个词 + 1 句跟读 + 1 句开口")
    }

    func testPlanDropsStepsWithoutEvidence() {
        let words = WarmUpPlan.plan(
            dueEntries: Self.entries(count: 2), shadowSentence: nil, speakPrompt: nil
        )
        XCTAssertEqual(words.steps.map(\.kind), [.word, .word], "没有句子就只认词，不凑三步")
        XCTAssertFalse(words.hasShadow)
        XCTAssertFalse(words.hasSpeak)
    }

    /// 空白句子不算依据：一句空白摆上去，用户点「跟读」读的是空气。
    func testBlankSentenceAndPromptAreDropped() {
        let plan = WarmUpPlan.plan(
            dueEntries: Self.entries(count: 1),
            shadowSentence: "   \n  ",
            speakPrompt: ""
        )
        XCTAssertEqual(plan.total, 1, "空白的不是句子，是没排上")
    }

    func testNothingToDoYieldsEmptyPlan() {
        let plan = WarmUpPlan.plan(dueEntries: [], shadowSentence: nil, speakPrompt: nil)
        XCTAssertTrue(plan.isEmpty, "一步都排不出来时 UI 整块不画，不留空壳")
        XCTAssertEqual(plan.compositionText, "", "空的那一轮不写任何构成")
    }

    func testOnlyMasteredWordsProduceNoWordStep() {
        let masteredEntries = Self.entries(count: 3).map { entry -> VocabularyEntry in
            var copy = entry
            copy.mastery = 5
            return copy
        }
        let due = VocabularyReviewSession.queue(from: masteredEntries, now: Date(), limit: 3)
        XCTAssertTrue(due.isEmpty, "已掌握的词不该出现在到期队列里")
        let plan = WarmUpPlan.plan(dueEntries: due, shadowSentence: nil, speakPrompt: nil)
        XCTAssertTrue(plan.isEmpty)
    }

    func testDueQueueRespectsLimit() {
        let due = VocabularyReviewSession.queue(from: Self.entries(count: 9), now: Date(), limit: 3)
        XCTAssertEqual(due.count, 3)
        let plan = WarmUpPlan.plan(dueEntries: due, shadowSentence: "Hello there.", speakPrompt: nil)
        XCTAssertEqual(plan.wordCount, 3, "队列已经夹过上限，编排不再放大")
    }

    // MARK: - 构成与预估

    func testCompositionTextCountsRealSteps() {
        let full = WarmUpPlan.plan(
            dueEntries: Self.entries(count: 3),
            shadowSentence: "Practice makes progress.",
            speakPrompt: "How was your day?"
        )
        XCTAssertEqual(full.compositionText, "3 个到期词 · 1 句跟读 · 1 句开口")

        let twoWords = WarmUpPlan.plan(
            dueEntries: Self.entries(count: 2), shadowSentence: nil, speakPrompt: nil
        )
        XCTAssertEqual(twoWords.compositionText, "2 个到期词", "词数来自真队列，不是写死的 3")
    }

    /// 预估按步骤构成算：少一步就少一截，不许整轮写死「90 秒」。
    func testEstimateGrowsWithSteps() {
        let wordsOnly = WarmUpPlan.plan(
            dueEntries: Self.entries(count: 2), shadowSentence: nil, speakPrompt: nil
        )
        let full = WarmUpPlan.plan(
            dueEntries: Self.entries(count: 3),
            shadowSentence: "Practice makes progress.",
            speakPrompt: "How was your day?"
        )
        XCTAssertLessThan(wordsOnly.estimatedSeconds, full.estimatedSeconds)
        XCTAssertFalse(full.estimateText.isEmpty)
        XCTAssertEqual(
            full.estimatedSeconds,
            full.steps.reduce(0) { $0 + $1.estimatedSeconds },
            "预估就是各步之和，不另外拍一个数"
        )
    }

    func testMaxWordsOfZeroDropsAllWords() {
        let plan = WarmUpPlan.plan(
            dueEntries: Self.entries(count: 3),
            shadowSentence: "Hello there.",
            speakPrompt: nil,
            maxWords: 0
        )
        XCTAssertEqual(plan.wordCount, 0)
        XCTAssertEqual(plan.total, 1)
    }

    // MARK: - 按天抽句子

    func testPickedSentenceIsStableWithinADay() {
        let pool = Self.sentencePool
        let first = WarmUpPlan.pickSentence(from: pool, dayKey: "2026-10-12", language: "en-US")
        let again = WarmUpPlan.pickSentence(from: pool, dayKey: "2026-10-12", language: "en-US")
        XCTAssertEqual(first, again, "同一天必须同一句：看中了没点，回来还是它")
        XCTAssertNotNil(first)
    }

    func testPickedSentenceRotatesAcrossDays() {
        let pool = Self.sentencePool
        var seen: Set<String> = []
        for day in 1...9 {
            if let picked = WarmUpPlan.pickSentence(from: pool, dayKey: "2026-10-\(day)", language: "en-US") {
                seen.insert(picked)
            }
        }
        XCTAssertGreaterThan(seen.count, 1, "九天里天天同一句的话，「按天轮换」就是假的")
    }

    /// 跟读句与开口提示各走各的种子：否则两步永远抽到同一句，看着像同一步做两遍。
    func testSentenceAndPromptDoNotRotateInLockstep() {
        let pool = Self.sentencePool
        var sentences: [String] = []
        var prompts: [String] = []
        for day in 1...9 {
            sentences.append(WarmUpPlan.pickSentence(from: pool, dayKey: "2026-10-\(day)", language: "en-US") ?? "")
            prompts.append(WarmUpPlan.pickPrompt(from: pool, dayKey: "2026-10-\(day)", language: "en-US") ?? "")
        }
        XCTAssertNotEqual(sentences, prompts, "两个抽取必须各走各的序列")
    }

    func testEmptyPoolYieldsNil() {
        XCTAssertNil(WarmUpPlan.pickSentence(from: [], dayKey: "2026-10-12", language: "en-US"))
        XCTAssertNil(WarmUpPlan.pickPrompt(from: ["   "], dayKey: "2026-10-12", language: "en-US"))
    }

    // MARK: - 推进

    func testGradeAdvancesOnlyOnAWordStep() {
        var progress = Self.progress(steps: [.shadow(sentence: "Hello there.")])
        XCTAssertFalse(progress.gradeCurrentWord(remembered: true),
                       "跟读这一步没有「记得 / 忘了」，认词的键推不动它")
        XCTAssertEqual(progress.index, 0)
        XCTAssertEqual(progress.remembered, 0)
    }

    func testMarkShadowAdvancesOnlyOnAShadowStep() {
        var progress = Self.progress(steps: [.word(entryID: UUID(), word: "resilient")])
        XCTAssertFalse(progress.markShadow(score: 80), "认词这一步不记跟读分")
        XCTAssertNil(progress.shadowScore)
        XCTAssertEqual(progress.index, 0)
    }

    /// 空白的「听到的原话」一律记成 nil：拿空串冒充「说过」会让结算写着「开口 1 句」。
    func testBlankSpokenTextIsRecordedAsNil() {
        var progress = Self.progress(steps: [.speak(prompt: "How was your day?")])
        XCTAssertTrue(progress.markSpoken("   \n "))
        XCTAssertNil(progress.spokenText)
        XCTAssertTrue(progress.isFinished)
    }

    /// 跳过不计成绩：没判就是没判，不能算进「忘了」。
    func testSkippingAWordIsNotCountedAsForgotten() {
        var progress = Self.progress(steps: [
            .word(entryID: UUID(), word: "resilient"),
            .word(entryID: UUID(), word: "fragile")
        ])
        XCTAssertTrue(progress.skipCurrent())
        XCTAssertTrue(progress.gradeCurrentWord(remembered: true))
        XCTAssertEqual(progress.remembered, 1)
        XCTAssertEqual(progress.forgotten, 0, "跳过的那个词既不算记得也不算忘了")
    }

    func testSkippingPastTheLastStepDoesNothing() {
        var progress = Self.progress(steps: [.word(entryID: UUID(), word: "resilient")])
        XCTAssertTrue(progress.skipCurrent())
        XCTAssertTrue(progress.isFinished)
        XCTAssertFalse(progress.skipCurrent(), "走完之后没有「下一步」可跳")
    }

    // MARK: - 结算

    func testSummaryInterpolatesRealNumbers() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var progress = Self.progress(steps: [
            .word(entryID: UUID(), word: "resilient"),
            .word(entryID: UUID(), word: "fragile"),
            .word(entryID: UUID(), word: "lucid")
        ], now: start)
        XCTAssertTrue(progress.gradeCurrentWord(remembered: true))
        XCTAssertTrue(progress.gradeCurrentWord(remembered: true))
        XCTAssertTrue(progress.gradeCurrentWord(remembered: false))
        progress.finish(now: start.addingTimeInterval(72))

        let summary = progress.summary(now: start.addingTimeInterval(600))
        XCTAssertEqual(summary.headline, "记得 2/3 · 用时 1 分 12 秒")
        XCTAssertEqual(summary.detail, "走完 3/3 步")
    }

    /// 用时钉在结束那一刻：结算卡挂在屏幕上，数字不能再往后长。
    func testElapsedStopsGrowingAfterFinish() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var progress = Self.progress(steps: [.word(entryID: UUID(), word: "resilient")], now: start)
        XCTAssertTrue(progress.gradeCurrentWord(remembered: true))
        progress.finish(now: start.addingTimeInterval(30))
        XCTAssertEqual(
            progress.summary(now: start.addingTimeInterval(900)).elapsedSeconds, 30,
            "跑完就钉住 —— 结算卡挂着不动，用时却在涨，是最容易被当成 bug 的一种错觉"
        )
    }

    func testSummaryWithoutWordsDoesNotClaimAScore() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var progress = Self.progress(steps: [.shadow(sentence: "Hello there.")], now: start)
        XCTAssertTrue(progress.markShadow(score: 81.6))
        progress.finish(now: start.addingTimeInterval(45))
        let summary = progress.summary(now: start)
        XCTAssertNil(summary.scoreText, "一轮没带词时写「记得 0/0」是在编数字")
        XCTAssertEqual(summary.headline, "热身完成 · 用时 45 秒")
        XCTAssertEqual(summary.detail, "跟读 82 分")
    }

    func testSummaryReportsSpokenTurn() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var progress = Self.progress(steps: [.speak(prompt: "How was your day?")], now: start)
        XCTAssertTrue(progress.markSpoken("I had a good day."))
        progress.finish(now: start.addingTimeInterval(40))
        let summary = progress.summary(now: start)
        XCTAssertEqual(summary.spokenText, "I had a good day.")
        XCTAssertTrue(summary.detail.contains("开口 1 句"), "实测：\(summary.detail)")
    }

    // MARK: - 工装

    private static func entries(count: Int) -> [VocabularyEntry] {
        (0..<count).map { index in
            VocabularyEntry(word: "word-\(index)")
        }
    }

    private static func progress(steps: [WarmUpStep], now: Date = Date()) -> WarmUpProgress {
        WarmUpProgress(plan: WarmUpPlan(steps: steps), now: now)
    }

    private static let sentencePool: [String] = {
        (0..<12).map { "Sentence number \($0) for a warm up drill." }
    }()
}
