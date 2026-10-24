import AIInterfaces
import AIInfrastructure
import AIProviders
import AppCore
import Foundation

// MARK: - CoachServices · Provider 装配与工厂
//
// #660 自 CoachServices.swift 拆出（2026-10-24）：原文件 3165 行单 actor 超载，按域切为扩展。
// 同模块 extension，语义与拆分前完全一致；跨文件调用的成员已从 private 放宽到
// internal（模块内可见，跨模块零影响，public API 不变）。
extension CoachServices {

// MARK: - Provider 装配（LLM / 语音 / 发音评测）

/// 「还没配语言模型」的同一句话。
///
/// 开屏装配与高级设置两条路都会撞上它，**写两份就迟早漂移成一长一短两种说法**。
/// 措辞要与「AI 大脑还没启动，先在设置里点绿色的「启动」，再来查…」一致：说清**去哪儿做什么**，
/// 而不是说「配置错误」——用户既不知道「配置」指什么，也不知道点哪里。
static let missingLLMProviderMessage = "还没有可用的语言模型，先在设置里启用一个。"

/// 按当前配置装配 LLM Provider（初始化 + 校验）。不抛错则可用。
public func bootstrapLLM() async throws {
    let configuration = await config.current
    guard var providerConfig = configuration.resolvedProvider(for: .llm) else {
        throw AppError.configuration(Self.missingLLMProviderMessage)
    }
    if let model = configuration.resolvedModel(for: .llm) {
        providerConfig.model = model
    }
    providerConfig = Self.fillServiceCommands(providerConfig)
    let provider = Self.makeLLMProvider(providerConfig)
    try await provider.initialize(config: providerConfig)
    // load 失败（如 runtime 未启动）不阻断启动：UI 需展示明确状态。
    try? await provider.load()
    llmProvider = provider
    await llm.register(provider)
}

/// **确保 LLM 已装配**。用户可能在应用还没启动完就发了消息 —— 那时 Provider 尚未注册，
/// 请求会直接以「尚未初始化」失败，表现就是「老师说啥都不回」。
/// 这里做一次幂等的装配（并发调用共享同一个任务），让首条消息自己把自己救回来。
public func ensureLLMReady() async throws {
    if llmProvider != nil { return }
    if let existing = llmReadyTask {
        try await existing.value
        return
    }
    let task = Task { [weak self] in
        guard let self else { throw AIProviderError.notInitialized }
        try await self.bootstrapLLM()
    }
    llmReadyTask = task
    do {
        try await task.value
    } catch {
        // 失败不缓存：下次发送时应当重新尝试装配（例如用户刚启动了本地服务）。
        llmReadyTask = nil
        throw error
    }
}

/// 装配发音评测的**声学通道**（第 23 步：音素级打分）。
///
/// 两条通道的分工见 `PronunciationService`：
/// 配置了云端发音评测（如 Azure）就用实测，否则自动回落规则推断。
/// **不需要 Key 也能用**，所以这里从不抛错——没有云端配置不是错误，只是走另一条路。
///
/// - Returns: 声学通道的健康状态；未配置时返回 `configurationInvalid`（说明走推断）。
@discardableResult
public func bootstrapPronunciation() async -> ProviderHealth {
    let configuration = await config.current
    guard let raw = Self.preferredProvider(.pronunciation, in: configuration),
          raw.runtime == .remoteAPI else {
        await pronunciation.attachAcousticProvider(nil)
        return .configurationInvalid(reason: "未配置云端发音评测，使用规则推断")
    }
    var providerConfig = raw
    if let model = configuration.resolvedModel(for: .pronunciation) {
        providerConfig.model = model
    }
    let provider = RemotePronunciationAdapter(providerID: providerConfig.id)
    do {
        try await provider.initialize(config: providerConfig)
    } catch {
        // 配置不完整（缺端点 / 缺 Key / 没选语言）：卸掉声学通道，回到规则推断，
        // 但把原因如实带回去给 UI，别让用户以为「配了云端却在用推断」是无声发生的。
        await pronunciation.attachAcousticProvider(nil)
        return .configurationInvalid(reason: error.localizedDescription)
    }
    let health = await provider.healthCheck()
    if health.isUsable {
        await pronunciation.attachAcousticProvider(provider)
    } else {
        await pronunciation.attachAcousticProvider(nil)
    }
    return health
}

/// 装配语音能力（ASR + TTS）。**语音是可选能力**：runtime 没启动也不阻断应用。
@discardableResult
public func bootstrapVoice() async -> (asr: ProviderHealth, tts: ProviderHealth) {
    let configuration = await config.current
    let asrHealth = await bootstrapASR(configuration)
    let ttsHealth = await bootstrapTTS(configuration)
    if ttsHealth.isUsable { _ = await voice.refreshVoices() }
    return (asrHealth, ttsHealth)
}

private func bootstrapASR(_ configuration: AppConfiguration) async -> ProviderHealth {
    guard let raw = Self.preferredProvider(.asr, in: configuration) else {
        return .configurationInvalid(reason: "没有启用的语音识别 Provider")
    }
    var providerConfig = Self.fillServiceCommands(raw)
    if let model = configuration.resolvedModel(for: .asr) { providerConfig.model = model }
    let provider = Self.makeASRProvider(providerConfig)
    do {
        try await provider.initialize(config: providerConfig)
    } catch {
        return .configurationInvalid(reason: error.localizedDescription)
    }
    try? await provider.load()
    await asr.register(provider)
    return await provider.healthCheck()
}

private func bootstrapTTS(_ configuration: AppConfiguration) async -> ProviderHealth {
    guard let raw = Self.preferredProvider(.tts, in: configuration) else {
        return .configurationInvalid(reason: "没有启用的教师语音 Provider")
    }
    var providerConfig = Self.fillServiceCommands(raw)
    if let model = configuration.resolvedModel(for: .tts) { providerConfig.model = model }
    let provider = Self.makeTTSProvider(providerConfig)
    do {
        try await provider.initialize(config: providerConfig)
    } catch {
        return .configurationInvalid(reason: error.localizedDescription)
    }
    try? await provider.load()
    await tts.register(provider)
    return await provider.healthCheck()
}

/// 某能力实际要装配的 Provider：**先认用户选中的那个（本地 / 云端二选一）**，
/// 没选过再从启用的里面挑真实 runtime；只有 mock 时才用 mock。
///
/// 这一步很关键：否则用户在设置里切到云端后，语音链路仍会挑到本地 runtime，
/// 表现为「界面显示已启用云端，实际还是本地（或反过来的鬼打墙）」。
private static func preferredProvider(_ kind: AIProviderKind, in configuration: AppConfiguration) -> ProviderConfig? {
    if let chosen = configuration.resolvedProvider(for: kind) { return chosen }
    let candidates = configuration.providers.filter { $0.kind == kind && $0.enabled }
    return candidates.first { $0.runtime != .mock } ?? candidates.first
}

// MARK: - 按能力重装配

/// 按能力重装配（本地模型切换 / 云端激活后调用）。
public func rebootstrap(kind: AIProviderKind) async {
    switch kind {
    case .llm:
        try? await bootstrapLLM()
    case .asr, .tts:
        _ = await bootstrapVoice()
    case .pronunciation:
        // 音素评测换了供应商 / 填了 Key，声学通道要跟着换（否则还在用旧端点）。
        _ = await bootstrapPronunciation()
    case .embedding:
        // 语义索引的装配是「一次一条路」，重装配要显式放行（见 ensureEmbeddingReady）。
        await ensureEmbeddingReady(force: true)
    default:
        break // vad 尚无真实 runtime
    }
}

/// **全部**能力重装配。用于「用户在外面手改了 config.json / 把备份配置拷回来」之后：
/// 只把配置读回内存是不够的 —— 真正干活的是已经装配好的 provider，
/// 不重装配就会出现「设置页按新配置显示、实际还在打旧端点」这种最难查的错位。
public func rebootstrapAll() async {
    for kind in AIProviderKind.allCases {
        await rebootstrap(kind: kind)
    }
}

// MARK: - 启停命令兜底（存量配置缺这两个字段）

/// 把配置里的启停命令补齐：老配置文件（本轮新增字段之前写的）里没有这两项，
/// 用内置默认配置里同 id 的值兜底，保证「启动 / 关闭」按钮一装上就能用。
public static func fillServiceCommands(_ config: ProviderConfig) -> ProviderConfig {
    guard config.serviceStartCommand == nil || config.serviceStopCommand == nil,
          let defaults = try? DefaultConfiguration.load(),
          let fallback = defaults.providers.first(where: { $0.id == config.id })
    else { return config }
    var result = config
    if result.serviceStartCommand == nil { result.serviceStartCommand = fallback.serviceStartCommand }
    if result.serviceStopCommand == nil { result.serviceStopCommand = fallback.serviceStopCommand }
    return result
}

// MARK: - Provider 工厂（唯一允许 new 出 Adapter 的地方）

private static func makeASRProvider(_ config: ProviderConfig) -> any ASRProvider {
    switch config.runtime {
    case .externalLocalRuntime:
        WhisperASRAdapter(providerID: config.id)
    case .remoteAPI:
        RemoteASRAdapter(providerID: config.id)
    default:
        MockASRProvider()
    }
}

internal static func makeTTSProvider(_ config: ProviderConfig) -> any TTSProvider {
    switch config.runtime {
    case .externalLocalRuntime:
        Qwen3TTSAdapter(providerID: config.id)
    case .remoteAPI:
        RemoteTTSAdapter(providerID: config.id)
    default:
        MockTTSProvider()
    }
}

private static func makeLLMProvider(_ config: ProviderConfig) -> any LLMProvider {
    switch config.runtime {
    case .ollama:
        OllamaLLMAdapter(providerID: config.id)
    case .remoteAPI:
        RemoteLLMAdapter(providerID: config.id)
    case .mock:
        MockLLMProvider(providerID: config.id)
    default:
        // 其余 runtime（MLX / llama.cpp / python_process）V1 未实现 → 降级为 Mock，
        // 保证架构可跑通且不会编译期缺实现。
        MockLLMProvider(providerID: config.id)
    }
}

internal static func makeEmbeddingProvider(_ config: ProviderConfig) -> (any EmbeddingProvider)? {
    switch config.runtime {
    case .ollama:
        OllamaEmbeddingAdapter(providerID: config.id, dimensions: config.dimensions ?? 768)
    case .mock:
        MockEmbeddingProvider()
    case .remoteAPI:
        // 云端嵌入：同样经过计费闸门（RemoteCommon.beginBillableCall），
        // 与本地 Ollama 复用同一套「记忆索引」发现 / 健康逻辑。
        RemoteEmbeddingAdapter(providerID: config.id, dimensions: config.dimensions ?? 0)
    default:
        // 其余 runtime（MLX / llama.cpp …）V1 未实现嵌入适配器。
        // **不注册**，而不是拿 mock 冒充 —— 语义索引缺席，记忆退回结构化。
        nil
    }
}
}
