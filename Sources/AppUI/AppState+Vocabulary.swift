import AIDomain
import AIServices
import AppCore
import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - AppState · 词汇本 + 复习闭环 + 每日推荐
// #267 自 AppState.swift 拆出（2026-09-20）：单文件 5136 行超载，按域切为扩展。
// 同模块 extension，语义与拆分前完全一致；成员访问级别已放宽到 internal。
extension AppState {
    // MARK: - 词汇本（Vocabulary，第 24 步）

    /// 进入词汇本页：加载词表 + 从复盘导入新词。
    public func openVocabulary() async {
        applySection(.vocabulary)
        let imported = await services.importVocabularyFromReviews()
        if imported > 0 {
            vocabularyNotice = AppNotice(text: "从最近复盘导入了 \(imported) 个新词，点「查释义」配上中文解释。")
        }
        await reloadVocabulary()
        await loadVocabularyBankIfNeeded()
        await healVocabularyTermsIfNeeded()
    }

    /// 进页面时把**历史落库**里缺「词性 / 中文」的词条补一遍（后台，每次启动每个词只试一次）。
    ///
    /// 早先版本模型只把重点单词写成英文（实测 `precipitation, rainfall, drizzle, drought`），
    /// 老数据不会自己变好 —— 这里定向问一次模型补上并覆盖落库，之后的启动就直接是好的。
    /// 模型没在跑 / 补不到就静默跳过，不打扰用户。
    func healVocabularyTermsIfNeeded() async {
        for entry in vocabularyEntries where !collapsedVocabularyDefinitions.contains(entry.id) {
            guard !termsHealAttempted.contains(entry.id) else { continue }
            let definition = VocabularyDefinitionRule.decodeStored(entry.meaning)
            guard !definition.termsNeedingCompletion.isEmpty else { continue }
            await healVocabularyTerms(id: entry.id)
        }
    }

    /// 重新读库 + 汇总统计。
    public func reloadVocabulary() async {
        let loaded = await services.vocabulary.entries()
        vocabularyEntries = loaded
        // 收录单词数按「词」去重（忽略大小写）——同词多条记录（不同释义版本）只算一个。
        // 设置页词汇本卡片的数字从这里取，收录 / 删除后跟着更新。
        vocabularyUniqueWordCount = Set(loaded.map { $0.word.lowercased() }).count
        vocabularyStats = VocabularyStats.from(loaded)
        // 复习卡上那张是队列里的**值拷贝**：词表一刷新就把新的那份资料带回卡上。
        // 不做这一步，「复习途中查到的释义」只在词表里生效，翻面还是「还没有释义」；
        // 放在这里（而不是查释义那个函数里）是因为改释义的路不止一条
        // （查释义 / 重新释义 / 补全词性与中文），凡是改了词表都该同步。
        if let current = vocabularyReview?.current,
           let fresh = loaded.first(where: { $0.id == current.id }) {
            vocabularyReview?.updateCurrent(fresh)
        }
    }

    /// 给一个词补「详细中文释义 + 例句 + 重点单词」（按需 LLM）。失败原因走页面提示条。
    public func defineVocabulary(id: UUID) async {
        guard let message = await requestVocabularyDefinition(id: id).message else { return }
        let retryID = id
        // 「这个词已经不在词表里了」这类没有可重试的动作 —— 词都没了，再点一次还是同一句话。
        vocabularyNotice = AppNotice(
            text: message,
            action: vocabularyEntries.contains(where: { $0.id == retryID })
                ? .retry { [weak self] in
                    guard let self else { return }
                    Task { await self.defineVocabulary(id: retryID) }
                }
                : nil
        )
    }

    /// 复习途中**就地**查释义：与词表里的「查释义」是同一条链路（同一次模型调用、
    /// 同样落库、同样刷新词表），差别只在提示走复习卡自己的通道。
    ///
    /// 为什么要就地查：用户实测反馈「没有释义的词只能回词表点查释义，打断复习的连续性」。
    /// 查到的释义既落到词表（`reloadVocabulary` 会把它带回这一张卡上），也不离开这一轮。
    public func defineVocabularyReviewWord() async {
        guard let entry = vocabularyReview?.current else { return }
        vocabularyReviewNotice = nil
        // 重试用 `retryDefinition`：那句话里已经说了「可以再点一次试试」，
        // 就该真有一个按钮 —— 只给文案不给出口，等于让用户自己去找原来那个按钮。
        if let message = await requestVocabularyDefinition(id: entry.id).message {
            vocabularyReviewNotice = AppNotice(
                text: message,
                action: vocabularyReview?.current != nil
                    ? .retry { [weak self] in
                        guard let self else { return }
                        Task { await self.defineVocabularyReviewWord() }
                    }
                    : nil
            )
            return
        }
        // 模型偶尔回一段空的：如实说一句，而不是留用户对着「还没有释义」发呆。
        if vocabularyReview?.current?.meaning.isEmpty ?? true {
            vocabularyReviewNotice = AppNotice(
                text: "模型这次没给出「\(entry.word)」的解释，可以再点一次试试。",
                action: .retry { [weak self] in
                    guard let self else { return }
                    Task { await self.defineVocabularyReviewWord() }
                }
            )
        }
    }

    /// 查释义的共用实现（词表与复习卡都走这里）。
    ///
    /// 成功时 `entry` 是落库后的词条；失败时 `message` 是**一句给用户看的原因** ——
    /// 调用方只决定这句话往哪条提示走（页面提示条 / 复习卡的提示条）。
    func requestVocabularyDefinition(
        id: UUID
    ) async -> (entry: VocabularyEntry?, message: String?) {
        guard let entry = vocabularyEntries.first(where: { $0.id == id }) else {
            return (nil, "这个词已经不在词表里了。")
        }
        // 「模型没开」要说清是模型没开，别把 notInitialized 翻译成「查失败」。
        guard isModelRunning(.llm) else {
            return (nil, "\(await services.modelLabel(for: .llm)) 已关闭，请在设置里点绿色的「启动」后再查释义。")
        }
        isDefiningVocabulary.insert(id)
        defer { isDefiningVocabulary.remove(id) }
        do {
            _ = try await services.defineVocabulary(entry)
            collapsedVocabularyDefinitions.remove(id)
            await reloadVocabulary()
            guard let updated = vocabularyEntries.first(where: { $0.id == id }) else {
                return (nil, "「\(entry.word)」的释义没能读回来。")
            }
            return (updated, nil)
        } catch {
            return (nil, "「\(entry.word)」释义失败：\(error.localizedDescription)")
        }
    }

    /// 查释义按钮（与收起开关集成）：没释义 → 请求模型；有释义 → 展开 / 收起切换。
    public func toggleVocabularyDefinition(id: UUID) async {
        guard let entry = vocabularyEntries.first(where: { $0.id == id }) else { return }
        if entry.meaning.isEmpty {
            await defineVocabulary(id: id)
        } else if collapsedVocabularyDefinitions.contains(id) {
            collapsedVocabularyDefinitions.remove(id)
            // 展开时顺手补一次「词性 / 中文」：早年落库的释义里重点单词只有英文。
            await healVocabularyTerms(id: id)
        } else {
            collapsedVocabularyDefinitions.insert(id)
        }
    }

    /// 已落库释义的词条补全：近义词 / 反义词 / 重点单词缺词性或中文时，
    /// 定向请求一次模型补上并覆盖落库（每个词只试一次，失败静默）。
    func healVocabularyTerms(id: UUID) async {
        guard !termsHealAttempted.contains(id) else { return }
        // 模型没开就等下次进页面再试（不标记，否则本次启动内不再补）。
        guard isModelRunning(.llm) else { return }
        termsHealAttempted.insert(id)
        guard let entry = vocabularyEntries.first(where: { $0.id == id }) else { return }
        guard let updated = await services.completeVocabularyTerms(entry) else { return }
        if let index = vocabularyEntries.firstIndex(where: { $0.id == id }) {
            vocabularyEntries[index] = updated
        }
    }

    /// 重新释义：旧数据（早先版本只存了整段中文，没有音标 / 词性 / 例句翻译）
    /// 想升级成新格式时用 —— 重新请求模型并覆盖落库。
    public func redefineVocabulary(id: UUID) async {
        await defineVocabulary(id: id)
    }

    /// 复习判分：认识 / 忘了。判分后刷新（到期列表随之变化）。
    public func gradeVocabulary(id: UUID, remembered: Bool) async {
        _ = await services.vocabulary.grade(id: id, remembered: remembered)
        await reloadVocabulary()
    }

    /// 删除一个词。
    public func removeVocabulary(id: UUID) async {
        await services.vocabulary.remove(id: id)
        await reloadVocabulary()
    }

    public func dismissVocabularyNotice() {
        vocabularyNotice = nil
    }

    // MARK: - 词汇复习闭环（P1-3 复习会话）
    //
    // 队列、判分推进、结算全部在 `AIDomain.VocabularyReviewSession`（纯函数）；
    // 这里只做三件事：开一轮、把学员的动作转成服务调用、把结果摆到界面上。
    //
    // ⚠️ **朗读分不参与等级**。音素评测回答的是「你刚才读得准不准」，
    // 而认识 / 忘了回答的是「你还记不记得这个词」—— 拿发音分替学员点等级，
    // 是两件事混成一件（读错一个音就被判「忘了」）。所以朗读只把证据摆出来。

    /// 开一轮复习：把**真的到期**的词排成队列（最多 `VocabularyReviewSession.maxCards` 个）。
    ///
    /// 没有到期的词就如实说一声，不硬开一个空会话 —— 空会话只会让人看到一条「0/0」的进度条。
    public func startVocabularyReview() async {
        // 一轮走多少张由 stance 定（欠得多就多走，见 `DailyPlanTuning.reviewSessionLimit`）——
        // 与每日任务里「复习 N 个」是同一个判断，别一处加量一处不加。
        let session = VocabularyReviewSession(
            entries: vocabularyEntries,
            limit: DailyPlanTuningRule.tuning(for: adaptivePath.stance).reviewSessionLimit
        )
        guard !session.queue.isEmpty else {
            vocabularyNotice = AppNotice(text: "今天没有到期的词。过几天再来，或者去每日推荐里挑几个加进复习列表。")
            return
        }
        await stopSpeaking()
        vocabularyReview = session
        vocabularyReviewRevealed = false
        vocabularyReviewReport = nil
        vocabularyReviewRecognized = nil
        vocabularyReviewNotice = nil
        isVocabularyReviewRecording = false
        isVocabularyReviewBusy = false
    }

    /// 翻面看释义（正面只给词，先自己想一遍）。
    public func revealVocabularyReviewCard() {
        vocabularyReviewRevealed = true
    }

    /// 判分并推到下一张。
    ///
    /// 朗读结果（如果有）随判分记进结算 —— 但等级用的是学员自己按的那个。
    public func gradeVocabularyReviewCard(remembered: Bool) async {
        guard let entry = vocabularyReview?.current else { return }
        if isVocabularyReviewRecording { await cancelVocabularyReviewRecording() }
        _ = await services.vocabulary.grade(id: entry.id, remembered: remembered)
        vocabularyReview?.grade(
            remembered: remembered,
            pronunciationScore: vocabularyReviewReport?.overall,
            phonemeSource: vocabularyReviewReport?.phonemeSource
        )
        vocabularyReviewRevealed = false
        vocabularyReviewReport = nil
        vocabularyReviewRecognized = nil
        vocabularyReviewNotice = nil
        await reloadVocabulary()
        // 队列判空 = 这一轮复习真的做完了（**最后一张判完**才算，不是「打开过」）。
        // ⚠️ 完成只在这一处发：收起（`finishVocabularyReview`）那边的同一判据
        // 会再发一次，森林就会为同一轮复习演两遍。
        if vocabularyReview?.current == nil {
            forest.ingest(.moduleCompleted(module: .vocabulary))
        }
        // ⚠️ 黑板要跟着复习实时走：每判一张就刷新今日作业（force 跳过 15s 节流）。
        // 之前只刷词表不刷进度快照，黑板一直显示「0/8 个词」，要点开学习进度才同步（2026-09-19）。
        await refreshTodayPanel(force: true)
    }

    /// 收起这一轮（提前退出 / 结算卡上的「完成」都走这里）。
    public func finishVocabularyReview() async {
        // ⚠️ 判据要在清空之前算：还有没判完的词 = 提前退出。
        // 全部判完时 `current` 已为 nil —— 那种情况在 `gradeVocabularyReviewCard` 里
        // 发过「完成」了，这里**绝不能**再发一次（同一轮复习不许演两遍）。
        let abandoned = vocabularyReview?.current != nil
        if isVocabularyReviewRecording { await cancelVocabularyReviewRecording() }
        await services.shadowing.stopAudio()
        vocabularyReview = nil
        vocabularyReviewRevealed = false
        vocabularyReviewReport = nil
        vocabularyReviewRecognized = nil
        vocabularyReviewNotice = nil
        isVocabularyReviewRecording = false
        isVocabularyReviewBusy = false
        await reloadVocabulary()
        await refreshTodayPanel(force: true)
        if abandoned { forest.ingest(.practiceAbandoned(module: .vocabulary)) }
    }

    /// 点一下开始读，再点一下停止并评分。
    public func toggleVocabularyReviewRecording() async {
        if isVocabularyReviewRecording {
            await finishVocabularyReviewRecording()
        } else {
            await startVocabularyReviewRecording()
        }
    }

    /// 开始读当前这个词（录音期间 VoiceService 会把识别结果流式推给输入框）。
    public func startVocabularyReviewRecording() async {
        guard vocabularyReview?.current != nil else { return }
        // ⚠️ 识别 / 评分期间不重开麦克风（同跟读页，2026-09-27）：
        // 上一段的识别还在跑就开新录，两次识别在串行的语音服务上排队，
        // 而且先回来的那次会把分数挂到**当前这个**词上。
        guard !isVocabularyReviewBusy else { return }
        // ⚠️ 真源而非界面快照（见 `isModelRunning` 的说明）：巡检挂起后快照会过期。
        _ = (try? await services.resumeIfSuspended(.asr)) ?? false
        await syncModelRunStates()
        guard await services.isModelRunning(.asr) else {
            // 「重试」在这里是**有用的**：它会再问一次真源（而不是界面快照），
            // 用户在设置里点完「启动」回来按一下就行 —— 不用退出复习重进。
            vocabularyReviewNotice = AppNotice(
                text: "\(await services.modelLabel(for: .asr)) 已关闭，请在设置里点绿色的「启动」后再读。",
                action: .retry { [weak self] in
                    guard let self else { return }
                    Task { await self.startVocabularyReviewRecording() }
                }
            )
            return
        }
        vocabularyReviewNotice = nil
        vocabularyReviewReport = nil
        vocabularyReviewRecognized = nil
        // 录音前先停掉朗读，别把喇叭里的老师声音也录进去。
        await stopSpeaking()
        await services.shadowing.stopAudio()
        await services.shadowing.startRecording(language: ShadowingService.practiceLanguage)
        isVocabularyReviewRecording = await services.voice.isRecording
        if !isVocabularyReviewRecording {
            // 重试 = 再开一次麦克风：权限刚给完、麦克风刚插上，往往就是「再点一次」的事。
            vocabularyReviewNotice = AppNotice(
                text: await services.shadowing.lastError() ?? "麦克风没能打开，检查一下系统权限。",
                action: .retry { [weak self] in
                    guard let self else { return }
                    Task { await self.startVocabularyReviewRecording() }
                }
            )
        }
    }

    /// 停止录音 → **原始**识别（不做拼写纠正）→ 音素评测（跟读同一套双通道）。
    public func finishVocabularyReviewRecording() async {
        guard let entry = vocabularyReview?.current else { return }
        // 同上：只有真在录音时才收尾，否则拿空音频换回一句假的「没有听清」。
        guard isVocabularyReviewRecording else { return }
        isVocabularyReviewRecording = false
        isVocabularyReviewBusy = true
        let recognized = await services.shadowing.finishRecording(language: ShadowingService.practiceLanguage)
        voiceTranscript = nil
        guard let recognized, !recognized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isVocabularyReviewBusy = false
            vocabularyReviewNotice = AppNotice(
                text: await services.shadowing.lastError() ?? "没有听清，凑近麦克风再说一次。",
                action: .retry { [weak self] in
                    guard let self else { return }
                    Task { await self.startVocabularyReviewRecording() }
                }
            )
            return
        }
        vocabularyReviewRecognized = recognized
        vocabularyReviewReport = await services.shadowing.evaluateSpeech(reference: entry.word, recognized: recognized)
        if vocabularyReviewReport == nil {
            // 没拿到音频就不给分数：宁可少一项，也不拿 0 分冒充「读得很差」。
            vocabularyReviewNotice = AppNotice(
                text: "这次没拿到录音，所以没算分（发音是通过录音量出来的，识别文本替代不了）。",
                action: .retry { [weak self] in
                    guard let self else { return }
                    Task { await self.startVocabularyReviewRecording() }
                }
            )
        }
        isVocabularyReviewBusy = false
    }

    /// 放弃这次录音。
    ///
    /// **离开词汇页时也要调用**（2026-09-27，同跟读页）：切页只销毁视图，
    /// `AppState` 里的录音状态还在 —— 不主动收尾，麦克风就会跟着用户去别的页面。
    public func cancelVocabularyReviewRecording() async {
        guard isVocabularyReviewRecording else { return }
        isVocabularyReviewRecording = false
        await services.shadowing.cancelRecording()
    }

    /// 停掉复习页的回放声音（离开页面时调用）。
    ///
    /// 只停声音、**不动** `isVocabularyReviewBusy`：评分可能还在跑，
    /// 回来时那张卡还要显示结果（把忙碌态抹掉会让它看起来像已经完成了）。
    public func stopVocabularyReviewAudio() async {
        await services.shadowing.stopAudio()
    }

    /// 听我的：回放刚才读的那遍。
    public func replayVocabularyReviewRecording() async {
        guard await services.shadowing.hasRecording else {
            vocabularyReviewNotice = AppNotice(text: "还没有录音，先点「读一遍」。")
            return
        }
        vocabularyReviewNotice = nil
        isVocabularyReviewBusy = true
        do {
            try await services.shadowing.replayRecording(rate: Float(product.speechRate))
        } catch {
            vocabularyReviewNotice = AppNotice(
                text: "回放失败：\(error.localizedDescription)",
                action: .retry { [weak self] in
                    guard let self else { return }
                    Task { await self.replayVocabularyReviewRecording() }
                }
            )
        }
        isVocabularyReviewBusy = false
    }

    /// 朗读当前这个词（听示范）。
    public func speakVocabularyReviewWord() async {
        guard let entry = vocabularyReview?.current else { return }
        if stateSpeakingThis(entry.word) {
            await stopSpeaking()
        } else {
            await speak(entry.word)
        }
    }

    /// 正在朗读的文本是不是这一条（避免两处各写一遍比较逻辑）。
    func stateSpeakingThis(_ text: String) -> Bool {
        speakingText == text && speechPhase != .idle
    }

    public func dismissVocabularyReviewNotice() {
        vocabularyReviewNotice = nil
    }

    // MARK: - 词汇本 · 词库总词数

    /// 载入「每日推荐词库总词数」（一次）：设置页「已学 x / y 词」的分母。
    ///
    /// ⚠️ 这个分母必须用**词典库**那份（`dailyWordBank()`，已按词去重）：
    ///   推荐词本来就是从可见词典里抽的。早先误用随包词库，会得到
    ///   「词库共 7,404 词」旁边写着「已学 0 / 145 词」这种自相矛盾。
    public func loadVocabularyBankIfNeeded() async {
        guard !vocabularyBankLoaded else { return }
        vocabularyBankLoaded = true
        dailyBankTotal = await services.dailyWordBank().count
    }

    // MARK: - 词汇本 · 每日推荐

    /// 读「认识」计数（UserDefaults，轻量 [word: count]）。
    static func loadDailyRecognitions() -> [String: Int] {
        guard let data = UserDefaults.standard.data(forKey: dailyRecognitionStorageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
    }

    func saveDailyRecognitions() {
        if let data = try? JSONEncoder().encode(dailyRecognitions) {
            UserDefaults.standard.set(data, forKey: Self.dailyRecognitionStorageKey)
        }
    }

    /// 某词累计被点「认识」的次数。
    public func dailyRecognitionCount(word: String) -> Int {
        dailyRecognitions[word.lowercased()] ?? 0
    }

    /// 已认熟（满 3 次）的词集合：抽词时排除。
    var retiredDailyWords: Set<String> {
        Set(dailyRecognitions.filter { $0.value >= Self.dailyRecognitionRetireCount }.keys)
    }

    /// 已学完（累计认识满 3 次）的词数。
    public var dailyLearnedCount: Int {
        dailyRecognitions.values.filter { $0 >= Self.dailyRecognitionRetireCount }.count
    }

    /// 重置每日推荐学习进度：清空「认识」记录与派生缓存，重新从最低档开始推荐。
    /// 同时记下**重置那一刻**的时间与已学词数（设置页展示「上次已学 x / y 词」）。
    public func resetDailyProgress() async {
        dailyProgressResetAt = Date()
        dailyProgressResetLearned = dailyLearnedCount   // 先记，再清空
        if let stamp = dailyProgressResetAt {
            UserDefaults.standard.set(stamp.timeIntervalSince1970, forKey: Self.dailyResetAtKey)
        }
        UserDefaults.standard.set(dailyProgressResetLearned, forKey: Self.dailyResetLearnedKey)

        dailyRecognitions = [:]
        saveDailyRecognitions()
        dailyAcknowledged = []
        expandedDailyWords = []
        dailyDefinitions = [:]
        dailyWords = await services.dailyWordRecommendation(excluding: retiredDailyWords, seed: dailyWordsSeed)
        vocabularyNotice = AppNotice(text: "每日推荐学习进度已重置：认识记录清零，词库重新从简单档开始推荐。")
    }

    /// 抽一批推荐词（4 生词 / 3 简单 / 5 中等 / 2 困难 / 2 词组，共 16 张 = 收起态 4 页）。
    /// 只在第一次进词汇本页时抽，之后进页面保持同一组；已认熟的词不再出现。
    ///
    /// 其中「生词」档来自**词汇本**（练习里遇到的生词，见 `DailyVocabularyPool`），
    /// 不足 4 个时由词典档补齐 —— 总数恒定 16，收起态翻页不会翻出半空的尾巴页。
    ///
    /// ⚠️ **按天恒定**：种子由「日期 + 学习语言」派生，所以同一天关掉再打开看到的还是
    /// 这一批（原先是每次启动真随机，一天里换好几拨，「今天要学的词」这件事立不住）。
    public func loadDailyWordsIfNeeded() async {
        guard !dailyWordsLoaded else { return }
        dailyWordsLoaded = true
        dailyWords = await services.dailyWordRecommendation(excluding: retiredDailyWords, seed: dailyWordsSeed)
    }

    /// 每日推荐「按天恒定」的种子：同一天、同一学习语言 → 同一批词。
    var dailyWordsSeed: UInt64 {
        DailySeed.seed(
            dayKey: ShadowingDailyRule.dayKey(),
            language: chat.profile.learningLanguage
        )
    }

    /// 刷新：重新抽一批与当前展示的**不同**的词典词（清空展开态与本次「认识」记录，
    /// 已认熟的词不再出现；释义缓存保留可复用）。
    ///
    /// ⚠️ **生词档不参与「换一批」**：换一批的语义是「换几个雅思词看看」，
    /// 而生词是你自己的词 —— 把它一起排掉的话，用户点一下「换一批」，
    /// 自己的生词就当天再也见不到了（还得再点一次才回来）。
    public func refreshDailyWords() async {
        var excluding = Set(dailyWords.filter { !$0.isVocabularyWord }.map { $0.word.lowercased() })
        excluding.formUnion(retiredDailyWords)
        let next = await services.dailyWordRecommendation(excluding: excluding)
        // 词库不足时可能抽不满，把排除条件放宽再抽一次。
        dailyWords = next.isEmpty && !dailyWords.isEmpty
            ? await services.dailyWordRecommendation(excluding: retiredDailyWords)
            : next
        expandedDailyWords = []
        dailyAcknowledged = []
    }

    /// 每日推荐词的「查释义」按钮：展开 / 收起切换，首次展开时请求模型。
    public func toggleDailyDefinition(word: String) async {
        if expandedDailyWords.contains(word) {
            expandedDailyWords.remove(word)
            return
        }
        if dailyDefinitions[word] == nil {
            isDefiningDaily.insert(word)
            defer { isDefiningDaily.remove(word) }
            do {
                dailyDefinitions[word] = try await services.defineDailyWord(word)
            } catch {
                let retryWord = word
                vocabularyNotice = AppNotice(
                    text: "「\(word)」释义失败：\(error.localizedDescription)",
                    action: .retry { [weak self] in
                        guard let self else { return }
                        Task { await self.toggleDailyDefinition(word: retryWord) }
                    }
                )
                return
            }
        }
        expandedDailyWords.insert(word)
    }

    /// 每日推荐的「认识」按钮（同一按钮切换）：
    /// - 未计入 → 计数 +1，按钮变灰显示「再想想」（再点撤销 → 计数 -1）；
    /// - 每次出现最多计一次，换一批 / 重启后重新可计；
    /// - 累计满 3 次 → 该词从推荐中移除，之后不再推荐。
    public func toggleDailyRecognized(word: String) async {
        let key = word.lowercased()
        if dailyAcknowledged.contains(word) {
            dailyRecognitions[key] = max((dailyRecognitions[key] ?? 1) - 1, 0)
            dailyAcknowledged.remove(word)
        } else {
            dailyRecognitions[key] = (dailyRecognitions[key] ?? 0) + 1
            dailyAcknowledged.insert(word)
        }
        saveDailyRecognitions()
        if (dailyRecognitions[key] ?? 0) >= Self.dailyRecognitionRetireCount {
            dailyWords.removeAll { $0.word.caseInsensitiveCompare(word) == .orderedSame }
            vocabularyNotice = AppNotice(text: "「\(word)」累计认识 3 次，已从每日推荐中毕业 🎉")
        }
    }

    /// 把推荐词加入复习列表（用户手动；已在词表时只提示）。
    public func addDailyToReview(word: String) async {
        if vocabularyEntries.contains(where: { $0.word.caseInsensitiveCompare(word) == .orderedSame }) {
            vocabularyNotice = AppNotice(text: "「\(word)」已经在词表里了。")
            return
        }
        guard await services.vocabulary.add(word: word) != nil else {
            vocabularyNotice = AppNotice(text: "「\(word)」没能加入词表（为空或没有学习数据库）。")
            return
        }
        vocabularyNotice = AppNotice(text: "「\(word)」已加入复习列表。")
        await reloadVocabulary()
    }

}
