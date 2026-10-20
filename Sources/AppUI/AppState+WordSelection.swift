import AIDomain
import AIServices
import AppCore
import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - AppState · 划词翻译（悬停/拖选 → 气泡卡）
// #267 自 AppState.swift 拆出（2026-09-20）：单文件 5136 行超载，按域切为扩展。
// 同模块 extension，语义与拆分前完全一致；成员访问级别已放宽到 internal。
extension AppState {
    // MARK: - 划词翻译（悬停 / 拖选 → 气泡卡）

    /// 划词上下文：**三个页面共用这一份**（查词 / 跟读 / 练习）。
    ///
    /// 三处各写一套绑定的话，「朗读走哪条链路」「点了查单词跳到哪」这些口径迟早漂移，
    /// 而症状只会是「同一件事在 A 页好用、在 B 页不一样」。
    public var wordLookupContext: WordLookupContext {
        WordLookupContext(
            card: { [self] text in wordLookupCard(for: text) },
            onProbe: { [self] text in Task { await probeWordLookup(text) } },
            onDismiss: { [self] in clearWordLookupCard() },
            onSpeak: { [self] text in Task { await speak(text) } },
            onStopSpeak: { [self] in Task { await stopSpeaking() } },
            isSpeaking: { [self] text in speakingText == text && speechPhase != .idle },
            onOpenDictionary: { [self] text in Task { await openDictionaryForLookupWord(text) } },
            onAddToReview: { [self] text in Task { await addLookupWordToReview(text) } },
            onRetryLookup: { [self] text in Task { await retryWordLookup(text) } },
            // 按键提示（#619）：读**当前**绑定，不是写死的「⌘D / ⌘R」——
            // 用户在设置里改过键，气泡上那行必须跟着变（同复习卡的纪律）。
            openDictionaryHint: shortcutBinding(for: .wordLookupDictionary).displayString,
            addReviewHint: shortcutBinding(for: .wordLookupAddReview).displayString
        )
    }

    /// 气泡要显示的内容（页面按划到的文字来取，不匹配 → nil，气泡自然不出现）。
    public func wordLookupCard(for text: String) -> WordLookupCard? {
        guard let card = wordLookupCard else { return nil }
        return card.matches(WordLookupQuery.normalize(text)) ? card : nil
    }

    public func clearWordLookupCard() {
        wordLookupCard = nil
        wordLookupTicket += 1
    }

    /// 查不到时在气泡卡上点 ↻ **直接重查**（2026-09-19 用户口径）：
    /// 「同一个词一个会话只问一次」的省钱闸门在这条路上**显式放行** ——
    /// 用户亲手点的重试就是要再问一次，闸门只挡鼠标扫过的误触。
    public func retryWordLookup(_ raw: String) async {
        let text = WordLookupQuery.normalize(raw)
        wordLookupAttempted.remove(WordLookupQuery.key(text))
        // ⚠️ 必须先清卡：`probeWordLookup` 开头有「当前卡已匹配就早退」的闸门，
        // 不清的话失败卡还挂着、重试会被它自己挡回去。
        wordLookupCard = nil
        await probeWordLookup(text)
    }

    /// 划到一段文字（悬停一个词 / 拖选一段）→ 取内容。
    ///
    /// 取数顺序，每一步都是为了「不白花一次模型调用」：
    /// 1. **本地词库**（ECDICT 编出来的三本词典就在进程里）→ 零延迟、零成本；
    /// 2. 本地没有 → 多词走**翻译**、单词走**查词**（查词结果进词典进程内缓存，
    ///    用户接着点右上角「查单词」进那一页时直接命中，不重复问模型）；
    /// 3. 同一个单词同一个会话只问一次 —— 划来划去不重复花钱。
    public func probeWordLookup(_ raw: String) async {
        let text = WordLookupQuery.normalize(raw)
        let key = WordLookupQuery.key(text)
        guard !key.isEmpty else {
            clearWordLookupCard()
            return
        }
        // 同一个词已经出过结果 / 正在查：不重来（鼠标在同一句上微动会反复触发）。
        if let current = wordLookupCard, current.matches(text) { return }

        wordLookupTicket += 1
        let ticket = wordLookupTicket
        let isPhrase = WordLookupQuery.isPhrase(text)

        // ① 本地词库
        if let hit = await services.dictionaryKnownWord(text) {
            guard ticket == wordLookupTicket else { return }
            wordLookupCard = WordLookupCard(
                text: hit.word,
                phonetic: hit.phonetic,
                pos: hit.pos,
                translation: hit.translation,
                isPhrase: isPhrase,
                notice: hit.translation.isEmpty ? "词库里这个词没有中文释义" : nil
            )
            return
        }

        // ② 变体（复数 / -ing / -ed…）：本地词库里查**本体**。
        //
        // 用户口径：「单词一旦变为复数或 -ing、-ed 等变体就一直显示查不到 —— 应该查出
        // 单词的本体，同时解释当前变体相对本体的含义，每一个单词都要能够查到」。
        // 这一步同样零成本：只在本地库里找原形，命中就直接出条目，连模型都不用起。
        if !isPhrase, let base = await services.dictionaryBaseFormWord(of: text) {
            guard ticket == wordLookupTicket else { return }
            wordLookupCard = WordLookupCard(
                text: text,
                phonetic: base.word.phonetic,
                pos: base.word.pos,
                translation: base.word.translation,
                isPhrase: false,
                notice: base.word.translation.isEmpty ? "词库里这个词没有中文释义" : nil,
                lemma: base.word.word,
                formLabel: base.candidate.label
            )
            return
        }

        // ③ 模型没起：如实说一句，并指向「查单词」那条路（内置词典仍可用）。
        guard isModelRunning(.llm) else {
            guard ticket == wordLookupTicket else { return }
            wordLookupCard = WordLookupCard(
                text: text,
                isPhrase: isPhrase,
                notice: "词库里没有「\(text)」。启动 \(await services.modelLabel(for: .llm)) 后这里可以直接查。"
            )
            return
        }

        if !isPhrase, wordLookupAttempted.contains(key) {
            guard ticket == wordLookupTicket else { return }
            wordLookupCard = WordLookupCard(
                text: text,
                notice: "「\(text)」这次没查到，点右上角的 ↻ 再查一次，或用放大镜去词典里翻。"
            )
            return
        }

        wordLookupCard = WordLookupCard(text: text, isLoading: true, isPhrase: isPhrase)
        do {
            if isPhrase {
                let translated = try await services.translate(text, targetLanguage: nativeLanguage)
                guard ticket == wordLookupTicket else { return }
                wordLookupCard = WordLookupCard(
                    text: text, translation: translated, isPhrase: true, isFromModel: true
                )
            } else {
                // 到顶先倒掉再记（#S3-6）：闸门只挡「鼠标扫过的误触」，
                // 被倒掉的那几个词允许再问一次，比让它无限涨划算。
                if wordLookupAttempted.count >= Self.wordLookupAttemptLimit {
                    wordLookupAttempted.removeAll(keepingCapacity: true)
                }
                wordLookupAttempted.insert(key)
                // 变体：把本地推出的候选原形当**提示**带给模型（模型可以否掉）。
                // 这一步是「subtitles / listening 查不到」的正解 —— 之前只把变体本身
                // 丢给模型，它会用一句话解释「这是 subtitle 的复数」，格式就崩了。
                let hints = WordForm.candidates(of: text).prefix(3).map(\.lemma)
                let detail = try await services.dictionaryLookUp(text, baseFormHints: Array(hints))
                guard ticket == wordLookupTicket else { return }
                wordLookupCard = Self.wordLookupCard(from: detail, text: text)
            }
        } catch {
            guard ticket == wordLookupTicket else { return }
            wordLookupCard = WordLookupCard(
                text: text,
                isPhrase: isPhrase,
                notice: "没查到「\(text)」：\(Self.dictionaryFailureMessage(error, word: text))"
            )
        }
    }

    /// 把查词结果压成气泡要的那几行（音标 + 词性 + 中文义项）。
    ///
    /// ⚠️ `text` 是用户**划到的那个写法**，而 `detail.word` 是模型给出的**本体**：
    /// 两者不同时，气泡上多一行「= 本体 · 什么形式」，这就是用户要的
    /// 「解释当前变体相对本体的含义」。形态名称由本地规则倒推（拿不到就不显示）。
    static func wordLookupCard(from detail: DictionaryDetail, text: String) -> WordLookupCard {
        let phonetic = detail.phoneticUS.isEmpty ? detail.phoneticUK : detail.phoneticUS
        let first = detail.senses.first
        let lines = detail.senses.prefix(3).map { sense -> String in
            sense.pos.isEmpty ? sense.text : "\(sense.pos) \(sense.text)"
        }
        let translation = first == nil
            ? ""
            : lines.joined(separator: "\n")
        // 本体优先看 `form:` 那行给的（模型自己判的），没有再退回条目里的 `word:`
        // （`dictionaryLookUp` 传了 fallback，所以 `word` 正常就等于用户查的那个写法）。
        let declared = detail.baseForm.isEmpty ? detail.word : detail.baseForm
        let lemma = declared.trimmingCharacters(in: .whitespaces)
        let isSameWord = lemma.isEmpty || lemma.caseInsensitiveCompare(text) == .orderedSame
        return WordLookupCard(
            text: text,
            phonetic: phonetic,
            // 词性只在**首条义项**上显示一次：气泡只有巴掌大，每条都带词性会挤成一片。
            pos: first?.pos ?? "",
            translation: translation,
            isPhrase: false,
            isFromModel: true,
            lemma: isSameWord ? "" : lemma,
            formLabel: isSameWord ? "" : (WordForm.label(surface: text, lemma: lemma) ?? ""),
            formNote: detail.formNote
        )
    }

    /// 气泡右上角「查单词」：切到词典页并把这个词查出来（命中划词时的缓存则不发请求）。
    public func openDictionaryForLookupWord(_ raw: String) async {
        // 变体先还原成本体再进词典页：`subtitles` 直接搜是搜不到 `subtitle` 这一条的，
        // 用户在气泡上看到的就是本体的释义，进词典却空手而归会显得前后矛盾。
        let normalized = WordLookupQuery.normalize(raw)
        let word = wordLookupCard?.matches(normalized) == true
            ? (wordLookupCard?.lookupWord ?? normalized)
            : normalized
        guard !word.isEmpty else { return }
        clearWordLookupCard()
        await openDictionary()
        dictionaryQuery = word
        await lookUpDictionaryWord(word, pushing: false)
    }

    /// 气泡右上角「添加复习」：加进词汇本，并在气泡里给一句反馈。
    public func addLookupWordToReview(_ raw: String) async {
        let normalized = WordLookupQuery.normalize(raw)
        // 变体收**本体**：单词本里该出现的是 `subtitle`，不是只在一个句子里见过的 `subtitles`。
        let word = wordLookupCard?.matches(normalized) == true
            ? (wordLookupCard?.lookupWord ?? normalized)
            : normalized
        guard !word.isEmpty else { return }
        let existed = vocabularyEntries.contains { $0.word.caseInsensitiveCompare(word) == .orderedSame }
        guard await services.vocabulary.add(word: word) != nil else {
            wordLookupCard?.notice = "「\(word)」没能加入复习列表（为空或没有学习数据库）。"
            return
        }
        await reloadVocabulary()
        wordLookupCard?.notice = existed ? "「\(word)」已经在复习列表里了" : "已把「\(word)」加入复习"
    }

}
