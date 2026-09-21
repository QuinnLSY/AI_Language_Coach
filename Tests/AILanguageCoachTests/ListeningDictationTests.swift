import AIDomain
import XCTest

/// 无文本听力（精听 / 听写，进阶 ④）：分档 / 轮转 / 当天账本 / 结算，
/// 以及那条最要紧的**「提交前不给原文」**。
///
/// 全是纯函数 —— 听写作答不发起任何模型请求，判分口径才钉得死。
final class ListeningDictationTests: XCTestCase {

    private func makeDrill(
        id: String,
        text: String,
        translation: String = "译文",
        difficulty: Int = 2
    ) -> ShadowingDrill {
        ShadowingDrill(
            id: id, text: text, translation: translation, topic: "测试", difficulty: difficulty
        )
    }

    private func makeAttempt(
        drillID: String = "d1",
        reference: String,
        typed: String,
        playCount: Int = 1,
        usedSlowRate: Bool = false
    ) -> ListeningAttempt {
        ListeningAttempt(
            drillID: drillID,
            reference: reference,
            translation: "译文",
            typed: typed,
            comparison: ShadowingScorer.compare(reference: reference, recognized: typed),
            playCount: playCount,
            usedSlowRate: usedSlowRate
        )
    }

    // MARK: - 分档

    /// 分档看两件事：**写对了没有** 与 **听了几遍**。
    func testStepNeedsBothOnePlayAndAccuracyForFirstPass() {
        XCTAssertEqual(ListeningRule.step(playCount: 1, accuracy: 0.9), .firstPass)
        // 只听了一遍但没写准 → 不算「一遍听懂」（差得不多也算听懂了）。
        XCTAssertEqual(ListeningRule.step(playCount: 1, accuracy: 0.6), .understood)
        // 写得很准但听了不止一遍 → 也不算。
        XCTAssertEqual(ListeningRule.step(playCount: 3, accuracy: 0.95), .understood)
        XCTAssertEqual(ListeningRule.step(playCount: 2, accuracy: 0.59), .notYet)
        // 边界：恰好踩在门槛上算过（0.6 / 0.85 都是「达到」而不是「接近」）。
        XCTAssertEqual(ListeningRule.step(playCount: 1, accuracy: ListeningRule.understoodAccuracy), .understood)
        XCTAssertEqual(ListeningRule.step(playCount: 1, accuracy: ListeningRule.firstPassAccuracy), .firstPass)
    }

    /// 一遍没听（playCount = 0）与只听一遍同档 —— 凭记忆直接写对，也该算一遍听懂。
    func testZeroPlaysCountsLikeASinglePlay() {
        XCTAssertEqual(ListeningRule.step(playCount: 0, accuracy: 1.0), .firstPass)
        XCTAssertEqual(ListeningRule.step(playCount: 0, accuracy: 0.6), .understood)
    }

    /// 慢速只是手段，不影响分档 —— 否则用户会为了拿到「一遍听懂」硬撑着不听慢速。
    func testSlowPlaybackDoesNotChangeStep() {
        let slow = makeAttempt(reference: "I need a receipt", typed: "I need a receipt", usedSlowRate: true)
        let fast = makeAttempt(reference: "I need a receipt", typed: "I need a receipt")
        XCTAssertEqual(slow.step, fast.step)
    }

    // MARK: - 逐词对齐（复用跟读那把尺）

    /// 听写与跟读共用 `ShadowingScorer`：同一个「听到 / 没听出来 / 多写」口径。
    func testAttemptUsesShadowingAlignment() {
        let attempt = makeAttempt(reference: "Can I have a receipt", typed: "Can I have receipt")
        XCTAssertEqual(attempt.comparison.referenceCount, 5)
        XCTAssertEqual(attempt.comparison.matched, 4)
        XCTAssertEqual(attempt.missedWords, ["a"])
        // 「没听出来的词」逐句就有，不必等到结算。
        XCTAssertEqual(attempt.accuracy, 0.8, accuracy: 1e-9)
    }

    // MARK: - 一轮的句子

    /// 一轮取 `roundSize` 句，同一天稳定，隔天起点不同 ——
    /// 否则素材后半批永远没人练。
    func testRoundIsStableWithinADayAndRotatesAcrossDays() {
        let drills = (0..<20).map { makeDrill(id: "d\($0)", text: "sentence \($0)") }
        let calendar = Calendar(identifier: .gregorian)
        let day1 = Date(timeIntervalSince1970: 1_772_000_000)          // 固定时刻，不依赖「今天」
        let day2 = day1.addingTimeInterval(24 * 3600)

        let first = ListeningRule.round(from: drills, date: day1, calendar: calendar)
        let again = ListeningRule.round(from: drills, date: day1, calendar: calendar)
        let next = ListeningRule.round(from: drills, date: day2, calendar: calendar)

        XCTAssertEqual(first.count, ListeningRule.roundSize)
        XCTAssertEqual(first.map(\.id), again.map(\.id), "同一天必须拿到同一批")
        XCTAssertNotEqual(first.map(\.id), next.map(\.id), "隔天起点要挪")
        XCTAssertEqual(Set(first.map(\.id)).count, first.count, "一句不重复")
    }

    /// 素材比一轮还少时不许崩、不许补空。
    func testRoundHandlesShortMaterial() {
        let drills = (0..<3).map { makeDrill(id: "d\($0)", text: "s\($0)") }
        XCTAssertEqual(ListeningRule.round(from: drills).count, 3)
        XCTAssertTrue(ListeningRule.round(from: []).isEmpty)
    }

    // MARK: - 无文本（这条是整个功能的前提）

    /// ⚠️ 提交前屏幕上出现的每一行文案，都不许含参考句里的实词。
    ///
    /// 这条冲的是一种很具体的退化：日后有人在提示区顺手写一句
    /// 「这句里有 check-in」—— 那还叫听写吗？靠人眼复核看不出这种问题。
    func testChromeNeverLeaksReferenceWords() {
        let drills = [
            makeDrill(id: "a", text: "Can I check in my luggage here"),
            makeDrill(id: "b", text: "The meeting starts at nine sharp"),
            makeDrill(id: "c", text: "I would like a refund please"),
            makeDrill(id: "d", text: "Could you speak a little slower"),
        ]
        for drill in drills {
            for plays in [0, 1, 3] {
                for slow in [false, true] {
                    let chrome = ListeningRule.chrome(
                        index: 0, total: 8, playCount: plays, slow: slow
                    )
                    XCTAssertFalse(
                        ListeningRule.leaksReference(chrome: chrome.all, reference: drill.text),
                        "「\(drill.text)」的文案里泄露了原文：\(chrome.all)"
                    )
                }
            }
        }
    }

    /// 反证：检查器本身是有效的 —— 把原文的词塞进文案，必须被抓住。
    ///
    /// 没有这条，上面那条测试可能只是「检查器永远返回 false」。
    func testLeakCheckerActuallyCatchesLeaks() {
        let reference = "Can I check in my luggage here"
        XCTAssertTrue(
            ListeningRule.leaksReference(chrome: ["提示：这句里有 luggage"], reference: reference)
        )
        // 连字符要再拆一层：`check-in` 就是 `check`，不然这条泄露会漏过去。
        XCTAssertTrue(
            ListeningRule.leaksReference(chrome: ["check-in 是连读"], reference: reference)
        )
        // 大小写不敏感。
        XCTAssertTrue(
            ListeningRule.leaksReference(chrome: ["LUGGAGE"], reference: reference)
        )
        // 短词（≤2 字母）不参与比对：`at` 会撞进 `that`，拿它当判据尽是假阳性。
        XCTAssertFalse(
            ListeningRule.leaksReference(chrome: ["We are ready"], reference: "Meet me at the gate")
        )
    }

    // MARK: - 当天账本

    /// 同一句写两遍只留更好的一次：重写一次不该把今天成绩拉低。
    func testLogKeepsBestPerDrill() {
        var log = ListeningLog.today()
        log = log.recording(drillID: "d1", accuracy: 0.4)
        log = log.recording(drillID: "d1", accuracy: 0.9)
        log = log.recording(drillID: "d1", accuracy: 0.5)

        XCTAssertEqual(log.resolvedCount, 1)
        XCTAssertEqual(log.best["d1"] ?? 0, 0.9, accuracy: 1e-9)
        XCTAssertEqual(log.averageAccuracy ?? 0, 0.9, accuracy: 1e-9)
    }

    /// 跨天必须归零 —— 「昨天写了 6 句」挂在今天是最容易被忽略的那种错。
    func testLogRollsOverOnNewDay() {
        let yesterday = Date(timeIntervalSince1970: 1_772_000_000)
        let today = yesterday.addingTimeInterval(24 * 3600)
        let log = ListeningLog.today(yesterday)
            .recording(drillID: "d1", accuracy: 0.8, at: yesterday)

        let rolled = log.rolledOver(to: today)
        XCTAssertEqual(rolled.resolvedCount, 0)
        XCTAssertNil(rolled.averageAccuracy)

        // 同一天内不许清。
        XCTAssertEqual(log.rolledOver(to: yesterday).resolvedCount, 1)
    }

    /// 记账时撞上跨天：这一笔要算在**今天**，而不是被并进昨天。
    func testRecordingAfterMidnightStartsFreshLog() {
        let stale = ListeningLog(dayKey: "2001-01-01", best: ["old": 1.0])
        let recorded = stale.recording(drillID: "new", accuracy: 0.7)
        XCTAssertEqual(recorded.dayKey, ListeningLog.today().dayKey)
        XCTAssertNil(recorded.best["old"], "跨天那一笔不许把旧账带过来")
        XCTAssertEqual(recorded.resolvedCount, 1)
    }

    // MARK: - 结算

    /// 结算的三个数：平均分 / 一遍听懂句数 / 平均遍数 —— 顺序与输入无关。
    func testSummaryAggregates() {
        let attempts = [
            makeAttempt(drillID: "d1", reference: "I need a receipt", typed: "I need a receipt", playCount: 1),
            makeAttempt(drillID: "d2", reference: "Where is the gate", typed: "Where is gate", playCount: 2),
            makeAttempt(drillID: "d3", reference: "The flight is delayed", typed: "The flight is delay", playCount: 4),
        ]
        let summary = ListeningSummary.from(attempts)
        XCTAssertEqual(summary.attempted, 3)
        XCTAssertEqual(summary.firstPassCount, 1)
        XCTAssertEqual(summary.averagePlays, 7.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(summary.accuracyPercent, Int((summary.averageAccuracy * 100).rounded()))
        XCTAssertTrue(summary.headline.contains("3 句"))
    }

    /// 漏词按出现次数排：跨句反复没听出来的词排前面。
    func testSummaryRanksMissedWordsByFrequency() {
        let attempts = [
            makeAttempt(drillID: "d1", reference: "Could you hold the line", typed: "Could you hold line"),
            makeAttempt(drillID: "d2", reference: "I will hold on", typed: "I will on"),
            makeAttempt(drillID: "d3", reference: "Can you hold on", typed: "Can you on"),
        ]
        let summary = ListeningSummary.from(attempts)
        XCTAssertEqual(summary.missedWords.first, "hold", "漏了两次的词排最前")
        XCTAssertTrue(summary.missedWords.contains("the"))
    }

    /// 一句都不交时给个诚实的空结算，不是 crash 也不是假分数。
    func testEmptySummary() {
        let summary = ListeningSummary.from([])
        XCTAssertFalse(summary.hasAttempts)
        XCTAssertEqual(summary.accuracyPercent, 0)
        XCTAssertEqual(summary, .empty)
        XCTAssertFalse(summary.verdict.isEmpty)
    }
}
