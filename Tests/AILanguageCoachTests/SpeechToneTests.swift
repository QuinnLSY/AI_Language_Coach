import AIInterfaces
import AppCore
import XCTest

/// ② 朗读调门 / 语气：领域与配置层的纯函数。
///
/// 这一批的两个「旋钮」各走一条路：
/// - **调门**（`SpeechPitch`）走播放侧，与供应商能力无关；
/// - **语气**（`SpeechTone`）走合成侧，必须同时满足「用户给了值 + 供应商声明了 + 协议载得动」。
final class SpeechToneTests: XCTestCase {

    // MARK: - 调门档位

    func testPitchLadderIsSymmetricAroundNatural() {
        XCTAssertEqual(SpeechPitch.allCases.count, 5)
        XCTAssertEqual(SpeechPitch.natural.rawValue, 0)
        XCTAssertEqual(SpeechPitch.allCases.map(\.rawValue), [-2, -1, 0, 1, 2])
    }

    /// 半音 → 音分：`AVAudioUnitTimePitch.pitch` 的单位是音分（1 个半音 = 100 音分）。
    ///
    /// 换算写错不会报任何错：少 ×100 的症状是「调了一档听不出差别」，
    /// 多 ×100 则是「调一档就变成卡通角色」—— 两种都只能靠耳朵发现。
    func testPitchCentsConversion() {
        XCTAssertEqual(SpeechPitch.natural.cents, 0)
        XCTAssertEqual(SpeechPitch.lower1.cents, -100)
        XCTAssertEqual(SpeechPitch.lower2.cents, -200)
        XCTAssertEqual(SpeechPitch.higher1.cents, 100)
        XCTAssertEqual(SpeechPitch.higher2.cents, 200)
    }

    func testPitchLabelsAreDistinct() {
        let labels = SpeechPitch.allCases.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count, "档位文案不能重复")
        XCTAssertEqual(SpeechPitch.natural.label, "原声")
        XCTAssertTrue(SpeechPitch.allCases.allSatisfy { !$0.detail.isEmpty })
    }

    /// 配置文件被手改（`speechPitch: 3.7` / `-99`）时自愈到最近档，而不是照发越界音分。
    func testPitchNearestSelfHeals() {
        XCTAssertEqual(SpeechPitch.nearest(to: 3.7), .higher2)
        XCTAssertEqual(SpeechPitch.nearest(to: -99), .lower2)
        XCTAssertEqual(SpeechPitch.nearest(to: 0.4), .natural)
        XCTAssertEqual(SpeechPitch.nearest(to: 1.6), .higher2)
    }

    // MARK: - 语气取值归一

    func testToneTreatsBlankAsUnspecified() {
        XCTAssertTrue(SpeechTone(style: "", emotion: "   ").isEmpty)
        XCTAssertTrue(SpeechTone(style: nil, emotion: nil).isEmpty)
        XCTAssertTrue(SpeechTone.none.isEmpty)
    }

    /// 空串按「没指定」算：配置里清空输入框会留下空串，
    /// 照发就是一个空值参数（有的网关 400、有的静默走默认），两种都不该由「清了个输入框」触发。
    func testToneTrimsSurroundingWhitespace() {
        let tone = SpeechTone(style: "  cheerful\n", emotion: " calm ")
        XCTAssertEqual(tone.style, "cheerful")
        XCTAssertEqual(tone.emotion, "calm")
        XCTAssertFalse(tone.isEmpty)
    }

    func testToneAllowsPartialSpecification() {
        let onlyStyle = SpeechTone(style: "cheerful")
        XCTAssertFalse(onlyStyle.isEmpty)
        XCTAssertNil(onlyStyle.emotion)
    }

    // MARK: - 请求形态天花板

    /// 严格 OpenAI 协议**结构上**没有语气字段位。
    ///
    /// 反证：把这条改成 `[.style, .emotion]` 会让云端请求带上 `style` ——
    /// 真实 OpenAI 会以 `Unrecognized request argument` 400 拒掉，
    /// 而错误信息看起来像模型名或密钥的问题，排查方向被彻底带偏。
    func testStrictProtocolCarriesNoToneCapabilities() {
        XCTAssertTrue(SpeechRequestStyle.openAISpeech.supportedVoiceCapabilities.isEmpty)
    }

    func testGatewayShapesCarryStyleAndEmotion() {
        for style in [SpeechRequestStyle.textJSON, .textQuery] {
            XCTAssertEqual(style.supportedVoiceCapabilities, [.style, .emotion])
        }
    }

    // MARK: - 三层与：供应商配置

    private func ttsProvider(
        _ style: SpeechRequestStyle,
        capabilities: [String]?,
        styleField: String? = nil,
        styleOptions: [String]? = nil,
        emotionOptions: [String]? = nil
    ) -> ProviderConfig {
        ProviderConfig(
            id: "p.tts",
            kind: .tts,
            runtime: .remoteAPI,
            endpoint: "https://example.invalid/v1",
            speechRequestStyle: style,
            capabilities: capabilities,
            speechStyleField: styleField,
            speechStyleOptions: styleOptions,
            speechEmotionOptions: emotionOptions
        )
    }

    func testToneCapabilitiesRequireBothDeclarationAndShape() {
        // 声明了但形态载不动 → 不算支持（否则必然发出一个会被拒的参数）。
        let strict = ttsProvider(.openAISpeech, capabilities: ["style", "emotion"])
        XCTAssertTrue(strict.supportedToneCapabilities().isEmpty)

        // 形态载得动但没声明 → 供应商没开这个口子。
        let undeclared = ttsProvider(.textJSON, capabilities: nil)
        XCTAssertTrue(undeclared.supportedToneCapabilities().isEmpty)

        // 两样都齐才算有。
        let ok = ttsProvider(.textJSON, capabilities: ["style", "emotion"])
        XCTAssertEqual(ok.supportedToneCapabilities(), [.style, .emotion])
    }

    /// 音高由播放侧实现，与供应商能力无关 —— 它**不该**混进语气能力里。
    func testPitchIsNotPartOfToneCapabilities() {
        let provider = ttsProvider(.textJSON, capabilities: ["style", "emotion", "pitchControl"])
        XCTAssertFalse(provider.supportedToneCapabilities().contains(.pitchControl))
        XCTAssertFalse(provider.supportedToneCapabilities().contains(.voiceCloning))
    }

    func testStyleFieldNameDefaultsToGenericKeyword() {
        let plain = ttsProvider(.textJSON, capabilities: ["style"])
        XCTAssertEqual(plain.resolvedSpeechStyleField, "style")
        XCTAssertEqual(plain.resolvedSpeechEmotionField, "emotion")

        let custom = ttsProvider(.textJSON, capabilities: ["style"], styleField: "prosodyStyle")
        XCTAssertEqual(custom.resolvedSpeechStyleField, "prosodyStyle")
    }

    /// 配置里把键名清空（留空串）要回落通用名，而不是发一个空键。
    func testBlankStyleFieldFallsBackToGenericKeyword() {
        let provider = ttsProvider(.textJSON, capabilities: ["style"], styleField: "   ")
        XCTAssertEqual(provider.resolvedSpeechStyleField, "style")
    }

    func testToneOptionsAreGatedByCapability() {
        let declared = ttsProvider(
            .textJSON,
            capabilities: ["style"],
            styleOptions: ["cheerful", " ", "sad"]
        )
        XCTAssertEqual(declared.toneOptions(for: .style), ["cheerful", "sad"], "空白候选值要去掉")
        XCTAssertTrue(declared.toneOptions(for: .emotion).isEmpty, "没声明的能力不该有候选值")

        let strict = ttsProvider(.openAISpeech, capabilities: ["style"], styleOptions: ["cheerful"])
        XCTAssertTrue(strict.toneOptions(for: .style).isEmpty, "形态载不动 → 连候选值都不该给")
    }

    // MARK: - 要写进请求体的字段

    func testToneFieldsCarryConfiguredKeyNames() {
        let provider = ttsProvider(
            .textJSON,
            capabilities: ["style", "emotion"],
            styleField: "prosodyStyle"
        )
        let fields = provider.toneFields(for: SpeechTone(style: "cheerful", emotion: "calm"))
        XCTAssertEqual(fields, [
            SpeechToneField(key: "prosodyStyle", value: "cheerful"),
            SpeechToneField(key: "emotion", value: "calm"),
        ])
    }

    func testToneFieldsAreEmptyWhenUserPickedNothing() {
        let both = ttsProvider(.textJSON, capabilities: ["style", "emotion"])
        XCTAssertTrue(both.toneFields(for: .none).isEmpty)
        XCTAssertTrue(both.toneFields(for: SpeechTone(style: "  ")).isEmpty, "空白取值等于没选")
    }

    /// 只支持风格时，用户选的情感**不该**被偷偷发出去。
    func testToneFieldsDropTheHalfTheProviderCannotDo() {
        let onlyStyle = ttsProvider(.textJSON, capabilities: ["style"])
        XCTAssertEqual(
            onlyStyle.toneFields(for: SpeechTone(style: "cheerful", emotion: "calm")),
            [SpeechToneField(key: "style", value: "cheerful")]
        )
    }

    // MARK: - 请求对象

    func testTTSRequestDefaultsToNoTone() {
        let request = TTSRequest(text: "hi")
        XCTAssertTrue(request.tone.isEmpty)
        XCTAssertFalse(request.usesTone)
        XCTAssertFalse(request.usesClonedVoice)
    }

    func testTTSRequestConvenienceInitCarriesToneAlongsideVoice() {
        let voice = SpeechVoiceSelection.builtin("serena")
        let request = TTSRequest(
            text: "hi",
            voice: voice,
            language: "English",
            tone: SpeechTone(style: "cheerful")
        )
        XCTAssertEqual(request.voice, "serena")
        XCTAssertEqual(request.language, "English")
        XCTAssertTrue(request.usesTone)
        XCTAssertEqual(request.tone.style, "cheerful")
    }
}
