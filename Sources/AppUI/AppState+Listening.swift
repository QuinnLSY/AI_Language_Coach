import AIDomain
import AIServices
import Foundation

// MARK: - 听力（#308 #309：独立成页，三种形式共用一批句子）
//
// 这一层只做四件事：**发声音**、**收学员的作答**、**判分**、**记账**。
// 判分与分档全在 `AIDomain`（纯函数），因此三种形式都是**零模型请求** ——
// 听力练习的作答不该为「对个答案」付一次调用。
//
// 三种形式的差别只在「问什么」：
//   · 精听默写 —— 整句写下来，逐词对（`ListeningAttempt`）
//   · 关键词捕捉 —— 只写主干词，看命中几个（`KeywordCapture`）
//   · 听句选义 —— 四个释义挑一个，对或错（`MeaningQuestion`）
// 三者共用：同一批句子（今天的跟读素材）、同一条播放链路、同一本当天账本。

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

    // MARK: 进页

    /// 进听力页：素材与跟读**同一批**（今天的句子），进页即开一轮。
    ///
    /// 已经在一轮里就直接接着练 —— 切走再回来不该把进度丢掉
    /// （与跟读页「停在离开时那句」同一条口径）。
    public func openListening() async {
        applySection(.listening)
        if shadowingDrills.isEmpty { await loadShadowing() }
        guard !isListeningDrill else { return }
        await startListeningDrill()
    }

    /// 换一种练法：**不换句子、不换进度**，只换问法。
    ///
    /// 三种形式本来就是同一批句子的三种问法，换模式时把进度清零
    /// 等于逼人「想换个练法就得从头再来」，而那正是最容易让人放弃的地方。
    public func switchListeningMode(_ mode: ListeningMode) {
        guard mode != listeningMode else { return }
        // S4-3：换形式也要先停声 —— 停在上句的示范音会跟着新形式继续念。
        Task { await stopListeningAudio() }
        listeningMode = mode
        listeningNotice = nil
        guard isListeningDrill else { return }
        resetAnswerState()
        if mode == .meaning { prepareMeaningQuestion() }
    }

    // MARK: 一轮

    /// 开一轮。
    ///
    /// 素材就是**今天跟读的那一批**（`shadowingDrills`）—— 不另起一条生成链路：
    /// 同一批句子，先听写再跟读，或者反过来，都比每次重新生成更省事也更连贯。
    /// 一轮取 `ListeningRule.roundSize` 句，按日期轮转（同一天稳定、隔天不重样）。
    public func startListeningDrill() async {
        if shadowingDrills.isEmpty { await loadShadowing() }
        let round = ListeningRule.round(from: shadowingDrills)
        guard !round.isEmpty else {
            listeningNotice = "还没有可练的句子 —— 跟读页拿到今日素材后就能开始。"
            return
        }
        listeningRound = round
        listeningIndex = 0
        listeningAttempts = []
        listeningKeywordAttempts = []
        listeningMeaningCorrect = []
        listeningMeaningPlays = []
        listeningMeaningMissedWords = []
        listeningSummary = nil
        listeningNotice = nil
        isListeningDrill = true
        resetAnswerState()
        if listeningMode == .meaning { prepareMeaningQuestion() }
    }

    /// 清掉「这一句」的作答态（换句 / 换模式都要清，但不动这一轮的累计）。
    private func resetAnswerState() {
        listeningDraft = ""
        listeningResult = nil
        listeningKeywordDraft = ""
        listeningKeywordResult = nil
        listeningMeaningQuestion = nil
        listeningMeaningSelection = nil
        listeningPlayCount = 0
        listeningNotice = nil
    }

    // MARK: 播放（三种形式共用）

    /// 放这一句（无文本）。
    ///
    /// 复用跟读的朗读链路：同一个声音、同一个语言标记、同一个分句流水线 ——
    /// 精听 / 关键词 / 选义听到的必须是**同一把声音**，否则「换了个音就听不懂」
    /// 会混进听力成绩里。
    public func playListeningPrompt() async {
        guard let drill = currentListeningDrill else { return }
        // ⚠️ S4-3 连点防线：两次点击各起一个 Task，都会在下面第一个 await **之前**进来。
        // `listeningIsPlaying` 原先在「恢复挂起 + 巡检」两步 await 之后才置位，拦不住 →
        // 两路播放叠在一起，而且「听完的遍数」两路各记一遍（遍数虚高）。
        // 把它提到最前面：它同时是「正在放」的唯一真源 ——
        // 按钮据此切成「停止」，切句 / 提交据此置灰。
        guard !listeningIsPlaying else { return }
        listeningIsPlaying = true
        defer { listeningIsPlaying = false }

        // ⚠️ 问真源而不是界面快照（同 `playShadowingExample`）：巡检把 TTS 挂起后，
        // 快照还说在跑 → 跳过自动恢复 → 用户听到的是「点了没反应」。
        _ = (try? await services.resumeIfSuspended(.tts)) ?? false
        await syncModelRunStates()
        guard await services.isModelRunning(.tts) else {
            listeningNotice = "\(await services.modelLabel(for: .tts)) 已关闭，请到设置里点绿色的「启动」后再听。"
            return
        }
        listeningNotice = nil
        // 恢复 / 巡检那两步要等（TTS 冷启动可能好几秒）。这期间用户可能按了「停止」——
        // 那时 `listeningIsPlaying` 已被放下，就别再出声了。
        guard listeningIsPlaying else { return }
        let selection = await services.effectiveSpeechVoiceSelection()
        let base = Float(product.speechRate)
        // 听力示范也是「那个老师」在说话：调门与语气同样要带上（慢速档只再乘一次倍速）。
        let playback = await currentSpeechPlayback()
        await services.shadowing.playReference(
            drill,
            selection: selection,
            language: ShadowingService.practiceLanguage,
            rate: listeningSlowPlayback ? base * ListeningRule.slowRateFactor : base,
            pitch: playback.pitch,
            tone: playback.tone
        )
        // ⚠️ S4-3：这一遍只算在**刚才那一句**头上。播放期间用户可能已经切到下一句
        // （`advanceListening` 会 `resetAnswerState()` 把遍数清零），
        // 不校验就会让新句凭空多出「听了 1 遍」，失败提示也挂到无关的句子上。
        guard currentListeningDrill?.id == drill.id else { return }
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

    // MARK: ① 精听默写

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
        record(drillID: drill.id, accuracy: comparison.accuracy)
        listeningNotice = nil
    }

    // MARK: ② 关键词捕捉

    /// 交卷：只看命中哪几个关键信息词。**零模型请求**（纯函数比对）。
    ///
    /// ⚠️ 一个关键词都没抓住也**照样出对照**（不像精听空着不许交）：
    /// 这个模式问的就是「你抓住了什么」，答「什么都没抓住」本身就是有效答案，
    /// 而屏幕上给出的那几个关键词正是他下一步要盯的东西。
    public func submitListeningKeywords() {
        guard let drill = currentListeningDrill else { return }
        let typed = listeningKeywordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else {
            listeningNotice = "先写几个你听到的词 —— 一个也写不出来也算信息，但得先写出来。"
            return
        }
        let capture = ListeningKeywordRule.capture(
            drillID: drill.id,
            reference: drill.text,
            translation: drill.translation,
            typed: typed,
            playCount: listeningPlayCount
        )
        listeningKeywordResult = capture
        listeningKeywordAttempts.append(capture)
        record(drillID: drill.id, accuracy: capture.hitRatio)
        listeningNotice = nil
    }

    // MARK: ③ 听句选义

    /// 出这一句的题（出不了就往下找一句能出的；整轮都出不了就结算）。
    ///
    /// 判据是 `ListeningMeaningRule.question` 返回 nil —— 释义缺失、或者这一轮里
    /// 凑不出足够的**互不相同**的干扰项。绝不拿空串或重复项凑一道有白送答案的题。
    ///
    /// 内部可见（不是 `private`）：它决定了「哪一句会被跳过」，而这件事**只能**在
    /// 指定好 `listeningRound` 的前提下断言 —— 若是从 `shadowingDrills` 现取一轮，
    /// 句序会随日期轮转，测试就得跟着算日子（`AppState+Shadowing` 里几个
    /// 内部可见的恢复方法同款理由）。
    func prepareMeaningQuestion() {
        var index = listeningIndex
        while listeningRound.indices.contains(index) {
            let drill = listeningRound[index]
            if let question = ListeningMeaningRule.question(for: drill, in: listeningRound) {
                listeningIndex = index
                listeningMeaningQuestion = question
                listeningMeaningSelection = nil
                listeningPlayCount = 0
                return
            }
            index += 1
        }
        // 后面没有能出题的句子了 —— 这一轮到此为止，别把用户留在空题上。
        listeningMeaningQuestion = nil
        finishListeningRound()
    }

    /// 点了一个选项：**点下去即判**，不需要再按提交。
    ///
    /// ⚠️ 已经选过的题再点不算（否则可以一路点到对为止，正确率就没有意义了）。
    public func chooseListeningMeaning(_ index: Int) {
        guard let question = listeningMeaningQuestion,
              let drill = currentListeningDrill,
              listeningMeaningSelection == nil,
              question.options.indices.contains(index)
        else { return }
        listeningMeaningSelection = index
        let correct = question.isCorrect(index)
        listeningMeaningCorrect.append(correct)
        listeningMeaningPlays.append(listeningPlayCount)
        if !correct {
            // 答错的句子：把它那几个关键信息词留下来，结算时一起收进词汇本。
            listeningMeaningMissedWords.append(
                contentsOf: ListeningKeywordRule.keyWords(of: drill.text)
            )
        }
        record(drillID: drill.id, accuracy: correct ? 1 : 0)
        listeningNotice = nil
    }

    // MARK: 推进 / 结算

    /// 看过对照 → 下一句（最后一句之后直接结算）。
    public func advanceListening() {
        // S4-3：切句先停声。播放中那颗「下一句」已经置灰，这里是其它入口
        // （键盘 / 结算路径）的兜底 —— 留着上句的示范音，按钮归属却已经换到新句，
        // 用户按新句的「停止」停不掉正在念的旧句。
        Task { await stopListeningAudio() }
        if listeningIndex + 1 < listeningRound.count {
            listeningIndex += 1
            resetAnswerState()
            if listeningMode == .meaning { prepareMeaningQuestion() }
        } else {
            resetAnswerState()
            finishListeningRound()
        }
    }

    /// 收尾结算。
    ///
    /// 账本**在这里已经不需要再写**（每交一句就记过了）—— 中途退出也不该抹掉
    /// 已经写对的成绩，所以 `exitListeningDrill` 不会回滚账本。
    public func finishListeningRound() {
        switch listeningMode {
        case .dictation:
            listeningSummary = .from(listeningAttempts)
        case .keyword:
            listeningSummary = .keyword(from: listeningKeywordAttempts)
        case .meaning:
            let plays = listeningMeaningPlays.isEmpty
                ? 0
                : Double(listeningMeaningPlays.reduce(0, +)) / Double(listeningMeaningPlays.count)
            listeningSummary = .meaning(
                correct: listeningMeaningCorrect,
                missedWords: listeningMeaningMissedWords,
                averagePlays: plays
            )
        }
        resetAnswerState()
        // 结算完成（走完最后一句）：森林里该有谁竖起耳朵庆祝一下。
        forest.ingest(.moduleCompleted(module: .listening))
    }

    /// 关掉整个听力会话（走完 / 提前退出都走这里）。
    public func exitListeningDrill() {
        // ⚠️ 判据要在清空之前算（`listeningRound` 马上就被清了）：
        // 还没走到最后一句就关掉 = 提前退出，森林目送你而不是庆祝。
        let abandoned = listeningIndex + 1 < listeningRound.count
        isListeningDrill = false
        listeningSummary = nil
        resetAnswerState()
        listeningAttempts = []
        listeningKeywordAttempts = []
        listeningMeaningCorrect = []
        listeningMeaningPlays = []
        listeningMeaningMissedWords = []
        listeningRound = []
        listeningIndex = 0
        if abandoned { forest.ingest(.practiceAbandoned(module: .listening)) }
    }

    public func dismissListeningNotice() { listeningNotice = nil }

    /// 记账（三种形式共用一本当天账本）。
    ///
    /// ⚠️ 共用的理由：三个模式练的是**同一批句子**，比分表要能横向比；
    /// 各记各的账会得到三份「今天 3 句」，加起来还没有意义。
    private func record(drillID: String, accuracy: Double) {
        listeningLog = listeningLog.recording(drillID: drillID, accuracy: accuracy)
        saveListeningLog()
    }

    /// 把这一轮「没听出来的词」收进词汇本。
    ///
    /// 为什么值得一个按钮：这些词正是**耳朵过不去**的词（多半是功能词、连读、词尾），
    /// 让它们停在结算卡上，下一次还会栽在同一处。
    /// 只加词不查释义（和词典页的「添加复习」同一口径）：零请求，释义在词汇本里点一下就有了。
    public func collectListeningMissedWords() async {
        let words: [String]
        if let summary = listeningSummary, !summary.missedWords.isEmpty {
            words = summary.missedWords
        } else {
            words = listeningAttempts.flatMap(\.missedWords)
                + listeningKeywordAttempts.flatMap(\.missed)
                + listeningMeaningMissedWords
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
