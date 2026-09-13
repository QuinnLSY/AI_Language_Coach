import AIDomain
import AIInfrastructure
import AppCore
import Foundation
import XCTest

/// 云端音色目录 / 选音规则 / 免密钥语义（纯函数 + 配置解码，脱机可测）。
///
/// 背景：接入 `tts.kina.ink` 这类 Edge TTS 代理时发现——
/// - 音色清单不是 OpenAI 的 `/models` 形态，而是 `{"count":19,"voices":[{id,name}…]}`；
/// - 合成协议是 `{text, voice, rate}`，没有 model 概念；
/// - 无需 API Key，也不产生费用。
/// 这些差异全部由配置驱动（`speech_request_style` / `voice_list_path` / `api_key_required`），
/// 解析与选音是纯函数——这里把它们的行为钉死。
final class RemoteVoiceRulesTests: XCTestCase {

    // MARK: - 音色目录：宽容解析

    func testCatalogDecodesEdgeTTSProxyShape() {
        // kina /voices 的真实形态（id + 中文友好名）
        let json = """
        {"count":2,"voices":[
          {"id":"zh-CN-XiaoxiaoNeural","name":"晓晓（女，温柔）"},
          {"id":"en-US-AriaNeural","name":"Aria（美，女）"}
        ]}
        """
        let voices = RemoteVoiceCatalog.decode(Data(json.utf8))
        XCTAssertEqual(voices.count, 2)
        XCTAssertEqual(voices[0].id, "zh-CN-XiaoxiaoNeural")
        XCTAssertEqual(voices[0].name, "晓晓（女，温柔）")
        XCTAssertEqual(voices[1].id, "en-US-AriaNeural")
    }

    func testCatalogDecodesOpenAIModelListShape() {
        let json = """
        {"data":[{"id":"alloy","name":"Alloy"},{"id":"nova"}]}
        """
        let voices = RemoteVoiceCatalog.decode(Data(json.utf8))
        XCTAssertEqual(voices.map(\.id), ["alloy", "nova"])
        XCTAssertEqual(voices[1].name, "nova", "没有友好名时用 id 兜底")
    }

    func testCatalogDecodesPlainArraysAndMinimalShapes() {
        XCTAssertEqual(RemoteVoiceCatalog.decode(Data(#"["a","b"]"#.utf8)).map(\.id), ["a", "b"])
        XCTAssertEqual(RemoteVoiceCatalog.decode(Data(#"{"voices":["a"]}"#.utf8)).map(\.id), ["a"])
        XCTAssertEqual(RemoteVoiceCatalog.decode(Data(#"{"list":[{"short_name":"s1"}]}"#.utf8)).map(\.id), ["s1"])
    }

    func testCatalogIgnoresGarbageAndDuplicatesInsteadOfThrowing() {
        XCTAssertEqual(RemoteVoiceCatalog.decode(Data()), [])
        XCTAssertEqual(RemoteVoiceCatalog.decode(Data("not json".utf8)), [])
        XCTAssertEqual(RemoteVoiceCatalog.decode(Data(#"{"error":"boom"}"#.utf8)), [])
        // 重复 id 去重（大小写不敏感），保持服务端顺序
        let dup = RemoteVoiceCatalog.decode(Data(#"["Aria","aria","ARIA","Xiaoxiao"]"#.utf8))
        XCTAssertEqual(dup.map(\.id), ["Aria", "Xiaoxiao"])
    }

    // MARK: - 选音：按语言回退，而不是盲取第一个

    func testLanguageTagNormalization() {
        XCTAssertEqual(RemoteVoiceResolver.languageTag("en-US"), "en")
        XCTAssertEqual(RemoteVoiceResolver.languageTag("English"), "en")
        XCTAssertEqual(RemoteVoiceResolver.languageTag("zh-CN-XiaoxiaoNeural"), "zh")
        XCTAssertEqual(RemoteVoiceResolver.languageTag("zh_HK"), "zh")
        XCTAssertNil(RemoteVoiceResolver.languageTag(""), "空值不做过滤依据")
        XCTAssertNil(RemoteVoiceResolver.languageTag("Klingon"))
    }

    func testPickHonorsExplicitChoiceThenLanguageThenOrder() {
        let voices = ["zh-CN-XiaoxiaoNeural", "en-US-AriaNeural", "en-US-GuyNeural"]
        // ① 用户明确选了且在清单里 → 原样用（选了谁就读谁）
        XCTAssertEqual(
            RemoteVoiceResolver.pick(requested: "en-US-GuyNeural", language: "en-US", voices: voices),
            "en-US-GuyNeural"
        )
        // ② 请求的音色不在清单里（本地音色名）→ 按语言挑第一个
        XCTAssertEqual(
            RemoteVoiceResolver.pick(requested: "serena", language: "en-US", voices: voices),
            "en-US-AriaNeural",
            "英语朗读必须回退到英语音色（历史缺陷：盲取第一个会读成中文腔）"
        )
        // ③ 没有请求音色 → 按语言挑
        XCTAssertEqual(
            RemoteVoiceResolver.pick(requested: nil, language: "Chinese", voices: voices),
            "zh-CN-XiaoxiaoNeural"
        )
        // ④ 语言也对不上 → 清单第一个（服务端默认）
        XCTAssertEqual(
            RemoteVoiceResolver.pick(requested: nil, language: nil, voices: voices),
            "zh-CN-XiaoxiaoNeural"
        )
        // ⑤ 清单为空 → 原样返回请求（没有清单就没有可挑的依据）
        XCTAssertEqual(
            RemoteVoiceResolver.pick(requested: "whatever", language: "en", voices: []),
            "whatever"
        )
    }

    // MARK: - 免密钥语义与协议字段（配置解码）

    /// AppConfiguration 的解码器带 snake_case 转换，单独验证 ProviderConfig 一层。
    func testKeylessProviderFieldsRoundTrip() throws {
        let provider = ProviderConfig(
            id: "x", kind: .tts, runtime: .remoteAPI, endpoint: "https://example.com",
            speechPath: "tts", speechRequestStyle: .textJSON,
            voiceListPath: "voices", healthPath: "health",
            apiKeyRequired: false, billable: false
        )
        XCTAssertEqual(provider.resolvedSpeechPath, "tts")
        XCTAssertEqual(provider.resolvedSpeechRequestStyle, .textJSON)
        XCTAssertFalse(provider.requiresAPIKey)
        XCTAssertTrue(provider.isUsable, "免密钥供应商没有 Key 也必须可用")
        XCTAssertFalse(provider.isBillable)
        XCTAssertNil(provider.voiceLabel(for: "v"), "没有友好名时返回 nil，由 UI 决定怎么显示 id")
    }

    func testDefaultProviderStillRequiresKeyAndUsesOpenAIPaths() {
        let provider = ProviderConfig(id: "x", kind: .llm, runtime: .remoteAPI)
        XCTAssertTrue(provider.requiresAPIKey, "云端 OpenAI 兼容接口默认仍然要 Key")
        XCTAssertFalse(provider.isUsable)
        XCTAssertEqual(provider.resolvedSpeechPath, "v1/audio/speech")
        XCTAssertEqual(provider.resolvedSpeechRequestStyle, .openAISpeech)
        XCTAssertTrue(provider.isBillable, "默认视为计费")
    }

    /// 内置默认配置里的 kina 预设：字段齐全、免密钥、免费、19 个音色。
    func testBundledKinaPreset() throws {
        let configuration = try DefaultConfiguration.load()
        let kina = try XCTUnwrap(
            configuration.providers.first { $0.id == "remote.kina-tts" },
            "内置默认配置必须包含 remote.kina-tts 预设"
        )
        XCTAssertEqual(kina.kind, .tts)
        XCTAssertFalse(kina.enabled, "预设默认关闭，用户在设置里点接入才启用")
        XCTAssertFalse(kina.requiresAPIKey)
        XCTAssertTrue(kina.isUsable)
        XCTAssertFalse(kina.isBillable)
        XCTAssertEqual(kina.resolvedSpeechPath, "tts")
        XCTAssertEqual(kina.resolvedSpeechRequestStyle, .textJSON)
        XCTAssertEqual(kina.voiceListPath, "voices")
        XCTAssertEqual(kina.healthPath, "health")
        XCTAssertEqual(kina.voices?.count, 19, "音色清单应与 /voices 探测结果一致")
        XCTAssertTrue(kina.voices?.contains("en-US-AriaNeural") ?? false)
        XCTAssertTrue(kina.voices?.contains("zh-CN-XiaoxiaoNeural") ?? false)
        XCTAssertEqual(kina.requestTimeout, 60, "服务端建议超时 60 秒")
    }
}
