import AIDomain
import AIInfrastructure
import AIServices
import AppCore
@testable import AppUI
import XCTest

/// 启动链路的回归（需求 #1：首屏不再等开场白）。
///
/// 2026-10-14 改造后：开屏**不自动开场** —— 引导卡（不知道练什么 / 快速开始）
/// 常驻，「继续上次对话」排在第一位，点了才总结上次、发起聊天。
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

    /// 清掉「今天」那几个 `UserDefaults` 键，返回**还原闭包**（用完 `defer { restore() }`）。
    ///
    /// ⚠️ 不隔离就会**串到同进程后续用例**：测试进程共用一个 `UserDefaults` 域，
    /// 而 `AppState` 每次汇总（`reloadProgress` → `raiseDailyTaskFloor`）都会把当天水位写进去 ——
    /// 下一条用例读到的「今天」就是上一条用例的今天。凡是断言 `today.*` 的用例都先用它。
    private func isolateTodayKeys() -> () -> Void {
        let keys = [
            AppState.todayTaskFloorKey,
            AppState.todayCelebratedDayKey,
            AppState.todayBoardAutoExpandedDayKey,
        ]
        let saved = keys.map { UserDefaults.standard.string(forKey: $0) }
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        return {
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
    }

    // MARK: - ① 启动结束时首屏就已经有「今天」

    func testLaunchLeavesTheTodayPanelPopulatedEvenWithADeadModel() async throws {
        let restore = isolateTodayKeys()
        defer { restore() }

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
        // ⚠️ 必须隔离：残留的今天水位会把「全新库」的今日对话数直接抬起来
        // （`today.messages` 说的是「今天做过的量」，它带高水位、且是跨启动持久化的）。
        let restore = isolateTodayKeys()
        defer { restore() }

        let state = try await makeDeadLLMState(withSeededHistory: false)
        await state.start()

        XCTAssertFalse(state.dailyPlan.tasks.isEmpty, "全新状态也要给出可做的任务（开口 + 跟读）")
        XCTAssertEqual(state.dailyPlan.tasks.first?.kind, .conversation)
        XCTAssertEqual(state.progressSnapshot.today.messages, 0)
    }

    // MARK: - ③ 学员先开口 / 点「继续上次对话」→ 那一轮不许把他的话清掉

    /// 「继续上次对话」里有一条**破坏性**分支（隐藏历史 → 复盘 → 清空会话换新的）。
    /// 学员一旦开口，这段会话就归他 —— 那是让位规则的核心。
    ///
    /// 两条入口都钉：先开口再点（让位规则），以及 2026-10-14 起开屏不再自动开场、
    /// 学员第一句话必须让被按住的历史揭开（否则他的话进了内存却不上屏）。
    func testLearnerEngagedKeepsHisOwnWords() async throws {
        let state = try await makeDeadLLMState(withSeededHistory: true)
        await state.start()
        // 学员抢在老师前面说话（现在没有自动开场了，他就是第一个）。
        XCTAssertTrue(state.sendChat("I want to practise ordering food."))
        // 等他这一轮收尾（死端口会秒失败，1 秒足够）。
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertTrue(
            state.chat.visibleMessages.contains { $0.role == .user && $0.content.contains("ordering food") },
            "谁先开口谁说话算数：学员的话必须上屏，也不许被谁清掉"
        )
    }

    /// 学员已经开口之后再点「继续上次对话」：整段让位，一个字都不许动他的会话。
    func testContinueLastConversationYieldsToTheLearner() async throws {
        let state = try await makeDeadLLMState(withSeededHistory: true)
        await state.start()
        XCTAssertTrue(state.sendChat("Let's talk about ordering food."))
        await state.continueLastConversation()
        XCTAssertTrue(
            state.chat.visibleMessages.contains { $0.role == .user && $0.content.contains("ordering food") },
            "「继续上次对话」绝不能把学员刚说的话清掉"
        )
    }

    // MARK: - ⑤ 开屏引导卡（2026-10-14 改造）

    /// 开屏**不再自动开场**：恢复的历史按住不显示，也没有老师的话自己滑进来 ——
    /// 引导卡从此常驻，不再被老师的开场白一瞬间顶掉（用户实测的报障）。
    func testLaunchShowsTheGuideInsteadOfAutoOpening() async throws {
        let state = try await makeDeadLLMState(withSeededHistory: true)
        await state.start()
        XCTAssertTrue(state.launchContinuationAvailable, "有恢复历史，引导卡上就该亮「继续上次对话」")
        XCTAssertTrue(state.chat.visibleMessages.isEmpty, "恢复的历史先按住（等「继续上次」决策）")
        // 等再久也不该有老师的话自己出现 —— 自动开场已移除。
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertTrue(state.chat.visibleMessages.isEmpty, "开屏不许自动开口：引导卡要被看见，不是被顶掉")
        XCTAssertFalse(state.teacherOpenerPending, "没有老师开口，左栏就不该亮提示点")
    }

    /// 第一次打开（库里什么都没有）：引导卡上不亮「继续上次对话」——
    /// 点下去只会收到一句泛泛招呼，凑一颗那种按钮比没有更糟。
    func testFreshLaunchOffersNoContinuation() async throws {
        let state = try await makeDeadLLMState(withSeededHistory: false)
        await state.start()
        XCTAssertFalse(state.launchContinuationAvailable, "什么都没有时不亮「继续上次对话」")
    }

    /// 点「继续上次对话」必须真把流程跑起来：复盘 → 换段 →（死模型下）开场白失败，
    /// 但等待态要复位、旧历史要换成新段 —— 卡在「正在总结」不下来的话，
    /// 引导卡再也回不来，用户点一次就再也打不了字。
    func testContinueLastConversationRunsTheFullFlow() async throws {
        let state = try await makeDeadLLMState(withSeededHistory: true)
        await state.start()
        await state.continueLastConversation()
        XCTAssertFalse(state.isPreparingOpening, "流程跑完（失败也算完）后等待态必须复位")
        XCTAssertTrue(state.chat.messages.isEmpty, "死模型下复盘失败也走完了换段：旧历史清掉，新段空着开口")
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
        let restore = isolateTodayKeys()
        defer { restore() }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("task-floor-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databasePath = directory.appendingPathComponent("learning.db").path
        let store = ConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        let services = CoachServices(config: store, databasePath: databasePath)

        // 今天聊了 10 条（目标 10 轮 → 刚好达标）。
        let session = ChatSession(startedAt: Date(), mode: .conversation)
        await services.persistSession(session)
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

    // MARK: - ⑥ 源码哨兵（删一行也不会编译报错的那几处）

    /// 「继续上次对话」必须**排在第一位**：问候之下、话题卡之上。
    ///
    /// ⚠️ 用**源码位置先后**而不是「出现几次」（渲染那边已经证明「第一位」对像素
    /// 度量不敏感）：把 `continueLastButton` 挪到 `KickoffRow(` 后面 →
    /// 三个 `lowerBound` 的顺序反转 → 这条红。钉调用形态整串的老规矩在这里换成
    /// 钉位置，是因为这里的判据本来就是「谁先谁后」。
    func testGuideCardListsContinuationFirst() throws {
        let chat = try Self.code("Sources/AppUI/Views/ChatView.swift")
        let hint = try XCTUnwrap(chat.range(of: "emptyHint")?.lowerBound, "空态问候要在引导卡里")
        let button = try XCTUnwrap(chat.range(of: "continueLastButton")?.lowerBound, "要有那颗按钮")
        let kickoff = try XCTUnwrap(chat.range(of: "KickoffRow(")?.lowerBound, "要有话题卡那一排")
        XCTAssertLessThan(hint, button, "「继续上次对话」要排在问候之后")
        XCTAssertLessThan(button, kickoff, "「继续上次对话」要排在话题卡之前 —— 它是主操作")
    }

    /// `start()` 必须是**只读地算可用性**（`prepareLaunchGuide`），不是起开场任务。
    /// 换成 `Task` 起任务 → 引导卡又会被顶掉 —— 那正是这次要修的报障。
    func testStartComputesTheGuideWithoutKickingOffATask() throws {
        let state = try Self.code("Sources/AppUI/AppState.swift")
        XCTAssertTrue(
            state.contains("await prepareLaunchGuide()"),
            "start() 要走只读的 prepareLaunchGuide"
        )
        // 开场任务只能由用户点击那条路径起（`continueLastConversationFromGuide`）。
        let openingAssignment = state.components(separatedBy: "openingTask = Task {").count - 1
        XCTAssertEqual(openingAssignment, 1, "起开场任务的地方只能有一处：用户点了「继续上次对话」")
    }

    /// 引导卡上的按钮要真的接在状态机上：光有图没接线，点了屏幕纹丝不动。
    func testMainViewWiresTheContinuationButton() throws {
        let main = try Self.code("Sources/AppUI/Views/MainView.swift")
        XCTAssertTrue(
            main.contains("canContinueLast: state.launchContinuationAvailable"),
            "可用性要来自启动时算好的 launchContinuationAvailable"
        )
        XCTAssertTrue(
            main.contains("onContinueLast: { state.continueLastConversationFromGuide() }"),
            "点击要落到 continueLastConversationFromGuide 上"
        )
        XCTAssertTrue(
            main.contains("isPreparingOpening: state.isPreparingOpening"),
            "等待态要传进去 —— 复盘那段 ChatView 得知道换成等待卡"
        )
    }

    /// 读源码并剥掉注释行 —— 注释里为说明反例写的旧写法不该把判据自己骗过去。
    private static func code(_ path: String) throws -> String {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
