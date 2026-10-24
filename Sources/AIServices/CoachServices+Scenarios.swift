import AIDomain
import AIInfrastructure
import AIInterfaces
import AppCore
import Foundation

// MARK: - CoachServices · 情景目录 / 自建情景 / 主线任务（第 21 步 / ⑦）
//
// #660 自 CoachServices.swift 拆出（2026-10-24）：原文件 3165 行单 actor 超载，按域切为扩展。
// 同模块 extension，语义与拆分前完全一致；跨文件调用的成员已从 private 放宽到
// internal（模块内可见，跨模块零影响，public API 不变）。
extension CoachServices {
// MARK: - 情景对话（Role Play，第 21 步）

/// 全部可用情景 = **内置**（`Resources/Scenarios/*.json`）+ **用户自建**（「我的情景」，⑦）。
///
/// 资源缺失时返回空数组，由 UI 给出可操作提示（不崩、不静默、不内置兜底场景）。
///
/// ⚠️ 自建情景必须走这一条：它要能被分组展示、被关卡绑定、被今日跟读轮换选中，
/// 还要能按 id 查回来（进行中的会话恢复靠 `scenario(id:)`）——
/// 每多一个「只认内置」的入口，自建情景就会在那里凭空消失一次。
public func availableScenarios() -> [Scenario] {
    if scenarioCache == nil { scenarioCache = ScenarioCatalog.bundled() }
    // ⚠️ 课内情景（③）必须并进来：一节课就是一个情景，它要能被分组展示、
    // 被关卡绑定、被今日跟读轮换选中，还要能按 id 查回来（进行中的会话恢复靠
    // `scenario(id:)`）—— 少并一份，AI 排的课在那些入口上就会凭空消失。
    return ScenarioCatalog.deduplicated(
        (scenarioCache ?? []) + customScenarioCache + courseScenarioCache
    )
}

/// 重新读盘，把用户自建情景并进目录。
///
/// 调用点：开情景面板 / 生成成功 / 删除之后。**不是**每次 `availableScenarios()` 都读盘 ——
/// 那个函数在同步上下文里被调得很频繁（今日跟读轮换、关卡绑定都走它）。
public func reloadCustomScenarios() async {
    customScenarioCache = await customScenarioStore.all().map(\.scenario)
}

/// 全部自建情景草稿（按生成时间倒序）。UI 用它回显「你要练的是什么」那句话。
public func availableScenarioDrafts() async -> [ScenarioDraft] {
    await customScenarioStore.all()
}

/// 删除一份自建情景（对应卡片与练习入口立即消失；已进词汇本的词**不回收** ——
/// 那已经是学员自己的词了）。
public func deleteScenarioDraft(id: String) async {
    await customScenarioStore.delete(id: id)
    await reloadCustomScenarios()
}

/// 一句话生成一个情景：**一次请求**产出一个完整可练的场景（开场白 / 目标句 / 目标词）。
///
/// 失败一律抛错、**不落盘**：宁可让用户改一句话重试，也不能在「我的情景」里留一份
/// 缺胳膊少腿的半成品 —— 它会长期占着列表，比一次失败难收拾得多。
///
/// 目标词顺带进词汇本（`source: .scenario`）：这既是「自动出题」的一半，
/// 也让这些词被每日推荐的**生词档**接住（生词档从词汇本取词）——
/// 练过的词第二天在推荐里再露一面，两个功能才算真正闭上环。
public func generateScenarioDraft(from raw: String) async throws -> ScenarioDraft {
    if let issue = ScenarioDraftRule.inputIssue(for: raw) {
        switch issue {
        case .empty:
            throw AppError.unknown("先写一句你想练的场景（比如「在咖啡店点一杯拿铁」）。")
        case .tooShort(let actual):
            throw AppError.unknown(
                "描述太短（\(actual) 字，至少 \(ScenarioDraftRule.minimumLength) 字），"
                    + "补一句「你是谁、在哪、要做什么」。"
            )
        case .tooLong(let actual):
            throw AppError.unknown(
                "描述太长（\(actual) 字，最多 \(ScenarioDraftRule.maximumLength) 字），一句话说清就好。"
            )
        }
    }
    guard isModelRunning(.llm) else { throw AIProviderError.notInitialized }
    try await ensureLLMReady()

    let configuration = await config.current
    let prompt = ScenarioDraftRule.sanitized(raw)
    let provider = await config.current.resolvedProvider(for: .llm)
    let request = LLMRequest(
        messages: [LLMMessage(role: .system, content: PromptBuilder.scenarioDraftPrompt(
            prompt: prompt,
            learningLanguage: promptLanguage(configuration),
            nativeLanguage: configuration.product.nativeLanguage
        ))],
        model: await currentLLMModel(),
        // 创作任务：要一点温度（同一句描述不该永远生成一模一样的情景），但不能飘 ——
        // 生成出来的东西要能直接拿去练。
        temperature: 0.6,
        maxTokens: min(provider?.maxTokens ?? 1536, 1536),
        streaming: false,
        reasoningEffort: LLMRequest.noThinkingEffort
    )
    let response = try await llm.generate(request)
    guard let draft = ScenarioDraftRule.parse(response.text, prompt: prompt) else {
        throw AppError.unknown(
            "没能生成一个完整的情景（缺标题 / 场景 / 开场白，或目标句不够两句）——换个说法再试一次。"
        )
    }
    try await customScenarioStore.save(draft)
    await reloadCustomScenarios()
    for word in draft.words {
        _ = await vocabulary.add(word: word.word, meaning: word.meaning, source: .scenario)
    }
    return draft
}

/// 按 id 取场景（不存在返回 nil）。
public func scenario(id: String) -> Scenario? {
    availableScenarios().first { $0.id == id }
}

// MARK: - 情景主线任务进度（需求 3 / 5）

public func questProgress(scenarioID: String) async -> ScenarioQuestRecord? {
    guard let learning else { return nil }
    return try? await learning.questProgress(scenarioID: scenarioID)
}

/// 全部情景的主线任务进度，按情景 id 索引（大树与情景卡片一次取完）。
public func allQuestProgress() async -> [String: ScenarioQuestRecord] {
    guard let learning else { return [:] }
    let records = (try? await learning.allQuestProgress()) ?? []
    return Dictionary(uniqueKeysWithValues: records.map { ($0.scenarioID, $0) })
}

public func saveQuestProgress(_ record: ScenarioQuestRecord) async {
    guard let learning else {
        await recordPersistenceFailure("保存情景任务进度", nil)
        return
    }
    do {
        try await learning.saveQuestProgress(record)
    } catch {
        await recordPersistenceFailure("保存情景任务进度", error)
    }
}

/// 清掉某情景的主线任务进度（重练这一关时调用）。
public func clearQuestProgress(scenarioID: String) async {
    guard let learning else {
        await recordPersistenceFailure("重练这一关", nil)
        return
    }
    // 重练是**不可逆删除**：删不掉却已推进到重练态，下次进情景状态就是错的。
    do {
        try await learning.clearQuestProgress(scenarioID: scenarioID)
    } catch {
        await recordPersistenceFailure("重练这一关", error)
    }
}

/// 某情景最近一次复盘（「任务前情提要」的原料）。
public func latestScenarioReview(scenarioID: String) async -> SessionReview? {
    guard let learning else { return nil }
    return try? await learning.latestReview(scenarioID: scenarioID)
}

/// 合成「任务前情提要」（纯本地读库，**不发起任何模型请求**）。
public func scenarioBriefing(for scenario: Scenario) async -> ScenarioBriefing {
    let record = await questProgress(scenarioID: scenario.id)
    let review = await latestScenarioReview(scenarioID: scenario.id)
    return ScenarioBriefingBuilder.build(
        scenario: scenario,
        questDone: record?.doneStepSet ?? [],
        review: review
    )
}
}
