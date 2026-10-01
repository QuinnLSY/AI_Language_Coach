import AIDomain
import Foundation

// 跨页全局搜索（#414）：一个输入框查遍词汇本 / 词典 / 对话 / 阅读。
//
// 为什么需要它：四个来源各有自己的筛选框，但「我上次练过那个词在哪」这类问题
// **跨了页** —— 用户不知道该去哪一页找，于是根本不找。搜索的价值不在「多一个入口」，
// 在「不用先知道它在哪一页」。
extension AppState {

    /// 打开搜索面板。
    public func openGlobalSearch() {
        showingGlobalSearch = true
    }

    /// 关闭搜索面板并清空结果（不留上一次的残影）。
    public func closeGlobalSearch() {
        showingGlobalSearch = false
        globalSearchQuery = ""
        globalSearchHits = []
    }

    /// 搜一次（面板里每次输入变化都会调，所以**必须能被打断**）。
    ///
    /// ⚠️ 顺序：先把本次的查询词抓在手里（`needle`），await 回来后只认它 ——
    /// 用户连着敲 "ca" → "cat" → "cats" 时，三个请求会乱序返回，
    /// 谁后到谁写结果的话，界面上就会停在 "ca" 的结果上而不自知。
    public func performGlobalSearch(_ rawQuery: String) async {
        let needle = GlobalSearch.normalize(rawQuery)
        guard !needle.isEmpty else {
            globalSearchHits = []
            return
        }
        isSearchingGlobally = true
        defer { isSearchingGlobally = false }

        // 词汇本是内存里的（进入词汇页才灌满），没灌过就现读一次 —— 只有几百条，不值得为它单独缓存。
        let vocabulary = vocabularyEntries.isEmpty
            ? await services.vocabulary.entries()
            : vocabularyEntries
        async let dictionary = services.dictionarySearch(needle)
        async let messages = services.searchMessages(query: needle)
        let readings = readingEntries.map { $0.passage }

        let hits = GlobalSearch.hits(
            query: needle,
            vocabulary: vocabulary,
            dictionary: await dictionary,
            messages: await messages,
            readings: readings
        )
        // 查询词已经变了：这次的结果作废，别盖掉更新的那一次。
        guard GlobalSearch.normalize(globalSearchQuery) == needle else { return }
        globalSearchHits = hits
    }

    /// 点一条结果：去它所在的那一页。
    ///
    /// 只切页、不做「精确定位到那一条」—— 定位要各页自己撑一套跳转协议，
    /// 而切到正确那一页已经解决了「不知道去哪找」这个真问题。
    public func open(globalSearchHit hit: GlobalSearchHit) async {
        showingGlobalSearch = false
        globalSearchHits = []
        switch hit.kind {
        case .vocabulary:
            await openVocabulary()
        case .dictionary:
            await openDictionaryLookingUp(hit.title)
        case .conversation:
            await openRecords()
        case .reading:
            await openReading()
        }
    }
}
