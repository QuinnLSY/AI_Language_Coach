import AIDomain
import AIInterfaces
import AIServices
import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - AppState · 词典（词典库 + 查单词）
// #267 自 AppState.swift 拆出（2026-09-20）：单文件 5136 行超载，按域切为扩展。
// 同模块 extension，语义与拆分前完全一致；成员访问级别已放宽到 internal。
extension AppState {
    // MARK: - 词典（词典库 + 查单词）

    /// 进入词典页。默认停在「查单词」（用户口径），**但不动已有会话**：
    /// 之前查过的词、跳转历史、输入框内容照旧留着。
    public func openDictionary() async {
        applySection(.dictionary)
        await reloadDictionaryLibrary()
    }

    /// 重新读词典库（删 / 恢复 / 改优先级 / 导入之后都走一遍）。
    public func reloadDictionaryLibrary() async {
        dictionaryBooks = await services.dictionaryBooks()
        restorableDictionaries = await services.restorableDictionaryBooks()
        dictionaryWordCount = await services.dictionaryWordCount()
        dictionaryUniqueWordCount = await services.dictionaryUniqueWordCount()
        dictionarySourceRanks = await services.dictionarySourceRanks()
        dictionarySampleWords = await services.dictionarySampleWords().map(\.word)
        dictionarySamplePool = await services.dictionarySamplePool().map(\.word)
    }

    /// 顶栏按钮：查单词 ←→ 词典库。两边状态各自保留，不用重载 ——
    /// 切走再切回来，查词会话（当前词 / 上一页 / 最初那个词）与输入框都还在。
    public func toggleDictionaryMode() async {
        dictionaryMode = dictionaryMode.toggled()
        dictionaryNotice = nil
        dictionaryPendingDelete = nil
        if dictionaryMode == .library {
            await reloadDictionaryLibrary()
        }
    }

    // MARK: 查单词

    /// 输入变化 → 刷新模糊匹配（空输入 = 收起浮层）。
    public func dictionaryQueryChanged() async {
        let query = dictionaryQuery
        // 用户把输入清空 = 这次查询他不要了：**正在跑的请求要真取消**。
        // 不取消的话，它跑完照样把卡片顶上屏 —— 而用户明明已经取消（实测报障）。
        // ⚠️ 这一步必须放在下面那个 `return` 之前：清空后 `dictionaryQuery` 与
        //    `consumedDictionaryQuery` 都是空串，会走「已消费」那条提前返回的短路。
        if normalizedDictionaryQuery(query).isEmpty {
            cancelDictionaryLookup()
        }
        // 这个词已经被查询 / 刚被程序性同步进输入框：收起浮层，也不再联想。
        // 用户下次改动输入框（哪怕只多打一个字母）就会走出这个分支，重新联想。
        if normalizedDictionaryQuery(query) == consumedDictionaryQuery {
            isDictionaryMatchListArmed = false
            dictionaryMatches = []
            return
        }
        // 用户在输入框里动了一下 = 他又在找词了，浮层这一段可以出现。
        isDictionaryMatchListArmed = true
        let matches = await services.dictionarySearch(query)
        // 期间用户可能又敲了、或者中途按了查询：落后一轮的结果一律丢弃，
        // 免得闪现旧匹配 / 把刚收起的浮层又顶出来。
        guard isDictionaryMatchListArmed,
              normalizedDictionaryQuery(dictionaryQuery) != consumedDictionaryQuery,
              query == dictionaryQuery
        else { return }
        dictionaryMatches = matches
    }

    /// 匹配 / 消费判定都走同一把尺：首尾空白不算区别。
    func normalizedDictionaryQuery(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 收起匹配浮层（点「查询」/ 选中一条 / 清空之后）。
    public func dismissDictionaryMatches() {
        consumedDictionaryQuery = normalizedDictionaryQuery(dictionaryQuery)
        isDictionaryMatchListArmed = false
        dictionaryMatches = []
    }

    /// 用户**点回输入框**：把「已消费」这笔撤掉，重新联想一次。
    ///
    /// 用户口径：「查到之后自动隐藏，鼠标再次点击输入框时才浮现」—— 后半个动作
    /// 就靠这条。视图那边挂的是 `simultaneousGesture`（不抢输入框自己的那次点击）。
    public func rearmDictionaryMatches() async {
        consumedDictionaryQuery = nil
        await dictionaryQueryChanged()
    }

    /// 展示页出现哪个词，输入框里就是哪个词（用户口径：**任何情况下都同步**）。
    ///
    /// ⚠️ 同步的同时必须把这一笔记成「已消费」：否则这次**程序性**赋值会触发
    /// 视图上的 `.onChange`，凭空弹回一层联想浮层 —— 看着就像「跳转之后浮层
    /// 自己冒出来」（正是 09-16 那张截图里的样子）。
    func syncDictionaryQueryToDisplayedWord() {
        guard let word = dictionaryLookup.currentWord else { return }
        let clean = normalizedDictionaryQuery(word)
        consumedDictionaryQuery = clean
        isDictionaryMatchListArmed = false
        dictionaryMatches = []
        if dictionaryQuery != clean { dictionaryQuery = clean }
    }

    /// 点「查询」按钮或回车：查输入框里的词。
    /// **不清空输入框**（用户口径）—— 查完还能就着它改一两个字母再查。
    public func submitDictionaryQuery() async {
        let word = normalizedDictionaryQuery(dictionaryQuery)
        guard !word.isEmpty else { return }
        // 先记「消费掉」再清列表：浮层收起，也不会被在途的联想请求重新顶出来。
        consumedDictionaryQuery = word
        dictionaryMatches = []
        await lookUpDictionaryWord(word, pushing: false)
    }

    /// 点中一条匹配项：**直接查那一条**（不是把输入框改掉再等用户点查询）。
    public func selectDictionaryMatch(_ match: DictionaryWord) async {
        // 顺序要紧：`dictionaryQuery` 一改会触发一次新的联想（onChange），
        // 得先把「这个词已消费」记下，那次联想才会自己收起来。
        consumedDictionaryQuery = match.word
        dictionaryQuery = match.word
        dictionaryMatches = []
        await lookUpDictionaryWord(match.word, pushing: false)
    }

    /// 从别处（复习卡 / 划词卡）跳到词典页并**直接查这个词**。
    ///
    /// ⚠️ 刻意不走 `openDictionary()`：那个还要 `reloadDictionaryLibrary()`（重读整份
    /// 词典库，只有导入 / 删库 / 改优先级才需要）。跳转场景走它等于让用户白等一次重载。
    ///
    /// ⚠️ 顺序要紧：**先切页、后查询**。词典页的联想/展示挂在页面的 `onChange` 上，
    /// 页面还没挂载就发查询，那一次会被丢掉（表现是「跳过去了但停在空态」）。
    public func openDictionaryLookingUp(_ word: String) async {
        let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            await openDictionary()
            return
        }
        applySection(.dictionary)
        // 落在「查单词」而不是「词典库」：跳过来的意图就是查这**一个**词。
        dictionaryMode = .search
        await lookUpDictionaryWord(clean, pushing: false)
    }

    /// 点详情里可跳转的词（派生词 / 近义词 / 反义词）→ 压栈查它。
    public func openDictionaryRelated(_ word: String) async {
        await lookUpDictionaryWord(word, pushing: true)
    }

    /// 查一个词并展示。
    ///
    /// - `pushing == false`：这是「重新查一个词」，历史从它重新开始；
    /// - `pushing == true`：这是「从当前条目点进去的词」，压栈 → 左上角出现「返回上一页」。
    ///
    /// 历史**先动、请求后发**：页面立刻切到目标词（转圈），而不是让用户盯着上一页发呆。
    public func lookUpDictionaryWord(_ word: String, pushing: Bool, ignoringCache: Bool = false) async {
        let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        dictionaryNotice = nil

        if pushing {
            dictionaryLookup.push(clean)
        } else {
            dictionaryLookup.begin(clean)
        }
        // 展示页换了词 → 输入框跟着换（跳转来的词也一样），顺带收起浮层。
        syncDictionaryQueryToDisplayedWord()

        // 已经查过（进程内缓存 / 本次会话缓存）：立刻展示，不再发请求。
        if !ignoringCache {
            if let cached = await services.dictionaryCached(clean) {
                dictionaryLookup.cache(cached)
                return
            }
            if dictionaryLookup.detail(for: clean) != nil { return }
        }

        dictionaryLoadingWord = clean
        dictionaryLookupGeneration += 1
        let generation = dictionaryLookupGeneration
        // ⚠️ 包成 `Task` 是为了**留一个能取消的句柄**：`cancelDictionaryLookup()` 拿它 cancel，
        //    底层那次 HTTP 请求会跟着被中断（不再白跑一趟、也不再烧额度）。
        let task = Task { try await services.dictionaryLookUp(clean, ignoringCache: ignoringCache) }
        dictionaryLookupTask = task
        defer {
            // 只有「还是我这一轮」才清：晚到的旧请求不许踩掉新请求的状态。
            if dictionaryLookupGeneration == generation {
                dictionaryLoadingWord = nil
                dictionaryLookupTask = nil
            }
        }
        do {
            let detail = try await task.value
            dictionaryLookup.cache(detail)
        } catch is CancellationError {
            // 用户自己取消的（清空输入 / 换了查询词）：静默收场 ——
            // 不留错误提示，也不把结果顶上屏。
        } catch {
            dictionaryNotice = Self.dictionaryFailureMessage(error, word: clean)
        }
    }

    /// 取消正在跑的那次查词（用户清空输入 = 这次查询他不要了）。
    ///
    /// 三件事一起做，缺一不可：
    /// ① 取消请求（真的中断，不是只把结果丢掉）；
    /// ② 收掉「正在查…」的转圈 —— 请求不会再回来了，不收就永远转着；
    /// ③ 把**还没拿到结果的当前页**撤掉（撤回上一页 / 回到空态）——
    ///    已经查到的词不动，缓存也留着。
    public func cancelDictionaryLookup() {
        guard dictionaryLookupTask != nil || dictionaryLoadingWord != nil else { return }
        dictionaryLookupTask?.cancel()
        dictionaryLookupTask = nil
        dictionaryLoadingWord = nil
        dictionaryLookupGeneration += 1
        dictionaryLookup.discardPendingCurrent()
    }

    /// 忽略缓存重查当前这个词（模型这次给的条目不好用时用）。
    public func relookUpDictionaryWord() async {
        guard let word = dictionaryLookup.currentWord else { return }
        await lookUpDictionaryWord(word, pushing: false, ignoringCache: true)
    }

    /// 回到上一页（左上角左箭头）。
    public func goBackDictionary() async {
        guard dictionaryLookup.canGoBack else { return }
        dictionaryLookup.goBack()
        dictionaryNotice = nil
        // 换页也是「展示页换了词」，输入框一样要跟上。
        syncDictionaryQueryToDisplayedWord()
        await ensureCurrentDictionaryDetail()
    }

    /// 一键回到最初查的那个词（多层跳转时才有这个按钮）。
    public func returnToDictionaryOrigin() async {
        guard dictionaryLookup.canReturnToOrigin else { return }
        dictionaryLookup.returnToOrigin()
        dictionaryNotice = nil
        syncDictionaryQueryToDisplayedWord()
        await ensureCurrentDictionaryDetail()
    }

    /// 当前页的详情缺失（上次查失败 / 缓存被清）时补一次请求。
    func ensureCurrentDictionaryDetail() async {
        guard let word = dictionaryLookup.currentWord,
              dictionaryLookup.detail(for: word) == nil
        else { return }
        dictionaryLoadingWord = word
        defer { dictionaryLoadingWord = nil }
        do {
            let detail = try await services.dictionaryLookUp(word)
            dictionaryLookup.cache(detail)
        } catch {
            dictionaryNotice = Self.dictionaryFailureMessage(error, word: word)
        }
    }

    /// 查词页右上角「添加复习」：把当前词加进词汇本复习列表。
    public func addDictionaryWordToReview() async {
        guard let word = dictionaryLookup.currentWord else { return }
        if vocabularyEntries.contains(where: { $0.word.caseInsensitiveCompare(word) == .orderedSame }) {
            dictionaryNotice = "「\(word)」已经在词汇本里了。"
            return
        }
        guard await services.vocabulary.add(word: word) != nil else {
            dictionaryNotice = "「\(word)」没能加入复习列表（为空或没有学习数据库）。"
            return
        }
        await reloadVocabulary()
    }

    /// 当前词是否已在词汇本里（右上按钮据此显示「已在词表」）。
    public func dictionaryWordIsInVocabulary(_ word: String) -> Bool {
        vocabularyEntries.contains { $0.word.caseInsensitiveCompare(word) == .orderedSame }
    }

    // MARK: 词典库

    /// 点删除：第一次只是进入「确认」态（删除不可逆，导入的书连文件一起删）。
    public func requestRemoveDictionary(id: String) {
        dictionaryPendingDelete = dictionaryPendingDelete == id ? nil : id
        dictionaryNotice = nil
    }

    public func cancelRemoveDictionary() {
        dictionaryPendingDelete = nil
    }

    /// 再点一次 → 真删。
    public func confirmRemoveDictionary(id: String) async {
        dictionaryPendingDelete = nil
        do {
            let removed = try await services.removeDictionaryBook(id: id)
            await reloadDictionaryLibrary()
            await refreshDailyWordsAfterDictionaryChange()
            if let removed {
                dictionaryNotice = removed.isBuiltIn
                    ? "已把「\(removed.name)」从书架取下。内置词典不会丢，随时能在下面点回来。"
                    : "已删除导入的词典「\(removed.name)」，文件也一并删掉了。"
            }
        } catch {
            dictionaryNotice = error.localizedDescription
        }
    }

    /// 恢复一本被删的内置词典。
    public func restoreDictionary(id: String) async {
        do {
            try await services.restoreDictionaryBook(id: id)
            await reloadDictionaryLibrary()
            await refreshDailyWordsAfterDictionaryChange()
            dictionaryNotice = "「\(dictionaryBooks.first { $0.id == id }?.name ?? "词典")」已放回书架。"
        } catch {
            dictionaryNotice = error.localizedDescription
        }
    }

    /// 一键恢复全部内置词典。
    public func restoreBuiltInDictionaries() async {
        do {
            try await services.restoreBuiltInDictionaries()
            await reloadDictionaryLibrary()
            await refreshDailyWordsAfterDictionaryChange()
            dictionaryNotice = "内置词典已全部放回书架。"
        } catch {
            dictionaryNotice = error.localizedDescription
        }
    }

    /// 勾选 / 取消「作为每日推荐词源」。取消后名次自动补位，不留空洞。
    public func toggleDictionarySource(id: String) async {
        do {
            let on = try await services.toggleDictionarySource(id: id)
            await reloadDictionaryLibrary()
            await refreshDailyWordsAfterDictionaryChange()
            guard let book = dictionaryBooks.first(where: { $0.id == id }) else { return }
            if on, let rank = await services.dictionaryRank(of: id) {
                dictionaryNotice = "「\(book.name)」现在是每日推荐的词源，优先级 \(rank)。"
            } else {
                dictionaryNotice = "「\(book.name)」不再作为每日推荐的词源。一本都没选时，全部词典都参与推荐。"
            }
        } catch {
            dictionaryNotice = error.localizedDescription
        }
    }

    /// 导入一本词典（JSON；只有 word 必填，见词典库页的格式气泡）。
    public func importDictionary(from url: URL) async {
        isImportingDictionary = true
        defer { isImportingDictionary = false }
        do {
            let book = try await services.importDictionary(from: url)
            await reloadDictionaryLibrary()
            await refreshDailyWordsAfterDictionaryChange()
            dictionaryNotice = "已导入「\(book.name)」，共 \(book.entryCount) 词。"
        } catch {
            dictionaryNotice = "导入失败：\(error.localizedDescription)"
        }
    }

    /// 词源变了（删 / 恢复 / 改优先级）：每日推荐重新抽一批，否则本页推荐还是旧词典的词。
    func refreshDailyWordsAfterDictionaryChange() async {
        guard dailyWordsLoaded || !dailyWords.isEmpty else { return }
        await refreshDailyWords()
    }

    public func dismissDictionaryNotice() {
        dictionaryNotice = nil
    }

    /// 查词失败时给一句**能照着做**的话：模型没起 ≠ 这个词查不到。
    static func dictionaryFailureMessage(_ error: Error, word: String) -> String {
        if let providerError = error as? AIProviderError, providerError == .notInitialized {
            return "AI 大脑还没启动，先在设置里点绿色的「启动」，再来查「\(word)」。"
        }
        return "「\(word)」没查到：\(error.localizedDescription)"
    }

}
