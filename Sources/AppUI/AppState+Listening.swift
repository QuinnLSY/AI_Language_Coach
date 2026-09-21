import AIDomain
import AIServices
import Foundation

// MARK: - 无文本听力（精听 / 听写，进阶 ④）
//
// 这一层只做三件事：**发声音**、**收学员写的那句**、**记账**。
// 判分与分档全在 `AIDomain.ListeningRule`（纯函数），因此「对着原文打分」
// 这一段不发起任何模型请求 —— 听力练习的作答与跟读一样，必须是零成本的。

extension AppState {

    /// 当天账本的持久化键（UserDefaults：`dayKey + [句 id: 最佳准确率]`，几十字节）。
    static let listeningLogStorageKey = "listening.log"

    /// 读账本。⚠️ 加载后必须过一道 `rolledOver`：跨天不清，昨天写对的句子
    /// 会算进今天的进度里 —— 那种错不会报错，只会让人困惑「今天明明是 0 句」。
    static func loadListeningLog() -> ListeningLog {
        guard let data = UserDefaults.standard.data(forKey: listeningLogStorageKey),
              let decoded = try? JSONDecoder().decode(ListeningLog.self, from: data)
        else { return ListeningLog.today() }
        return decoded.rolledOver()
    }

    private func saveListeningLog() {
        guard let data = try? JSONEncoder().encode(listeningLog) else { return }
        UserDefaults.standard.set(data, forKey: Self.listeningLogStorageKey)
    }

    /// 当前这一句。
    public var currentListeningDrill: ShadowingDrill? {
        guard listeningRound.indices.contains(listeningIndex) else { return nil }
        return listeningRound[listeningIndex]
    }

    // MARK: 会话

    /// 开一轮听写。
    ///
    /// 素材就是**今天跟读的那一批**（`shadowingDrills`）—— 不另起一条生成链路：
    /// 同一批句子，先听写再跟读，或者反过来，都比每次重新生成更省事也更连贯。
    /// 一轮取 `ListeningRule.roundSize` 句，按日期轮转（同一天稳定、隔天不重样）。
    public func startListeningDrill() async {
        if shadowingDrills.isEmpty { await loadShadowing() }
        let round = ListeningRule.round(from: shadowingDrills)
        guard !round.isEmpty else {
            listeningNotice = "还没有可听写的句子 —— 跟读页拿到今日素材后就能开始。"
            return
        }
        listeningRound = round
        listeningIndex = 0
        listeningAttempts = []
        listeningResult = nil
        listeningSummary = nil
        listeningDraft = ""
        listeningPlayCount = 0
        listeningNotice = nil
        isListeningDrill = true
    }

    /// 放这一句（无文本）。
    ///
    /// 复用跟读的朗读链路：同一个声音、同一个语言标记、同一个分句流水线 ——
    /// 精听与跟读听到的必须是**同一把声音**，否则「换了个音就听不懂」会混进听力成绩里。
    public func playListeningPrompt() async {
        guard let drill = currentListeningDrill else { return }
        // ⚠️ 问真源而不是界面快照（同 `playShadowingExample`）：巡检把 TTS 挂起后，
        // 快照还说在跑 → 跳过自动恢复 → 用户听到的是「点了没反应」。
        _ = (try? await services.resumeIfSuspended(.tts)) ?? false
        await syncModelRunStates()
        guard await services.isModelRunning(.tts) else {
            listeningNotice = "\(await services.modelLabel(for: .tts)) 已关闭，请到设置里点绿色的「启动」后再听。"
            return
        }
        listeningNotice = nil
        listeningIsPlaying = true
        defer { listeningIsPlaying = false }
        let selection = await services.effectiveSpeechVoiceSelection()
        let base = Float(product.speechRate)
        await services.shadowing.playReference(
            drill,
            selection: selection,
            language: ShadowingService.practiceLanguage,
            rate: listeningSlowPlayback ? base * ListeningRule.slowRateFactor : base
        )
        // 听得出来的遍数才算一遍：播放失败提示挂上去了，就不该把这一次记进账。
        if let error = await services.shadowing.lastError() {
            listeningNotice = error
            return
        }
        listeningPlayCount += 1
    }

    /// 切换慢速播放（下一次播放生效）。慢速是**手段不是成绩** ——
    /// 用过慢速的次数会跟着记录走，但不会因此扣分。
    public func toggleListeningSlowPlayback() {
        listeningSlowPlayback.toggle()
    }

    public func stopListeningAudio() async {
        await services.shadowing.stopAudio()
        listeningIsPlaying = false
    }

    /// 交卷：逐词对照 + 记账。**零模型请求**（纯函数比对）。
    ///
    /// ⚠️ 提交后**停在这一句**给出对照，要用户点「下一句」才推进 ——
    /// 一交就跳走，等于没告诉他哪几个词没听出来，那样写一百句也长不了耳朵。
    public func submitListeningDraft() {
        guard let drill = currentListeningDrill else { return }
        let typed = listeningDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else {
            listeningNotice = "先把你听到的那句写下来 —— 空着交等于没听。"
            return
        }
        let comparison = ShadowingScorer.compare(reference: drill.text, recognized: typed)
        let attempt = ListeningAttempt(
            drillID: drill.id,
            reference: drill.text,
            translation: drill.translation,
            typed: typed,
            comparison: comparison,
            playCount: listeningPlayCount,
            usedSlowRate: listeningSlowPlayback
        )
        listeningResult = attempt
        listeningAttempts.append(attempt)
        listeningLog = listeningLog.recording(drillID: drill.id, accuracy: comparison.accuracy)
        saveListeningLog()
        listeningNotice = nil
    }

    /// 看过对照 → 下一句（最后一句之后直接结算）。
    public func advanceListening() {
        listeningResult = nil
        listeningDraft = ""
        listeningPlayCount = 0
        listeningNotice = nil
        if listeningIndex + 1 < listeningRound.count {
            listeningIndex += 1
        } else {
            finishListeningRound()
        }
    }

    /// 收尾结算。
    ///
    /// 账本**在这里已经不需要再写**（每交一句就记过了）—— 中途退出也不该抹掉
    /// 已经写对的成绩，所以 `exitListeningDrill` 不会回滚账本。
    public func finishListeningRound() {
        listeningSummary = ListeningSummary.from(listeningAttempts)
        listeningResult = nil
        listeningDraft = ""
        listeningPlayCount = 0
    }

    /// 关掉整个听写会话（走完 / 提前退出都走这里）。
    public func exitListeningDrill() {
        isListeningDrill = false
        listeningSummary = nil
        listeningResult = nil
        listeningDraft = ""
        listeningPlayCount = 0
        listeningAttempts = []
        listeningRound = []
    }

    public func dismissListeningNotice() { listeningNotice = nil }

    /// 把这轮「没听出来的词」收进词汇本。
    ///
    /// 为什么值得一个按钮：这些词正是**耳朵过不去**的词（多半是功能词、连读、词尾），
    /// 让它们停在结算卡上，下一次听写还会栽在同一处。
    /// 只加词不查释义（和词典页的「添加复习」同一口径）：零请求，释义在词汇本里点一下就有了。
    public func collectListeningMissedWords() async {
        let words: [String]
        if let summary = listeningSummary, !summary.missedWords.isEmpty {
            words = summary.missedWords
        } else {
            words = listeningAttempts.flatMap(\.missedWords)
        }
        guard !words.isEmpty else {
            listeningNotice = "这一轮没有漏掉的词。"
            return
        }
        var added = 0
        for word in Set(words) {
            let exists = vocabularyEntries.contains {
                $0.word.caseInsensitiveCompare(word) == .orderedSame
            }
            guard !exists else { continue }
            if await services.vocabulary.add(word: word) != nil { added += 1 }
        }
        await reloadVocabulary()
        listeningNotice = added > 0
            ? "已把 \(added) 个词收进词汇本；释义在词汇本里点一下就有。"
            : "这些词都已经在词汇本里了。"
    }
}
