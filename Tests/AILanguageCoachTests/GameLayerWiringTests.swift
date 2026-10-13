import AIDomain
import AIInfrastructure
import AIServices
import AppCore
@testable import AppUI
import XCTest

/// ⑦-C 的**接线**：钉「界面上这些数字读的是真数据」。
///
/// 与 `WarmUpWiringTests` 同款理由：纯函数全绿、页面上却永远不动
/// （连击一直是 0、成就墙永远是空的、预告永远是同一句），说明派生那一步没接上数据源。
/// 这一层就钉那一步。
@MainActor
final class GameLayerWiringTests: XCTestCase {

    // MARK: - ⑦-C① 连击跟着一轮复习

    func testStartingAReviewOpensABlitz() async {
        let state = makeState()
        state.vocabularyEntries = Self.entries(3)

        await state.startVocabularyReview()

        XCTAssertNotNil(state.reviewBlitz, "一轮复习开始就配一轮 60 秒连击")
        XCTAssertEqual(state.reviewBlitzRemaining, ReviewBlitz.windowSeconds)
    }

    /// 空队列上**不挂**倒计时：那一行会永远停在 60 秒不动，因为判不了词。
    func testEmptyQueueLeavesNoBlitz() async {
        let state = makeState()
        state.vocabularyEntries = []

        await state.startVocabularyReview()

        XCTAssertNil(state.reviewBlitz)
    }

    func testFinishingTheReviewStopsTheBlitz() async {
        let state = makeState()
        state.vocabularyEntries = Self.entries(3)
        await state.startVocabularyReview()

        await state.finishVocabularyReview()

        XCTAssertNil(state.reviewBlitz, "收起复习就收掉连击")
        XCTAssertEqual(state.reviewBlitzRemaining, 0)
    }

    /// 判一张卡 = 判一次连击（**同一条路径**，不是两条）。
    ///
    /// 反证：把 `gradeVocabularyReviewCard` 里的 `gradeReviewBlitz(remembered:)` 撤掉，
    /// 这条必须红 —— 否则「连击」只是个摆设，判词与连击各走各的。
    func testGradingACardAlsoGradesTheCombo() async {
        let state = makeState()
        state.vocabularyEntries = Self.entries(3)
        await state.startVocabularyReview()

        await state.gradeVocabularyReviewCard(remembered: true)
        XCTAssertEqual(state.reviewBlitz?.combo, 1, "判「记得」要涨连击")

        await state.gradeVocabularyReviewCard(remembered: false)
        XCTAssertEqual(state.reviewBlitz?.combo, 0, "判「忘了」要断连击")
        XCTAssertEqual(state.reviewBlitz?.bestCombo, 1)
        XCTAssertEqual(state.reviewBlitz?.graded, 2)
    }

    /// 收起时结纪录：最后一秒连的那一串不能因为顺手点了「完成」就丢掉。
    func testStoppingTheRoundSealsTheRecord() async {
        let state = makeState()
        let savedBest = state.reviewBlitzBest
        state.reviewBlitzBest = 0
        defer {
            state.reviewBlitzBest = savedBest
            state.stopReviewBlitz()
        }

        state.startReviewBlitz()
        _ = state.gradeReviewBlitz(remembered: true)
        _ = state.gradeReviewBlitz(remembered: true)
        _ = state.gradeReviewBlitz(remembered: false)
        // 破纪录**当场**就记账（不等收起）：中途退出 / 崩了也不该丢掉这一轮的纪录。
        XCTAssertEqual(state.reviewBlitzBest, 2)

        state.stopReviewBlitz()
        XCTAssertEqual(state.reviewBlitzBest, 2, "收起时把这一轮的最高连击结进纪录")
        XCTAssertTrue(state.reviewBlitzIsNewRecord)

        // 第二轮没超过纪录就不该再挂那枚徽章。
        state.startReviewBlitz()
        XCTAssertFalse(state.reviewBlitzIsNewRecord, "开新一轮时清掉上一轮的「新纪录」")
        _ = state.gradeReviewBlitz(remembered: true)
        state.stopReviewBlitz()
        XCTAssertEqual(state.reviewBlitzBest, 2, "没超过就不改纪录")
    }

    // MARK: - ⑦-C② 成就墙

    /// 墙上那几格来自**真的进度快照**（换一份快照，墙就得变）。
    func testAchievementWallReadsTheRealSnapshot() async {
        let state = makeState()
        state.progressSnapshot = Self.snapshot(messages: 0, seconds: 0)
        XCTAssertTrue(state.achievementWall.allSatisfy { !$0.isUnlocked })

        state.progressSnapshot = Self.snapshot(messages: 80, seconds: 0)
        XCTAssertTrue(state.achievementWall.contains { $0.id == "talk.50" && $0.isUnlocked },
                      "开口 80 句之后「开口 50 句」那一格必须亮")
        XCTAssertTrue(state.achievementHeadline.contains("已解锁"))
    }

    func testAchievementHeadlineMovesWithTheNumbers() async {
        let state = makeState()
        state.progressSnapshot = Self.snapshot(messages: 38)
        let first = state.achievementHeadline
        state.progressSnapshot = Self.snapshot(messages: 48)
        let second = state.achievementHeadline
        XCTAssertNotEqual(first, second, "差多少是插出来的真值，两版不许一样")
        XCTAssertTrue(first.contains("还差 12 句"))
        XCTAssertTrue(second.contains("还差 2 句"))
    }

    // MARK: - ⑦-C③ 森林解锁

    /// 林子里几位来自**真的累计时长**（时长变，人数和预告都得跟着变）。
    func testForestUnlockReadsTheRealTotalSeconds() async {
        let state = makeState()
        state.progressSnapshot = Self.snapshot(seconds: 0)
        let fresh = state.forestUnlockedCompanions
        XCTAssertEqual(fresh, ForestUnlock.baseCompanions)

        state.progressSnapshot = Self.snapshot(seconds: 75 * 60)
        XCTAssertGreaterThan(state.forestUnlockedCompanions, fresh, "练久了林子里要多几位")
        XCTAssertTrue(state.forestUnlockHeadline.contains("\(state.forestUnlockedCompanions) 位伙伴"))
        XCTAssertTrue(state.forestUnlockPreview.contains("再练"))
    }

    /// 满员之后不再挂倒计时（挂着一句永远兑现不了的话 = 假预告）。
    func testFullForestStopsPreviewing() async {
        let state = makeState()
        state.progressSnapshot = Self.snapshot(seconds: 400 * 60)
        XCTAssertEqual(state.forestUnlockedCompanions, ForestUnlock.maxCompanions)
        XCTAssertNil(state.forestNextCompanion)
        XCTAssertFalse(state.forestUnlockPreview.contains("再练"))
    }

    /// 排序同源：卡片上的那几只 == 地面带会排出来的那几只（都取 `unlockOrder` 的前 N 位）。
    func testCompanionsFollowTheUnlockOrder() async {
        let state = makeState()
        state.progressSnapshot = Self.snapshot(seconds: 30 * 60)
        XCTAssertEqual(state.forestCompanions,
                       Array(AnimalKind.unlockOrder.prefix(state.forestUnlockedCompanions)))
        XCTAssertEqual(state.forestCompanions.count, state.forestUnlockedCompanions)
        // 下一位必须是顺序表里紧接着的那一个 —— 预告点名的和真的会来的得是同一只。
        XCTAssertEqual(state.forestNextCompanion,
                       AnimalKind.unlockOrder[state.forestUnlockedCompanions])
    }

    /// **哨兵**：解锁上限必须等于物种总数。
    ///
    /// 加一个物种却忘了抬上限，多出来的那一位就永远来不了（预告会一直挂着一句空话）；
    /// 反过来上限抬过头，取下标会取空 —— 两边必须一起动。
    func testMaxCompanionsMatchesTheSpeciesTable() async {
        XCTAssertEqual(ForestUnlock.maxCompanions, AnimalKind.allCases.count,
                       "物种表变了，解锁上限要跟着变")
        XCTAssertEqual(AnimalKind.unlockOrder.count, AnimalKind.allCases.count,
                       "解锁顺序不许漏掉或重复任何一只")
        XCTAssertEqual(Set(AnimalKind.unlockOrder).count, AnimalKind.allCases.count)
    }

    // MARK: - 源码哨兵

    /// 地面带必须**喂进真的解锁数**。
    ///
    /// ⚠️ `ForestGroundBand.unlockedCompanions` 带默认值（= 满员），漏传不报错 ——
    /// 于是「预告说林子里 4 位、实际画了 8 只」这种对不上会静默存在。
    /// 这条钉的是**调用形态整串**，不是「出现过 unlockedCompanions 这个词」。
    func testForestBandIsFedTheRealUnlockCount() throws {
        let raw = try Self.code("Sources/AppUI/Views/MainView.swift")
        XCTAssertTrue(
            raw.contains("unlockedCompanions: state.forestUnlockedCompanions"),
            "MainView 要把 AppState 算出来的解锁数交给地面带（默认值是满员，漏传就是谎）"
        )
    }

    /// 成就墙 / 解锁预告必须摆在页面上（规则写好了没人挂，等于没做）。
    func testRewardBoardIsMountedOnTheProgressPage() throws {
        let raw = try Self.code("Sources/AppUI/Views/LearningProgressView.swift")
        XCTAssertTrue(raw.contains("AchievementWallCard(")) 
        XCTAssertTrue(raw.contains("ForestUnlockCard("))
        XCTAssertTrue(raw.contains("items: state.achievementWall"),
                      "墙上那几格要来自状态源的派生值，不能自己现算一套")
        XCTAssertTrue(raw.contains("companions: state.forestCompanions"))
    }

    /// 连击条必须挂在复习分支里（只在复习跑着的时候出现）。
    func testBlitzBarIsMountedOnlyDuringAReview() throws {
        let raw = try Self.code("Sources/AppUI/Views/VocabularyView.swift")
        XCTAssertTrue(raw.contains("BlitzBar("))
        XCTAssertTrue(raw.contains("remaining: state.reviewBlitzRemaining"),
                      "倒计时由状态源写进来，视图不许自己抓时钟")
    }

    // MARK: - 工装

    private static func code(_ path: String) throws -> String {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func entries(_ count: Int) -> [VocabularyEntry] {
        (0..<count).map { VocabularyEntry(word: "blitz-\($0)") }
    }

    private static func snapshot(
        messages: Int = 0,
        seconds: TimeInterval = 0,
        mastered: Int = 0,
        collected: Int = 0,
        shadowing: Int = 0,
        stars: Int = 0
    ) -> ProgressSnapshot {
        ProgressSnapshot(
            today: DailyActivity(day: Date(), seconds: 0, messages: 0),
            totalSeconds: seconds,
            totalMessages: messages,
            totalStars: stars,
            vocabulary: VocabularyStats(
                total: collected, due: 0, mastered: mastered, defined: 0,
                dueAtDayStart: 0, dueAtDayStartReviewed: 0
            ),
            shadowing: ShadowingStats(attempts: shadowing, bestAccuracy: 0,
                                      averageAccuracy: 0, lastAccuracy: nil)
        )
    }

    private func makeState() -> AppState {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("alc-gamelayer-\(UUID().uuidString).json")
        )
        // ⚠️ 必须 `:memory:`：裸 `CoachServices()` 的库路径是 nil，会落到真实学习库上。
        return AppState(services: CoachServices(config: store, databasePath: ":memory:"))
    }
}
