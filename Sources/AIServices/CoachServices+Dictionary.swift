import AIDomain
import AIInfrastructure
import AIInterfaces
import AppCore
import Foundation

// MARK: - CoachServices · 词典库与查词
//
// #660 自 CoachServices.swift 拆出（2026-10-24）：原文件 3165 行单 actor 超载，按域切为扩展。
// 同模块 extension，语义与拆分前完全一致；跨文件调用的成员已从 private 放宽到
// internal（模块内可见，跨模块零影响，public API 不变）。
extension CoachServices {
// MARK: - 词典（词典库 + 查词）

/// 词典库里可见的书（内置去掉用户删掉的 + 用户导入的），已按优先级排好序。
public func dictionaryBooks() async -> [DictionaryBook] {
    await dictionary.books()
}

/// 被用户删掉、**还能恢复**的内置词典。
public func restorableDictionaryBooks() async -> [DictionaryBook] {
    let state = await dictionary.library()
    return state.restorableBuiltIns(builtIns: await dictionary.builtInBooksSnapshot())
}

/// 模糊匹配（最多 10 条）。
public func dictionarySearch(_ query: String) async -> [DictionaryWord] {
    await dictionary.search(query)
}

/// 词库速查（**不起模型、不花钱**）：只查内置 / 导入词典里有没有这个词。
///
/// 划词气泡的第一站：鼠标扫过一个词时先问它，命中就直接出音标与中文，
/// 不必为一句话里的每个常见词都花一次模型调用。
public func dictionaryKnownWord(_ query: String) async -> DictionaryWord? {
    await dictionary.knownWord(query)
}

/// 划到的是变体时，用它的本体去词库速查（`subtitles` → `subtitle`）。
///
/// 与 `dictionaryKnownWord` 一样零成本、零延迟 —— 划词主路径上先走这两条，
/// 命中就完全不用起模型。
public func dictionaryBaseFormWord(of query: String) async -> (candidate: WordForm.Candidate, word: DictionaryWord)? {
    await dictionary.baseFormWord(of: query)
}

/// 查一个词的完整条目（按需 LLM；命中进程内缓存则不发请求）。
public func dictionaryLookUp(
    _ word: String,
    ignoringCache: Bool = false,
    baseFormHints: [String] = []
) async throws -> DictionaryDetail {
    guard isModelRunning(.llm) else { throw AIProviderError.notInitialized }
    try await ensureLLMReady()
    let provider = await config.current.resolvedProvider(for: .llm)
    let options = DictionaryLookupOptions(
        model: await currentLLMModel(),
        // 词典条目含搭配 / 例句 / 派生词，比词汇本释义长：上限给到 1024。
        maxTokens: min(provider?.maxTokens ?? 1024, 1024)
    )
    let configuration = await config.current
    return try await dictionary.lookUp(
        word,
        learningLanguage: promptLanguage(configuration),
        nativeLanguage: configuration.product.nativeLanguage,
        options: options,
        baseFormHints: baseFormHints,
        ignoringCache: ignoringCache
    )
}

/// 某本词典在「每日推荐词源」里的名次（没被选作词源 → nil）。
public func dictionaryRank(of id: String) async -> Int? {
    await dictionary.rank(of: id)
}

/// 每本词典的名次表（书封面上的优先级框显示用）。
public func dictionarySourceRanks() async -> [String: Int] {
    await dictionary.sourceRanks()
}

/// 空查询页的「试试这些词」（从可见词典里间隔取，不随机）。
public func dictionarySampleWords(limit: Int = 6) async -> [DictionaryWord] {
    await dictionary.sampleWords(limit: limit)
}

/// 「试试这些词」的**轮换词池**（随机抽，每次都不一样）。
///
/// 页面上那一排胶囊每 10 秒换一批，换的时候不该再去查一次库 —— 一次取一批放内存里慢慢用。
public func dictionarySamplePool(limit: Int = 48) async -> [DictionaryWord] {
    await dictionary.randomSampleWords(limit: limit)
}

/// 已缓存的查词结果（切页 / 回退时先占位，不闪空白）。
public func dictionaryCached(_ word: String) async -> DictionaryDetail? {
    await dictionary.cached(word)
}

/// 删掉一本词典（内置只隐藏可恢复；导入的连文件一起删）。
@discardableResult
public func removeDictionaryBook(id: String) async throws -> DictionaryBook? {
    try await dictionary.removeBook(id: id)
}

/// 恢复一本内置词典。
public func restoreDictionaryBook(id: String) async throws {
    try await dictionary.restoreBook(id: id)
}

/// 一键恢复全部内置词典。
public func restoreBuiltInDictionaries() async throws {
    try await dictionary.restoreBuiltIns()
}

/// 勾选 / 取消「作为每日推荐词源」（取消后名次自动补位）。
@discardableResult
public func toggleDictionarySource(id: String) async throws -> Bool {
    try await dictionary.toggleSource(id: id)
}

/// 导入一本词典（JSON，只有 word 必填）。
@discardableResult
public func importDictionary(from url: URL, name: String? = nil) async throws -> DictionaryBook {
    try await dictionary.importBook(from: url, name: name)
}

/// 可见词典的词条总数（页头统计 / 设置页分母）。
public func dictionaryWordCount() async -> Int {
    await dictionary.totalWordCount()
}

/// **去重后**的词库规模（跨词典同名词只算一个）。UI 上「词库共 N 词」都用它。
public func dictionaryUniqueWordCount() async -> Int {
    await dictionary.uniqueWordCount()
}
}
