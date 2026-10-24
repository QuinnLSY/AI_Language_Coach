import AIDomain
import AIInfrastructure
import AIInterfaces
import AppCore
import Foundation

// MARK: - CoachServices · 今日跟读与上传材料出题（第 22 步 / #208）
//
// #660 自 CoachServices.swift 拆出（2026-10-24）：原文件 3165 行单 actor 超载，按域切为扩展。
// 同模块 extension，语义与拆分前完全一致；跨文件调用的成员已从 private 放宽到
// internal（模块内可见，跨模块零影响，public API 不变）。
extension CoachServices {
// MARK: - 今日跟读（每天按情景现生成 20 句）

/// 每句跟读的**最近一次**记录（`drill_id` → 最新一条）。
///
/// 跟读页「每句的分析常驻」在重启后靠它把之前读过的几句摆回来。
public func latestShadowingAttempts(drillIDs: [String]) async -> [String: ShadowingAttempt] {
    guard let learning, !drillIDs.isEmpty else { return [:] }
    return (try? await learning.latestShadowingAttempts(drillIDs: drillIDs)) ?? [:]
}

/// 今日缓存的跟读句子（日期或学习语言不匹配 → nil）。
public func shadowingCachedDrills(day: String?) async -> [ShadowingDrill]? {
    let key = day ?? ShadowingDailyRule.dayKey()
    let language = await config.current.product.learningLanguage
    return await shadowingDailyStore.drills(day: key, language: language)
}

/// 今日跟读 20 句：**当天缓存优先**，没有才按当天轮到的情景生成并落盘。
///
/// 为什么缓存优先是本方法的第一条分支，而不是「每次都重新生成」：
/// 用户练到第 7 句去泡了杯茶，回来句子全换掉，等于这一轮练习作废。
/// 同一天必须拿到同一批句子（`ShadowingDailyRule.dayKey` 保证「同一天同一个键」）。
///
/// 生成失败一律抛错，由 UI 决定「先用内置素材顶着」——
/// 本方法不内置兜底句子（跟读素材写死在代码里，正是这一轮要拆掉的东西）。
public func shadowingDailyDrills(day: String? = nil) async throws -> [ShadowingDrill] {
    let key = day ?? ShadowingDailyRule.dayKey()
    let configuration = await config.current
    // ⚠️ 缓存键继续用配置里的 BCP-47（`en-US`）：换成 `English` 会让今天已缓存的
    // 20 句全部失效、当场重生成一批新句子。提示词那一侧才需要语言全名。
    let language = configuration.product.learningLanguage
    let native = configuration.product.nativeLanguage

    if let cached = await shadowingDailyStore.drills(day: key, language: language) {
        return cached
    }
    guard isModelRunning(.llm) else { throw AIProviderError.notInitialized }
    try await ensureLLMReady()

    let total = ShadowingDailyRule.dailySentenceCount
    let picked = ShadowingDailyRule.rotatedScenarios(from: availableScenarios())
    // 情景取不够（资源缺失）时退一步：一个情景都不给，模型就无从「按情景」写 —— 这时
    // 不猜、不编，直接报错让 UI 用内置素材。
    guard !picked.isEmpty else {
        throw AppError.unknown("没有可用的情景素材（Resources/Scenarios/*.json）")
    }
    let perScenario = max(total / picked.count, 1)
    let list = picked.map { scenario in
        (
            name: scenario.titleZh.isEmpty ? scenario.title : scenario.titleZh,
            objective: scenario.objective,
            level: scenario.level,
            difficulty: scenario.difficulty
        )
    }
    let prompt = PromptBuilder.shadowingDailyPrompt(
        learningLanguage: promptLanguage(configuration),
        nativeLanguage: native,
        scenarioList: list,
        perScenario: perScenario,
        total: perScenario * picked.count
    )
    let provider = await config.current.resolvedProvider(for: .llm)
    let request = LLMRequest(
        messages: [LLMMessage(role: .system, content: prompt)],
        model: await currentLLMModel(),
        // 每天要的是一批**不一样的**句子：温度必须给足，否则同一份情景清单
        // 会得到高度雷同的句子（换了日期却像没换）。
        temperature: 0.9,
        // 20 句 × 3 个字段，按 1024 会被截断在中途。
        maxTokens: min(provider?.maxTokens ?? 2048, 2048),
        streaming: false,
        reasoningEffort: LLMRequest.noThinkingEffort
    )
    let response = try await llm.generate(request)
    let drills = ShadowingDailyRule.parse(response.text, limit: total)
    guard drills.count >= total / 2 else {
        // 只解析出零星几句：不落盘（下次还会重试），也不假装这就是今天的素材。
        throw AppError.unknown("模型只给出了 \(drills.count) 句跟读素材")
    }
    await shadowingDailyStore.save(day: key, language: language, drills: drills)
    return drills
}

/// 清掉今日跟读缓存（用户点「重新生成」）。
public func clearShadowingDailyCache() async {
    await shadowingDailyStore.clear()
}

// MARK: - 上传材料自动出题（材料 → 情景 + 跟读句 + 生词表，#208）

/// 全部已生成的材料（按生成时间倒序）。材料是个位数规模，每次读盘即可，
/// 不做进程内缓存 —— 缓存失效点少一个是一个。
public func availableMaterials() async -> [MaterialKit] {
    await materialStore.all()
}

/// 删除一份材料（情景卡、跟读句、生词表一起消失；词汇本里已加入的词**不**回收）。
public func deleteMaterial(id: String) async {
    await materialStore.delete(id: id)
}

/// 把一份材料拆成整套练习：**一次请求**同时产出情景 + 生词表 + 跟读句。
///
/// 「一次操作 = 一个模型请求」的落点：拆解是一次性的整体动作，拆成三次请求
/// 只会让用户等三趟、多花三份钱。生成成功即落盘；同 id 重复生成 = 覆盖更新。
public func generateMaterialKit(from raw: String) async throws -> MaterialKit {
    if let issue = MaterialKitRule.inputIssue(for: raw) {
        switch issue {
        case .empty:
            throw AppError.unknown("材料是空的，先粘贴或导入一篇文字再生成。")
        case .tooShort(let actual):
            throw AppError.unknown("材料太短（只有 \(actual) 字，至少需要 \(MaterialKitRule.minimumLength) 字），撑不起一套练习。")
        }
    }
    guard isModelRunning(.llm) else { throw AIProviderError.notInitialized }
    try await ensureLLMReady()

    let configuration = await config.current
    let material = MaterialKitRule.sanitized(raw)
    let prompt = PromptBuilder.materialKitPrompt(
        material: material,
        learningLanguage: promptLanguage(configuration),
        nativeLanguage: configuration.product.nativeLanguage
    )
    let provider = await config.current.resolvedProvider(for: .llm)
    let request = LLMRequest(
        messages: [LLMMessage(role: .system, content: prompt)],
        model: await currentLLMModel(),
        // 拆解要忠实于材料：低温、关思考（确定性短任务必关思考）。
        temperature: 0.3,
        maxTokens: min(provider?.maxTokens ?? 2048, 2048),
        streaming: false,
        reasoningEffort: LLMRequest.noThinkingEffort
    )
    let response = try await llm.generate(request)
    guard let kit = MaterialKitRule.parse(response.text, text: material) else {
        // 解析失败不落盘：宁可让用户重试，也不能存一份缺胳膊少腿的材料。
        throw AppError.unknown("没能从材料里拆出完整的练习（缺标题 / 情景 / 跟读句），请重试一次。")
    }
    try await materialStore.save(kit)

    // 生词表自动进词汇本（已有同词则跳过，`add` 内部去重）。
    for word in kit.words {
        _ = await vocabulary.add(word: word.word, meaning: word.meaning, source: .material)
    }
    return kit
}
}
