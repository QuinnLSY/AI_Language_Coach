import AIInterfaces
import AIProviders
import AIServices
import AIInfrastructure
import AIDomain
import AppCore
import XCTest

// [MOCK] 第 27 步「资源管理」：纯函数决策 + 生命周期挂起/自动恢复，不依赖任何真实模型。

/// 给 mock LLM 补上「可真实启停」能力：资源管理据此把它当作可挂起的本地模型。
/// （生产里这个协议由 OllamaLLMAdapter / Qwen3TTSAdapter / WhisperASRAdapter 实现。）
extension MockLLMProvider: ModelServiceControlling {
    public func startModelService() async throws {}
    public func stopModelService() async throws {}
}

/// 同样给 mock ASR 补上可启停能力，使 ASR 在集成测试里也能被资源管理挂起/恢复。
extension MockASRProvider: ModelServiceControlling {
    public func startModelService() async throws {}
    public func stopModelService() async throws {}
}

/// 内存监控假实现（注入固定值，驱动策略决策）。available = nil 模拟「系统不告知」。
private struct FakeMemoryMonitor: MemoryPressureMonitoring {
    let available: UInt64?
    func availableMemoryBytes() -> UInt64? { available }
}

// MARK: - 纯函数决策

final class ResourcePolicyTests: XCTestCase {

    private func state(_ kind: AIProviderKind, unloadable: Bool = true, stopped: Bool = false,
                       suspended: Bool = false, idle: Double?) -> ResourcePolicy.ModelState {
        .init(kind: kind, isUnloadable: unloadable, isUserStopped: stopped,
              isSuspended: suspended, idleSeconds: idle)
    }

    private func budget(minMB: Double = 2048) -> ResourcePolicy.MemoryBudget {
        .init(minAvailableBytes: minMB * 1_048_576)
    }

    /// 空闲超时：只挂「可挂起 + 未被关 + 未挂起」且空闲超过各自超时的模型。
    func testIdleTimeoutPicksOnlyEligibleColdModels() {
        let states = [
            state(.llm, idle: 20 * 60),        // 超过 15 分钟 → 挂
            state(.asr, idle: 3 * 60),         // 未到 10 分钟 → 留
            state(.tts, idle: 999 * 60),       // 没配空闲超时 → 永不按空闲挂
            state(.llm, unloadable: false, idle: 99 * 60), // 云端/mock 不可挂
            state(.asr, stopped: true, idle: 99 * 60),     // 用户关闭的不碰
            state(.asr, suspended: true, idle: 99 * 60),   // 已挂起不重复
        ]
        let decisions = ResourcePolicy.suspendDecisions(
            states: states,
            idleTimeouts: [.llm: 15 * 60.0, .asr: 10 * 60.0],
            activeWindowSeconds: 2 * 60,
            budget: budget(),
            availableMemoryBytes: 8_000_000_000
        )
        XCTAssertEqual(decisions, [.llm])
    }

    /// 从未使用过的模型 = 最冷，也应按空闲挂起（省内存优先）。
    ///
    /// 注意：这里的 `idle: nil` 是「**完全没有注册任何 Provider**」的语义（管理器对未装配的能力
    /// 才报 nil），仍按 ∞（最冷）处理。而「已注册但尚未用过」的能力，自 2026-09-19 修复后
    /// 由 Manager 报「从装配时刻起算」的有限空闲（见 `ASRManager`/`LLMManager` 的 `startedAt`），
    /// 不会再被当成 ∞ 在首检即挂起——那正是语音识别「设置里开着、一用就连接失败」的根因。
    func testNeverUsedCountsAsColdest() {
        let decisions = ResourcePolicy.suspendDecisions(
            states: [state(.llm, idle: nil)],
            idleTimeouts: [.llm: 60],
            activeWindowSeconds: 120,
            budget: budget(),
            availableMemoryBytes: 8_000_000_000
        )
        XCTAssertEqual(decisions, [.llm])
    }

    /// 内存压力：活跃窗口内的模型绝不动（用户正在用），窗口外的按最冷优先。
    func testPressureUnloadsColdestFirstButProtectsActiveWindow() {
        let states = [
            state(.llm, idle: 30),      // 活跃窗口内 → 保护
            state(.asr, idle: 10 * 60), // 冷
            state(.tts, idle: 5 * 60),  // 更冷 → 先挂
        ]
        let decisions = ResourcePolicy.suspendDecisions(
            states: states,
            idleTimeouts: [:],
            activeWindowSeconds: 2 * 60,
            budget: budget(minMB: 2048),
            availableMemoryBytes: 1024 * 1_048_576 // 低于 2048MB
        )
        XCTAssertEqual(decisions, [.asr, .tts])
    }

    /// 内存信息缺失（系统不告知）→ 保守处理：不触发压力卸载，只按空闲规则走。
    func testUnknownAvailableMemoryNeverTriggersPressure() {
        let decisions = ResourcePolicy.suspendDecisions(
            states: [state(.llm, idle: 99 * 60)],
            idleTimeouts: [:], // 也没配空闲超时
            activeWindowSeconds: 120,
            budget: budget(),
            availableMemoryBytes: nil
        )
        XCTAssertTrue(decisions.isEmpty)
    }

    /// 可用内存充足 → 无压力卸载；空闲超时仍然生效。
    func testPlentyOfMemoryFallsBackToIdleRules() {
        let states = [state(.llm, idle: 99 * 60), state(.asr, idle: 30)]
        let decisions = ResourcePolicy.suspendDecisions(
            states: states,
            idleTimeouts: [.llm: 15 * 60.0, .asr: 10 * 60.0],
            activeWindowSeconds: 120,
            budget: budget(),
            availableMemoryBytes: 10_000_000_000
        )
        XCTAssertEqual(decisions, [.llm])
    }
}

// MARK: - 生命周期集成（挂起 → 使用时自动恢复）

@MainActor
final class ResourceLifecycleTests: XCTestCase {

    private func makeServices() async throws -> (CoachServices, URL) {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-lifecycle-\(UUID().uuidString).json")
        let store = ConfigStore(fileURL: fileURL)
        try await store.updateProvider(
            ProviderConfig(id: "ollama.llm", kind: .llm, enabled: true, runtime: .mock, model: "mock-model")
        )
        try await store.selectModel("mock-model", for: .llm)
        // 阈值压到最小：LLM 空闲即挂起、对话窗口趋近于零、巡检间隔最短。
        try await store.mutateResourcePolicy { policy in
            policy.llmIdleUnloadMinutes = 0.001
            policy.asrIdleUnloadMinutes = 0.001
            policy.activeWindowMinutes = 0.0001
            policy.minAvailableMemoryMB = 2048
            policy.tickSeconds = 0.05
        }
        let services = CoachServices(config: store, databasePath: ":memory:")
        return (services, fileURL)
    }

    /// 在 store 里补一个启用的 ASR Provider（mock，可真实启停），让 `bootstrapVoice()` 能装配它。
    /// 放行默认配置里所有 provider 的启停命令（#S2-6 的授权闸门在单测里要显式放行）。
    private func approveDefaultServiceCommands() {
        guard let defaults = try? DefaultConfiguration.load() else { return }
        for provider in defaults.providers {
            if let command = provider.serviceStartCommand { ShellCommandApproval.approve(command) }
            if let command = provider.serviceStopCommand { ShellCommandApproval.approve(command) }
        }
    }

    private func registerMockASR(_ services: CoachServices) async throws {
        let store = await services.configStore
        try await store.updateProvider(
            ProviderConfig(id: "mock.asr", kind: .asr, enabled: true, runtime: .mock, model: "mock-model")
        )
        try await store.selectModel("mock-model", for: .asr)
    }

    private func waitForReply(_ chat: ChatService, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if chat.messages.contains(where: { $0.role == .assistant }) { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// 资源巡检把空闲的本地 LLM 挂起：isModelRunning 变 false，快照可查。
    /// （内存读数 = nil → 系统不告知 → 保守地不走压力规则，纯靠「空闲超时」挂起。）
    ///
    /// ⚠️ 必须先让模型真正空闲超过阈值：自 2026-09-19 修复后，刚装配（注册）的模型空闲时长
    /// 从装配时刻起算（不再报 nil→∞），所以首检那一刻它只空闲了几毫秒，不该被挂起——
    /// 直接对「刚启动」的模型跑巡检得不到「已挂起」。这里先等 300ms 再巡检，模拟真实空闲窗口。
    func testResourceTickSuspendsIdleControllableModel() async throws {
        let (services, fileURL) = try await makeServices()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try await services.bootstrapLLM()
        var running = await services.isModelRunning(.llm)
        XCTAssertTrue(running)

        // 让 LLM 真正空闲超过阈值（llmIdleUnloadMinutes = 0.001 → 60ms）。
        try await Task.sleep(nanoseconds: 300_000_000)
        let tickSeconds = await services.runResourceTick(monitor: FakeMemoryMonitor(available: nil))
        running = await services.isModelRunning(.llm)
        XCTAssertFalse(running, "空闲超过阈值的可挂起模型应当被自动挂起")

        let states = await services.resourceStates()
        let llmState = try XCTUnwrap(states.first { $0.kind == .llm })
        XCTAssertTrue(llmState.isSuspended)
        XCTAssertFalse(llmState.isUserStopped, "挂起不是用户关闭，语义必须分开")

        // 下次巡检间隔来自配置。
        let store = await services.configStore
        let configured = await store.current.resourcePolicy.tickSeconds
        XCTAssertEqual(tickSeconds, configured, accuracy: 0.001)
    }

    /// 用户显式关闭的模型绝不会被资源管理触碰（意图必须尊重）。
    func testResourceTickNeverTouchesUserStoppedModel() async throws {
        let (services, fileURL) = try await makeServices()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try await services.bootstrapLLM()
        _ = try await services.setModelRunning(.llm, running: false)
        _ = await services.runResourceTick(monitor: FakeMemoryMonitor(available: 1))

        let states = await services.resourceStates()
        let llmState = try XCTUnwrap(states.first { $0.kind == .llm })
        XCTAssertTrue(llmState.isUserStopped)
        XCTAssertFalse(llmState.isSuspended, "用户关闭的资源管理不能再插手")
    }

    /// 核心承诺：被挂起的模型在下次使用时**自动恢复**——用户发消息，老师照样回复。
    func testSuspendedModelAutoResumesWhenUserSendsMessage() async throws {
        let (services, fileURL) = try await makeServices()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try await services.bootstrapLLM()
        // 先让模型真正空闲超过阈值（修复后空闲从装配时刻起算，刚启动的几毫秒不算「最冷」）。
        try await Task.sleep(nanoseconds: 300_000_000)
        _ = await services.runResourceTick(monitor: FakeMemoryMonitor(available: nil))
        var running = await services.isModelRunning(.llm)
        XCTAssertFalse(running, "前置：模型已被资源管理挂起")

        let chat = ChatService(services: services)
        chat.send("Are you back?")
        await waitForReply(chat)

        running = await services.isModelRunning(.llm)
        XCTAssertTrue(running, "发送消息应当自动恢复被挂起的模型")
        XCTAssertEqual(chat.messages.filter { $0.role == .assistant }.count, 1,
                       "挂起对用户透明：老师必须回复")
        XCTAssertNil(chat.errorMessage)
    }

    /// 生命周期管理器：start 后周期巡检（幂等）、stop 后停止（幂等）。
    func testLifecycleManagerStartsAndStopsIdempotently() async throws {
        let (services, fileURL) = try await makeServices()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try await services.bootstrapLLM()

        let manager = ModelLifecycleManager(services: services, monitor: FakeMemoryMonitor(available: nil))
        await manager.start()
        await manager.start() // 幂等：重复 start 不叠加
        // 周期巡检间隔下限为 1s（防忙转），故至少要等一轮巡检生效。
        // 修复后空闲从装配时刻起算，刚启动的模型不立即被挂起，需真正空闲超过阈值。
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let running = await services.isModelRunning(.llm)
        XCTAssertFalse(running, "周期巡检应当把空闲模型挂起")

        await manager.stop()
        await manager.stop() // 幂等：重复 stop 不崩
    }

    // MARK: - 回归（2026-09-19 语音识别「设置里明明开着、一用就连接失败」）

    /// 根因回归：随应用 / 设置启动的本地 ASR，第一次资源巡检**绝不该**被挂起。
    ///
    /// 修复前：`ASRManager.idleSeconds` 在「注册后还没转写过」时返回 nil → `ResourcePolicy`
    /// 把 nil 当 ∞（最冷）→ 开屏后的首轮巡检就把刚启动的 whisper 杀了，表现成
    /// 「设置里明明开着、一用就连接失败」（只有去设置里关了再开、真正重启服务才恢复）。
    /// 修复后：注册即记 `startedAt`，空闲从那一刻起算；首检时只有数秒空闲，远未到 1 分钟阈值，
    /// 因此 ASR 保持运行。
    func testFreshlyBootstrappedASRNotSuspendedOnFirstTick() async throws {
        let (services, fileURL) = try await makeServices()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try await registerMockASR(services)
        // 用现实阈值：模拟「开屏后还没人开口」的真实窗口，避免首检误杀。
        let store = await services.configStore
        try await store.mutateResourcePolicy { policy in
            policy.asrIdleUnloadMinutes = 1
        }

        await services.bootstrapVoice()
        var asrRunning = await services.isModelRunning(.asr)
        XCTAssertTrue(asrRunning, "前置：ASR 已随启动注册")

        // 紧接一次巡检——这正是 bug 触发点（开屏后的首轮巡检）。
        _ = await services.runResourceTick(monitor: FakeMemoryMonitor(available: nil))
        asrRunning = await services.isModelRunning(.asr)
        XCTAssertTrue(asrRunning,
                      "刚启动的 ASR 不应在第一轮巡检被挂起（空闲仅数秒，远未到 1 分钟阈值）")
    }

    /// 行为回归：被巡检挂起的 ASR，在使用处（`resumeIfSuspended`）应当**自动恢复**，
    /// 而非依赖一份已经过期的界面快照。对应修复 ①——使用处判断一律问服务层真源。
    ///
    /// 这里用极小阈值 + 短暂等待让 ASR 确实进入「已挂起」状态，再调用 `resumeIfSuspended`
    /// 验证它能把服务拉回来（`isModelRunning(.asr)` 回到 true）。
    func testSuspendedASRAutoResumesViaResumeIfSuspended() async throws {
        let (services, fileURL) = try await makeServices()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        // ⚠️ #S2-6：挂起本机 ASR 会执行它的 serviceStopCommand，而启停命令现在需要用户授权
        // （真实用户是在设置里点「启动/关闭」时确认的）。这里统一放行默认配置里的命令。
        // 不放行的话：挂起静默失败 → 用例卡在前置「ASR 已被巡检挂起」。
        approveDefaultServiceCommands()
        defer { ShellCommandApproval.revokeAll() }
        try await registerMockASR(services)
        // ⚠️ 必须把默认的 local.asr 一并禁用：`CoachServices.preferredProvider(.asr)`
        // 优先非 mock，不禁用的话 bootstrapVoice 装配的是**真实 WhisperASRAdapter** ——
        // 恢复时会跑它的启动命令、等 8858 满 60s（CI 上没有服务，必红；本地则靠
        // `$HOME/AI_Models/bin/start-asr.sh` 偷偷把真 whisper 拉起来才绿）。
        // 禁用后 asr 能力只剩 mock：suspend/resume 全程应用层面，不碰任何真实命令。
        let store = await services.configStore
        try await store.mutateProvider(id: "local.asr") { $0.enabled = false }
        try await store.mutateResourcePolicy { policy in
            policy.asrIdleUnloadMinutes = 0.001 // 60ms 即挂起
        }

        await services.bootstrapVoice()
        var asrRunning = await services.isModelRunning(.asr)
        XCTAssertTrue(asrRunning, "前置：ASR 已注册")

        // 等待超过 60ms 阈值，让首轮巡检把它挂起。
        try await Task.sleep(nanoseconds: 300_000_000)
        _ = await services.runResourceTick(monitor: FakeMemoryMonitor(available: nil))
        asrRunning = await services.isModelRunning(.asr)
        XCTAssertFalse(asrRunning, "前置：ASR 已被巡检挂起")

        // 使用处的自动恢复路径（与 AppState 各语音入口一致）。
        _ = try? await services.resumeIfSuspended(.asr)
        asrRunning = await services.isModelRunning(.asr)
        XCTAssertTrue(asrRunning,
                      "使用处应自动恢复被挂起的 ASR，不再依赖过期快照")
    }
}
