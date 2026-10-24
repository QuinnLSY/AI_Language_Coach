import AIDomain
import AIInfrastructure
import AIInterfaces
import AppCore
import Foundation

// MARK: - CoachServices · 词汇本与每日推荐（第 24 步）
//
// #660 自 CoachServices.swift 拆出（2026-10-24）：原文件 3165 行单 actor 超载，按域切为扩展。
// 同模块 extension，语义与拆分前完全一致；跨文件调用的成员已从 private 放宽到
// internal（模块内可见，跨模块零影响，public API 不变）。
extension CoachServices {
// MARK: - 词汇本（第 24 步 Vocabulary）

/// 从复盘 new_words 导入生词（按 word 去重）。返回新词数。
@discardableResult
public func importVocabularyFromReviews() async -> Int {
    await vocabulary.importFromReviews()
}

/// 给生词补「详细中文释义 + 例句 + 重点单词」（按需：点按钮才调用）。
/// 详细释义比旧版长，token 上限放宽到 768。
public func defineVocabulary(_ entry: VocabularyEntry) async throws -> VocabularyEntry {
    guard isModelRunning(.llm) else { throw AIProviderError.notInitialized }
    try await ensureLLMReady()
    let provider = await config.current.resolvedProvider(for: .llm)
    let options = VocabularyDefineOptions(
        model: await currentLLMModel(),
        maxTokens: min(provider?.maxTokens ?? 768, 768)
    )
    let configuration = await config.current
    return try await vocabulary.define(
        entry,
        learningLanguage: promptLanguage(configuration),
        nativeLanguage: configuration.product.nativeLanguage,
        options: options
    )
}

// MARK: - 每日推荐词 + 历史词条补全

/// 补齐已落库卡片里缺失的「词性 / 中文」（历史数据：模型当年只回了英文）。
/// 后台静默调用：模型没在跑 / 补不到就返回 nil，不打扰用户。
public func completeVocabularyTerms(_ entry: VocabularyEntry) async -> VocabularyEntry? {
    guard isModelRunning(.llm) else { return nil }
    try? await ensureLLMReady()
    let provider = await config.current.resolvedProvider(for: .llm)
    let options = VocabularyDefineOptions(
        model: await currentLLMModel(),
        maxTokens: min(provider?.maxTokens ?? 256, 256)
    )
    let configuration = await config.current
    return await vocabulary.completeTerms(
        of: entry,
        learningLanguage: promptLanguage(configuration),
        nativeLanguage: configuration.product.nativeLanguage,
        options: options
    )
}

/// 抽一组每日推荐词（3 简单 / 5 中等 / 2 困难 / 2 词组；本地选词，不调模型）。
///
/// **词源来自词典库**：按用户选定的优先级顺序取词（没勾选任何词典时 =
/// 全部可见词典，**词组书排最前**，见 `DictionaryLibrary.sourceBookIDs`）——
/// 词组书只含词组档词条，所以「词组 2 个」这条配额默认由它供货。
/// 词典库被清空（一本书都没有）时才退回随包词库 —— 单本入口的意义就在这里。
///
/// - Parameter seed: 给了就**按天恒定**（`DailySeed.seed(dayKey:language:)`）：
///   同一天多次打开看到同一批词，跨天才换。不给就是真随机 —— 「换一批」走这一条。
public func dailyWordRecommendation(excluding: Set<String> = [], seed: UInt64? = nil) async -> [DailyWord] {
    let pools = await dictionary.recommendationPools()
    if pools.contains(where: { !$0.isEmpty }) {
        return await vocabulary.dailyRecommendation(fromSources: pools, excluding: excluding, seed: seed)
    }
    return await vocabulary.dailyRecommendation(excluding: excluding, seed: seed)
}

/// 每日推荐所用词库的全部词（设置页统计「已学 x / y 词」）。
///
/// 口径跟着**词典库**走：推荐词是从可见词典里抽的，统计的分母就必须是同一批词，
/// 否则会出现「总共 145 词、已学 200 词」这种自相矛盾的数字。
///
/// ⚠️ 合并后**必须按词去重**：每本书各自一份池子，`say`/`go` 这类词几本书里都有，
/// 直接相加会把同一个词算好几遍 —— 分母虚高、和「词库共 N 词」也对不上。
/// （选词侧 `DailyWordPicker` 本来就会去重，这里对齐的是统计口径。）
public func dailyWordBank() async -> [DailyWord] {
    let pools = await dictionary.recommendationPools()
    let merged = pools.flatMap { $0 }
    guard !merged.isEmpty else { return await vocabulary.wordBank() }
    var seen = Set<String>()
    return merged.filter { seen.insert($0.word.lowercased()).inserted }
}

/// 给每日推荐的词补「音标 / 词性 / 中文义项 / 解释 / 例句及翻译 / 近反义 / 重点单词」
/// （按需 LLM，不落库；与词汇本同一套字段）。
public func defineDailyWord(_ word: String) async throws -> VocabularyDefinition {
    guard isModelRunning(.llm) else { throw AIProviderError.notInitialized }
    try await ensureLLMReady()
    let provider = await config.current.resolvedProvider(for: .llm)
    let options = VocabularyDefineOptions(
        model: await currentLLMModel(),
        maxTokens: min(provider?.maxTokens ?? 768, 768)
    )
    let configuration = await config.current
    return try await vocabulary.defineDaily(
        word,
        learningLanguage: promptLanguage(configuration),
        nativeLanguage: configuration.product.nativeLanguage,
        options: options
    )
}
}
