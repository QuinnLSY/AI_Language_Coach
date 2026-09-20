import AIDomain
import AIInfrastructure
import AIInterfaces
import AIServices
import AppCore
import XCTest

/// 配置写入的回归测试。
///
/// 背景：云端 Provider 的激活路径曾经是「函数开头取一份 `AppConfiguration` 快照 →
/// 逐字段 `updateProvider` 写回」。`AppConfiguration` 是**值类型**，同一次操作里
/// 后写的字段会把先写的**覆盖回旧值**——实测把刚保存的 API Key 与模型名抹成空、
/// 只留下 `enabled`，界面上就表现为「提示已启用云端模型，卡片却写着未配置 /
/// 未填写 API Key」，对话时则报未连接不可用。
///
/// 现在所有写入一律走 ConfigStore 的原子局部更新（`mutateProvider` /
/// `mutateProviders` / `mutateProduct`），下面把当时的行为固定下来。
final class ConfigPersistenceTests: XCTestCase {

    private func makeStore() throws -> (store: ConfigStore, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-test-\(UUID().uuidString).json")
        return (ConfigStore(fileURL: url), url)
    }

    // MARK: - 云端 Provider 激活：Key / 模型 / 激活记录一个都不能丢

    /// 与 `CoachServices.applyRemoteProvider` 一致的写入顺序。
    func testApplyingRemoteProviderKeepsKeyModelAndActiveProvider() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let providerID = "remote.siliconflow-asr"
        let apiKey = "sk-test-1234567890abcdef"
        let model = "XingChenAGI/XingChenASR-Diarize-V3.0"

        try await store.mutateProviders(kind: .asr) { $0.enabled = ($0.id == providerID) }
        try await store.mutateProvider(id: providerID) { provider in
            provider.apiKey = apiKey
            provider.model = model
        }
        try await store.mutateProduct { product in
            product.activateProvider(providerID, for: .asr)
            product.selectModel(model, for: .asr)
        }

        let saved = await store.current
        let provider = try XCTUnwrap(saved.providers.first { $0.id == providerID })
        XCTAssertEqual(provider.apiKey, apiKey, "刚填的 API Key 不能被覆盖成空")
        XCTAssertEqual(provider.model, model, "刚选的模型名不能被覆盖成空")
        XCTAssertTrue(provider.enabled)
        XCTAssertEqual(saved.product.activeProvider(for: .asr), providerID)
        XCTAssertEqual(saved.product.selectedModel(for: .asr), model)
        // 解析链路（设置页卡片与对话链路都读它）
        XCTAssertEqual(saved.resolvedProvider(for: .asr)?.id, providerID)
        XCTAssertEqual(saved.resolvedModel(for: .asr), model)

        // 必须真的落盘：重启后 Key 与模型仍在（草稿框是空的，只能从配置读）。
        // 直接读磁盘 JSON 验证（配置的键会被转成 snake_case）。
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let savedProviders = try XCTUnwrap(json["providers"] as? [[String: Any]])
        let onDisk = try XCTUnwrap(savedProviders.first { $0["id"] as? String == providerID })
        XCTAssertEqual(onDisk["api_key"] as? String, apiKey, "配置文件里必须存下 API Key")
        XCTAssertEqual(onDisk["model"] as? String, model, "配置文件里必须存下模型名")
        let savedProduct = try XCTUnwrap(json["product"] as? [String: Any])
        let activeProviders = try XCTUnwrap(savedProduct["active_providers"] as? [String: String])
        XCTAssertEqual(activeProviders["asr"], providerID, "激活记录必须落盘")
        let selectedModels = try XCTUnwrap(savedProduct["selected_models"] as? [String: String])
        XCTAssertEqual(selectedModels["asr"], model, "选中模型必须落盘")
    }

    /// 原子写入**顺序无关**：先写 Key 再走「同类只留一个 enabled」的遍历，同样不丢。
    /// （旧写法在这一步会把 Key 抹掉。）
    func testEnableSweepNeverErasesKeyEvenWhenRunAfterwards() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let providerID = "remote.openai-asr"
        let apiKey = "sk-reversed-order"
        try await store.mutateProvider(id: providerID) { provider in
            provider.apiKey = apiKey
            provider.model = "whisper-1"
        }
        try await store.mutateProviders(kind: .asr) { $0.enabled = ($0.id == providerID) }

        let saved = await store.current
        XCTAssertEqual(saved.providers.first { $0.id == providerID }?.apiKey, apiKey)
        XCTAssertEqual(saved.providers.first { $0.id == providerID }?.model, "whisper-1")
        for provider in saved.providers where provider.kind == .asr && provider.id != providerID {
            XCTAssertFalse(provider.enabled, "同类的其它 Provider 应当被停用")
        }
    }

    /// 切换某个能力使用的模型时，只能动 model，不能连带抹掉同一条记录上的 Key。
    func testSwitchingModelKeepsApiKey() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let providerID = "remote.siliconflow-tts"
        let apiKey = "sk-tts-keep-me"
        try await store.mutateProvider(id: providerID) { provider in
            provider.apiKey = apiKey
            provider.model = "FunAudioLLM/CosyVoice2-0.5B"
        }

        // `setCapabilityModel` 的等价序列
        try await store.mutateProvider(id: providerID) { $0.model = "fishaudio/fish-speech-1.5" }
        try await store.mutateProduct { $0.selectModel("fishaudio/fish-speech-1.5", for: .tts) }

        let saved = await store.current
        let provider = try XCTUnwrap(saved.providers.first { $0.id == providerID })
        XCTAssertEqual(provider.apiKey, apiKey)
        XCTAssertEqual(provider.model, "fishaudio/fish-speech-1.5")
        XCTAssertEqual(saved.resolvedModel(for: .tts), "fishaudio/fish-speech-1.5")
    }

    /// 写 Provider 不影响产品层，写产品层不影响 Provider——两边的原子性互不干扰。
    func testProductAndProviderWritesAreIndependent() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        try await store.mutateProduct { $0.dailyGoalMinutes = 42 }
        try await store.mutateProvider(id: "remote.groq-asr") { $0.apiKey = "sk-groq" }

        let saved = await store.current
        XCTAssertEqual(saved.product.dailyGoalMinutes, 42)
        XCTAssertEqual(saved.providers.first { $0.id == "remote.groq-asr" }?.apiKey, "sk-groq")
    }

    // MARK: - 服务层端到端：走真实的 CoachServices 写入链路

    /// 用真实的 `CoachServices` 跑一遍「填 Key → 选模型」，验证配置里真的留下了 Key 与模型。
    /// （历史上这条链路会把 Key 覆盖成空，界面表现为「显示已启用却仍是未配置」。）
    func testServiceLayerPersistsKeyAndModelEndToEnd() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("coach-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let services = CoachServices(
            config: ConfigStore(fileURL: directory.appendingPathComponent("config.json")),
            databasePath: directory.appendingPathComponent("learning.db").path
        )
        let apiKey = "sk-e2e-keep-me"
        let model = "XingChenAGI/XingChenASR-Diarize-V3.0"
        try await services.persistRemoteProvider(
            providerID: "remote.siliconflow-asr", apiKey: apiKey, model: model, kind: .asr
        )

        let configuration = await services.configuration
        XCTAssertEqual(configuration.resolvedProvider(for: .asr)?.id, "remote.siliconflow-asr")
        XCTAssertEqual(configuration.resolvedModel(for: .asr), model)
        XCTAssertEqual(configuration.providers.first { $0.id == "remote.siliconflow-asr" }?.apiKey, apiKey)
        XCTAssertEqual(configuration.product.activeProvider(for: .asr), "remote.siliconflow-asr")
        XCTAssertEqual(configuration.product.selectedModel(for: .asr), model)
    }

    /// 只填了 Key 但还没选模型时，云端 Provider 也算「可用」——不能回退到本地。
    func testCloudProviderBecomesUsableOnceKeyIsSet() async throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        try await store.mutateProviders(kind: .tts) { $0.enabled = ($0.id == "remote.openai-tts") }
        try await store.mutateProduct { $0.activateProvider("remote.openai-tts", for: .tts) }
        // 还没填 Key：不该生效
        var saved = await store.current
        XCTAssertNotEqual(saved.resolvedProvider(for: .tts)?.id, "remote.openai-tts")

        try await store.mutateProvider(id: "remote.openai-tts") { $0.apiKey = "sk-tts" }
        saved = await store.current
        XCTAssertEqual(saved.resolvedProvider(for: .tts)?.id, "remote.openai-tts")
    }

    // MARK: - 29 步费用事故：任何路径都不许「替用户」挑模型

    /// 切到「有候选清单、但自己没配默认模型」的 Provider 时，
    /// **绝不能**把 `candidateModels.first` 写成新的选中模型 —— 那等于替用户选了
    /// 账号里任意一个模型去计费（正是这次事故的形态）。
    ///
    /// 用本地端口的无效地址装配：健康检查会立刻连接失败（不产生任何费用），
    /// 正好验证「装配失败也不该悄悄塞一个模型进来」。
    func testSwitchingProviderNeverInventsModelFromCandidateList() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("switch-provider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        try await store.mutateProvider(id: "ollama.llm") { provider in
            provider.model = nil                                   // 该 Provider 没配默认模型
            provider.candidateModels = ["qwen3:8b", "llama3:8b"]     // 只有一份候选清单
            provider.endpoint = "http://127.0.0.1:1"                 // 必然连不上，装机过程不产生费用
        }
        let services = CoachServices(
            config: store,
            databasePath: directory.appendingPathComponent("learning.db").path
        )
        try await services.switchLLMProvider("ollama.llm")

        let configuration = await services.configuration
        XCTAssertNil(configuration.product.selectedModel(for: .llm),
                     "候选清单里的第一个模型不能变成「用户选中的模型」")
        XCTAssertNil(configuration.resolvedModel(for: .llm),
                     "什么都没选时就是没有模型 —— 交给闸门拒绝，而不是猜一个")
    }

    // MARK: - 启动 / 关闭按钮的语义

    /// 按钮只在「用户没关掉 **且** 健康检查通过」时才是「关闭」。
    func testRunControlOnlyShowsStopWhenActuallyUsable() {
        // 用户没关，但服务没启动 / 没填 Key → 必须给「启动」，否则用户无处可点。
        XCTAssertFalse(ModelRunControl.isActive(running: true, healthOK: false))
        XCTAssertEqual(ModelRunControl.title(running: true, healthOK: false), "启动")
        XCTAssertEqual(ModelRunControl.systemImage(running: true, healthOK: false), "play.circle.fill")
        XCTAssertTrue(ModelRunControl.nextRunningState(running: true, healthOK: false),
                      "点「启动」应当真的去拉起服务（而不是关掉一个没在跑的东西）")

        // 真正可用 → 「关闭」。
        XCTAssertTrue(ModelRunControl.isActive(running: true, healthOK: true))
        XCTAssertEqual(ModelRunControl.title(running: true, healthOK: true), "关闭")
        XCTAssertEqual(ModelRunControl.systemImage(running: true, healthOK: true), "stop.circle.fill")
        XCTAssertFalse(ModelRunControl.nextRunningState(running: true, healthOK: true))

        // 用户主动关掉 → 回到「启动」。
        XCTAssertFalse(ModelRunControl.isActive(running: false, healthOK: true))
        XCTAssertTrue(ModelRunControl.nextRunningState(running: false, healthOK: true))
    }

    // MARK: - 旧版用户配置的字段兜底

    /// **存量用户的配置文件可能是旧版本写下的**：默认配置后来给某个 Provider 加了字段
    /// （本地语音识别的启停命令就是这么来的），而 `merge` 是按**整条 provider** 替换的 ——
    /// 用户那一版里没有这个键，合并后被吞掉，表现为「设置页点启动报没有命令」。
    ///
    /// 因此仓库要留一份内置默认供取用（`bundledProvider`），缺什么补什么。
    func testFillServiceCommandsRecoversCommandsForLegacyConfig() {
        // 旧版配置：整条 provider 里没有启停命令（本轮新增字段之前写下的）。
        let legacy = ProviderConfig(
            id: "local.asr",
            kind: .asr,
            runtime: .externalLocalRuntime,
            endpoint: "http://127.0.0.1:8858",
            model: "ggml-small.en"
        )
        XCTAssertNil(legacy.serviceStartCommand)

        let filled = CoachServices.fillServiceCommands(legacy)
        XCTAssertFalse(
            (filled.serviceStartCommand ?? "").isEmpty,
            "内置默认里必须还能取到启动命令 —— 否则本机语音识别每次都得手动点「启动」"
        )
        XCTAssertFalse((filled.serviceStopCommand ?? "").isEmpty, "停止命令同样要补齐")

        // 用户自己配了命令时不能被内置的覆盖回去。
        var customized = legacy
        customized.serviceStartCommand = "echo mine"
        XCTAssertEqual(CoachServices.fillServiceCommands(customized).serviceStartCommand, "echo mine")
    }
}
