import AIInfrastructure
import AppCore
import XCTest

final class ConfigurationTests: XCTestCase {

    func testDefaultConfigurationLoadsAndResolvesLLMModel() throws {
        let configuration = try DefaultConfiguration.load()

        let provider = try XCTUnwrap(configuration.enabledProvider(for: .llm))
        XCTAssertEqual(provider.runtime, .ollama)
        XCTAssertNotNil(provider.endpoint)

        let model = try XCTUnwrap(configuration.resolvedModel(for: .llm))
        XCTAssertFalse(model.isEmpty)
    }

    func testDefaultConfigurationCoversAllSixCapabilities() throws {
        let configuration = try DefaultConfiguration.load()
        for kind in AIProviderKind.allCases {
            XCTAssertNotNil(configuration.enabledProvider(for: kind), "缺少 \(kind.rawValue) 的 provider 配置")
        }
    }

    func testProductSelectionOverridesProviderDefault() {
        var configuration = AppConfiguration()
        configuration.product.selectModel("custom-model", for: .llm)
        XCTAssertEqual(configuration.resolvedModel(for: .llm), "custom-model")
    }

    /// 回归（29 步费用事故同类隐患）：**候选清单不是「备胎」**。
    /// 没显式选定、Provider 自己也没配默认模型时，必须返回 nil ——
    /// 让云端闸门拒绝请求并提示用户去选，而不是替用户猜账号里的某个模型
    /// （`candidateModels` 是探测出来的可选清单，可能装着几十个模型）。
    func testResolvedModelNeverUsesCandidateListAsFallback() {
        var configuration = AppConfiguration()
        configuration.providers = [
            ProviderConfig(
                id: "remote.x-tts", kind: .tts, runtime: .remoteAPI,
                endpoint: "https://example.invalid/v1", apiKey: "sk-test",
                model: nil, candidateModels: ["fnlp/MOSS-TTSD-v0.5", "fishaudio/fish-speech-1.5"]
            )
        ]
        XCTAssertNil(configuration.resolvedModel(for: .tts), "候选清单里的第一个模型绝不能替用户做主")

        // 空字符串同样视为「没选」
        configuration.product.selectModel("", for: .tts)
        XCTAssertNil(configuration.resolvedModel(for: .tts))

        // 依次验证 产品层选择 > Provider 默认模型 > nil
        configuration.providers[0].model = "fishaudio/fish-speech-1.5"
        XCTAssertEqual(configuration.resolvedModel(for: .tts), "fishaudio/fish-speech-1.5")
        configuration.product.selectModel("fnlp/MOSS-TTSD-v0.5", for: .tts)
        XCTAssertEqual(configuration.resolvedModel(for: .tts), "fnlp/MOSS-TTSD-v0.5")
    }

    func testResolvedModelFallsBackToProviderDefault() {
        var configuration = AppConfiguration()
        configuration.providers = [
            ProviderConfig(id: "x.llm", kind: .llm, runtime: .ollama, model: "provider-default")
        ]
        XCTAssertEqual(configuration.resolvedModel(for: .llm), "provider-default")
    }

    func testConfigStorePersistsUserOverride() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-config-\(UUID().uuidString).json")
        let store = ConfigStore(fileURL: fileURL)
        try await store.selectModel("user-picked", for: .llm)

        let reloaded = ConfigStore(fileURL: fileURL)
        let model = await reloaded.current.resolvedModel(for: .llm)
        XCTAssertEqual(model, "user-picked")
        try? FileManager.default.removeItem(at: fileURL)
    }

    func testPromptBuilderSubstitutesPlaceholders() {
        let prompt = PromptBuilder.teacherSystemPrompt(
            learningLanguage: "en-US",
            nativeLanguage: "zh-CN",
            proficiency: "萌新",
            practiceMode: .conversation
        )
        XCTAssertFalse(prompt.contains("{learning_language}"))
        XCTAssertTrue(prompt.contains("en-US"))
        XCTAssertTrue(prompt.contains("zh-CN"))
    }

    // MARK: - 老师人格档位（配置字段）

    /// 老配置文件没有 `teacherPersona` 字段 —— 必须落回 `standard`，
    /// 也就是「加档位之前的行为」，不能因为升级就把老用户的教学口径改掉。
    func testLegacyProductConfigWithoutPersonaDefaultsToStandard() throws {
        let legacy = Data(#"{"learningLanguage":"en-US","teacherAnimal":"panda"}"#.utf8)
        let product = try JSONDecoder().decode(ProductConfig.self, from: legacy)
        XCTAssertEqual(product.teacherPersona, "standard")

        let empty = try JSONDecoder().decode(ProductConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.teacherPersona, "standard")
    }

    /// 缺字段补齐、写了就保留（`ProductConfig` 的向后兼容解码约定）。
    func testProductConfigRoundTripsPersona() throws {
        let product = ProductConfig(teacherPersona: "strict")
        let data = try JSONEncoder().encode(product)
        let decoded = try JSONDecoder().decode(ProductConfig.self, from: data)
        XCTAssertEqual(decoded.teacherPersona, "strict")
        XCTAssertEqual(decoded, product)
    }

    // MARK: - 目标档位 / 练习提醒（配置字段）

    /// 老配置没有新字段：档位落回 `advanced`（升级不改口径）、提醒默认关。
    func testLegacyProductConfigDefaultsForGoalModeAndReminder() throws {
        let legacy = Data(#"{"learningLanguage":"en-US"}"#.utf8)
        let product = try JSONDecoder().decode(ProductConfig.self, from: legacy)
        XCTAssertEqual(product.dailyGoalMode, .advanced)
        XCTAssertFalse(product.practiceReminderEnabled)
        XCTAssertEqual(product.practiceReminderHour, 20)
        XCTAssertEqual(product.practiceReminderMinute, 0)
    }

    /// 新字段 round-trip；非法时刻被夹取到合法区间。
    func testProductConfigRoundTripsGoalModeAndReminder() throws {
        let product = ProductConfig(
            dailyGoalMode: .baseline,
            practiceReminderEnabled: true,
            practiceReminderHour: 8,
            practiceReminderMinute: 30
        )
        let data = try JSONEncoder().encode(product)
        let decoded = try JSONDecoder().decode(ProductConfig.self, from: data)
        XCTAssertEqual(decoded.dailyGoalMode, .baseline)
        XCTAssertTrue(decoded.practiceReminderEnabled)
        XCTAssertEqual(decoded.practiceReminderHour, 8)
        XCTAssertEqual(decoded.practiceReminderMinute, 30)
        XCTAssertEqual(decoded, product)

        // 非法时刻在 init 就被夹取到合法区间。
        let clamped = ProductConfig(practiceReminderHour: 25, practiceReminderMinute: 99)
        XCTAssertEqual(clamped.practiceReminderHour, 23)
        XCTAssertEqual(clamped.practiceReminderMinute, 59)
    }

    // MARK: - 本地 / 云端 Provider 并存

    func testDefaultConfigurationContainsRemoteProviders() throws {
        let configuration = try DefaultConfiguration.load()
        let deepseek = try XCTUnwrap(configuration.providers.first { $0.id == "remote.deepseek" })
        let openrouter = try XCTUnwrap(configuration.providers.first { $0.id == "remote.openrouter" })
        XCTAssertEqual(deepseek.runtime, .remoteAPI)
        XCTAssertEqual(openrouter.runtime, .remoteAPI)
        // 默认不启用、不带密钥
        XCTAssertFalse(deepseek.enabled)
        XCTAssertNil(deepseek.apiKey)
        XCTAssertEqual(deepseek.userFacingName, "DeepSeek")
    }

    func testResolvedProviderPrefersActiveProductSelection() {
        var configuration = AppConfiguration()
        configuration.providers = [
            ProviderConfig(id: "local.llm", kind: .llm, enabled: true, runtime: .ollama),
            ProviderConfig(id: "remote.llm", kind: .llm, enabled: false, runtime: .remoteAPI, apiKey: "sk-test")
        ]
        // 未激活时选首个启用的
        XCTAssertEqual(configuration.resolvedProvider(for: .llm)?.id, "local.llm")
        // 激活云端后（即使 enabled=false 也能被激活逻辑选中）
        configuration.product.activateProvider("remote.llm", for: .llm)
        XCTAssertEqual(configuration.resolvedProvider(for: .llm)?.id, "remote.llm")
    }

    /// 激活了一个**没填 API Key** 的云端 Provider 时，不能让整个能力一起废掉：
    /// 应当自动回退到可用的本地模型（否则语音识别 / 对话会直接不可用）。
    func testResolvedProviderSkipsCloudWithoutAPIKey() {
        var configuration = AppConfiguration()
        configuration.providers = [
            ProviderConfig(id: "local.asr", kind: .asr, enabled: false, runtime: .externalLocalRuntime,
                           model: "ggml-small.en"),
            ProviderConfig(id: "remote.openai-asr", kind: .asr, enabled: true, runtime: .remoteAPI,
                           endpoint: "https://api.openai.com/v1", model: "whisper-1")
        ]
        configuration.product.activateProvider("remote.openai-asr", for: .asr)

        // 云端没 Key → 不算可用，回退到本地
        XCTAssertEqual(configuration.resolvedProvider(for: .asr)?.id, "local.asr")
        XCTAssertFalse(configuration.providers[1].isUsable)
        XCTAssertTrue(configuration.providers[0].isUsable)

        // 填上 Key 后立刻生效（无需重启）
        configuration.providers[1].apiKey = "sk-test"
        XCTAssertTrue(configuration.providers[1].isUsable)
        XCTAssertEqual(configuration.resolvedProvider(for: .asr)?.id, "remote.openai-asr")
    }

    func testSwitchingProviderAlignsSelectedModel() throws {
        var configuration = AppConfiguration()
        configuration.providers = [
            ProviderConfig(id: "local.llm", kind: .llm, enabled: true, runtime: .ollama, model: "qwen3:8b"),
            ProviderConfig(id: "remote.llm", kind: .llm, enabled: false, runtime: .remoteAPI, model: "deepseek-chat")
        ]
        configuration.product.selectModel("qwen3:8b", for: .llm)
        // 模拟 switchLLMProvider 的产品层对齐（激活 + 选中模型跟随 Provider 默认值）
        let target = try XCTUnwrap(configuration.providers.first { $0.id == "remote.llm" })
        configuration.product.activateProvider(target.id, for: .llm)
        configuration.product.selectModel(target.model, for: .llm)
        XCTAssertEqual(configuration.resolvedModel(for: .llm), "deepseek-chat")
    }

    func testProviderConfigCodableRoundTripsRemoteFields() throws {
        let provider = ProviderConfig(
            id: "remote.test", kind: .llm, enabled: true, runtime: .remoteAPI,
            displayName: "Test", endpoint: "https://example.com",
            apiKey: "sk-test", reasoningEffort: "high", contextLength: 65536,
            model: "test-model"
        )
        let data = try JSONEncoder().encode(provider)
        let decoded = try JSONDecoder().decode(ProviderConfig.self, from: data)
        XCTAssertEqual(decoded, provider)
    }

    func testLegacyConfigWithoutNewFieldsStillDecodes() throws {
        // 只保留旧版就有的字段（candidateModels / streaming 是必填，旧配置一直带）
        let legacy = """
        {"id":"old.llm","kind":"llm","enabled":true,"runtime":"ollama","model":"m","candidateModels":[],"streaming":true}
        """
        let provider = try JSONDecoder().decode(ProviderConfig.self, from: Data(legacy.utf8))
        XCTAssertNil(provider.apiKey)
        XCTAssertNil(provider.reasoningEffort)
        XCTAssertNil(provider.contextLength)
        XCTAssertEqual(provider.model, "m")
    }

    func testForestTogglesDefaultOnAndRoundTrip() throws {
        // 旧 product 配置缺少新开关 → 默认全开
        let legacy = """
        {"learning_language":"en-US","teacher_animal":"panda"}
        """
        let old = try JSONDecoder().decode(ProductConfig.self, from: Data(legacy.utf8))
        XCTAssertTrue(old.teacherBubbles)
        XCTAssertTrue(old.animalBubbles)
        XCTAssertTrue(old.animalActivity)

        // 关闭后编码 → 再解码，值应保留（全局记忆的基础）
        var product = ProductConfig()
        product.teacherBubbles = false
        product.animalBubbles = false
        product.animalActivity = false
        let data = try JSONEncoder().encode(product)
        let restored = try JSONDecoder().decode(ProductConfig.self, from: data)
        XCTAssertFalse(restored.teacherBubbles)
        XCTAssertFalse(restored.animalBubbles)
        XCTAssertFalse(restored.animalActivity)
    }

    func testContextWindowFromResolvedProvider() {
        var configuration = AppConfiguration()
        configuration.providers = [
            ProviderConfig(id: "remote.llm", kind: .llm, runtime: .remoteAPI, contextLength: 65536)
        ]
        configuration.product.activateProvider("remote.llm", for: .llm)
        XCTAssertEqual(configuration.contextWindow(for: .llm), 65536)
    }

    // MARK: - 自动朗读（默认开，且可持久化关掉）

    func testAutoSpeakDefaultsToOn() {
        XCTAssertTrue(ProductConfig().autoSpeak, "老师回复后自动朗读默认勾选")
    }

    func testAutoSpeakBackwardCompatibleDecode() throws {
        // 旧配置文件没有 autoSpeak 字段 → 补默认值 true（不整体作废）
        let legacy = Data(#"{"learningLanguage":"en-US","themeMode":"night"}"#.utf8)
        let decoded = try JSONDecoder().decode(ProductConfig.self, from: legacy)
        XCTAssertTrue(decoded.autoSpeak)
        XCTAssertEqual(decoded.themeMode, .night)

        // 关掉后能往返
        var config = ProductConfig()
        config.autoSpeak = false
        let data = try JSONEncoder().encode(config)
        XCTAssertFalse(try JSONDecoder().decode(ProductConfig.self, from: data).autoSpeak)
    }

    // MARK: - 轻音效（批次六 · F：默认关）

    func testSoundEffectsDefaultsOffAndRoundTrips() throws {
        // 老配置没有 soundEffects 字段 → 补默认值 false（升级不突然出声）
        let legacy = Data(#"{"learningLanguage":"en-US"}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(ProductConfig.self, from: legacy).soundEffects)

        // 打开后能往返（全局记忆的基础）
        var config = ProductConfig()
        config.soundEffects = true
        let data = try JSONEncoder().encode(config)
        XCTAssertTrue(try JSONDecoder().decode(ProductConfig.self, from: data).soundEffects)
    }

    func testForestWelcomedDefaultsOffAndRoundTrips() throws {
        // 老配置没有 forestWelcomed 字段 → 补默认值 false（0 星老用户升级后会欢迎一次，
        // 有进度的老用户由判据挡住 —— 见 AppState.markForestWelcomeIfNeeded）
        let legacy = Data(#"{"learningLanguage":"en-US"}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(ProductConfig.self, from: legacy).forestWelcomed)

        // 演过记名后能往返（欢迎只此一次的基础）
        var config = ProductConfig()
        config.forestWelcomed = true
        let data = try JSONEncoder().encode(config)
        XCTAssertTrue(try JSONDecoder().decode(ProductConfig.self, from: data).forestWelcomed)
    }

    // MARK: - 解码 / 编码 / 属性三处漂移的兜底

    /// `ProductConfig` 三处手写（属性、`init(from:)`、`encode(to:)`）任一处漏改都会红。
    ///
    /// 做法：把**每一个**字段都设成与默认值不同的值，编码再解码，要求完全相等。
    /// - 只加属性、没加进 `CodingKeys`：键根本没写出去 → 解回来是默认值 → 不等；
    /// - 加进 `CodingKeys` 却漏了 `encode`：同上；
    /// - 漏了 `init(from:)`：解回来取兜底值 → 不等。
    ///
    /// ⚠️ 取值必须落在字段自己的合法区间（时长 5...180、时刻 0...23）且语速取真实档位，
    /// 否则会被夹取 / 取最近档，测出来的不相等是测试自己的锅。
    func testProductConfigRoundTripCoversEveryField() throws {
        let original = ProductConfig(
            learningLanguage: "ja-JP",
            nativeLanguage: "en-US",
            teacherVoice: "Ryan",
            practiceMode: .shadowing,
            themeMode: .night,
            motionMode: .reduced,
            selectedModels: ["llm": "some-model"],
            teacherAnimal: "tiger",
            teacherPersona: "strict",
            studentAnimal: "penguin",
            studentCompanion: "fox",
            forestFollowsClock: true,
            forestFollowsSeason: true,
            forestFollowsWeather: true,
            forestFollowsMomentum: true,
            forestSeasonOverride: "autumn",
            forestWeatherOverride: "snow",
            soundEffects: true,
            forestWelcomed: true,
            activeProviders: ["tts": "local.tts"],
            teacherBubbles: false,
            animalBubbles: false,
            animalActivity: false,
            animalActivityFrequency: 0.25,
            voicePreview: false,
            autoSpeak: false,
            speechRate: SpeechRate.x1_5.rawValue,
            speechPitch: SpeechPitch.higher1.rawValue,
            speechStyle: "cheerful",
            speechEmotion: "calm",
            dailyGoalMinutes: 45,
            dailyGoalMode: .baseline,
            practiceReminderEnabled: true,
            practiceReminderHour: 7,
            practiceReminderMinute: 30,
            activeVoiceProfileID: "my-voice"
        )
        // 前提：这套取值确实全部偏离默认（否则测不出「漏改」）。
        XCTAssertNotEqual(original, ProductConfig(), "用例自身要保证每个字段都不是默认值")

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProductConfig.self, from: data)
        XCTAssertEqual(decoded, original, "ProductConfig 往返丢字段：检查 CodingKeys / init(from:) / encode(to:) 是否漏改")

        // 每个键都真的写出去了（空值字段除外，那条走 encodeIfPresent）。
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let expectedKeys = [
            "learningLanguage", "nativeLanguage", "teacherVoice", "practiceMode", "themeMode",
            "motionMode",
            "selectedModels", "teacherAnimal", "teacherPersona", "studentAnimal", "studentCompanion",
            "forestFollowsClock", "forestFollowsSeason", "forestFollowsWeather", "forestFollowsMomentum",
            "forestSeasonOverride", "forestWeatherOverride",
            "soundEffects", "forestWelcomed", "activeProviders",
            "teacherBubbles", "animalBubbles", "animalActivity", "animalActivityFrequency",
            "voicePreview", "autoSpeak", "speechRate", "dailyGoalMinutes", "dailyGoalMode",
            "speechPitch", "speechStyle", "speechEmotion",
            "practiceReminderEnabled", "practiceReminderHour", "practiceReminderMinute",
            "activeVoiceProfileID", "autoBackupEnabled", "autoBackupIntervalDays",
            "typeSize", "interfaceDensity",
        ]
        XCTAssertEqual(Set(json.keys), Set(expectedKeys), "写出的键与字段清单对不上")
    }

    /// 缺省值表就是默认 init：老配置缺字段时应当**恰好**拿到 `ProductConfig()` 的同名值。
    func testLegacyDecodeFallsBackToDefaultInit() throws {
        let decoded = try JSONDecoder().decode(ProductConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, ProductConfig(), "空配置应等价于默认 init（兜底值只此一份）")
    }

    /// 「跟随季节」是 2026-09-29 从「跟随时间与季节」拆出来的：**老配置没有这个字段**，
    /// 缺字段时跟随已解码的 `forestFollowsClock` —— 升级不该悄悄改变用户已经看到的样子。
    ///
    /// 反证：把解码兜底改回 `?? fallback.forestFollowsSeason`（恒 false）→ 红。
    func testLegacyConfigInheritsSeasonFromTheOldCombinedToggle() throws {
        // 老配置：只有合并开关（开着），没有 forestFollowsSeason 键。
        let legacy = Data(#"{"learningLanguage":"en-US","forestFollowsClock":true}"#.utf8)
        let decoded = try JSONDecoder().decode(ProductConfig.self, from: legacy)
        XCTAssertTrue(decoded.forestFollowsSeason,
                      "老用户合并开关开着 → 升级后季节跟随要延续，不许悄悄关掉")

        // 显式写过新键的以新键为准（不跟随时间也可以单独开季节）。
        let explicit = Data(#"{"forestFollowsClock":false,"forestFollowsSeason":true}"#.utf8)
        let explicitDecoded = try JSONDecoder().decode(ProductConfig.self, from: explicit)
        XCTAssertFalse(explicitDecoded.forestFollowsClock)
        XCTAssertTrue(explicitDecoded.forestFollowsSeason)
    }

    /// 季节 / 天气**手动档**是 2026-10 新增的：老配置没有这两个键 → nil（没选过）。
    /// 升级不替用户挑一季 / 挑一种天气 —— 偏好只能用户自己给。
    ///
    /// 反证：把 `init(from:)` 里的兜底改成非 nil 默认值（如恒 `"spring"`）→ 红。
    func testLegacyConfigHasNoManualSeasonOrWeatherOverride() throws {
        let legacy = Data(#"{"forestFollowsClock":true,"forestFollowsSeason":false,"forestFollowsWeather":false}"#.utf8)
        let decoded = try JSONDecoder().decode(ProductConfig.self, from: legacy)
        XCTAssertNil(decoded.forestSeasonOverride, "老配置没有手动季节 → 没选过，不是某一季")
        XCTAssertNil(decoded.forestWeatherOverride, "老配置没有手动天气 → 没选过，不是某种降水")
    }

    /// 「跟随学习节奏」是 #600（2026-10-19）新增的开关：老配置没有这个键 → false（关）。
    /// 升级后森林不读学习数据，样子逐字不变 —— 与其它三个跟随开关的升级口径一致。
    ///
    /// 反证：把兜底改成 `?? true` → 红（老用户一升级林子就被学业数据推着变）。
    func testLegacyConfigHasNoMomentumFollow() throws {
        let legacy = Data(#"{"forestFollowsClock":true,"forestFollowsSeason":true,"forestFollowsWeather":true}"#.utf8)
        let decoded = try JSONDecoder().decode(ProductConfig.self, from: legacy)
        XCTAssertFalse(decoded.forestFollowsMomentum,
                       "老配置没有这个开关 → 关着，森林不读学习数据")
    }

    /// 朗读调门与语速同一个自愈口径：手改到档位之外的值要落回最近档，
    /// 而不是把一个越界音分原样送进播放链路（`AVAudioUnitTimePitch.pitch` 上限 ±2400）。
    func testPitchSelfHealsOnDecode() throws {
        let decoded = try JSONDecoder().decode(ProductConfig.self, from: Data(#"{"speechPitch":9}"#.utf8))
        XCTAssertEqual(decoded.speechPitch, SpeechPitch.higher2.rawValue)

        let negative = try JSONDecoder().decode(ProductConfig.self, from: Data(#"{"speechPitch":-40}"#.utf8))
        XCTAssertEqual(negative.speechPitch, SpeechPitch.lower2.rawValue)

        let missing = try JSONDecoder().decode(ProductConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(missing.speechPitch, SpeechPitch.natural.rawValue, "老配置没有这个字段 → 原声")
        XCTAssertEqual(missing.speechStyle, "")
        XCTAssertEqual(missing.speechEmotion, "")
    }
}
