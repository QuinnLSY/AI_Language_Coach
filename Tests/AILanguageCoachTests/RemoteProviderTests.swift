import AIInfrastructure
import AIDomain
import AIInterfaces
import AIProviders
import AppCore
import XCTest

/// 云端 Provider（本地 / 云端并存，按 API Key 接入）的规则与装配测试。
///
/// 覆盖三件事：① 混合模型列表能否按能力正确归类；② 各能力是否都配了云端供应商；
/// ③ 用户在设置里选中云端后，装配链路是否真的听他的（而不是继续用本地 runtime）。
final class RemoteProviderTests: XCTestCase {

    // MARK: - 按能力归类

    func testClassifyRecognisesSpeechModels() {
        XCTAssertEqual(RemoteModelFilter.classify("whisper-1"), .asr)
        XCTAssertEqual(RemoteModelFilter.classify("gpt-4o-transcribe"), .asr)
        XCTAssertEqual(RemoteModelFilter.classify("tts-1-hd"), .tts)
        XCTAssertEqual(RemoteModelFilter.classify("gpt-4o-mini-tts"), .tts)
        XCTAssertEqual(RemoteModelFilter.classify("text-embedding-3-small"), .embedding)
        XCTAssertEqual(RemoteModelFilter.classify("deepseek-chat"), .llm)
    }

    func testFilterKeepsOnlyRequestedKind() {
        let ids = ["gpt-4o", "whisper-1", "tts-1", "text-embedding-3-small", "deepseek-chat"]
        XCTAssertEqual(RemoteModelFilter.filterIDs(ids, for: .asr), ["whisper-1"])
        XCTAssertEqual(RemoteModelFilter.filterIDs(ids, for: .tts), ["tts-1"])
        XCTAssertEqual(RemoteModelFilter.filterIDs(ids, for: .embedding), ["text-embedding-3-small"])
        XCTAssertEqual(
            Set(RemoteModelFilter.filterIDs(ids, for: .llm)),
            ["gpt-4o", "deepseek-chat"]
        )
    }

    /// 铁律：厂商命名完全不认识时**原样返回**，不能因为规则不认识就把模型挡在门外。
    func testFilterFallsBackWhenNothingMatches() {
        let ids = ["acme-model-alpha", "acme-model-beta"]
        XCTAssertEqual(RemoteModelFilter.filterIDs(ids, for: .asr), ids)
        XCTAssertEqual(RemoteModelFilter.filterIDs([], for: .asr), [])
    }

    // MARK: - 端点拼接

    func testEndpointNormalisation() throws {
        XCTAssertEqual(
            RemoteEndpoint.base("https://api.groq.com/openai/")?.absoluteString,
            "https://api.groq.com/openai"
        )
        XCTAssertNil(RemoteEndpoint.base("不是 URL"))

        let base = try? XCTUnwrap(RemoteEndpoint.base("https://api.groq.com/openai"))
        XCTAssertEqual(
            RemoteEndpoint.url(base: try XCTUnwrap(base), path: "v1/models").path,
            "/openai/v1/models"
        )
        // 端点已含 /v1 的厂商（OpenAI / SiliconFlow）不能拼出 /v1/v1。
        let openai = try XCTUnwrap(RemoteEndpoint.base("https://api.openai.com/v1"))
        XCTAssertEqual(RemoteEndpoint.url(base: openai, path: "v1/models").path, "/v1/models")
        let v1 = try? XCTUnwrap(RemoteEndpoint.base("https://api.siliconflow.cn/v1"))
        XCTAssertEqual(
            RemoteEndpoint.url(base: try XCTUnwrap(v1), path: "/v1/models").path,
            "/v1/models"
        )
    }

    func testLanguageTagNormalisation() {
        XCTAssertEqual(RemoteEndpoint.primaryLanguageTag("en-US"), "en")
        XCTAssertEqual(RemoteEndpoint.primaryLanguageTag("zh-CN"), "zh")
        XCTAssertEqual(RemoteEndpoint.primaryLanguageTag("EN"), "en")
        XCTAssertNil(RemoteEndpoint.primaryLanguageTag(nil))
        XCTAssertNil(RemoteEndpoint.primaryLanguageTag("  "))
    }

    // MARK: - 默认配置：每种能力都要有云端可选

    func testDefaultConfigProvidesRemoteOptionsPerKind() throws {
        let configuration = try DefaultConfiguration.load()
        for kind in [AIProviderKind.llm, .asr, .tts] {
            let remote = configuration.providers.filter { $0.kind == kind && $0.runtime == .remoteAPI }
            XCTAssertFalse(remote.isEmpty, "\(kind.rawValue) 至少要有一个云端供应商可接")
            XCTAssertTrue(remote.allSatisfy { $0.endpoint?.isEmpty == false })
        }
        // 本地 Provider 保持默认启用，云端默认关闭（不替用户做联网决定）。
        let localASR = try XCTUnwrap(configuration.providers.first { $0.id == "local.asr" })
        XCTAssertTrue(localASR.enabled)
        let cloudASR = try XCTUnwrap(configuration.providers.first { $0.id == "remote.openai-asr" })
        XCTAssertFalse(cloudASR.enabled)
        XCTAssertEqual(cloudASR.resolvedModelsPath, "v1/models")
    }

    func testCloudTTSPresetCarriesVoices() throws {
        let configuration = try DefaultConfiguration.load()
        let tts = try XCTUnwrap(configuration.providers.first { $0.id == "remote.openai-tts" })
        XCTAssertEqual(tts.kind, .tts)
        XCTAssertFalse(try XCTUnwrap(tts.voices).isEmpty, "云端音色必须来自配置，不能写死在代码里")
    }

    /// 老用户升级：新增的云端预设要自动出现，但**不能覆盖他已经填好的 Key / 模型**。
    func testMigratedUserConfigKeepsSavedSecrets() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-provider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let saved = """
        {
          "product": { "active_providers": { "asr": "remote.openai-asr" } },
          "providers": [
            { "id": "remote.openai-asr", "kind": "asr", "enabled": true, "runtime": "remoteAPI",
              "endpoint": "https://api.openai.com/v1", "api_key": "sk-saved-by-user",
              "model": "whisper-1", "candidate_models": [], "streaming": false }
          ]
        }
        """
        let fileURL = directory.appendingPathComponent("config.json")
        try Data(saved.utf8).write(to: fileURL)

        let store = ConfigStore(fileURL: fileURL)
        let configuration = await store.current
        let openai = try XCTUnwrap(configuration.providers.first { $0.id == "remote.openai-asr" })
        XCTAssertEqual(openai.apiKey, "sk-saved-by-user")
        XCTAssertEqual(openai.model, "whisper-1")
        // 新预设（Groq / SiliconFlow / 云端 TTS）应当自动补齐。
        XCTAssertTrue(configuration.providers.contains { $0.id == "remote.groq-asr" })
        XCTAssertTrue(configuration.providers.contains { $0.id == "remote.openai-tts" })
    }

    // MARK: - 装配：听用户的本地 / 云端选择

    func testResolvedProviderFollowsUserChoice() {
        let local = ProviderConfig(
            id: "local.asr", kind: .asr, enabled: false, runtime: .externalLocalRuntime,
            endpoint: "http://127.0.0.1:8858", model: "ggml-small.en"
        )
        let cloud = ProviderConfig(
            id: "remote.openai-asr", kind: .asr, enabled: true, runtime: .remoteAPI,
            endpoint: "https://api.openai.com/v1", apiKey: "sk-test", model: "whisper-1"
        )
        var product = ProductConfig()
        product.activateProvider("remote.openai-asr", for: .asr)
        let configuration = AppConfiguration(product: product, providers: [local, cloud])

        XCTAssertEqual(configuration.resolvedProvider(for: .asr)?.id, "remote.openai-asr")
        XCTAssertEqual(configuration.resolvedModel(for: .asr), "whisper-1")
        XCTAssertTrue(configuration.resolvedProvider(for: .asr)?.isRemote == true)
    }

    func testCloudProviderRequiresAPIKey() throws {
        let config = ProviderConfig(
            id: "remote.openai-asr", kind: .asr, enabled: true, runtime: .remoteAPI,
            endpoint: "https://api.openai.com/v1", model: "whisper-1"
        )
        XCTAssertTrue(config.requiresAPIKey)
        XCTAssertThrowsError(try RemoteCommon.resolve(config)) { error in
            guard case AIProviderError.invalidConfiguration = error else {
                return XCTFail("应当是配置错误：\(error)")
            }
        }
    }

    func testWhitelistOfMultipartBodyIsWellFormed() {
        let field = RemoteCommon.multipartField(name: "model", value: "whisper-1", boundary: "B")
        XCTAssertTrue(String(data: field, encoding: .utf8)?.contains("name=\"model\"") == true)
        let file = RemoteCommon.multipartFileField(
            name: "file", filename: "speech.wav", mimeType: "audio/wav",
            data: Data([0x52, 0x49]), boundary: "B"
        )
        XCTAssertTrue(String(data: file, encoding: .utf8)?.contains("filename=\"speech.wav\"") == true)
    }
}
