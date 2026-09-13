import AIDomain
import AIInfrastructure
import AIInterfaces
import AIProviders
import AppCore
import XCTest

/// 云端调用护栏测试：**「只调用用户选定的那个模型」是结构性保证**。
///
/// 背景是一次真实事故：用户只点了一次「朗读」，云端账单上却出现了十几个不同模型的计费。
/// 逐行审计确认应用里没有遍历模型的循环，但代码里确实埋着一个隐患——
/// 云端 Adapter 在「没选中模型」时会静默回退到 `candidateModels.first`，
/// 那可以是账号里的任意一个模型。本组测试把修复钉在测试里：
///
/// 1. 解析模型时**绝不**回退候选列表（没选就返回 nil）；
/// 2. Adapter 在没选模型时**抛错而不是发请求**——哪怕候选列表里明明有别的模型；
/// 3. 频率 / 总量护栏能掐断失控调用，并把它记进审计。
final class RemoteCallPolicyTests: XCTestCase {

    // MARK: - 单一模型铁律

    func testResolvedModelPrefersExplicitSelection() {
        XCTAssertEqual(RemoteCallPolicy.resolvedModel(selected: "fnlp/MOSS-TTSD-v0.5", providerDefault: "other"), "fnlp/MOSS-TTSD-v0.5")
    }

    func testResolvedModelFallsBackToProviderDefaultOnly() {
        XCTAssertEqual(RemoteCallPolicy.resolvedModel(selected: "  ", providerDefault: "fnlp/MOSS-TTSD-v0.5"), "fnlp/MOSS-TTSD-v0.5")
    }

    /// 核心回归：两者都为空时返回 nil —— 调用方必须拒绝发请求，而不是去猜一个模型。
    func testResolvedModelIsNilWhenNothingSelected() {
        XCTAssertNil(RemoteCallPolicy.resolvedModel(selected: nil, providerDefault: nil))
        XCTAssertNil(RemoteCallPolicy.resolvedModel(selected: "", providerDefault: "   "))
    }

    func testResolvedModelTrimsWhitespace() {
        XCTAssertEqual(RemoteCallPolicy.resolvedModel(selected: "  moSS  ", providerDefault: nil), "moSS")
    }

    // MARK: - 准入判定

    private func intent(_ operation: RemoteCallPolicy.Operation, model: String = "fnlp/MOSS-TTSD-v0.5") -> RemoteCallPolicy.Intent {
        RemoteCallPolicy.Intent(kind: .tts, providerID: "remote.siliconflow-tts", model: model, host: "api.example.com", operation: operation)
    }

    func testEmptyModelIsDenied() {
        let decision = RemoteCallPolicy.decide(intent: intent(.speech, model: "  "), history: [], sessionBillableCount: 0)
        guard case .denied(let reason) = decision else { return XCTFail("空模型必须被拒绝") }
        XCTAssertTrue(reason.contains("未选择模型"), reason)
    }

    func testNormalUsageIsAllowed() {
        let decision = RemoteCallPolicy.decide(intent: intent(.speech), history: [], sessionBillableCount: 0)
        XCTAssertEqual(decision, .allowed)
    }

    /// 同操作一分钟内超限即被掐断，且原因要能让人看懂。
    func testRateLimitBlocksRunawayCalls() {
        let now = Date()
        let history = (0..<20).map { index in
            RemoteCallPolicy.Stamp(at: now.addingTimeInterval(Double(-index)), model: "fnlp/MOSS-TTSD-v0.5", operation: .chat)
        }
        let decision = RemoteCallPolicy.decide(
            intent: intent(.chat), history: history, sessionBillableCount: 20, now: now
        )
        guard case .denied(let reason) = decision else { return XCTFail("超频必须被拒绝") }
        XCTAssertTrue(reason.contains("已拦截"), reason)
    }

    /// 窗口外的历史不该继续压着新请求。
    func testHistoryOutsideWindowDoesNotBlock() {
        let now = Date()
        let history = (0..<30).map { index in
            RemoteCallPolicy.Stamp(at: now.addingTimeInterval(-120 - Double(index)), model: "m", operation: .chat)
        }
        XCTAssertEqual(
            RemoteCallPolicy.decide(intent: intent(.chat), history: history, sessionBillableCount: 30, now: now),
            .allowed
        )
    }

    func testSessionCapBlocksBillableCalls() {
        let limits = RemoteCallPolicy.Limits(billablePerSession: 5)
        let decision = RemoteCallPolicy.decide(
            intent: intent(.speech), history: [], sessionBillableCount: 5, limits: limits
        )
        guard case .denied(let reason) = decision else { return XCTFail("会话总量超限必须被拒绝") }
        XCTAssertTrue(reason.contains("已拦截"), reason)
    }

    /// 只读的模型列表探测不计费，因此不受「计费总量」约束（否则健康检查会被误杀）。
    func testDiscoveryIsNotLimitedByBillableSessionCap() {
        let limits = RemoteCallPolicy.Limits(billablePerSession: 1)
        XCTAssertEqual(
            RemoteCallPolicy.decide(intent: intent(.models, model: ""), history: [], sessionBillableCount: 999, limits: limits),
            .allowed
        )
    }

    /// 模型列表探测也带防失控上限（只读不等于可以无限循环）。
    func testDiscoveryHasItsOwnRateLimit() {
        let now = Date()
        let limits = RemoteCallPolicy.Limits()
        // 全部落在同一个统计窗口内（60s）：按 0.25s 间隔铺 200 条。
        let history = (0..<limits.perMinute(for: .models)).map { index in
            RemoteCallPolicy.Stamp(at: now.addingTimeInterval(-Double(index) * 0.25), model: "", operation: .models)
        }
        if case .allowed = RemoteCallPolicy.decide(intent: intent(.models, model: ""), history: history, sessionBillableCount: 0, limits: limits, now: now) {
            XCTFail("探测次数超限也必须被拦住")
        }
    }

    // MARK: - 异常扇出预警

    func testNoWarningForSingleModel() {
        let now = Date()
        let history = (0..<5).map { _ in RemoteCallPolicy.Stamp(at: now, model: "fnlp/MOSS-TTSD-v0.5", operation: .speech) }
        XCTAssertNil(RemoteCallPolicy.fanOutWarning(history: history, now: now))
    }

    /// 一分钟内出现 ≥3 个不同模型 = 事故形态，必须告警。
    func testWarningOnMultipleModelsInWindow() {
        let now = Date()
        let history = [
            RemoteCallPolicy.Stamp(at: now, model: "a", operation: .chat),
            RemoteCallPolicy.Stamp(at: now, model: "b", operation: .chat),
            RemoteCallPolicy.Stamp(at: now, model: "c", operation: .chat)
        ]
        XCTAssertNotNil(RemoteCallPolicy.fanOutWarning(history: history, now: now))
    }

    /// 护栏自己拦下的「未选择模型」记录（模型名为空）不该被算成一个模型，
    /// 否则预警会自己顶起来，把用户吓一跳。
    func testEmptyModelDoesNotTriggerFanOutWarning() {
        let now = Date()
        let history = [
            RemoteCallPolicy.Stamp(at: now, model: "fnlp/MOSS-TTSD-v0.5", operation: .speech),
            RemoteCallPolicy.Stamp(at: now, model: "", operation: .chat),
            RemoteCallPolicy.Stamp(at: now, model: "   ", operation: .chat)
        ]
        XCTAssertNil(RemoteCallPolicy.fanOutWarning(history: history, now: now))
    }

    func testNoWarningWhenModelsAreSpreadOverTime() {
        let now = Date()
        let history = [
            RemoteCallPolicy.Stamp(at: now, model: "a", operation: .chat),
            RemoteCallPolicy.Stamp(at: now.addingTimeInterval(-90), model: "b", operation: .chat),
            RemoteCallPolicy.Stamp(at: now.addingTimeInterval(-180), model: "c", operation: .chat)
        ]
        XCTAssertNil(RemoteCallPolicy.fanOutWarning(history: history, now: now))
    }

    // MARK: - 审计

    func testAuditCountsBillableAndDiscoverySeparately() async {
        let audit = RemoteCallAudit(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-\(UUID().uuidString).jsonl"))
        await audit.record(intent(.speech), outcome: .ok)
        await audit.record(intent(.speech), outcome: .httpError, httpStatus: 402)
        await audit.record(intent(.models, model: ""), outcome: .ok)

        let summary = await audit.summary()
        XCTAssertEqual(summary.billableTotal, 2)
        XCTAssertEqual(summary.discoveryTotal, 1)
        XCTAssertEqual(summary.models, ["fnlp/MOSS-TTSD-v0.5"])
        XCTAssertEqual(summary.count(for: .speech), 2)
        XCTAssertEqual(summary.count(for: .models), 0)
        XCTAssertEqual(summary.blockedTotal, 0)
        XCTAssertEqual(summary.fanOutWarning, nil)
    }

    /// 被拦截的调用**没有发出去**：不能算进计费次数，也不能污染模型统计。
    func testBlockedCallsAreNotCountedAsBillable() async {
        let audit = RemoteCallAudit(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-\(UUID().uuidString).jsonl"))
        await audit.record(intent(.chat, model: ""), outcome: .blocked)
        let summary = await audit.summary()
        XCTAssertEqual(summary.billableTotal, 0)
        XCTAssertEqual(summary.blockedTotal, 1)
        XCTAssertTrue(summary.models.isEmpty)
        XCTAssertNil(summary.fanOutWarning)
    }

    func testAuditRecordsBlockedCalls() async {
        let audit = RemoteCallAudit(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-\(UUID().uuidString).jsonl"))
        let now = Date()
        let limits = RemoteCallPolicy.Limits()
        // 先用满 chat 名额，再让下一条被拦。
        for index in 0..<limits.perMinute(for: .chat) {
            _ = await audit.authorize(intent(.chat, model: "m"), now: now.addingTimeInterval(-Double(index) - 0.001))
            await audit.record(intent(.chat, model: "m"), outcome: .ok, now: now.addingTimeInterval(-Double(index) - 0.001))
        }
        let decision = await audit.authorize(intent(.chat, model: "m"), now: now)
        guard case .denied = decision else { return XCTFail("应当被拦截") }

        let summary = await audit.summary(now: now)
        XCTAssertEqual(summary.blockedTotal, 1)
        let records = await audit.recent(limit: 5)
        XCTAssertEqual(records.first?.outcome, .blocked)
        XCTAssertFalse(records.first?.isBillable ?? true, "被拦截的调用不计费")
    }

    /// 审计必须落盘（用户要能拿它跟账单逐条对账）。
    func testAuditWritesJSONLinesFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let audit = RemoteCallAudit(fileURL: url)
        await audit.record(intent(.speech), outcome: .ok)
        await audit.record(intent(.models, model: ""), outcome: .ok)

        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(text.contains("fnlp/MOSS-TTSD-v0.5"))
        XCTAssertTrue(text.contains("\"operation\":\"speech\""))
        // 审计绝不含密钥。
        XCTAssertFalse(text.lowercased().contains("sk-"))
    }

    func testAuditResetClearsMemoryNotDisk() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let audit = RemoteCallAudit(fileURL: url)
        await audit.record(intent(.speech), outcome: .ok)
        await audit.reset()
        let summary = await audit.summary()
        XCTAssertEqual(summary.billableTotal, 0)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("speech"), "磁盘留痕不应被清掉")
    }

    // MARK: - Adapter 层：没选模型时抛错，而不是去调别的模型
    //
    // 这两条是本次修复的核心回归——它们证明「候选列表里有别的模型」绝不会被误用。

    private func remoteConfig(kind: AIProviderKind, id: String, model: String?) -> ProviderConfig {
        ProviderConfig(
            id: id, kind: kind, enabled: true, runtime: .remoteAPI,
            endpoint: "https://api.invalid-host.example/v1", apiKey: "sk-test-only",
            model: model, candidateModels: ["some/other-model", "another/model"]
        )
    }

    func testTTSAdapterRefusesWhenNoModelSelected() async throws {
        let provider = RemoteTTSAdapter(providerID: "test.tts")
        try await provider.initialize(config: remoteConfig(kind: .tts, id: "test.tts", model: nil))
        do {
            _ = try await provider.synthesize(TTSRequest(text: "hello"))
            XCTFail("没有选定模型时必须抛错，绝不能拿候选列表里的模型去发请求")
        } catch let error as AIProviderError {
            guard case .invalidConfiguration(let reason) = error else {
                return XCTFail("应当是配置错误，实际：\(error)")
            }
            XCTAssertTrue(reason.contains("未选择"), reason)
        }
    }

    func testASRAdapterRefusesWhenNoModelSelected() async throws {
        let provider = RemoteASRAdapter(providerID: "test.asr")
        try await provider.initialize(config: remoteConfig(kind: .asr, id: "test.asr", model: nil))
        do {
            _ = try await provider.transcribe(ASRRequest(audioSamples: [0.1, 0.2]))
            XCTFail("没有选定模型时必须抛错")
        } catch let error as AIProviderError {
            guard case .invalidConfiguration(let reason) = error else {
                return XCTFail("应当是配置错误，实际：\(error)")
            }
            XCTAssertTrue(reason.contains("未选择"), reason)
        }
    }

    /// 空端点 / 空 Key 依然在装配阶段就被挡下（与既有行为一致）。
    func testAdaptersStillValidateEndpointAndKey() async {
        let provider = RemoteTTSAdapter(providerID: "test.tts")
        let noKey = ProviderConfig(id: "test.tts", kind: .tts, runtime: .remoteAPI, endpoint: "https://api.invalid-host.example/v1", model: "m")
        do {
            try await provider.initialize(config: noKey)
            XCTFail("缺 Key 应当装配失败")
        } catch {
            // 预期
        }
    }
}
