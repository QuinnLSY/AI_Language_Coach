import AIDomain
import AIInterfaces
import AIInfrastructure
import AIProviders
import AppCore
import Foundation

// MARK: - CoachServices · 模型注册表与 Provider 管理（Phase 3）
//
// #660 自 CoachServices.swift 拆出（2026-10-24）：原文件 3165 行单 actor 超载，按域切为扩展。
// 同模块 extension，语义与拆分前完全一致；跨文件调用的成员已从 private 放宽到
// internal（模块内可见，跨模块零影响，public API 不变）。
extension CoachServices {
// MARK: - 模型注册表（Phase 3）

/// 全部可选 Provider 的配置视图（只读投影：可用性 / 是否生效都在这里问）。
public func modelConfigs(kind: AIProviderKind? = nil) async -> [ModelConfig] {
    ModelRegistry.listAvailable(await config.current, kind: kind)
}

/// 某能力当前**生效**的那一个。
public func defaultModelConfig(for kind: AIProviderKind) async -> ModelConfig? {
    ModelRegistry.getDefault(await config.current, for: kind)
}

/// 该能力应当由谁去探活。
///
/// 注册表只回答「该探谁」——真探活在 `llmHealth()` / `asrHealth()` / `ttsHealth()`
/// （要发网络请求、要看 runtime 进程），**不在纯逻辑层假装探过**。
public func healthTarget(for kind: AIProviderKind) async -> HealthTarget? {
    ModelRegistry.healthTarget(await config.current, for: kind)
}

/// 配置一致性体检：找出会让「生效 Provider 解析不出来」的问题。
public func registryInconsistencies(for kind: AIProviderKind) async -> [String] {
    ModelRegistry.inconsistencies(await config.current, kind: kind)
}

/// 只更新某个 Provider 的 API Key（空 = 清除），不动 enabled / model / 产品层选择。
///
/// 「记住密钥」的唯一形式是**用户把它填进了输入框**。输入框为空即视为不配置：
/// 这里会把配置里的旧 Key 一并清掉，并让产品层不再指向一个没有 Key 的云端 Provider。
@discardableResult
public func setRemoteProviderKey(providerID: String, apiKey: String, kind: AIProviderKind) async throws -> Bool {
    guard await config.current.providers.contains(where: { $0.id == providerID && $0.kind == kind }) else {
        throw AppError.configuration("找不到 Provider：\(providerID)")
    }
    // 落盘前统一做粘贴清洗：控制台复制出来的引号 / 「Bearer 」前缀 / 换行
    // 会让每一次调用都被服务端判为「Invalid token」，而用户看不出哪里不对。
    let trimmed = CredentialText.normalizedKey(apiKey)
    try await config.mutateProvider(id: providerID) { p in
        p.apiKey = trimmed.isEmpty ? nil : trimmed
    }
    if trimmed.isEmpty {
        try await config.mutateProduct { product in
            if product.activeProvider(for: kind) == providerID {
                product.selectModel(nil, for: kind)
            }
        }
    }
    return !trimmed.isEmpty
}

/// 校验云端 API Key 并拉取可用模型（不落盘，仅探测）。
/// 各厂商均为 OpenAI 兼容协议，发现流程对任意能力（llm/asr/tts/…）通用。
public func fetchRemoteModels(providerID: String, apiKey: String, kind: AIProviderKind = .llm) async throws -> [DiscoveredModel] {
    let configuration = await config.current
    guard var providerConfig = configuration.providers.first(where: { $0.id == providerID && $0.kind == kind }) else {
        throw AppError.configuration("找不到 Provider：\(providerID)")
    }
    providerConfig.apiKey = CredentialText.normalizedKey(apiKey)
    // 发现流程对任意能力通用（llm / asr / tts …）：同一套 OpenAI 兼容 `/models`，
    // 只是按能力过滤掉不属于这一类模型的条目（云端返回的是混合列表）。
    return try await RemoteCommon.discoverModels(
        config: providerConfig,
        kind: kind,
        client: HTTPClient(useSystemProxy: true)
    )
}

/// 验证云端**发音评测**的 Key / 端点是否真的可用。
///
/// 与模型列表探测的区别：发音评估没有只读端点，唯一的验证方式是**发一段音频**。
/// 这里用 1 秒静音——它足够让服务端把「认证 / 端点 / 音频格式」三件事验完
/// （静音通常回 `NoMatch`，那恰好证明上面三件事都通过），而费用可以忽略。
///
/// ⚠️ 这是**计费调用**，所以只在用户点「验证」时发生，不做后台静默探测。
///
/// - Returns: 面向用户的一句话结论。
@discardableResult
public func verifyRemotePronunciation(
    providerID: String, apiKey: String, model: String?
) async throws -> String {
    let configuration = await config.current
    guard var providerConfig = configuration.providers.first(where: {
        $0.id == providerID && $0.kind == .pronunciation
    }) else {
        throw AppError.configuration("找不到发音评测 Provider：\(providerID)")
    }
    providerConfig.apiKey = CredentialText.normalizedKey(apiKey)
    if let model, !model.isEmpty { providerConfig.model = model }
    guard let locale = providerConfig.model, !locale.isEmpty else {
        throw AIProviderError.invalidConfiguration("未选择评测语言（如 en-US）")
    }
    let adapter = RemotePronunciationAdapter(providerID: providerID)
    try await adapter.initialize(config: providerConfig)
    let status = try await adapter.probe()
    let host = providerConfig.endpoint.flatMap { RemoteEndpoint.base($0) }.map { RemoteCommon.host(of: $0) } ?? "?"
    return "认证通过（\(host) · \(locale)）。探测返回 \(status)——静音的预期结果，说明端点与密钥都可用。"
}

/// 记住某云端 Provider 探测到的模型列表（写进 `candidateModels`）。
///
/// 探测本身仍是只读的（`fetchRemoteModels` 不写配置），但把结果留下来能让用户
/// **重开设置时选择器直接可用**——否则「验证并获取模型」每次都要重点一遍。
public func rememberRemoteModels(_ models: [DiscoveredModel], providerID: String, kind: AIProviderKind) async {
    let ids = models.map(\.id)
    guard !ids.isEmpty else { return }
    guard await config.current.providers.contains(where: { $0.id == providerID && $0.kind == kind }) else { return }
    // 写不进去不影响探测结果本身（模型列表已经拿到了），但**不能静默**：
    // 「下次开设置还要重点一次」这种症状，靠这条 debug 才能定位到是落盘失败。
    do {
        try await config.mutateProvider(id: providerID) { p in
            p.candidateModels = ids
        }
    } catch {
        AppLog.debug("候选模型清单落盘失败（\(providerID)/\(kind.rawValue)）：\(error)", category: "config")
    }
}

/// 拉取供应商自报的音色清单（`voice_list_path`，如 Edge TTS 代理的 `/voices`），
/// 并把「音色 id → 友好名」写进配置（原子局部更新），UI 据此显示晓晓 / 云希这类名字。
///
/// - 若配置里还没有静态音色清单，把探测结果补进去（选择器从此直接可用）。
/// - 探测失败原样抛错：调用方（设置页）把错误显示给用户即可。
@discardableResult
public func discoverRemoteVoices(providerID: String, kind: AIProviderKind = .tts) async throws -> [RemoteVoiceCatalog.Voice] {
    let configuration = await config.current
    guard let providerConfig = configuration.providers.first(where: { $0.id == providerID && $0.kind == kind }) else {
        throw AppError.configuration("找不到 Provider：\(providerID)")
    }
    let voices = try await RemoteCommon.discoverVoices(config: providerConfig, client: HTTPClient(useSystemProxy: true))
    guard !voices.isEmpty else { return [] }
    let names = Dictionary(uniqueKeysWithValues: voices.map { ($0.id, $0.name) })
    let ids = voices.map(\.id)
    // 同上：音色名字写不进去只是「选择器下次还得重新问」，不该吞成无声失败。
    do {
        try await config.mutateProvider(id: providerID) { p in
            p.voiceNames = names
            if (p.voices ?? []).isEmpty { p.voices = ids }
        }
    } catch {
        AppLog.debug("音色清单落盘失败（\(providerID)/\(kind.rawValue)）：\(error)", category: "config")
    }
    return voices
}

/// 配置里已存的音色友好名（id → 名字；没有则原样返回 id）。
public func voiceLabel(providerID: String, voice: String, kind: AIProviderKind = .tts) async -> String {
    let configuration = await config.current
    guard let provider = configuration.providers.first(where: { $0.id == providerID && $0.kind == kind }) else {
        return voice
    }
    return provider.voiceLabel(for: voice) ?? voice
}

/// 某供应商是否**免密钥**（UI 据此隐藏 Key 输入框、放行无 Key 的接入）。
public func isKeyless(providerID: String, kind: AIProviderKind) async -> Bool {
    let configuration = await config.current
    return configuration.providers.first { $0.id == providerID && $0.kind == kind }?.requiresAPIKey == false
}

/// 保存云端 Provider 的 API Key / 模型 / 推理强度，并把该能力切换到这个 Provider。
///
/// **只写配置，不做重装配**（重装配见 `applyRemoteProvider`）。拆成两步是为了让
/// 「配置到底写对没有」可以脱离 Provider 装配单独验证——历史上这里丢过 Key。
public func persistRemoteProvider(providerID: String, apiKey: String, model: String,
                                  reasoningEffort: String? = nil, kind: AIProviderKind = .llm) async throws {
    guard await config.current.providers.contains(where: { $0.id == providerID && $0.kind == kind }) else {
        throw AppError.configuration("找不到 Provider：\(providerID)")
    }
    // ⚠️ API Key **以输入框内容为唯一真相**：输入框为空 = 用户没有配置 Key，
    // 这里就把已保存的 Key 一并清掉（连同产品层的选择）。
    //
    // 历史行为是「输入框为空则沿用配置里已保存的 Key」，于是界面上明明没填 Key，
    // 应用却仍拿旧 Key 去调用云端——用户明确禁止这种情况（2026-09-13 反馈）。
    // 记住一个 Key 的唯一形式是**把它填进输入框**，不是替用户保管。
    let trimmedKey = CredentialText.normalizedKey(apiKey)
    let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
    // 全部走**原子局部更新**：每步都基于 actor 内的最新值，字段之间不会互相覆盖。
    // 顺序也有讲究——先改 enabled（会遍历同类所有 Provider），再写这个 Provider 的
    // Key/模型，最后动产品层。反过来写就会出现「enabled 循环把刚保存的 Key 抹掉」。
    try await config.mutateProviders(kind: kind) { p in
        p.enabled = (p.id == providerID)
    }
    try await config.mutateProvider(id: providerID) { p in
        p.apiKey = trimmedKey.isEmpty ? nil : trimmedKey
        p.model = trimmedModel.isEmpty ? nil : trimmedModel
        p.reasoningEffort = reasoningEffort
        // 用过的模型并入候选集：下次打开设置时选择器要能直接列出它，
        // 不必再点一次「验证并获取模型」才能切换（产品要求见需求 ①）。
        if !trimmedModel.isEmpty, !p.candidateModels.contains(trimmedModel) {
            p.candidateModels.insert(trimmedModel, at: 0)
        }
    }
    try await config.mutateProduct { product in
        product.activateProvider(providerID, for: kind)
        product.selectModel(trimmedModel.isEmpty ? nil : trimmedModel, for: kind)
    }
}

/// 保存云端 Provider 的 API Key / 模型 / 推理强度，并激活 + 重装配（任意能力通用）。
public func applyRemoteProvider(providerID: String, apiKey: String, model: String,
                                reasoningEffort: String? = nil, kind: AIProviderKind = .llm) async throws {
    try await persistRemoteProvider(
        providerID: providerID, apiKey: apiKey, model: model,
        reasoningEffort: reasoningEffort, kind: kind
    )
    await rebootstrap(kind: kind)
}

// MARK: - 切换生效的 Provider（本地 / 云端二选一）

/// 高级设置：修改 LLM Provider 的端点 / 温度后重新装配。
public func setLLMProviderField(endpoint: String? = nil, temperature: Double? = nil) async throws {
    let configuration = await config.current
    guard let provider = configuration.resolvedProvider(for: .llm) else {
        throw AppError.configuration(Self.missingLLMProviderMessage)
    }
    // 原子更新：只动高级设置里这两个字段，避免整条写回覆盖 apiKey 等。
    try await config.mutateProvider(id: provider.id) { p in
        if let endpoint { p.endpoint = endpoint }
        if let temperature { p.temperature = temperature }
    }
    try await bootstrapLLM()
}

/// 切换激活的 LLM Provider（本地 / 云端并存，二选一生效）。
/// 同时把产品层选中模型对齐到该 Provider 的默认模型，避免跨 Provider 串模型名。
public func switchLLMProvider(_ providerID: String) async throws {
    try await setCapabilityProvider(.llm, providerID: providerID)
}

/// 把**任意能力**切换到指定 Provider（本地或云端），同类其它 Provider 一律停用。
///
/// 这是「切到本地模型后没有关掉外部模型接口」的修复点。旧行为是：选本地模型时
/// 只把模型名写进**当前生效**的 Provider——而当前生效的往往是云端那家，
/// 于是云端既没被关掉，还被写进了一个本地模型名（实测 `remote.siliconflow-asr`
/// 的 model 变成了 `ggml-small.en`），界面也就显示成「SiliconFlow 语音识别 · ggml-small.en」。
///
/// 现在「切换」= 真正换 Provider：
/// - 同类只留目标这一个 `enabled`，其余全部停用（**外部模型接口就此关闭**）；
/// - 云端 Provider 没有 Key 时直接拒绝，不允许出现「已启用却调不动」的状态；
/// - 产品层选中模型对齐到该 Provider 自己配的模型，没配就清空
///   （交给云端闸门拒绝并提示用户去选，而不是拿候选清单第一个顶替）。
public func setCapabilityProvider(_ kind: AIProviderKind, providerID: String) async throws {
    guard let target = await config.current.providers.first(where: { $0.id == providerID && $0.kind == kind }) else {
        throw AppError.configuration("找不到\(kind.displayName) Provider：\(providerID)")
    }
    let hasKey = !((target.apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    if target.isRemote, !hasKey {
        throw AppError.configuration(
            "请先填写 API Key 再启用「\(target.userFacingName)」：输入框为空时，应用不会使用任何已保存的旧密钥。"
        )
    }
    try await config.mutate { configuration in
        // 用注册表的语义做这次写入（同类只留一个 enabled + 产品层指向与模型对齐）。
        // 注册表是**纯函数**：它只给出变换，落盘仍只走 ConfigStore 这一条路，
        // 因此不会长出「配置 vs 注册表」两份互相漂移的真相。
        _ = ModelRegistry.enable(&configuration, providerID: providerID)
    }
    await rebootstrap(kind: kind)
}

// MARK: - 选用模型与历史坏配置自愈

/// 设置某能力当前使用的模型（本地检测选择 / 手动填写共用），并重装配。
public func setCapabilityModel(_ kind: AIProviderKind, model: String) async throws {
    guard let provider = await config.current.resolvedProvider(for: kind) else {
        throw AppError.configuration("还没有可用的\(kind.displayName)，先在设置里启用一个。")
    }
    // 原子更新：只改这个 Provider 的 model 与产品层的选中模型，
    // 不碰同一条记录上的 apiKey / endpoint（旧写法用过期快照整体写回，会连带覆盖）。
    try await config.mutateProvider(id: provider.id) { p in
        p.model = model
        // 手动填写的模型也要并入候选清单：云端调用的「模型白名单」以候选清单为准
        // （见 `RemoteCallPolicy.allowedModelSet`），不并进去就会被自己的闸门拦下。
        if p.isRemote, !p.candidateModels.contains(model) {
            p.candidateModels.insert(model, at: 0)
        }
    }
    try await config.mutateProduct { $0.selectModel(model, for: kind) }
    await rebootstrap(kind: kind)
}

/// 修掉「本地模型名被写进云端供应商」的历史坏配置。
///
/// 实测过的状态：`remote.siliconflow-asr` 的 model 变成了本地的 `ggml-small.en`，
/// 界面于是显示成「SiliconFlow 语音识别 · ggml-small.en 已就绪」——本地被关掉、
/// 外部接口却开着，而且这个模型名在云端**不可能**存在（要么 404，要么被路由到别的模型）。
///
/// 判定依据是「这个名字确实是本机 `~/AI_Models` 里的模型」：这种串线只可能来自
/// 旧版本「选本地模型 → 写进当前生效的云端 Provider」那条路径。
///
/// 处理方式（三件事一起做，缺一不可）：
/// 1. **清掉该 Provider 的 model** —— 这个名字在云端不存在，留着只会显示错误；
/// 2. **把这个云端接口关掉（`enabled = false`）** —— 用户反馈的原话是
///    「切换本地模型后，没有关闭外部模型接口」：它上面写着本地模型名本来就调不通，
///    却因为 `enabled = true` 一直占着生效位、害得本地 Provider 用不上；
///    并让产品层不再指向它；
/// 3. **把该能力对应的本地 Provider 打开** —— 「切本地」当初只做了一半
///    （名字写进云端、本地没启用），这里补完，避免落到「云端关了、本地也没开」的真空。
///
/// 例外：如果这个名字出现在该 Provider **自己探测到的候选清单**里，说明它可能是用户
/// 正当地从云端列表里选的（本地恰好装了同名模型，如公开可下载的 Qwen3-TTS 系列），
/// 这种情况一律不动——不能为了修坏数据而误伤一份能用的云端配置。
///
/// - Parameter localModelNames: 本机某能力已安装的模型名（可注入，便于脱机测试）。
/// - Returns: 被修掉的能力（供 UI 提示）。
@discardableResult
public func healCrossProviderModels(
    localModelNames: (@Sendable (AIProviderKind) -> Set<String>)? = nil
) async -> [AIProviderKind] {
    let names: @Sendable (AIProviderKind) -> Set<String> = localModelNames ?? { kind in
        Set(LocalModelScanner.scan(kind: kind).map(\.name))
    }
    let configuration = await config.current
    var healed: [AIProviderKind] = []
    for provider in configuration.providers where provider.isRemote {
        let model = (provider.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, names(provider.kind).contains(model) else { continue }
        // 例外：这家供应商**自己广告过**这个名字（探测进了候选清单）→ 它可能是
        // 用户正当地从云端列表里选的（本地恰好装了同名模型，如 Qwen3-TTS 系列）。
        // 这种情况不动它，免得误伤一个能用的云端配置。
        guard !provider.candidateModels.contains(model) else { continue }
        do {
            try await config.mutateProvider(id: provider.id) { p in
                p.model = nil
                p.enabled = false   // 「外部模型接口」就此关闭，不再占着生效位
            }
        } catch {
            AppLog.debug("本地模型自愈：关闭云端 \(provider.id) 失败：\(error)", category: "config")
        }
        // 「切本地」这个动作在旧版本里只做了一半：本地模型名写进了云端，本地却没启用。
        // 这里把它补完——找到该能力下**名字对得上的**本地 Provider 打开，
        // 否则用户会落到「云端被关了、本地也没开」的真空状态。
        let localCandidates = configuration.providers.filter {
            $0.kind == provider.kind && !$0.isRemote && $0.runtime != .mock
        }
        if let local = localCandidates.first(where: { ($0.model ?? "") == model }) ?? localCandidates.first {
            do {
                try await config.mutateProvider(id: local.id) { p in
                    p.enabled = true
                    if (p.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        p.model = model   // 它本来就是本机的模型名，落到本地 Provider 上正好
                    }
                }
            } catch {
                AppLog.debug("本地模型自愈：启用本地 \(local.id) 失败：\(error)", category: "config")
            }
        }
        try? await config.mutateProduct { product in
            if product.selectedModel(for: provider.kind) == model {
                product.selectModel(nil, for: provider.kind)
            }
            if product.activeProvider(for: provider.kind) == provider.id {
                product.activateProvider(nil, for: provider.kind)
            }
        }
        if !healed.contains(provider.kind) { healed.append(provider.kind) }
        AppLog.warning(
            "云端 Provider \(provider.id) 的模型名「\(model)」是本地模型，已清除并关闭该接口（请重新选择云端模型或改用本地模型）",
            category: "configuration"
        )
    }
    return healed
}
}
