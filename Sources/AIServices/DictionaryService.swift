import AIDomain
import AIInfrastructure
import AIInterfaces
import AppCore
import Foundation

/// 查词请求参数（与词汇本释义同风格：模型名与 token 上限由装配层决定）。
public struct DictionaryLookupOptions: Sendable {
    public var model: String?
    public var maxTokens: Int?

    public init(model: String? = nil, maxTokens: Int? = nil) {
        self.model = model
        self.maxTokens = maxTokens
    }
}

/// 词典（新功能）：词典库（内置三本 + 导入）、模糊匹配、按词查完整条目。
///
/// 职责切分（与词汇本同一套规矩）：
/// - **规则全在领域层纯函数里**：库状态与优先级 `DictionaryLibrary`、匹配 `DictionaryMatcher`、
///   详情解析 `DictionaryDetailRule`、跳转历史 `DictionaryLookupSession`；
/// - 本服务只做编排：读写词典库、调一次 LLM 把词查出来、进程内缓存。
///
/// 缓存口径：**只缓存成功的结果**。查失败（模型没起、解析为空）一律不入缓存 ——
/// 否则用户点一次「重试」会拿到同一个空结果，看着像坏了。
public actor DictionaryService {

    private let llm: LLMManager
    private let store: DictionaryBookStore
    /// 进程内查词缓存（小写词 → 详情）。来回点派生词 / 重查同一个词都不再烧 token。
    private var cache: [String: DictionaryDetail] = [:]

    public init(llm: LLMManager, store: DictionaryBookStore = .shared) {
        self.llm = llm
        self.store = store
    }

    // MARK: - 词典库

    public func library() async -> DictionaryLibrary { await store.state }

    public func books() async -> [DictionaryBook] { await store.visibleBooks }

    /// 内置词典的元数据（恢复入口 / 优先级文案用）。
    public func builtInBooksSnapshot() async -> [DictionaryBook] { await store.builtInBooks }

    public func allBooks() async -> [DictionaryBook] { await store.allBooks }

    /// 今日推荐词源（按优先级排序的词典 id；词组书默认排最前）。
    public func sourceBookIDs() async -> [String] {
        let state = await store.state
        return state.sourceBookIDs(
            builtIns: await store.builtInBooks,
            phraseBookID: DictionaryCatalog.phraseBookID
        )
    }

    public func rank(of bookID: String) async -> Int? { await store.state.rank(of: bookID) }

    /// 每本词典在「每日推荐词源」里的名次（bookID → 名次）。
    public func sourceRanks() async -> [String: Int] { await store.state.priority }

    /// 空查询页上的「试试这些词」：按**固定间隔**取几个。
    ///
    /// 刻意不随机：每次进页面看到的示例词都一样，用户才不会觉得「这页面自己在变」；
    /// 间隔取样又保证它不会每次都只给 a、b、c 那三个词。
    ///
    /// ⚠️ 与 `randomSampleWords` 分工不同：那个是**轮换用的词池**（用户口径改成每 10 秒换一批），
    /// 这个保留给「一页之内不许自己变」的场合（单测仍在守）。
    public func sampleWords(limit: Int = 6) async -> [DictionaryWord] {
        let words = await store.searchableWords()
        guard !words.isEmpty else { return [] }
        let step = max(words.count / max(limit, 1), 1)
        var result: [DictionaryWord] = []
        var index = 0
        while index < words.count, result.count < limit {
            result.append(words[index])
            index += step
        }
        return result
    }

    /// 轮换用的随机词池（每次调用都不一样）。
    ///
    /// 「随机抽 `limit` 个下标」而不是 `shuffled().prefix(limit)`：可见词典上万个词，
    /// 整表打乱的代价纯属浪费；抽下标是 O(limit)。
    public func randomSampleWords(limit: Int = 48) async -> [DictionaryWord] {
        let words = await store.searchableWords()
        guard !words.isEmpty else { return [] }
        guard words.count > limit else { return words.shuffled() }
        var indexes = Set<Int>()
        // 上限 48 个，撞不出死循环；仍然写 `while` + 集合去重，保证不重样。
        while indexes.count < limit {
            indexes.insert(Int.random(in: 0..<words.count))
        }
        return indexes.map { words[$0] }
    }

    @discardableResult
    public func removeBook(id: String) async throws -> DictionaryBook? {
        try await store.removeBook(id: id)
    }

    public func restoreBook(id: String) async throws {
        try await store.restoreBook(id: id)
    }

    public func restoreBuiltIns() async throws {
        try await store.restoreBuiltIns()
    }

    /// 勾选 / 取消「作为每日推荐词源」；返回勾选后的状态。
    @discardableResult
    public func toggleSource(id: String) async throws -> Bool {
        try await store.toggleSource(id: id)
    }

    @discardableResult
    public func importBook(from url: URL, name: String? = nil) async throws -> DictionaryBook {
        try await store.importBook(from: url, name: name)
    }

    /// 全部可见词典的词条数（各书相加；**不去重**，只用于「一本书多少条」这类分账）。
    public func totalWordCount() async -> Int {
        await store.visibleBooks.reduce(0) { $0 + $1.entryCount }
    }

    /// **去重后**的词库规模：跨词典的同名词只算一个（口径与查词 / 联想完全一致）。
    ///
    /// ⚠️ 与 `totalWordCount()` 不是一个数，别混用：三本内置词典各 4,510 / 5,219 / 2,896 条，
    /// 相加 12,625，但按词去重只有 7,404（`say`/`go`/`get` 这类常用词两本都有）。
    /// **面向用户的「词库共多少词」一律用这个数**，否则同一件事会出现两个自相矛盾的数字。
    /// 直接复用 `searchableWords()` 的去重结果（有缓存，不额外扫盘）。
    public func uniqueWordCount() async -> Int {
        await store.searchableWords().count
    }

    // MARK: - 搜索

    /// 模糊匹配（最多 10 条，规则与词汇本联想同一把尺）。
    public func search(_ query: String) async -> [DictionaryWord] {
        DictionaryMatcher.match(query, in: await store.searchableWords())
    }

    /// 每日推荐的选词池（按优先级：一本一个池子）。
    public func recommendationPools() async -> [[DailyWord]] {
        await store.recommendationPools()
    }

    /// 词库里的词条（校验输入是否「像个词」时用）。
    public func knownWord(_ query: String) async -> DictionaryWord? {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        return await store.searchableWords().first { $0.word.lowercased() == needle }
    }

    /// 划到的是**变体**时，用它的本体去词库里找。
    ///
    /// 用户口径：「单词一旦变为复数或 -ing、-ed 等变体就一直显示查不到 —— 应该查出本体」。
    /// 规则（候选怎么推）全在 `WordForm`，这里只负责**拿候选逐个问词库**，
    /// 第一个命中的就是本体（候选顺序 = 可能性顺序）。
    public func baseFormWord(of query: String) async -> (candidate: WordForm.Candidate, word: DictionaryWord)? {
        for candidate in WordForm.candidates(of: query) {
            if let hit = await knownWord(candidate.lemma) {
                return (candidate, hit)
            }
        }
        return nil
    }

    // MARK: - 查词（LLM）

    /// 查一个词的完整条目。命中缓存直接返回（不调模型）。
    ///
    /// 模型不可用 / 解析不出任何内容 → 抛错（UI 给可操作提示），**不写缓存**。
    ///
    /// - Parameter baseFormHints: 变体词的候选原形。只当提示交给模型（见 `PromptBuilder`），
    ///   **不影响缓存键**：键仍是划到的那个写法，用户来回划同一个变体不会重复烧 token。
    public func lookUp(
        _ word: String,
        learningLanguage: String,
        nativeLanguage: String,
        options: DictionaryLookupOptions,
        baseFormHints: [String] = [],
        ignoringCache: Bool = false
    ) async throws -> DictionaryDetail {
        let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw AppError.unknown("没有要查的词") }
        let key = clean.lowercased()
        if !ignoringCache, let cached = cache[key] { return cached }

        let request = LLMRequest(
            messages: [
                LLMMessage(
                    role: .system,
                    content: PromptBuilder.dictionaryLookupPrompt(
                        word: clean,
                        learningLanguage: learningLanguage,
                        nativeLanguage: nativeLanguage,
                        baseFormHints: baseFormHints
                    )
                )
            ],
            model: options.model,
            temperature: 0,
            // 词典条目比词汇本释义长得多（搭配 + 例句 + 派生词），上限给足。
            maxTokens: options.maxTokens ?? 1024,
            streaming: false,
            // 确定性短任务关思考：与翻译同理由。
            reasoningEffort: LLMRequest.noThinkingEffort
        )
        let response = try await llm.generate(request)
        let detail = DictionaryDetailRule.parse(response.text, fallbackWord: clean)
        guard !detail.isEmpty else {
            throw AppError.unknown("模型没有给出可解析的词条，可以再点一次试试")
        }
        cache[key] = detail
        return detail
    }

    /// 已经查过的词（切页 / 回退时先用它占位，避免闪一下空白）。
    public func cached(_ word: String) -> DictionaryDetail? {
        cache[word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }

    /// 清掉查词缓存（重查 / 释放内存用）。
    public func clearCache() { cache.removeAll() }
}
