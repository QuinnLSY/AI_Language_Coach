import AIDomain
import AIInfrastructure
import AIServices
import AppCore
@testable import AppUI
import XCTest

/// ⑦-B③ 盲盒情景的**接线**：钉「这一行读的是真数据」。
///
/// 与 `WarmUpWiringTests` 同款理由：纯函数全绿、面板上却永远抽不出东西
/// （或抽出来的跟列表对不上），说明派生那一步没接上数据源。这一层就钉那一步。
///
/// ⚠️ 断言只钉本用例自己喂进去的那部分：`AppState` 里的情景来自真实素材加载，
/// 测试环境里那批素材解不解得出来不由本文件决定。
@MainActor
final class ScenarioBlindBoxWiringTests: XCTestCase {

    // MARK: - 池子来自真的情景列表

    func testPoolFollowsRealScenarios() {
        let state = makeState()
        state.scenarios = [
            Self.scenario(id: "a"), Self.scenario(id: "b"), Self.scenario(id: "c"),
            Self.scenario(id: "course.1", origin: .course)
        ]

        let pool = state.blindBoxPool

        XCTAssertEqual(pool.count, 3, "课内情景在课卡里，不进盲盒池")
        XCTAssertFalse(pool.contains { $0.id == "course.1" })
    }

    func testEmptyLibraryLeavesNoPool() {
        let state = makeState()
        state.scenarios = []
        XCTAssertTrue(state.blindBoxPool.isEmpty, "没有可选情景时面板上不该画这一行")
    }

    // MARK: - 抽中之后

    func testRevealExpandsThePickedCard() {
        let state = makeState()
        state.scenarios = [Self.scenario(id: "a"), Self.scenario(id: "b"), Self.scenario(id: "c")]

        state.revealRandomScenario()

        guard let picked = state.blindBoxLastID else { return XCTFail("抽不出来") }
        XCTAssertTrue(state.blindBoxPool.contains { $0.id == picked }, "抽中的必须是池子里的一个")
        XCTAssertEqual(state.expandedScenarioID, picked, "抽中 = 把那张卡展开，不是直接开练")
        XCTAssertEqual(state.blindBoxRoll, 1)
    }

    /// 连点 12 次，每次都换一个（抽回同一个 = 用户以为按钮坏了）。
    func testConsecutiveRevealsAlwaysChange() {
        let state = makeState()
        state.scenarios = (0..<6).map { Self.scenario(id: "s\($0)") }

        var last: String?
        for round in 0..<12 {
            state.revealRandomScenario()
            XCTAssertNotEqual(state.blindBoxLastID, last, "第 \(round) 次抽回了刚抽过的那个")
            last = state.blindBoxLastID
        }
        XCTAssertEqual(state.blindBoxRoll, 12, "每抽一次 roll 就 +1；它不前进，「换一个」就换了序列")
    }

    /// 没有可抽的：一步都不能动（返回 nil 就够了，别把计数也推着走）。
    func testNothingToPickLeavesTheCountersAlone() {
        let state = makeState()
        state.scenarios = []

        state.revealRandomScenario()

        XCTAssertNil(state.blindBoxLastID)
        XCTAssertEqual(state.blindBoxRoll, 0)
        XCTAssertNil(state.expandedScenarioID)
    }

    // MARK: - 已过关的来自真的关卡进度

    /// 「已过关」取自 `progress.levels`，与情景卡片上那枚徽标同源。
    ///
    /// ⚠️ 这里**不能只赌第一下**：只抽一次的话，即使「已过关」那条判据整根断掉，
    /// 三个里随机也可能正好抽到没练过的那一个（实测就是这么假绿的）——
    /// 所以要把整条 roll 序列都走一遍，20 次里只要有一次给到练过的就算断线。
    func testCompletedLevelsAreDeprioritized() {
        let state = makeState()
        state.scenarios = [Self.scenario(id: "a"), Self.scenario(id: "b"), Self.scenario(id: "c")]
        state.progress = Self.progress(completed: ["a", "b"])

        state.revealRandomScenario()
        XCTAssertEqual(state.blindBoxLastID, "c", "第一下该给还没练过的那个")

        for roll in 0..<20 {
            XCTAssertEqual(
                ScenarioBlindBox.pick(from: state.blindBoxPool, avoiding: nil, roll: roll)?.id, "c",
                "已过关的排在后面：第 \(roll) 抽轮到练过的了（说明「已过关」没接进池子）"
            )
        }
    }

    // MARK: - 开练走的是同一条链路

    /// 「就练这个」走的是情景卡片那条「开始任务」（切页 + 关面板），不是另开一条。
    func testStartRevealedScenarioEntersThePickedOne() async {
        let state = makeState()
        state.scenarios = [Self.scenario(id: "a"), Self.scenario(id: "b")]
        state.showingScenarios = true
        state.revealRandomScenario()
        let picked = state.blindBoxLastID

        await state.startRevealedScenario()

        XCTAssertFalse(state.showingScenarios, "开练要关掉面板（与「开始任务」同一条链路）")
        XCTAssertEqual(state.chat.scenarioProgress?.scenario.id, picked,
                       "进的必须是刚开出来的那个")
    }

    /// 还没抽过就按「就练这个」：什么都不做（没有 lastID 就没有可进的情景）。
    func testStartWithoutARevealDoesNothing() async {
        let state = makeState()
        state.scenarios = [Self.scenario(id: "a")]
        state.showingScenarios = true

        await state.startRevealedScenario()

        XCTAssertTrue(state.showingScenarios, "没抽过就开练 = 没有目标，面板该原地不动")
        XCTAssertNil(state.chat.scenarioProgress)
    }

    // MARK: - 工装

    private static func scenario(
        id: String,
        title: String = "Scenario",
        titleZh: String = "情景",
        origin: Scenario.Origin = .builtIn
    ) -> Scenario {
        Scenario(
            id: id,
            title: title,
            titleZh: titleZh,
            category: "日常",
            difficulty: 2,
            level: "A2-B1",
            objective: "",
            aiRole: "",
            learnerRole: "",
            opening: "",
            origin: origin
        )
    }

    private static func progress(completed: [String]) -> LearnerProgress {
        LearnerProgress(
            levels: completed.enumerated().map { index, id in
                TreeLevel(
                    id: "lv.\(index)",
                    title: "第 \(index) 关",
                    subtitle: "",
                    heightFraction: Double(index) / 10,
                    branch: index % 2 == 0 ? .left : .right,
                    state: .completed,
                    scenarioID: id
                )
            }
        )
    }

    private func makeState() -> AppState {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("alc-blindbox-\(UUID().uuidString).json")
        )
        // ⚠️ 必须 `:memory:`：裸 `CoachServices()` 的库路径是 nil，会落到真实学习库上。
        return AppState(services: CoachServices(config: store, databasePath: ":memory:"))
    }
}
