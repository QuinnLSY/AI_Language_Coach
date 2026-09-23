import AIDomain
import AIInfrastructure
import AIServices
import AppCore
@testable import AppUI
import XCTest

/// 启动链路的回归（需求 #1：首屏不再等开场白）。
///
/// 以前 `AppState.start()` 末尾 `await resumeOrOpenPractice()` —— 老师那句开场白是
/// **一次真实模型调用**（本机冷加载实测 30～60s），于是
///   ① 主界面 `.task` 里排在后面的启动钩子（--theme / --open-* / --send）全被堵住；
///   ② 这半分钟里对话区只有一张等待卡。
/// 现在开场白挪进后台任务，首屏由**本地聚合**的今日卷轴秒开。
///
/// 这里钉的是「**模型不可用 / 网络慢时首屏照样有东西可练**」：
/// 把 LLM 指到死端口（必定秒失败），启动后今日卷轴仍必须带着真实记录出现。
@MainActor
final class LaunchTodayPanelTests: XCTestCase {

    /// 造一支「模型必定秒失败」+「数据库里有真实练习记录」的 AppState。
    ///
    /// ⚠️ 必须把 llm 指到死端口并 activate：默认配置里的 `ollama.llm` 在本机
    /// Ollama 真在跑时是**可用**的，会让「模型不可用」类断言变成环境彩票。
    private func makeDeadLLMState(withSeededHistory: Bool) async throws -> AppState {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-today-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let databasePath = directory.appendingPathComponent("learning.db").path
        if withSeededHistory {
            let db = try LearningDatabase(path: databasePath)
            let session = ChatSession(startedAt: Date(), mode: .freeTalk)
            try await db.createSession(session)
            try await db.appendMessage(
                ChatMessage(role: .user, content: "Hello teacher, how are you today?"),
                sessionID: session.id
            )
            try await db.appendMessage(
                ChatMessage(role: .assistant, content: "I'm great, thanks for asking!"),
                sessionID: session.id
            )
        }

        let store = ConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        try await store.updateProvider(
            ProviderConfig(
                id: "stub.llm", kind: .llm, enabled: true, runtime: .remoteAPI,
                endpoint: "http://127.0.0.1:9/v1", apiKey: "sk-dead",
                model: "stub-model", candidateModels: ["stub-model"]
            )
        )
        try await store.mutateProduct { product in
            product.activateProvider("stub.llm", for: .llm)
            product.selectModel("stub-model", for: .llm)
        }
        return AppState(services: CoachServices(config: store, databasePath: databasePath))
    }

    // MARK: - ① 启动结束时首屏就已经有「今天」

    func testLaunchLeavesTheTodayPanelPopulatedEvenWithADeadModel() async throws {
        let state = try await makeDeadLLMState(withSeededHistory: true)
        await state.start()

        XCTAssertFalse(state.isBooting, "服务装配完就该揭开界面 —— 不等老师的开场白")
        XCTAssertGreaterThan(
            state.progressSnapshot.today.messages, 0,
            "启动就要把「今天练过什么」汇总出来（本地聚合，一条模型调用都不等）"
        )
        XCTAssertFalse(state.dailyPlan.tasks.isEmpty, "首屏今日卷轴必须有可做的事")
        XCTAssertFalse(state.dailyPlan.isAllDone, "刚开口两句不该显示「今天都做完了」")
    }

    // MARK: - ② 全新的库也不能是「今日 0/3」

    func testFreshDatabaseStillOffersSomethingToDo() async throws {
        let state = try await makeDeadLLMState(withSeededHistory: false)
        await state.start()

        XCTAssertFalse(state.dailyPlan.tasks.isEmpty, "全新状态也要给出可做的任务（开口 + 跟读）")
        XCTAssertEqual(state.dailyPlan.tasks.first?.kind, .conversation)
        XCTAssertEqual(state.progressSnapshot.today.messages, 0)
    }

    // MARK: - ③ 学员先开口 → 后台开场不许把他的话清掉

    /// 后台开场里有一条**破坏性**分支（隐藏历史 → 复盘 → 清空会话换新的）。
    /// 学员一旦开口，这段会话就归他 —— 那是 `openInBackground` 让位规则的核心。
    func testLearnerEngagedKeepsHisOwnWords() async throws {
        let state = try await makeDeadLLMState(withSeededHistory: true)
        await state.start()
        // 学员抢在老师开口之前说话（后台开场此刻还在跑）。
        XCTAssertTrue(state.sendChat("I want to practise ordering food."))
        // 等后台任务收尾（死端口会秒失败，1 秒足够）。
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertTrue(
            state.chat.visibleMessages.contains { $0.role == .user && $0.content.contains("ordering food") },
            "后台开场绝不能把学员刚说的话清掉"
        )
    }

    // MARK: - ④ 已完成的任务不许回退（#328）

    /// 用户报障的完整时序（2026-09-23）：
    /// 今天聊够了 → 关掉应用 → 重开时对上一段做了复盘（**流水被清**）→ 续聊。
    /// 此刻的记录只剩新会话那几句，对话数掉回个位数，卡片又变成「未完成」。
    ///
    /// 这里按真实路径走一遍：`refreshTodayPanel`（记高水位）→ 清流水 → 再汇总。
    ///
    /// ⚠️ 顺带钉住**持久化**：`dailyTaskFloor` 写在 `UserDefaults` 上，
    /// 第二个 `AppState`（= 重开应用）读到的必须还是「已完成」。
    func testFinishedTasksStayFinishedAfterTheFlowIsPurged() async throws {
        let keys = [
            AppState.todayTaskFloorKey,
            AppState.todayCelebratedDayKey,
            AppState.todayBoardAutoExpandedDayKey,
        ]
        // ⚠️ 测试进程用的是 `com.apple.dt.xctest.tool` 域，会串到同进程后续用例 ——
        // 改完必须原样还原（见技能 macos-ui-verify）。
        let saved = keys.map { UserDefaults.standard.string(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("task-floor-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databasePath = directory.appendingPathComponent("learning.db").path
        let store = ConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        let services = CoachServices(config: store, databasePath: databasePath)

        // 今天聊了 10 条（目标 10 轮 → 刚好达标）。
        let session = ChatSession(startedAt: Date(), mode: .conversation)
        try await services.persistSession(session)
        for index in 0..<10 {
            await services.persistMessage(
                ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant, content: "turn \(index)"),
                sessionID: session.id
            )
        }
        let state = AppState(services: services)
        await state.refreshTodayPanel(force: true)
        let conversation = { (plan: DailyPlan) in plan.tasks.first { $0.kind == .conversation } }
        let before = try XCTUnwrap(conversation(state.dailyPlan))
        XCTAssertTrue(before.isDone, "10 条对话对 10 轮目标就是达标；实测 \(before.progress)/\(before.target)")

        // 复盘成功 → 练习流水被清（真实路径见 `concludeCurrentPractice`）。
        let purged = await services.purgePracticeMessages(sessionID: session.id)
        XCTAssertGreaterThan(purged, 0, "夹具前提：流水真的被清掉了")

        await state.refreshTodayPanel(force: true)
        let after = try XCTUnwrap(conversation(state.dailyPlan))
        XCTAssertEqual(
            after.progress, before.progress,
            "流水清了，完成量也不许掉 —— 记录少不等于那天没做到"
        )
        XCTAssertTrue(after.isDone, "任务一旦完成就固定为已完成")

        // 重开应用：同一个 UserDefaults，读到的还得是「已完成」。
        let relaunched = AppState(services: CoachServices(config: store, databasePath: databasePath))
        await relaunched.refreshTodayPanel(force: true)
        let restored = try XCTUnwrap(conversation(relaunched.dailyPlan))
        XCTAssertTrue(restored.isDone, "重开应用也不许回退（高水位是落盘的）")
        XCTAssertEqual(restored.progress, before.progress)
    }
}
