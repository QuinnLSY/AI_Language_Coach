import AIDomain
import AIInterfaces
import AIInfrastructure
import AppCore
import Foundation

// MARK: - CoachServices · 健康状态与运行环境（设置页）
//
// #660 自 CoachServices.swift 拆出（2026-10-24）：原文件 3165 行单 actor 超载，按域切为扩展。
// 同模块 extension，语义与拆分前完全一致；跨文件调用的成员已从 private 放宽到
// internal（模块内可见，跨模块零影响，public API 不变）。
extension CoachServices {

// MARK: - 各能力健康状态

public func asrHealth() async -> ProviderHealth { await asr.healthCheck() }
public func ttsHealth() async -> ProviderHealth { await tts.healthCheck() }
public func availableVoices() async -> [String] { await voice.refreshVoices() }

public func llmHealth() async -> ProviderHealth {
    await llm.healthCheck()
}

// MARK: - 运行环境与能力面

/// 某能力的「哪个模型」描述（设置页与提示共用）。
public func modelLabel(for kind: AIProviderKind) async -> String {
    let configuration = await config.current
    let provider = configuration.resolvedProvider(for: kind)
    return ModelDiagnostics.label(
        providerName: provider?.userFacingName,
        model: configuration.resolvedModel(for: kind)
    )
}

/// 当前生效 LLM 的上下文窗口（token）。nil = 未知。
public func contextWindow() async -> Int? {
    await config.current.contextWindow(for: .llm)
}

/// 统一的产品配置写入口（避免 UI 直接访问 ConfigStore）。
public func updateProduct(_ product: ProductConfig) async throws {
    try await config.updateProduct(product)
}

public func switchLLMModel(_ model: String) async throws {
    try await config.selectModel(model, for: .llm)
    try await bootstrapLLM()
}

/// runtime 发现优先；不可用时降级为配置候选列表。
public func availableLLMModels() async -> [DiscoveredModel] {
    var result: [DiscoveredModel] = []
    if let provider = llmProvider, let discovered = try? await provider.discoverModels() {
        result = discovered
    }
    if result.isEmpty {
        let configuration = await config.current
        let candidates = configuration.resolvedProvider(for: .llm)?.candidateModels ?? []
        result = candidates.map { DiscoveredModel(id: $0, name: $0) }
    }
    return result
}

/// 跑一轮本地 LLM 基准（设置页「本地模型测速」）。
///
/// ⚠️ 只打**本地 runtime**（Ollama），零云端费用 —— 所以这里不走计费闸门。
/// 以前这条链路只有 `alc-bench` 命令行在用，界面上一个入口都没有，
/// 于是「我的机器跑这个模型到底快不快」只能靠体感。
///
/// - Parameter rounds: 每个提示词重复几轮（默认 2：够看方差，又不至于跑一分钟）。
public func runLocalBenchmark(rounds: Int = 2) async throws -> LocalLLMBenchmark.Result {
    let configuration = await config.current
    return try await LocalLLMBenchmark(rounds: rounds).run(configuration: configuration)
}

/// 本机当前可用内存（字节；nil = 取不到）。
///
/// 本地模型是**吃内存**的：7B 量化模型加载后占几 GB。界面上给一个数，
/// 用户才能把「卡」和「内存不够」对上，而不是盲猜模型不行。
public func availableMemoryBytes() -> UInt64? {
    OSMemoryPressureMonitor().availableMemoryBytes()
}

/// 当前生效的 LLM 能不能**真的读图**。
///
/// 谁在用：对话区带了图片附件时提醒用户「老师看不到这张图，只会知道文件名」。
/// 这条能力声明以前只有产出方没有消费方（`ProviderCapabilities.vision` 与配置里的
/// `vision` 并列存在，没人读能力面那一份），于是「不读图的模型收到图」是**静默降级**的。
public func llmSupportsVision() async -> Bool {
    await llm.current?.capabilities().vision ?? false
}

/// 当前生效的语音识别引擎**给不给词级时间戳**。
///
/// 谁会用到：设置页「运行环境」的配置体检行。`ProviderCapabilities.wordTimestamp`
/// 这条声明以前只有产出方（`WhisperASRAdapter` 声明 true）没有消费方 ——
/// 于是没人知道 `ASRResult.words` 到底会不会被填上，也没人盯着它别退化成空数组。
/// 这里把它读出来如实展示：**声明的能力必须有人看**，否则就是个装饰。
public func asrWordTimestampSupport() async -> Bool {
    await asr.current?.capabilities().wordTimestamp ?? false
}

/// 当前激活的 LLM Provider 配置（供 UI 展示名称 / 运行时类型）。
public func activeLLMProvider() async -> ProviderConfig? {
    await config.current.resolvedProvider(for: .llm)
}

public func currentLLMModel() async -> String? {
    await config.current.resolvedModel(for: .llm)
}

/// 上次会话（含消息），供启动时恢复聊天框。没有历史时返回 nil。
public func latestChatSession() async -> (session: ChatSession, messages: [ChatMessage])? {
    guard let learning else { return nil }
    return try? await learning.latestSession()
}

/// 当前生效 LLM 的推理强度（low / medium / high；nil = 标准）。
public func activeReasoningEffort() async -> String? {
    await config.current.resolvedProvider(for: .llm)?.reasoningEffort
}
}
