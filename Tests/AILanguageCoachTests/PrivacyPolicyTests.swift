import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import XCTest

/// 隐私策略测试（Phase 29）。
///
/// 这里守的不是「功能对不对」，而是三条**会伤害用户**的底线：
/// ① 默认不能偷偷外发；② 一旦外发必须说得清清楚楚；③ 日志里不许出现内容本身。
final class PrivacyPolicyTests: XCTestCase {

    // MARK: - 默认本地优先

    func testBuiltInDefaultConfigurationSendsNothing() throws {
        let configuration = try DefaultConfiguration.load()
        let disclosure = PrivacyPolicy.disclosure(for: configuration)
        XCTAssertTrue(disclosure.isLocalOnly)
        XCTAssertFalse(disclosure.requiresDisclosure)
        XCTAssertTrue(disclosure.flows.isEmpty)
    }

    /// 所有数据类别的默认存储都是「仅本地」——没有哪个类别天生就该上云。
    func testEveryCategoryDefaultsToLocalOnly() {
        for category in PrivacyPolicy.DataCategory.allCases {
            XCTAssertEqual(category.defaultStorage, .localOnly, "\(category.rawValue) 不该默认外发")
        }
    }

    // MARK: - 外发披露

    func testEnablingRemoteASRIsDisclosedWithWhatLeavesTheDevice() throws {
        var configuration = try DefaultConfiguration.load()
        guard let index = configuration.providers.firstIndex(where: {
            $0.runtime == .remoteAPI && $0.kind == .asr
        }) else {
            throw XCTSkip("默认配置里没有云端 ASR 供应商")
        }
        configuration.providers[index].enabled = true
        // 填上 Key：没 Key 的云端供应商根本不会被调用（会自动回退本地），
        // 那种状态不该算作「正在外发」。
        configuration.providers[index].apiKey = "test-key-not-real"
        configuration.product.activateProvider(configuration.providers[index].id, for: .asr)

        let disclosure = PrivacyPolicy.disclosure(for: configuration)
        XCTAssertFalse(disclosure.isLocalOnly)
        XCTAssertTrue(disclosure.requiresDisclosure)

        let flow = try XCTUnwrap(disclosure.flows.first { $0.kind == .asr })
        // 语音识别会把**录音本身**发出去，这一条必须让用户看见。
        XCTAssertTrue(flow.categories.contains(.audio))
        XCTAssertFalse(flow.host.isEmpty)
        XCTAssertFalse(flow.displayName.isEmpty)
        XCTAssertTrue(disclosure.summary.contains("云端"))
    }

    func testOnlyCurrentlyEffectiveProvidersAreDisclosed() throws {
        var configuration = try DefaultConfiguration.load()
        guard let index = configuration.providers.firstIndex(where: {
            $0.runtime == .remoteAPI && $0.kind == .llm
        }) else {
            throw XCTSkip("默认配置里没有云端 LLM 供应商")
        }
        // 配好了 Key、也启用了，但**生效位仍是本地模型** → 不该被算作外发。
        // 否则用户会看到「正在上传」，实际上一次请求都没发——那是谎报。
        configuration.providers[index].enabled = true
        configuration.providers[index].apiKey = "test-key-not-real"
        XCTAssertTrue(PrivacyPolicy.disclosure(for: configuration).isLocalOnly)

        // 真正切过去之后，才需要披露。
        configuration.product.activateProvider(configuration.providers[index].id, for: .llm)
        XCTAssertFalse(PrivacyPolicy.disclosure(for: configuration).isLocalOnly)
    }

    /// 开在本机回环上的「云端」Provider 不算外发——数据没离开这台机器。
    ///
    /// 这条守的是出厂默认：Edge-TTS 代理（`http://127.0.0.1:8856`）默认启用，
    /// 若按 runtime 标签一刀切成外发，默认配置就会「自带一条云端披露」，
    /// 既吓用户，也会把发布闸门 `privacy.noUnintendedNetwork` 判红。
    func testLoopbackProxyProviderIsNotDisclosedAsOutbound() throws {
        var configuration = try DefaultConfiguration.load()
        guard let index = configuration.providers.firstIndex(where: {
            $0.kind == .tts && $0.runtime == .remoteAPI
                && PrivacyRedactor.isLoopbackEndpoint($0.endpoint)
        }) else {
            throw XCTSkip("默认配置里没有开在回环上的云端 TTS")
        }
        configuration.providers[index].enabled = true
        configuration.providers[index].apiKeyRequired = false
        configuration.product.activateProvider(configuration.providers[index].id, for: .tts)
        // 先确认选的确实是那一条（否则这条断言测的是本地回退，等于没测）。
        XCTAssertEqual(configuration.resolvedProvider(for: .tts)?.id, configuration.providers[index].id)

        let disclosure = PrivacyPolicy.disclosure(for: configuration)
        XCTAssertTrue(disclosure.isLocalOnly, "回环端点上的本机代理不该被算成云端外发")
        XCTAssertFalse(disclosure.flows.contains { $0.kind == .tts })
    }

    /// 反证：同一家 Provider 若把端点换到公网主机，**必须**被披露。
    ///
    /// 没有这一条，上面那条「回环不外发」的测试撤掉修复也不会变红——
    /// 分不清「判对了」和「压根没判」。
    func testSameProviderOnPublicHostIsStillDisclosed() throws {
        var configuration = try DefaultConfiguration.load()
        guard let index = configuration.providers.firstIndex(where: {
            $0.kind == .tts && $0.runtime == .remoteAPI
                && PrivacyRedactor.isLoopbackEndpoint($0.endpoint)
        }) else {
            throw XCTSkip("默认配置里没有开在回环上的云端 TTS")
        }
        configuration.providers[index].enabled = true
        configuration.providers[index].apiKeyRequired = false
        configuration.providers[index].endpoint = "https://tts.example.com"
        configuration.product.activateProvider(configuration.providers[index].id, for: .tts)

        let disclosure = PrivacyPolicy.disclosure(for: configuration)
        XCTAssertFalse(disclosure.isLocalOnly, "换到公网端点后必须披露")
        let flow = try XCTUnwrap(disclosure.flows.first { $0.kind == .tts })
        XCTAssertEqual(flow.host, "tts.example.com")
        XCTAssertEqual(flow.categories, [.speechText])
    }

    func testOutboundCategoriesPerKind() {
        XCTAssertTrue(PrivacyPolicy.outboundCategories(for: .asr).contains(.audio))
        XCTAssertEqual(PrivacyPolicy.outboundCategories(for: .tts), [.speechText])
        XCTAssertEqual(PrivacyPolicy.outboundCategories(for: .llm), [.conversation])
        // 这些能力当前没有 runtime 外发（VAD / 评测走本地）。
        XCTAssertTrue(PrivacyPolicy.outboundCategories(for: .vad).isEmpty)
        XCTAssertTrue(PrivacyPolicy.outboundCategories(for: .pronunciation).isEmpty)
    }

    // MARK: - 脱敏

    func testRedactorNeverRevealsContent() {
        let sentence = "I has went to the store yesterday"
        let redacted = PrivacyRedactor.text(sentence)
        XCTAssertFalse(redacted.contains("yesterday"))
        XCTAssertTrue(redacted.contains("\(sentence.count)"))
        XCTAssertEqual(PrivacyRedactor.text(nil), "文本（空）")

        let audio = Data(repeating: 7, count: 4_096)
        let audioSummary = PrivacyRedactor.binary(audio)
        XCTAssertTrue(audioSummary.hasPrefix("音频"))
        XCTAssertFalse(audioSummary.contains("7"))

        XCTAssertEqual(PrivacyRedactor.audio(samples: 24_000, sampleRate: 16_000).contains("1.50s"), true)
    }

    func testRedactorKeepsHostButDropsPathAndHidesSecrets() {
        XCTAssertEqual(PrivacyRedactor.host(of: "https://api.example.com/v1/chat/completions"), "api.example.com")
        XCTAssertEqual(PrivacyRedactor.host(of: "http://127.0.0.1:11434"), "127.0.0.1")
        XCTAssertEqual(PrivacyRedactor.host(of: nil), "未知主机")
        XCTAssertEqual(PrivacyRedactor.host(of: "not a url"), "未知主机")

        let secret = PrivacyRedactor.secret("sk-abcdefghijklmnopqrstuv")
        XCTAssertFalse(secret.contains("sk-"))
        XCTAssertFalse(secret.contains("abcdef"))
        XCTAssertEqual(PrivacyRedactor.secret(nil), "未设置")
        XCTAssertEqual(PrivacyRedactor.secret(""), "未设置")
    }

    /// 回环识别：尺子是「数据出不出机器」，划错一边就会误报或漏报。
    func testLoopbackHostRecognition() {
        for host in ["127.0.0.1", "127.1.2.3", "127.255.255.254",
                     "localhost", "LocalHost", "api.localhost",
                     "::1", "0:0:0:0:0:0:0:1", "0.0.0.0"] {
            XCTAssertTrue(PrivacyRedactor.isLoopback(host: host), "\(host) 应判为本机回环")
        }
        // 内网 / 局域网名**不算**本机：那些数据确实离开了这台机器。
        for host in ["api.example.com", "192.168.1.10", "10.0.0.5", "172.16.0.9",
                     "example.local", "127", "127.0.0", "127.0.0.300", "1270.0.0.1", ""] {
            XCTAssertFalse(PrivacyRedactor.isLoopback(host: host), "\(host) 不该判为本机回环")
        }

        XCTAssertTrue(PrivacyRedactor.isLoopbackEndpoint("http://127.0.0.1:8856"))
        XCTAssertTrue(PrivacyRedactor.isLoopbackEndpoint("http://[::1]:11434"))
        XCTAssertFalse(PrivacyRedactor.isLoopbackEndpoint("https://api.deepseek.com"))
        // 解析不出来时按「可能外发」处理——未知不替用户打包票。
        XCTAssertFalse(PrivacyRedactor.isLoopbackEndpoint(nil))
        XCTAssertFalse(PrivacyRedactor.isLoopbackEndpoint("not a url"))
    }

    // MARK: - 数据位置

    func testLocalStorageLocationsAreDocumented() {
        let locations = PrivacyDataLocator.locations()
        XCTAssertFalse(locations.isEmpty)
        XCTAssertTrue(locations.contains { $0.title == "学习记忆" })
        XCTAssertTrue(locations.contains { $0.title == "应用配置" })
        // 运行日志必须明确说明「不落盘」——这是承诺，不是实现细节。
        XCTAssertTrue(locations.contains { $0.path == "（不落盘）" })
        XCTAssertFalse(PrivacyDataLocator.dataDirectory().isEmpty)
    }

    // MARK: - 服务层装配

    func testPrivacyReportMatchesConfiguration() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("alc-privacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let services = CoachServices(
            config: ConfigStore(fileURL: directory.appendingPathComponent("config.json")),
            databasePath: ":memory:"
        )
        let report = await services.privacyReport()
        XCTAssertTrue(report.disclosure.isLocalOnly, "全新配置应当是纯本地的")
        XCTAssertFalse(report.locations.isEmpty)
        XCTAssertFalse(report.dataDirectory.isEmpty)
    }
}
