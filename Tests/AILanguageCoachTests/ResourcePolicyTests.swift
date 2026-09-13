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
            idleTimeouts: [.llm: 15 * 60, .asr: 10 * 60],
            activeWindowSeconds: 2 * 60,
            budget: budget(),
            availableMemoryBytes: 8_000_000_000
        )
        XCTAssertEqual(decisions, [.llm])
    }

    /// 从未使用过的模型 = 最冷，也应按空闲挂起（省内存优先）。
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
            idleTimeouts: [.llm: 15 * 60, .asr: 10 * 60],
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

    private func waitForReply(_ chat: ChatService, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if chat.messages.contains(where: { $0.role == .assistant }) { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// 资源巡检把空闲的本地 LLM 挂起：isModelRunning 变 false，快照可查。
    /// （内存读数 = nil → 系统不告知 → 保守地不走压力规则，纯靠「空闲超时」挂起。）
    func testResourceTickSuspendsIdleControllableModel() async throws {
        let (services, fileURL) = try await makeServices()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try await services.bootstrapLLM()
        var running = await services.isModelRunning(.llm)
        XCTAssertTrue(running)

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
        // 等待至少一次巡检生效（tickSeconds = 0.05）。
        try await Task.sleep(nanoseconds: 300_000_000)
        let running = await services.isModelRunning(.llm)
        XCTAssertFalse(running, "周期巡检应当把空闲模型挂起")

        await manager.stop()
        await manager.stop() // 幂等：重复 stop 不崩
    }
}
