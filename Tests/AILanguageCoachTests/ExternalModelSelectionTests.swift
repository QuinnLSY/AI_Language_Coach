import AIDomain
import AIInfrastructure
import AIServices
import AppCore
@testable import AppUI
import XCTest

/// 外部模型面板的三条选择规则 + 它们与 `AppState` 的接线。
///
/// 防的是一类**看不见**的事故：面板的三处判断（预选哪家 / 绿点亮不亮 / 模型停在哪一项）
/// 曾经都读 `capabilityInfos`，而它只覆盖 asr/tts/vad/embedding/pronunciation ——
/// **不含 `llm`**。于是「AI 大脑」这条路上三条规则同时退化成默认值：
/// 打开面板不定位当前供应商、绿点从来不亮、选好的模型跳回列表第一个。
/// 这里用单测把「数据源必须覆盖 llm」和「三条规则本身」分别钉住。
@MainActor
final class ExternalModelSelectionTests: XCTestCase {

    // MARK: - ① 预选厂商

    /// 当前生效的那家优先 —— 用户点开面板多半就是想看/改它。
    func testPreselectedVendorPrefersActive() {
        XCTAssertEqual(
            ExternalModelSelection.preselectedVendor(
                activeProviderID: "remote.deepseek",
                lastSelected: "remote.openai-llm",
                vendors: ["remote.openai-llm", "remote.deepseek"]
            ),
            "remote.deepseek"
        )
    }

    /// 生效的是**本地** Provider 时（id 不在外部清单里），退回「上次停在哪家」。
    func testPreselectedVendorFallsBackToLastSelected() {
        XCTAssertEqual(
            ExternalModelSelection.preselectedVendor(
                activeProviderID: "local.llm",
                lastSelected: "remote.openrouter",
                vendors: ["remote.deepseek", "remote.openrouter"]
            ),
            "remote.openrouter"
        )
    }

    func testPreselectedVendorFallsBackToFirst() {
        XCTAssertEqual(
            ExternalModelSelection.preselectedVendor(
                activeProviderID: nil, lastSelected: nil, vendors: ["a", "b"]
            ),
            "a"
        )
        XCTAssertNil(
            ExternalModelSelection.preselectedVendor(
                activeProviderID: nil, lastSelected: nil, vendors: []
            )
        )
    }

    // MARK: - ② 绿点

    /// 绿点 = **当前生效**（不是「填过 Key」）。
    func testIsInUseOnlyForActiveProvider() {
        XCTAssertTrue(
            ExternalModelSelection.isInUse(vendor: "remote.deepseek", activeProviderID: "remote.deepseek")
        )
        XCTAssertFalse(
            ExternalModelSelection.isInUse(vendor: "remote.openai-llm", activeProviderID: "remote.deepseek"),
            "切走之后旧 Key 草稿还在，但绿点不该亮"
        )
        XCTAssertFalse(
            ExternalModelSelection.isInUse(vendor: "remote.deepseek", activeProviderID: nil)
        )
    }

    // MARK: - ③ 模型下拉

    /// 这家就是在用的那家 → 下拉停在**当前生效的模型**上，而不是列表第一个。
    func testPreselectedModelPrefersInUseModel() {
        XCTAssertEqual(
            ExternalModelSelection.preselectedModel(
                inUseModel: "deepseek-reasoner",
                models: ["deepseek-chat", "deepseek-reasoner"]
            ),
            "deepseek-reasoner"
        )
    }

    func testPreselectedModelFallsBackToFirstWhenNotInUse() {
        XCTAssertEqual(
            ExternalModelSelection.preselectedModel(
                inUseModel: nil, models: ["deepseek-chat", "deepseek-reasoner"]
            ),
            "deepseek-chat"
        )
        XCTAssertNil(ExternalModelSelection.preselectedModel(inUseModel: nil, models: []))
    }

    /// 拉取会整体替换列表：当前生效的模型即便不在新列表里也要留着，
    /// 否则下拉「跳回默认模型」，而它其实还在生效。
    func testModelOptionsKeepsCurrentEvenWhenMissingFromList() {
        XCTAssertEqual(
            ExternalModelSelection.modelOptions(models: ["a", "b"], keeping: "z"),
            ["z", "a", "b"]
        )
        // 已经在列表里就不重复插。
        XCTAssertEqual(
            ExternalModelSelection.modelOptions(models: ["a", "b"], keeping: "a"),
            ["a", "b"]
        )
        XCTAssertEqual(
            ExternalModelSelection.modelOptions(models: ["a"], keeping: nil),
            ["a"]
        )
        XCTAssertEqual(
            ExternalModelSelection.modelOptions(models: [], keeping: "z"),
            ["z"]
        )
    }

    // MARK: - 推理强度

    func testReasoningOptionsStartWithStandard() {
        let options = ExternalModelSelection.reasoningOptions()
        XCTAssertEqual(options.count, 4)
        XCTAssertNil(options[0].value, "「标准」= 不额外下发思考参数")
        XCTAssertEqual(options[0].label, "标准")
        XCTAssertEqual(options.map(\.value), [nil, "low", "medium", "high"])
    }

    /// 配置里存着不认得的档位时退回「标准」：否则下拉会因为没有匹配项而显示成空白。
    func testNormalizedReasoningRejectsUnknownEffort() {
        XCTAssertEqual(ExternalModelSelection.normalizedReasoning("high"), "high")
        XCTAssertNil(ExternalModelSelection.normalizedReasoning("ultra"))
        XCTAssertNil(ExternalModelSelection.normalizedReasoning(nil))
        XCTAssertNil(ExternalModelSelection.normalizedReasoning(""))
    }

    // MARK: - 「已应用」的判定口径

    /// 供应商 / 模型 / 推理强度任意一项变化都必须让签名变化，
    /// 否则按钮旁那句「已应用到模型卡片」会谎报「已经生效」。
    func testSelectionSignatureChangesWithAnyField() {
        let base = ExternalModelSelection.selectionSignature(
            providerID: "p", model: "m", reasoning: "high"
        )
        XCTAssertNotEqual(
            base,
            ExternalModelSelection.selectionSignature(providerID: "q", model: "m", reasoning: "high")
        )
        XCTAssertNotEqual(
            base,
            ExternalModelSelection.selectionSignature(providerID: "p", model: "n", reasoning: "high")
        )
        XCTAssertNotEqual(
            base,
            ExternalModelSelection.selectionSignature(providerID: "p", model: "m", reasoning: nil)
        )
        XCTAssertEqual(
            base,
            ExternalModelSelection.selectionSignature(providerID: "p", model: "m", reasoning: "high")
        )
    }

    // MARK: - 与 AppState 的接线（不联网）

    /// ⚠️ 核心回归：`capabilityInfos` **本就不含 llm**，所以必须有另一份覆盖全部能力的快照。
    /// 这条用例把「成因」与「修法」同时钉住：哪天有人把它删掉，就会再次出现
    /// 「面板不定位当前供应商 / 绿点不亮 / 模型跳回默认」。
    func testActiveSelectionsCoverLLM() async throws {
        let (services, directory) = makeServices()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await services.persistRemoteProvider(
            providerID: "remote.deepseek",
            apiKey: "sk-test",
            model: "deepseek-chat",
            kind: .llm
        )
        let state = AppState(services: services)
        await state.refreshCapabilityInfos()

        XCTAssertNil(
            state.capabilityInfos[.llm],
            "capabilityInfos 不含 llm 是既有事实 —— 面板若读它，llm 永远查不到生效者"
        )
        XCTAssertEqual(state.activeProviderIDs[.llm], "remote.deepseek")
        XCTAssertEqual(state.activeModels[.llm], "deepseek-chat")
    }

    /// 面板要能「直接显示当前选定的模型」：模型清单里必须有它，且排在首个候选位置。
    func testPrefillExposesActiveLLMModelToSheet() async throws {
        let (services, directory) = makeServices()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await services.persistRemoteProvider(
            providerID: "remote.deepseek",
            apiKey: "sk-test",
            model: "deepseek-reasoner",
            kind: .llm
        )
        let state = AppState(services: services)
        await state.prefillExternalDrafts()

        let models = try XCTUnwrap(state.externalModels["remote.deepseek"])
        XCTAssertTrue(
            models.contains { $0.id == "deepseek-reasoner" },
            "当前在用的模型必须出现在清单里，否则下拉只能显示默认模型：\(models.map(\.id))"
        )
        XCTAssertEqual(state.externalSelectedProvider["llm"], "remote.deepseek")
    }

    /// 输入框为空 = 不配置该供应商：不给启用，也不该顺带发任何请求。
    func testApplyWithEmptyKeyRefusesAndReports() async throws {
        let (services, directory) = makeServices()
        defer { try? FileManager.default.removeItem(at: directory) }

        let state = AppState(services: services)
        await state.applyExternalModel(
            .llm, providerID: "remote.deepseek", model: "deepseek-chat"
        )
        let message = state.externalMessages["remote.deepseek"] ?? ""
        XCTAssertTrue(message.contains("请先填写 API Key"), message)
        XCTAssertNotEqual(
            state.activeProviderIDs[.llm], "remote.deepseek",
            "没填 Key 就不该把这家标成当前生效"
        )
    }

    /// 可复现的最小环境：独立临时目录 + 内存库，不与真实配置互相污染。
    private func makeServices() -> (services: CoachServices, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-select-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let services = CoachServices(
            config: ConfigStore(fileURL: directory.appendingPathComponent("config.json")),
            databasePath: ":memory:"
        )
        return (services, directory)
    }
}
