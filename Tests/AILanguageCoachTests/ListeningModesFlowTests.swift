import AIDomain
import AIInfrastructure
import AIServices
@testable import AppUI
import XCTest

/// 听力三种形式在 `AppState` 上的接线（#309）。
///
/// 判分口径由 `ListeningModesTests` 钉住（纯函数）；这里只管**会话怎么走**：
/// 换形式会不会丢进度、选择题点完还能不能改、出不了题的句子会不会把人卡住、
/// 三种形式是不是共用同一本当天账本。
///
/// ⚠️ 会碰 `UserDefaults`（`listening.log` 就存在那儿）—— 每条都先快照、`defer` 原样放回：
/// 测试数据绝不能留在开发机上（那是**真实用户数据**）。
///
/// ⚠️ **每一条会写账本的用例都要 isolate，一条都不能漏**：`submitXxx` / `chooseListeningMeaning`
/// 会当场记账，漏掉的那条就把脏值留在了这个域里，而之后所有用例「快照 → 还原」
/// 会把脏值一路带下去（实测漏了一条，`ListeningFlowTests` 立刻虚报 4 条失败：
/// 它期望「今天写了 1 句」，读到的却是 2 句）。
///
/// ⚠️ 想控制「这一轮是哪几句」，必须走 `listeningRound`（而不是 `shadowingDrills`）：
/// `startListeningDrill()` 会按日期轮转**重新取一轮**，句序随日子变。
@MainActor
final class ListeningModesFlowTests: XCTestCase {

    private func makeState() -> AppState {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("listening-modes-\(UUID().uuidString).json")
        )
        return AppState(services: CoachServices(config: store, databasePath: ":memory:"))
    }

    private func isolateListeningLog() -> () -> Void {
        let key = AppState.listeningLogStorageKey
        let saved = UserDefaults.standard.data(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        return {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    private func drill(_ id: String, _ text: String, _ translation: String = "") -> ShadowingDrill {
        ShadowingDrill(id: id, text: text, translation: translation, topic: "测试")
    }

    /// 把「这一轮是这几句」直接摆好（绕过按日期轮转的取数）。
    private func beginRound(_ round: [ShadowingDrill], mode: ListeningMode, on state: AppState) {
        state.listeningRound = round
        state.listeningIndex = 0
        state.isListeningDrill = true
        state.listeningMode = mode
        if mode == .meaning { state.prepareMeaningQuestion() }
    }

    // MARK: - 换形式不丢进度

    /// 三种形式练的是**同一批句子**，换个问法不该从头再来。
    func testSwitchingModeKeepsTheRoundAndTheProgress() async {
        let state = makeState()
        state.shadowingDrills = (0..<12).map { drill("d\($0)", "line number \($0)", "第 \($0) 句") }
        await state.startListeningDrill()
        let round = state.listeningRound.map(\.id)
        state.listeningIndex = 3

        state.switchListeningMode(.keyword)

        XCTAssertEqual(state.listeningMode, .keyword)
        XCTAssertEqual(state.listeningRound.map(\.id), round, "换形式不许换句子")
        XCTAssertEqual(state.listeningIndex, 3, "换形式不许清进度")
        XCTAssertTrue(state.isListeningDrill, "还在这一轮里")
    }

    /// 换形式只清「这一句的作答」—— 这一轮的累计（已经交过的句数）不动。
    func testSwitchingModeClearsOnlyTheCurrentAnswer() async {
        let snapshot = isolateListeningLog()
        defer { snapshot() }

        let state = makeState()
        beginRound([drill("d0", "Can I have a receipt", "能给我收据吗")], mode: .dictation, on: state)
        state.listeningDraft = "can i have a receipt"
        state.submitListeningDraft()
        XCTAssertNotNil(state.listeningResult)
        XCTAssertEqual(state.listeningAttempts.count, 1)

        state.switchListeningMode(.keyword)

        XCTAssertNil(state.listeningResult, "上一句的对照不能挂到新形式下")
        XCTAssertTrue(state.listeningDraft.isEmpty)
        XCTAssertTrue(state.listeningKeywordDraft.isEmpty)
        XCTAssertEqual(state.listeningAttempts.count, 1, "这一轮已经交过的成绩不动")
    }

    /// 换形式不清 `UserDefaults` 里的账本：今天练过的句子跟形式无关。
    func testSwitchingModeKeepsTheDailyLog() async {
        let snapshot = isolateListeningLog()
        defer { snapshot() }

        let state = makeState()
        beginRound([drill("d0", "Where is the gate", "登机口在哪里")], mode: .dictation, on: state)
        state.listeningDraft = "where is the gate"
        state.submitListeningDraft()
        XCTAssertEqual(state.listeningLog.resolvedCount, 1)

        state.switchListeningMode(.meaning)

        XCTAssertEqual(state.listeningLog.resolvedCount, 1, "换个练法不该把今天练过的句子抹掉")
    }

    /// 换到选择题形式时**立刻**出一句题（不是等到用户点了播放才有题）。
    func testSwitchingToMeaningPreparesAQuestion() async {
        let state = makeState()
        state.shadowingDrills = (0..<8).map { drill("d\($0)", "line number \($0)", "第 \($0) 句") }
        await state.startListeningDrill()
        XCTAssertEqual(state.listeningMode, .dictation)
        XCTAssertNil(state.listeningMeaningQuestion)

        state.switchListeningMode(.meaning)

        XCTAssertNotNil(state.listeningMeaningQuestion, "换到选义就该有题可答")
        XCTAssertNil(state.listeningMeaningSelection)
    }

    /// 开新一轮**不重置形式**：刚选好的练法要留着（不然每轮都要重新选一次）。
    func testStartingARoundKeepsTheChosenMode() async {
        let state = makeState()
        state.shadowingDrills = (0..<12).map { drill("d\($0)", "line number \($0)", "第 \($0) 句") }
        state.listeningMode = .keyword
        state.listeningKeywordDraft = "上一轮留下的草稿"

        await state.startListeningDrill()

        XCTAssertEqual(state.listeningMode, .keyword)
        XCTAssertTrue(state.listeningKeywordAttempts.isEmpty)
        XCTAssertNil(state.listeningKeywordResult)
        XCTAssertTrue(state.listeningKeywordDraft.isEmpty, "开新一轮要清掉上一轮的草稿")
    }

    /// 空素材时开一轮：给一句人话，不是一张空卡。
    func testStartWithoutMaterialFallsBackToABundledRound() async {
        let state = makeState()
        state.listeningRound = []
        state.isListeningDrill = false

        await state.startListeningDrill()

        XCTAssertTrue(state.isListeningDrill, "内置素材在包里，开得出轮")
        XCTAssertFalse(state.listeningRound.isEmpty)
        XCTAssertNotNil(state.currentListeningDrill)
    }

    /// 切走再回来（`openListening` 第二次）接着练，不重开一轮。
    func testOpenListeningTwiceKeepsTheSameRound() async {
        let state = makeState()
        state.shadowingDrills = (0..<12).map { drill("d\($0)", "line number \($0)", "第 \($0) 句") }
        await state.openListening()
        let round = state.listeningRound.map(\.id)
        state.listeningIndex = 2

        await state.openListening()

        XCTAssertEqual(state.listeningRound.map(\.id), round)
        XCTAssertEqual(state.listeningIndex, 2, "切走再回来要停在离开时那一句")
    }

    // MARK: - 关键词捕捉

    /// 精听空着不许交；关键词模式**也是**空着不许交（什么都没写不叫「什么都没抓住」）。
    func testKeywordSubmitRejectsBlankDraft() async {
        let state = makeState()
        beginRound([drill("d0", "The reservation is confirmed")], mode: .keyword, on: state)
        state.listeningKeywordDraft = "   "

        state.submitListeningKeywords()

        XCTAssertNil(state.listeningKeywordResult)
        XCTAssertTrue(state.listeningKeywordAttempts.isEmpty)
        XCTAssertNotNil(state.listeningNotice)
    }

    /// 但**写出来了却一个都没抓住**是有效答案：照样给对照 —— 屏幕上那几个关键词
    /// 正是他下一步要盯的东西。
    func testKeywordSubmitAllowsZeroHits() async {
        let snapshot = isolateListeningLog()
        defer { snapshot() }

        let state = makeState()
        beginRound([drill("d0", "The reservation is confirmed", "预订确认了")], mode: .keyword, on: state)
        state.listeningKeywordDraft = "something else entirely"

        state.submitListeningKeywords()

        let capture = state.listeningKeywordResult
        XCTAssertNotNil(capture, "一个都没抓住也要给对照")
        XCTAssertEqual(capture?.caughtCount, 0)
        XCTAssertEqual(capture?.missed, ["reservation", "confirmed"], "要告诉他漏了哪几个")
        XCTAssertEqual(state.listeningKeywordAttempts.count, 1)
        XCTAssertNil(state.listeningNotice)
    }

    /// 关键词模式的推进与精听同一条路：看完对照 → 下一句（最后一句之后结算）。
    func testKeywordAdvanceWalksToTheEndThenSummarises() async {
        let snapshot = isolateListeningLog()
        defer { snapshot() }

        let state = makeState()
        beginRound([
            drill("d0", "Where is the gate", "登机口在哪里"),
            drill("d1", "The reservation is confirmed", "预订确认了"),
        ], mode: .keyword, on: state)

        state.listeningKeywordDraft = "gate"
        state.submitListeningKeywords()
        state.advanceListening()

        XCTAssertNil(state.listeningSummary, "还有第二句，不该结算")
        XCTAssertEqual(state.listeningIndex, 1)
        XCTAssertNil(state.listeningKeywordResult, "换句要清掉上一句的对照")
        XCTAssertTrue(state.listeningKeywordDraft.isEmpty)

        state.listeningKeywordDraft = "reservation confirmed"
        state.submitListeningKeywords()
        state.advanceListening()

        let summary = state.listeningSummary
        XCTAssertEqual(summary?.mode, .keyword)
        XCTAssertEqual(summary?.attempted, 2)
        XCTAssertEqual(summary?.firstPassCount, 1, "只有第二句是整句全抓住")
        XCTAssertEqual(state.listeningKeywordAttempts.count, 2, "对照数据仍在（结算卡要用）")
    }

    // MARK: - 听句选义

    /// **点下去即判，且只判一次**：再点不算 —— 否则可以一路点到对为止。
    func testChooseMeaningIsLockedAfterTheFirstPick() async {
        let snapshot = isolateListeningLog()
        defer { snapshot() }

        let state = makeState()
        let round = (0..<5).map { drill("d\($0)", "line number \($0)", "第 \($0) 句的意思") }
        beginRound(round, mode: .meaning, on: state)

        let question = state.listeningMeaningQuestion
        XCTAssertNotNil(question)
        let wrong = (question?.correctIndex ?? 0) == 0 ? 1 : 0

        state.chooseListeningMeaning(wrong)
        XCTAssertEqual(state.listeningMeaningSelection, wrong)
        XCTAssertEqual(state.listeningMeaningCorrect, [false])

        state.chooseListeningMeaning(question?.correctIndex ?? 0)
        XCTAssertEqual(state.listeningMeaningSelection, wrong, "第一次点过之后整排锁死")
        XCTAssertEqual(state.listeningMeaningCorrect, [false], "成绩按第一次算")
    }

    /// 答错的那一句，它的关键信息词要留下来（结算时一起进词汇本）。
    func testWrongMeaningAnswerKeepsItsKeyWords() async {
        let snapshot = isolateListeningLog()
        defer { snapshot() }

        let state = makeState()
        let round = (0..<5).map {
            drill("d\($0)", "reservation confirmed \($0)", "第 \($0) 句的意思")
        }
        beginRound(round, mode: .meaning, on: state)

        let wrong = (state.listeningMeaningQuestion?.correctIndex ?? 0) == 0 ? 1 : 0
        state.chooseListeningMeaning(wrong)

        XCTAssertEqual(
            Set(state.listeningMeaningMissedWords), ["reservation", "confirmed"],
            "答错要把它那几个关键信息词收下来"
        )
    }

    /// 出不了题的句子**直接跳过**，不把人留在空题上。
    func testMeaningModeSkipsSentencesWithoutOptions() async {
        // ⚠️ 这条会写账本（`chooseListeningMeaning` 一句一记）—— 必须 isolate。
        let snapshot = isolateListeningLog()
        defer { snapshot() }

        let state = makeState()
        // 第 1 句没有释义 → 出不了题；其余四句释义互不相同 → 出得了。
        let round = [
            drill("a0", "line zero", "第 0 句"),
            drill("b1", "line one", ""),
            drill("a2", "line two", "第 2 句"),
            drill("a3", "line three", "第 3 句"),
            drill("a4", "line four", "第 4 句"),
        ]
        beginRound(round, mode: .meaning, on: state)

        XCTAssertEqual(state.listeningIndex, 0)
        XCTAssertEqual(state.listeningMeaningQuestion?.drillID, "a0")

        state.chooseListeningMeaning(state.listeningMeaningQuestion?.correctIndex ?? 0)
        state.advanceListening()

        XCTAssertEqual(state.listeningIndex, 2, "第 1 句出不了题，要直接跳到第 2 句")
        XCTAssertEqual(state.listeningMeaningQuestion?.drillID, "a2")
        XCTAssertNil(state.listeningMeaningSelection, "新的一句是没答过的")
    }

    /// 整轮一句都出不了题 → 直接结算，而不是把用户晾在原地。
    func testMeaningModeFinishesWhenNothingIsAnswerable() async {
        let state = makeState()
        beginRound((0..<3).map { drill("d\($0)", "line \($0)", "") }, mode: .meaning, on: state)

        XCTAssertNil(state.listeningMeaningQuestion)
        XCTAssertNotNil(state.listeningSummary, "出不了题就收尾，别停在空卡上")
        XCTAssertEqual(
            state.listeningSummary?.mode, .meaning,
            "⚠️ 空结算也必须带自己的模式：结算卡的标签随模式变，写成精听那一套会让人以为自己在默写"
        )
        XCTAssertFalse(state.listeningSummary?.hasAttempts ?? true)
    }

    /// 走在「这一句出不了题」那条路上时，页面上不会出现空题 ——
    /// `listeningMeaningQuestion` 为空只可能出现在收尾的那一瞬（上一条）或「正在找」的中间态。
    func testMeaningModeNeverLeavesAnEmptyQuestionMidRound() async {
        let state = makeState()
        let round = [
            drill("b0", "line zero", ""),
            drill("a1", "line one", "第 1 句"),
            drill("a2", "line two", "第 2 句"),
            drill("a3", "line three", "第 3 句"),
            drill("a4", "line four", "第 4 句"),
        ]
        beginRound(round, mode: .meaning, on: state)

        XCTAssertEqual(state.listeningIndex, 1, "第 0 句出不了题 → 直接从那句能出的开始")
        XCTAssertNotNil(state.listeningMeaningQuestion)
    }

    // MARK: - 共用一本当天账本

    /// 三种形式记在**同一本账**上，且同一句只留更好的那次
    /// （换形式重练一遍不该把成绩拉低，也不该变成两句）。
    func testThreeModesShareOneDailyLedgerKeepingTheBest() async {
        let snapshot = isolateListeningLog()
        defer { snapshot() }

        let state = makeState()
        let sentence = drill("d0", "The reservation is confirmed", "预订确认了")
        beginRound([sentence], mode: .keyword, on: state)

        // 关键词模式：只抓住一个（命中率 0.5）。
        state.listeningKeywordDraft = "reservation"
        state.submitListeningKeywords()
        XCTAssertEqual(state.listeningLog.resolvedCount, 1)
        XCTAssertEqual(state.listeningLog.averageAccuracy ?? 0, 0.5, accuracy: 1e-9)

        // 同一句再默写一遍，写全对 → 账本该记 1.0，句数仍然是 1。
        state.switchListeningMode(.dictation)
        state.listeningDraft = sentence.text
        state.submitListeningDraft()

        XCTAssertEqual(state.listeningLog.resolvedCount, 1, "同一句练两次还是这一句")
        XCTAssertEqual(state.listeningLog.averageAccuracy ?? 0, 1.0, accuracy: 1e-9, "只留更好的那次")

        // 选择题答错也不该把成绩拉回 0（那 0 分只在结算卡里体现）。
        state.listeningMode = .meaning
        state.listeningMeaningCorrect.append(false)
        state.listeningMeaningPlays.append(2)
        state.finishListeningRound()
        XCTAssertEqual(state.listeningLog.averageAccuracy ?? 0, 1.0, accuracy: 1e-9, "答错不该覆盖已写对的成绩")
        XCTAssertEqual(state.listeningSummary?.mode, .meaning)
        XCTAssertEqual(state.listeningSummary?.correctCount, 0)
    }

    /// 结算用的三份累计各自对应自己的形式（互相不串）。
    func testFinishUsesTheAccumulatorsOfTheCurrentMode() async {
        let snapshot = isolateListeningLog()
        defer { snapshot() }

        let state = makeState()
        beginRound([drill("d0", "Where is the gate", "登机口在哪里")], mode: .keyword, on: state)
        state.listeningKeywordDraft = "gate"
        state.submitListeningKeywords()
        // 精听那条链路上也攒了一条（换形式的中间态），结算时**不许**被算进关键词这一轮。
        state.listeningAttempts.append(
            ListeningAttempt(
                drillID: "d0", reference: "Where is the gate", typed: "where is the gate",
                comparison: ShadowingScorer.compare(
                    reference: "Where is the gate", recognized: "where is the gate"
                ),
                playCount: 1
            )
        )

        state.finishListeningRound()

        XCTAssertEqual(state.listeningSummary?.mode, .keyword)
        XCTAssertEqual(state.listeningSummary?.attempted, 1, "只算关键词模式交过的那一句")
    }

    /// 中途退出：会话清掉，但**今天的账不清** —— 已经写对的成绩不该被收回。
    func testExitKeepsTheDailyLogForEveryMode() async {
        let snapshot = isolateListeningLog()
        defer { snapshot() }

        let state = makeState()
        beginRound([drill("d0", "reservation confirmed", "预订确认了")], mode: .keyword, on: state)
        state.listeningKeywordDraft = "reservation confirmed"
        state.submitListeningKeywords()
        XCTAssertEqual(state.listeningLog.resolvedCount, 1)

        state.exitListeningDrill()

        XCTAssertFalse(state.isListeningDrill)
        XCTAssertTrue(state.listeningRound.isEmpty)
        XCTAssertNil(state.listeningKeywordResult)
        XCTAssertNil(state.listeningSummary)
        XCTAssertEqual(state.listeningLog.resolvedCount, 1)
    }
}
