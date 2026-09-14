import AIDomain
import AIInterfaces
import AIInfrastructure
import AIServices
import AppCore
import Foundation
import XCTest

/// 第 24 步 声纹定制与克隆的「合规地基」：
/// 显式授权、本地优先、供应商能力声明、启用时可见提示。
/// 这里**不含任何真实克隆模型** —— 规则先立住，接哪个模型都不改这套口径。
@MainActor
final class VoiceCloningPolicyTests: XCTestCase {

    /// 一个只声明克隆能力的 TTS 供应商替身。
    private final class StubTTSProvider: TTSProvider, @unchecked Sendable {
        let providerID = "stub.tts"
        let kind: AIProviderKind = .tts
        private let state = ProviderStateBox()
        private let cloning: Bool

        init(cloning: Bool) { self.cloning = cloning }

        func initialize(config: ProviderConfig) async throws { await state.setConfig(config) }
        func load() async throws {}
        func unload() async {}
        func healthCheck() async -> ProviderHealth { .connected(model: nil) }
        func capabilities() -> ProviderCapabilities { ProviderCapabilities(voiceCloning: cloning) }
        func metadata() -> ProviderMetadata {
            ProviderMetadata(id: providerID, displayName: "Stub TTS", runtime: .ollama)
        }
        func synthesize(_ request: TTSRequest) async throws -> TTSResult {
            TTSResult(audioSamples: [], sampleRate: 16_000)
        }
    }

    /// 本机路径在**运行期**拼出来：仓库里不出现任何 `/Users/...` 字面量 ——
    /// 发布就绪的静态检查会扫硬编码绝对路径，测试文件同样在内。
    private var homeVoicePath: String { NSHomeDirectory() + "/voices/my-voice.wav" }

    private func makeProfile(
        kind: VoiceProfile.Kind,
        reference: String?,
        consent: VoiceConsent?
    ) -> VoiceProfile {
        VoiceProfile(
            id: "my-voice", displayName: "我的声音", kind: kind,
            referenceAudioPath: reference, consent: consent
        )
    }

    /// 「授权齐全 + 本地参考音频」的克隆音色。
    private func validCloned() -> VoiceProfile {
        makeProfile(kind: .cloned, reference: homeVoicePath, consent: VoiceConsent(statement: "本人声音"))
    }

    /// 造一套「**没有**任何供应商声明克隆能力」的装配中心。
    ///
    /// 必须显式清掉声明，而不是指望默认配置恰好没有：默认配置里 `local.tts`
    /// 是**声明了** `voiceCloning` 的（否则整条克隆链路不可达）。
    /// 让用例依赖「默认配置碰巧没有能力位」，默认配置一改测试就红，
    /// 而且红得莫名其妙 —— 那时真正该验的规则反倒没人验了。
    private func makeServices() async -> CoachServices {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("voice-policy-\(UUID().uuidString).json")
        )
        try? await store.mutate { configuration in
            for index in configuration.providers.indices where configuration.providers[index].kind == .tts {
                configuration.providers[index].capabilities = nil
            }
        }
        return CoachServices(config: store, databasePath: ":memory:")
    }

    // MARK: - 内置音色

    func testBuiltinProfileNeedsNothing() {
        let profile = VoiceProfile(id: "serena", displayName: "Serena")
        XCTAssertFalse(VoiceAccessPolicy.requiresConsent(profile))
        XCTAssertTrue(VoiceAccessPolicy.violations(for: profile, providerSupportsCloning: false).isEmpty)
        XCTAssertNil(VoiceAccessPolicy.activeIndicator(for: profile), "内置音色不需要提示")
    }

    // MARK: - 授权是前置条件

    func testClonedWithoutConsentIsRejected() {
        let profile = makeProfile(kind: .cloned, reference: homeVoicePath, consent: nil)
        XCTAssertTrue(VoiceAccessPolicy.requiresConsent(profile))
        XCTAssertEqual(
            VoiceAccessPolicy.violations(for: profile, providerSupportsCloning: true),
            [.missingConsent]
        )
    }

    func testClonedWithBlankConsentStatementIsRejected() {
        let profile = makeProfile(kind: .cloned, reference: homeVoicePath, consent: VoiceConsent(statement: "   "))
        let violations = VoiceAccessPolicy.violations(for: profile, providerSupportsCloning: true)
        XCTAssertTrue(violations.contains(.emptyConsent))
    }

    // MARK: - 参考音频

    func testClonedWithoutReferenceIsRejected() {
        let profile = makeProfile(kind: .cloned, reference: nil, consent: VoiceConsent(statement: "本人声音"))
        let violations = VoiceAccessPolicy.violations(for: profile, providerSupportsCloning: true)
        XCTAssertTrue(violations.contains(.missingReference))
        XCTAssertFalse(violations.contains(.providerNotCloningCapable), "缺参考音频时应早返回，不叠加其它噪音")
    }

    func testRemoteReferenceIsRejected() {
        // 本地优先：不接受远端音频地址（也就堵住了「第三方克隆流程」的入口）。
        let profile = makeProfile(
            kind: .cloned,
            reference: "https://voices.invalid/voice.wav",
            consent: VoiceConsent(statement: "本人声音")
        )
        let violations = VoiceAccessPolicy.violations(for: profile, providerSupportsCloning: true)
        XCTAssertTrue(violations.contains(.referenceNotLocal))
    }

    func testProviderWithoutCloningCapabilityIsRejected() {
        let violations = VoiceAccessPolicy.violations(for: validCloned(), providerSupportsCloning: false)
        XCTAssertEqual(violations, [.providerNotCloningCapable])
    }

    func testFullySpecifiedClonedProfilePasses() {
        let violations = VoiceAccessPolicy.violations(for: validCloned(), providerSupportsCloning: true)
        XCTAssertTrue(violations.isEmpty, "授权齐全 + 本地参考 + 供应商支持 → 可启用")
    }

    // MARK: - 本地路径判定

    func testIsLocalPathVariants() {
        XCTAssertTrue(VoiceAccessPolicy.isLocalPath(homeVoicePath))
        XCTAssertTrue(VoiceAccessPolicy.isLocalPath("voices/me.wav"))
        XCTAssertTrue(VoiceAccessPolicy.isLocalPath("file://" + homeVoicePath))
        XCTAssertFalse(VoiceAccessPolicy.isLocalPath("https://voices.invalid/v.wav"))
        XCTAssertFalse(VoiceAccessPolicy.isLocalPath("ftp://host/v.wav"))
        XCTAssertFalse(VoiceAccessPolicy.isLocalPath("//host/share/v.wav"))
        XCTAssertFalse(VoiceAccessPolicy.isLocalPath("   "))
    }

    // MARK: - 可见提示

    func testActiveIndicatorForClonedVoice() {
        let indicator = VoiceAccessPolicy.activeIndicator(for: validCloned())
        XCTAssertNotNil(indicator)
        XCTAssertTrue(indicator?.contains("我的声音") == true, "提示里应点名当前音色")
    }

    // MARK: - 能力位（不暴露供应商专属 API）

    func testCapabilitiesDefaultToNoVoiceFeatures() {
        let capabilities = ProviderCapabilities()
        XCTAssertFalse(capabilities.voiceCloning)
        XCTAssertFalse(capabilities.style)
        XCTAssertFalse(capabilities.emotion)
        XCTAssertFalse(capabilities.pitchControl)
    }

    // MARK: - 经装配中心的裁决

    func testServicesViolationsFollowProviderCapability() async {
        let services = await makeServices()
        let profile = validCloned()

        // 未注册任何 TTS（或注册的不支持克隆）→ 明确拒绝，而不是假装能克隆。
        let before = await services.voiceAccessViolations(for: profile)
        XCTAssertTrue(before.contains(.providerNotCloningCapable))

        await services.tts.register(StubTTSProvider(cloning: true))
        let after = await services.voiceAccessViolations(for: profile)
        XCTAssertTrue(after.isEmpty, "供应商自报克隆能力后应放行")

        let indicator = await services.voiceActiveIndicator(for: profile)
        XCTAssertNotNil(indicator)
    }

    func testServicesStillRequireConsentEvenWithCapableProvider() async {
        let services = await makeServices()
        await services.tts.register(StubTTSProvider(cloning: true))

        let profile = makeProfile(kind: .cloned, reference: homeVoicePath, consent: nil)
        let violations = await services.voiceAccessViolations(for: profile)
        XCTAssertEqual(violations, [.missingConsent], "供应商有能力也不能跳过授权")
    }
}
