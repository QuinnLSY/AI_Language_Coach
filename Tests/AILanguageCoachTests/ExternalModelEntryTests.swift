import AIDomain
@testable import AIInfrastructure
import AppCore
import XCTest

/// 统一「外部模型」入口（需求 1）：厂商归类 / 端点拼接 / 默认配置里的厂商预设是否自洽。
///
/// 这一组防的是两类**看不见**的事故：
/// ① 图像 / 视频模型混进「AI 大脑」的模型下拉里（选中后对话必然失败，报错也看不出原因）；
/// ② 默认配置里新增一个厂商预设时漏了非可选键 —— 解码整体失败、**整份配置回退成内置默认**，
///    用户会以为「我刚改的设置全没了」。
final class ExternalModelEntryTests: XCTestCase {

    // MARK: - 按能力归类

    func testAgnesChatModelsClassifyAsLLM() {
        XCTAssertEqual(RemoteModelFilter.classify("agnes-2.0-flash"), .llm)
        XCTAssertEqual(RemoteModelFilter.classify("agnes-2.5-flash"), .llm)
        XCTAssertEqual(RemoteModelFilter.classify("agnes-2.5-pro-alpha"), .llm)
    }

    /// ⚠️ 同一家厂商的文字模型与生成模型共用前缀（`agnes-*`），
    /// 所以只靠「正向加分」会把图像 / 视频模型也算成语言模型。
    func testAgnesGenerativeModelsAreExcludedFromChatList() {
        for id in ["agnes-image-2.1-flash", "agnes-image-2.0-flash", "agnes-video-v2.0"] {
            XCTAssertTrue(RemoteModelFilter.isGenerative(id), "\(id) 应当被识别为生成类模型")
            XCTAssertFalse(
                RemoteModelFilter.filterIDs([id, "agnes-2.0-flash"], for: .llm).contains(id),
                "\(id) 不该出现在对话模型列表里 —— 选中它对话必然失败"
            )
        }
    }

    func testFilterKeepsModelsWhenNothingMatches() {
        // 铁律：筛不出来就别筛。规则不认识的模型不能被悄悄挡掉。
        let unknown = ["mystery-model-x", "vendor-thing-7"]
        XCTAssertEqual(RemoteModelFilter.filterIDs(unknown, for: .llm), unknown)
        XCTAssertEqual(RemoteModelFilter.filterIDs(unknown, for: .asr), unknown)
    }

    func testFilterDoesNotEmptyTheListWhenAllLookGenerative() {
        // 万一某家把前缀全用在生成模型上，宁可原样返回，也不要给用户一个空下拉。
        let allGenerative = ["vendor-image-v1", "vendor-video-v2"]
        XCTAssertEqual(RemoteModelFilter.filterIDs(allGenerative, for: .llm), allGenerative)
    }

    func testSpeechModelsStillClassifyForTheirOwnKind() {
        XCTAssertEqual(RemoteModelFilter.classify("whisper-large-v3"), .asr)
        XCTAssertEqual(RemoteModelFilter.classify("tts-1"), .tts)
        XCTAssertEqual(RemoteModelFilter.classify("bge-m3"), .embedding)
        // `tts` 同时命中 tts 与 generativeMarkers —— 归类仍须落在 .tts（否则 TTS 区块会空）。
        XCTAssertFalse(
            RemoteModelFilter.filterIDs(["tts-1"], for: .tts).isEmpty
        )
    }

    // MARK: - 端点拼接（端点自带版本前缀时不能拼出 /v1/v1）

    func testURLDeduplicatesVersionPrefix() throws {
        let base = try XCTUnwrap(RemoteEndpoint.base("https://apihub.agnes-ai.cn/v1"))
        XCTAssertEqual(
            RemoteEndpoint.url(base: base, path: "v1/models").absoluteString,
            "https://apihub.agnes-ai.cn/v1/models",
            "端点已含 /v1 时不能再拼一次 v1"
        )
    }

    func testURLKeepsPathWhenEndpointsHaveNoVersionPrefix() throws {
        let base = try XCTUnwrap(RemoteEndpoint.base("https://openrouter.ai/api"))
        XCTAssertEqual(
            RemoteEndpoint.url(base: base, path: "v1/models").absoluteString,
            "https://openrouter.ai/api/v1/models"
        )
    }

    func testURLIgnoresLeadingSlashAndTrailingSlash() throws {
        let base = try XCTUnwrap(RemoteEndpoint.base("https://example.com/v1/"))
        XCTAssertEqual(
            RemoteEndpoint.url(base: base, path: "/models").absoluteString,
            "https://example.com/v1/models",
            "结尾斜杠与路径开头的斜杠都不该拼出双斜杠"
        )
    }

    func testBaseRejectsGarbage() {
        XCTAssertNil(RemoteEndpoint.base(""))
        XCTAssertNil(RemoteEndpoint.base("not a url"))
        XCTAssertNil(RemoteEndpoint.base("127.0.0.1:8855"), "缺 scheme 不该被当成合法端点")
    }

    // MARK: - 默认配置：厂商预设必须自洽

    private func defaultConfiguration() throws -> AppConfiguration {
        try DefaultConfiguration.load()
    }

    /// 内置默认配置必须能整份解码 —— 这是「漏一个键 → 整份回退」事故的前置防线。
    func testDefaultConfigurationDecodesCompletely() throws {
        let configuration = try defaultConfiguration()
        XCTAssertFalse(configuration.providers.isEmpty)
        XCTAssertNotNil(
            configuration.resolvedProvider(for: .llm),
            "默认配置里至少要有一个可用的 LLM Provider"
        )
    }

    /// 每个预设都必须带**身份字段**。
    ///
    /// 这是「漏一个键 → 整份配置解码失败 → 整体回退成内置默认」事故的前置防线：
    /// 一旦回退，用户会以为「我刚改的设置全没了」，而日志里只有一行解码失败。
    func testEveryPresetHasMandatoryIdentityKeys() throws {
        let root = try jsonRoot()
        let providers = try XCTUnwrap(root["providers"] as? [[String: Any]])
        XCTAssertFalse(providers.isEmpty)
        for provider in providers {
            let id = (provider["id"] as? String) ?? "<无 id>"
            for key in ["id", "kind", "enabled", "runtime"] {
                XCTAssertNotNil(provider[key], "预设 \(id) 缺少必填键 \(key)")
            }
        }
    }

    /// 云端 LLM 预设必须带齐**对话必需**参数。
    ///
    /// 为什么只查这几个：`temperature` / `max_tokens` 缺失会静默落到内置默认值，
    /// 表现是「换了一家供应商，老师突然变得又长又跑题」，极难联想到是配置漏键。
    /// 而 `models_path` / `vision` 是**故意可选**的（缺省 `v1/models` / 不声明视觉），
    /// 所以不能一起要求 —— 那会把「保守默认」误判成缺陷。
    func testRemoteLLMPresetsCarryChatParameters() throws {
        let root = try jsonRoot()
        let providers = try XCTUnwrap(root["providers"] as? [[String: Any]])
        let remoteLLMs = providers.filter {
            ($0["runtime"] as? String) == "remoteAPI" && ($0["kind"] as? String) == "llm"
        }
        XCTAssertGreaterThanOrEqual(remoteLLMs.count, 3, "云端 LLM 预设数量异常，检查是否漏读了配置文件")

        for provider in remoteLLMs {
            let id = (provider["id"] as? String) ?? "<无 id>"
            for key in ["streaming", "temperature", "max_tokens", "request_timeout"] {
                XCTAssertNotNil(provider[key], "云端 LLM 预设 \(id) 缺少对话参数 \(key)")
            }
        }
    }

    /// 钉住「`models_path` / `vision` 可选」这件事本身：
    /// 不是所有厂商都声明它们，而缺省行为必须是安全的（`v1/models`、不声明视觉）。
    func testOptionalKeysAreNotDeclaredEverywhere() throws {
        let root = try jsonRoot()
        let providers = try XCTUnwrap(root["providers"] as? [[String: Any]])
        let remote = providers.filter { ($0["runtime"] as? String) == "remoteAPI" }
        let withoutModelsPath = remote.filter { $0["models_path"] == nil }
        XCTAssertFalse(
            withoutModelsPath.isEmpty,
            "若每家都写了 models_path，就该把这条注释与 resolvedModelsPath 的兜底一起复核"
        )
        for provider in withoutModelsPath {
            let id = (provider["id"] as? String) ?? "<无 id>"
            if let endpoint = provider["endpoint"] as? String {
                XCTAssertFalse(endpoint.hasSuffix("/v1"), "\(id) 端点已含 /v1 却省略 models_path，兜底会拼出 /v1/v1/models")
            }
        }
    }

    private func jsonRoot() throws -> [String: Any] {
        let url = try XCTUnwrap(
            AppResourceBundle.module.url(forResource: "Config/default-config", withExtension: "json")
        )
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
    }

    func testAgnesPresetsArePresentAndCorrectlyShaped() throws {
        let configuration = try defaultConfiguration()
        let cn = configuration.providers.first { $0.id == "remote.agnes-cn" }
        let intl = configuration.providers.first { $0.id == "remote.agnes-intl" }

        for provider in [cn, intl] {
            let provider = try XCTUnwrap(provider, "AgnesAI 预设缺失")
            XCTAssertEqual(provider.kind, .llm)
            XCTAssertEqual(provider.runtime, .remoteAPI)
            XCTAssertFalse(provider.enabled, "新预设默认不启用：绝不能替用户直接切走当前模型")
            XCTAssertNotNil(provider.endpoint)
            XCTAssertEqual(provider.resolvedModelsPath, "v1/models")
        }
        XCTAssertNotEqual(cn?.endpoint, intl?.endpoint, "国内站与国际站必须是不同端点")
    }

    /// AgnesAI **需要** API Key：它是带账号体系的服务（免费档也要注册拿 Key）。
    /// 误标成免密钥会让 UI 藏掉 Key 输入框，于是用户永远接不上。
    func testAgnesPresetsRequireAPIKey() throws {
        let configuration = try defaultConfiguration()
        for id in ["remote.agnes-cn", "remote.agnes-intl"] {
            let provider = try XCTUnwrap(configuration.providers.first { $0.id == id })
            XCTAssertTrue(provider.requiresAPIKey, "\(id) 需要 API Key，不能标成免密钥")
        }
    }

    /// AgnesAI 的旗舰文字模型支持图像理解（官方目录明确写了 vision-language），
    /// 因此声明 `vision`，附件里的图片才会被内联发出。
    func testAgnesPresetsDeclareVision() throws {
        let configuration = try defaultConfiguration()
        for id in ["remote.agnes-cn", "remote.agnes-intl"] {
            let provider = try XCTUnwrap(configuration.providers.first { $0.id == id })
            XCTAssertEqual(provider.vision, true, "\(id) 的文字模型支持读图，应声明 vision")
        }
    }

    /// 计费默认必须是**保守**的（`isBillable` 默认 true）。
    ///
    /// AgnesAI 有免费档，但也有付费档与付费模型（如 pro 线）；供应商级别无法区分具体模型，
    /// 因此不能把它标成不计费 —— 那会让付费模型的调用绕过计费护栏、并从审计里消失。
    func testAgnesPresetsStayBillableByDefault() throws {
        let configuration = try defaultConfiguration()
        for id in ["remote.agnes-cn", "remote.agnes-intl"] {
            let provider = try XCTUnwrap(configuration.providers.first { $0.id == id })
            XCTAssertTrue(provider.isBillable, "\(id) 不应被标成不计费：它有付费模型，漏计比多计危险得多")
        }
    }

    /// `billable: false` 在本项目里只与免密钥公共服务配套出现。
    func testNonBillableIsOnlyUsedForKeylessProviders() throws {
        let configuration = try defaultConfiguration()
        for provider in configuration.providers where !provider.isBillable {
            XCTAssertFalse(
                provider.requiresAPIKey,
                "\(provider.id) 标了不计费却需要 API Key —— 这条组合在本项目里不该出现"
            )
        }
    }
}
