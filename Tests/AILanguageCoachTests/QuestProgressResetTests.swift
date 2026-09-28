import AIDomain
import AIInfrastructure
import AIServices
import AppCore
@testable import AppUI
import XCTest

/// 「重置闯关进度（全新起点）」的回归（2026-09-28 接上设置页入口）。
///
/// 两条钉住的事实：
/// 1. 归零口径**只用** `LearnerProgress.zeroed`：关卡元数据（标题 / 需求星数）是课程设计，
///    重置不许动它们；汇总字段（`totalStars` / `climbFraction`）必须跟着归零，
///    否则设置页会显示「0 颗星 · 爬升 40%」这种自相矛盾；
/// 2. 情景任务的完成记录在**另一张表**（`scenario_quests`）：只清进度不清它，
///    情景卡片还会显示「已完成」—— 用户以为重置没生效。
@MainActor
final class QuestProgressResetTests: XCTestCase {

    /// 临时配置 + `:memory:` 数据库 —— 绝不碰用户真实学习数据。
    private func makeState() -> AppState {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("quest-reset-\(UUID().uuidString).json")
        )
        return AppState(services: CoachServices(config: store, databasePath: ":memory:"))
    }

    // MARK: - ① 纯函数：zeroed 的归零口径

    func testZeroedClearsStarsButKeepsLevelMetadata() {
        var progress = LearnerProgress.seed()
        // 模拟练完前两关：星星 + 状态。
        progress.levels[0].earnedStars = 3
        progress.levels[0].state = .completed
        progress.levels[1].earnedStars = 4
        progress.levels[1].state = .inProgress
        progress.recalculateSummary()
        XCTAssertGreaterThan(progress.totalStars, 0)
        XCTAssertGreaterThan(progress.climbFraction, 0)

        let fresh = progress.zeroed(unlocking: 0)

        XCTAssertEqual(fresh.totalStars, 0, "星星要归零")
        XCTAssertEqual(fresh.climbFraction, 0, "爬升比例要跟着重算（不许残留旧值）")
        XCTAssertEqual(fresh.levels[0].state, .unlocked, "只开第一关")
        for level in fresh.levels.dropFirst() {
            XCTAssertEqual(level.state, .locked, "其余关卡要锁回去")
            XCTAssertEqual(level.earnedStars, 0)
        }
        // 元数据是课程设计，不是学员进度 —— 重置不许动。
        XCTAssertEqual(fresh.levels.map(\.title), progress.levels.map(\.title), "关卡标题不许被改")
        XCTAssertEqual(fresh.levels.map(\.requiredStars), progress.levels.map(\.requiredStars), "过关需求星数不许被改")
        XCTAssertEqual(fresh.levels.map(\.scenarioID), progress.levels.map(\.scenarioID), "情景绑定不许被改")
    }

    // MARK: - ② AppState：重置要真的清两处，并落库

    func testResetQuestProgressClearsStarsAndQuestRecords() async throws {
        let state = makeState()

        // 攒一点进度：两关的星星 + 一条情景任务完成记录。
        state.progress.levels[0].earnedStars = 3
        state.progress.levels[0].state = .completed
        state.progress.levels[1].earnedStars = 4
        state.progress.levels[1].state = .inProgress
        state.progress.recalculateSummary()
        await state.services.saveProgress(state.progress)

        await state.services.saveQuestProgress(
            ScenarioQuestRecord(scenarioID: "cafe-order", doneStepIDs: ["step-1", "step-2"], isComplete: true)
        )
        await state.refreshQuestRecords()
        XCTAssertFalse(state.questRecords.isEmpty, "前提：情景任务进度要真的先有一份")

        await state.resetQuestProgress()

        XCTAssertEqual(state.progress.totalStars, 0, "星星清零")
        XCTAssertEqual(state.progress.climbFraction, 0, "爬升比例清零")
        XCTAssertEqual(state.progress.levels[0].state, .unlocked, "只开第一关")
        XCTAssertEqual(state.progress.levels.dropFirst().map(\.state), Array(repeating: .locked, count: state.progress.levels.count - 1))
        XCTAssertTrue(state.questRecords.isEmpty, "情景任务的完成记录一并清空（否则情景卡片还显示已完成）")

        // 落库口径：重开一份「加载」要拿到的也是零进度，不能只是内存里看着是零。
        let reloaded = await state.services.loadProgress()
        XCTAssertEqual(reloaded.totalStars, 0, "重置要写进数据库，重载后仍是零进度")
        let questRecords = await state.services.allQuestProgress()
        XCTAssertTrue(questRecords.isEmpty, "情景任务记录要从库里消失")
    }
}
