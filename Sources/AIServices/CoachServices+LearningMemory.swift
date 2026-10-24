import AIDomain
import AIInfrastructure
import AIInterfaces
import AIProviders
import AppCore
import Foundation

// MARK: - CoachServices · 跨会话学习记忆与语义索引（第 15 步）
//
// #660 自 CoachServices.swift 拆出（2026-10-24）：原文件 3165 行单 actor 超载，按域切为扩展。
// 同模块 extension，语义与拆分前完全一致；跨文件调用的成员已从 private 放宽到
// internal（模块内可见，跨模块零影响，public API 不变）。
extension CoachServices {

// MARK: - 学习记忆（纠错 / 词汇 / 跟读 → 老师可用的背景）

/// 跨会话学习记忆（第 15 步）：把库里的纠错 / 词汇 / 跟读发音收敛成老师可用的背景。
///
/// 只读本地库、**不发起任何模型请求**（除非给了 `query` 且装配了真实语义索引）。
/// 排序 / 折算口径都在 `MemoryRetriever` 的纯函数里，这里只负责把原始事实取出来。
///
/// - Parameter query: 学员当前这句话。给了它、且语义索引可用时，记忆会按**相关度**
///   重排并丢掉明显不相关的条目；否则保持结构化结果（默认 mock 即走这条路）。
public func learningMemory(
    query: String? = nil,
    correctionLimit: Int = 200,
    pronunciationLimit: Int = 100,
    sessionLimit: Int = 500
) async -> LearningMemory {
    guard let learning else { return .empty }
    let corrections = (try? await learning.correctionRecords(since: .distantPast, limit: correctionLimit)) ?? []
    let vocabulary = (try? await learning.allVocabulary()) ?? []
    let attempts = (try? await learning.recentShadowingAttempts(limit: pronunciationLimit)) ?? []
    let sessions = (try? await learning.recentSessions(limit: sessionLimit)) ?? []
    let memory = MemoryRetriever.brief(
        corrections: corrections,
        vocabulary: vocabulary,
        reports: attempts.compactMap(\.pronunciation),
        sessionCount: sessions.count,
        sessionFacts: sessionFacts(sessions)
    )
    guard let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !memory.isEmpty else {
        return memory
    }
    await ensureEmbeddingReady()
    // mock 的向量没有语义，按它排序等于乱排 —— 只认真实 runtime。
    guard await embedding.supportsSemanticRanking else { return memory }
    return await semanticallyRanked(memory, query: query) ?? memory
}

/// 清除学习记忆（**不可逆**）：删掉喂给老师的纠错 / 复盘 / 跟读 / 复习流水。
///
/// 两道保险：
/// - **删除前自动留底**：把整个数据目录打包一份（标记「清除前」）。
///   留底失败就中止删除 —— 宁可清不成，不可白删；
/// - 没有可删的内容时**直接返回**，不制造空留底（那只会让备份目录堆垃圾）。
///
/// 库不可用时**报错而不是返回 0** —— 说「删掉了 0 条」会让人以为真的清干净了。
@discardableResult
public func clearLearningMemory() async throws -> MemoryClearance {
    guard let learning else { throw AppError.database("学习库尚未就绪") }
    let counts = try await learning.learningMemoryCounts()
    guard counts.total > 0 else { return counts }
    // 只有磁盘上真有可保护的文件时才留底（`:memory:` 库没有落盘文件，留无可留）。
    if await backup.hasAnythingToExport() {
        do {
            _ = try await backup.export(label: "清除前")
        } catch {
            throw AppError.database("清除前自动留底失败，已中止删除（学习记忆原样保留）：\(error.localizedDescription)")
        }
    }
    return try await learning.clearLearningMemory()
}

/// 忘记「同一处反复犯的错」：按指纹删掉它在库里的**全部**记录，返回删掉的条数。
///
/// 与整库清除不同，这里**不做整目录留底** —— 单条删除是学员对着具体某一条
/// 亲手点的，每删一次就打包一份完整备份只会把备份目录堆成垃圾；
/// 界面那边有二次确认兜底。出错原样上抛（**绝不 `try?`**），
/// 由 AppState 落成学员可见的提示。
@discardableResult
public func forgetRecurringError(_ error: RecurringError) async throws -> Int {
    guard let learning else { throw AppError.database("学习库尚未就绪") }
    return try await learning.deleteCorrections(matchingOriginal: error.original, corrected: error.corrected)
}

/// 修改「同一处反复犯的错」的改正与说明，返回改掉的条数。
///
/// **原句不可改**（学员当时真实说出的话，改了就是伪造历史），可改的只有
/// 老师给的改正与解释 —— 「老师这次改错了」是学员修记忆的唯一入口。
@discardableResult
public func editRecurringError(
    _ error: RecurringError,
    corrected: String,
    explanation: String
) async throws -> Int {
    guard let learning else { throw AppError.database("学习库尚未就绪") }
    return try await learning.updateCorrections(
        matchingOriginal: error.original,
        corrected: error.corrected,
        newCorrected: corrected,
        explanation: explanation
    )
}

/// 把会话记录折成记忆检索要的事实：纠错条数取会话自带的纠错，话题取情景标题。
///
/// **没绑情景的普通练习不编话题** —— 拿模式名或时间拼一个，等于让老师「以为」
/// 学员在练某个话题，那是编造不是记忆。
private func sessionFacts(_ sessions: [SessionSummary]) -> [MemorySessionFact] {
    sessions.map { session in
        let topic = session.scenarioID.flatMap { scenario(id: $0)?.title }
        return MemorySessionFact(
            startedAt: session.startedAt,
            topic: topic,
            correctionCount: session.corrections.count,
            messageCount: session.messageCount
        )
    }
}

/// 按与 `query` 的语义相似度重排记忆。任何失败都返回 nil（调用方保留结构化结果）——
/// 语义索引是增强，绝不能因为它挂了就让老师失忆。
private func semanticallyRanked(_ memory: LearningMemory, query: String) async -> LearningMemory? {
    let errors = memory.recurringErrors
    let words = memory.focusWords
    var texts = [query]
    texts.append(contentsOf: errors.map { "\($0.original) -> \($0.corrected)" })
    texts.append(contentsOf: words)
    guard texts.count > 1 else { return memory }
    do {
        let vectors = try await embedding.embed(texts)
        guard vectors.count == texts.count, let queryVector = vectors.first else { return nil }
        var relevance: [String: Double] = [:]
        for (index, error) in errors.enumerated() {
            relevance[error.id] = SemanticRanking.cosineSimilarity(queryVector, vectors[index + 1])
        }
        let wordOffset = 1 + errors.count
        for (index, word) in words.enumerated() {
            relevance[word] = SemanticRanking.cosineSimilarity(queryVector, vectors[wordOffset + index])
        }
        return MemoryRetriever.reranked(memory, relevance: relevance)
    } catch {
        return nil
    }
}

/// 按需装配语义索引（幂等）。
///
/// 每个进程只尝试一次：runtime 没起时不做「每轮重试」的网络风暴；
/// 装配失败就是「没有语义索引」，结构化记忆照常工作，不打扰用户。
/// - Parameter force: 重装配（配置被外部改动后「重新载入」会用到）。
///   不加这个开关的话，第一次装配失败会被记成「本进程已试过」，
///   用户把模型装好、点「重新载入配置」时反而永远接不上。
public func ensureEmbeddingReady(force: Bool = false) async {
    guard force || !embeddingBootstrapAttempted else { return }
    embeddingBootstrapAttempted = true
    guard !(await embedding.isUsable) else { return }
    let configuration = await config.current
    guard let providerConfig = configuration.resolvedProvider(for: .embedding),
          let provider = Self.makeEmbeddingProvider(providerConfig) else { return }
    do {
        try await provider.initialize(config: providerConfig)
        try await provider.load()
        await embedding.register(provider)
        AppLog.info(
            "语义记忆检索已接通：\(providerConfig.id)（\(await embedding.dimensions) 维）",
            category: "memory"
        )
    } catch {
        // ⚠️ 只警告、不弹给用户：语义索引是增强，缺席时结构化记忆照常工作。
        // 常见情形（Ollama 没开 / 没装嵌入模型）都是「用户没要求这项功能」，
        // 拿它去打扰用户，等于用警告换惊吓。
        AppLog.warning("语义索引装配失败（记忆退回结构化路径）: \(error.localizedDescription)", category: "memory")
    }
}

/// 语义记忆检索是否**真的接通**（诊断 / 设置页用）。
///
/// 判据是「装配到了真实 runtime 的嵌入 Provider」：mock 也能给向量，
/// 但那是字符桶计数、没有语义，按它排序会把相关历史随机丢掉（见 `EmbeddingManager`）。
public var isSemanticMemoryEnabled: Bool {
    get async { await embedding.supportsSemanticRanking }
}

// MARK: - 语义索引的运行环境（设置页）

/// 记忆索引（embedding）的本地 / 云端模型发现，与 `availableLLMModels` 同构。
///
/// 不依赖 Manager 的懒加载注册（首次聊天才注册），而是直接从配置构造适配器：
/// 这样设置页打开时就能列出本机 Ollama 的嵌入模型或云端的可选模型，
/// 与「AI 大脑」卡片的本地检测逻辑完全一致。
public func availableEmbeddingModels() async -> [DiscoveredModel] {
    let configuration = await config.current
    guard let providerConfig = configuration.resolvedProvider(for: .embedding),
          let provider = Self.makeEmbeddingProvider(providerConfig) else { return [] }
    do {
        try await provider.initialize(config: providerConfig)
        if let discovered = try? await provider.discoverModels() {
            return discovered
        }
    } catch {
        AppLog.warning("记忆索引模型发现失败（退回候选清单）: \(error.localizedDescription)", category: "memory")
    }
    let candidates = providerConfig.candidateModels
    return candidates.map { DiscoveredModel(id: $0, name: $0) }
}

/// 记忆索引的健康状态（设置页状态点用）。
///
/// 同样从配置直接构造适配器探查，不依赖懒加载注册，
/// 否则设置页打开时还没聊过天就会显示「未注册」。
public func embeddingHealth() async -> ProviderHealth {
    let configuration = await config.current
    guard let providerConfig = configuration.resolvedProvider(for: .embedding),
          let provider = Self.makeEmbeddingProvider(providerConfig) else {
        return .configurationInvalid(reason: "未配置记忆索引")
    }
    do {
        try await provider.initialize(config: providerConfig)
        return await provider.healthCheck()
    } catch {
        return .configurationInvalid(reason: error.localizedDescription)
    }
}

/// 记忆索引的「通没通 + 多少维」（设置页「运行环境」卡）。
///
/// 维度单独给出来，是因为「已接通」三个字回答不了用户的下一个问题：
/// **用的是哪个索引、换模型后会不会变**。装配成功但 runtime 是 mock 时
/// `isSemanticMemoryEnabled` 为 false，这里如实回 0 维。
public func semanticMemoryInfo() async -> (enabled: Bool, dimensions: Int) {
    let enabled = await isSemanticMemoryEnabled
    let dimensions = await embedding.dimensions
    return (enabled, dimensions)
}
}
