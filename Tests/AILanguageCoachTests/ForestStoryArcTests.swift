import XCTest
@testable import AppUI

/// 连续剧情（#418-C）单测：幕判定（纯函数）+ ForestStage 的记账 + 装配哨兵。
///
/// 幕判定在 `ForestStoryArc`（纯函数）、事件历史与记账在 `ForestStage`、
/// 挑角演在 `ForestGroundBand` —— 三层各管各的，测试分别钉住。
final class ForestStoryArcTests: XCTestCase {

    private func beat(_ kind: ForestStoryBeat.Kind, _ secondsAgo: TimeInterval,
                      now: Date = Date(timeIntervalSinceReferenceDate: 8_000_000)) -> ForestStoryBeat {
        ForestStoryBeat(kind: kind, at: now.addingTimeInterval(-secondsAgo))
    }

    // MARK: - ① 幕判定（纯函数）

    func testNoHistoryMeansNoAct() {
        let now = Date(timeIntervalSinceReferenceDate: 8_000_000)
        XCTAssertNil(ForestStoryArc.pendingAct(beats: [], now: now,
                                               performedActs: [], lastActAt: nil))
    }

    func testHarvestNeedsTwoStars() {
        let now = Date(timeIntervalSinceReferenceDate: 8_000_000)
        let one = [beat(.starEarned, 60, now: now)]
        XCTAssertNil(ForestStoryArc.pendingAct(beats: one, now: now,
                                               performedActs: [], lastActAt: nil),
                     "一颗星不值得出幕（攒星脉冲自己会演）")
        let two = one + [beat(.starEarned, 30, now: now)]
        XCTAssertEqual(ForestStoryArc.pendingAct(beats: two, now: now,
                                                 performedActs: [], lastActAt: nil),
                       .harvest)
    }

    func testEncoreMeansPracticedAfterClearing() {
        let now = Date(timeIntervalSinceReferenceDate: 8_000_000)
        // 练了 → 通关：不算安可（安可 = 通关之后还在练）。
        let beforeClear = [beat(.practiced, 300, now: now), beat(.levelCleared, 60, now: now)]
        XCTAssertNil(ForestStoryArc.pendingAct(beats: beforeClear, now: now,
                                               performedActs: [], lastActAt: nil))
        // 通关 → 又练了一段：安可。
        let afterClear = [beat(.levelCleared, 300, now: now), beat(.practiced, 60, now: now)]
        XCTAssertEqual(ForestStoryArc.pendingAct(beats: afterClear, now: now,
                                                 performedActs: [], lastActAt: nil),
                       .encore)
    }

    func testFocusNeedsThreePracticesInsideTheWindow() {
        let now = Date(timeIntervalSinceReferenceDate: 8_000_000)
        let inside = [beat(.practiced, 500, now: now),
                      beat(.practiced, 300, now: now),
                      beat(.practiced, 60, now: now)]
        XCTAssertEqual(ForestStoryArc.pendingAct(beats: inside, now: now,
                                                 performedActs: [], lastActAt: nil),
                       .focus)
        // 三段摊开在窗口外（最早的超出 600s）→ 不算专注。
        let spread = [beat(.practiced, 900, now: now),
                      beat(.practiced, 300, now: now),
                      beat(.practiced, 60, now: now)]
        XCTAssertNil(ForestStoryArc.pendingAct(beats: spread, now: now,
                                               performedActs: [], lastActAt: nil),
                     "散落在窗口外的练习不算「一小段时间里练满三段」")
    }

    func testPriorityIsHarvestThenEncoreThenFocus() {
        let now = Date(timeIntervalSinceReferenceDate: 8_000_000)
        let busy = [beat(.starEarned, 400, now: now), beat(.starEarned, 350, now: now),
                    beat(.levelCleared, 300, now: now), beat(.practiced, 200, now: now),
                    beat(.practiced, 100, now: now), beat(.practiced, 50, now: now)]
        XCTAssertEqual(ForestStoryArc.pendingAct(beats: busy, now: now,
                                                 performedActs: [], lastActAt: nil),
                       .harvest, "庆祝的优先于安静的")
        // 收获演过了 → 轮到安可。
        XCTAssertEqual(ForestStoryArc.pendingAct(beats: busy, now: now,
                                                 performedActs: [.harvest], lastActAt: nil),
                       .encore)
        // 收获与安可都演过了 → 轮到专注。
        XCTAssertEqual(ForestStoryArc.pendingAct(beats: busy, now: now,
                                                 performedActs: [.harvest, .encore], lastActAt: nil),
                       .focus)
        // 三幕都演过 → 没有新幕。
        XCTAssertNil(ForestStoryArc.pendingAct(beats: busy, now: now,
                                               performedActs: [.harvest, .encore, .focus],
                                               lastActAt: nil))
    }

    func testCooldownSuppressesActsRightAfterOne() {
        let now = Date(timeIntervalSinceReferenceDate: 8_000_000)
        let two = [beat(.starEarned, 400, now: now), beat(.starEarned, 60, now: now)]
        // 上一幕 60 秒前刚演过（< 120s 冷却）→ 不出幕。
        XCTAssertNil(ForestStoryArc.pendingAct(beats: two, now: now,
                                               performedActs: [], lastActAt: now.addingTimeInterval(-60)))
        // 冷却过后同样的历史 → 出幕。
        XCTAssertEqual(ForestStoryArc.pendingAct(beats: two, now: now,
                                                 performedActs: [],
                                                 lastActAt: now.addingTimeInterval(-ForestStoryArc.cooldown - 1)),
                       .harvest)
    }

    // MARK: - ② ForestStage：史官记录 + 记账（@MainActor）

    @MainActor
    func testStageTranslatesEventsIntoBeats() {
        let stage = ForestStage()
        stage.ingest(.practiceCompleted(rounds: 1))
        stage.ingest(.moduleCompleted(module: .shadowing))
        stage.ingest(.learnerTurn)
        stage.ingest(.teacherTurn)
        stage.ingest(.correctionsRecorded(count: 1))
        XCTAssertEqual(stage.beats.map(\.kind),
                       [.practiced, .practiced, .spoke, .spoke, .stumbled])
    }

    @MainActor
    func testStageLeavesWordAndAbandonOutOfTheStory() {
        let stage = ForestStage()
        stage.ingest(.wordCollected(word: "apple"))
        stage.ingest(.practiceAbandoned(module: .shadowing))
        XCTAssertTrue(stage.beats.isEmpty, "捡词与中途退出不构成剧情")
        // 但它们自己的脉冲照发（互不干扰）。
        XCTAssertEqual(stage.wordTick, 1)
        XCTAssertEqual(stage.abandonTick, 1)
    }

    @MainActor
    func testStageFiresTheActTickWithBookkeeping() {
        let stage = ForestStage()
        stage.ingest(.starsEarned(levelID: "l1", total: 1, delta: 1))
        XCTAssertEqual(stage.storyActTick, 0, "一颗星不出幕")
        stage.ingest(.starsEarned(levelID: "l1", total: 2, delta: 1))
        XCTAssertEqual(stage.storyActTick, 1, "第二颗星出「收获」幕")
        XCTAssertEqual(stage.lastStoryAct, .harvest)
        XCTAssertTrue(stage.performedActs.contains(.harvest))
        XCTAssertNotNil(stage.lastStoryActAt)
        // 同样的星不会让同一幕演第二次（会话级一次）。
        stage.ingest(.starsEarned(levelID: "l1", total: 3, delta: 1))
        stage.ingest(.starsEarned(levelID: "l1", total: 4, delta: 1))
        XCTAssertEqual(stage.storyActTick, 1, "第三、四颗星不会再演收获（每幕一次）")
        XCTAssertEqual(stage.lastStoryAct, .harvest, "没有新幕时脉冲与幕名都停在上一幕")
        XCTAssertEqual(stage.beats.count, 4)
    }

    @MainActor
    func testStageTrimsBeatHistoryToCapacity() {
        let stage = ForestStage()
        for _ in 0..<(ForestStage.storyBeatCapacity + 10) {
            stage.ingest(.learnerTurn)
        }
        XCTAssertEqual(stage.beats.count, ForestStage.storyBeatCapacity,
                       "历史必须封顶：幕判定只看最近这些条")
    }

    // MARK: - ③ 装配哨兵

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: "Sources/\(relativePath)", encoding: .utf8)
    }

    /// 出幕要接进地面带（居民在那里），且判定不做二次判断。
    func testMainViewWiresTheStoryActIntoTheGroundBand() throws {
        let main = try source("AppUI/Views/MainView.swift")
        let band = main.range(of: "ForestGroundBand(").map { main[$0.lowerBound...] } ?? ""
        XCTAssertTrue(band.contains("storyActTick: state.forest.storyActTick"),
                      "出幕脉冲没接进地面带")
        XCTAssertTrue(band.contains("lastStoryAct: state.forest.lastStoryAct"),
                      "幕名没接进地面带")
        let tree = try source("AppUI/Components/TreeCanvas.swift")
        XCTAssertTrue(tree.contains("performStoryAct(act)"), "出幕回调没接演幕")
        XCTAssertTrue(tree.contains("storyLead = nil") || tree.contains("storyLead = lead"),
                      "演员绑定断了（每次换角就不成剧情了）")
    }
}
