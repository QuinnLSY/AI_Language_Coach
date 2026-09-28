import AIDomain
import AIServices
import AppCore
import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - AppState · 考试模式（雅思口语/面试问答）
// #267 自 AppState.swift 拆出（2026-09-20）：单文件 5136 行超载，按域切为扩展。
// 同模块 extension，语义与拆分前完全一致；成员访问级别已放宽到 internal。
extension AppState {
    // MARK: - 考试模式（雅思口语 / 面试问答）

    /// 加载内置考卷（只读资源文件；失败时保持空列表，由面板给可操作提示）。
    public func loadExamBlueprints() async {
        guard !didLoadExamBlueprints else { return }
        examBlueprints = await services.examBlueprints()
        didLoadExamBlueprints = true
    }

    /// 开始一场考试。
    ///
    /// 与进入情景同一条口径：新的一段练习开始前，先把上一段复盘掉。
    /// 区别在于**没有前情提要、没有主线任务** —— 考场上老师只按考卷出题。
    public func startExam(_ blueprint: ExamBlueprint) async {
        applySection(.practice)
        // 上一局的判定先收起来：新的一局开始，旧卡片的覆盖率就是错的数据。
        assessmentDismissTask?.cancel()
        assessmentDismissTask = nil
        lastAssessment = nil
        lastAssessedScenarioID = nil
        expandedScenarioID = nil
        clearExamState()
        // 考试不是随口练：模式必须切回来，否则老师会同时收到「你是考官」
        // 与「学员主导，你跟着聊」两套相反的指令。
        if product.practiceMode != .conversation {
            product.practiceMode = .conversation
            await persistProduct()
        }
        await concludeCurrentPractice()
        // 学员主动开始一场考试：允许覆盖「本段已有内容」的守卫。
        chat.beginNewSession(allowWhenSessionHasContent: true)

        let runner = ExamRunner(blueprint: blueprint)
        guard let context = runner.turnContext else {
            // 一题都没有的考卷：说清楚，不进考试 —— 进去了只是卡在空白上。
            examRunner = nil
            practiceNotice = AppNotice(text: "这套考卷里没有题目，换一套试试。")
            return
        }
        examRunner = runner
        chat.beginExam(context)
        chat.deliverOpener()
    }

    /// 学员提交一次作答：先记进考卷（含实际用时）并推进到下一问，再把话交给考官。
    ///
    /// ⚠️ 顺序不可颠倒：老师这一轮拿到的「现在该问哪一句」必须是**推进之后**的那一题。
    /// - Returns: 真的记下了一次作答才返回 true。
    @discardableResult
    public func submitExamAnswer(_ text: String) -> Bool {
        guard var runner = examRunner, !runner.isFinished else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, runner.submit(text: trimmed) != nil else { return false }
        examRunner = runner
        guard !runner.isFinished else {
            // 最后一问答完：立刻结算，不等老师再开口 ——
            // 报告是这一场的结果，老师的收尾寒暄流没流完，不该决定报告出不出现。
            chat.updateExamContext(runner.closingContext)
            settleExam(runner)
            return true
        }
        chat.updateExamContext(runner.turnContext)
        return true
    }

    /// 学员主动跳过当前这一问。
    public func skipExamQuestion() async {
        await skipExamQuestion(reason: nil)
    }

    /// 当前这一问超时（界面倒计时到点）→ 自动跳过，整场继续。
    ///
    /// ⚠️ 这里只认「已经起表且真的到点」：界面重绘、视图重建都会再触发一次
    /// 同一条计时任务，靠 `isTimedOut` 把重复触发挡掉（否则一题能连跳好几问）。
    public func examQuestionTimedOut() async {
        guard let runner = examRunner, runner.isArmed, runner.isTimedOut(now: Date()) else { return }
        await skipExamQuestion(reason: "时间到")
    }

    func skipExamQuestion(reason: String?) async {
        guard var runner = examRunner, !runner.isFinished else { return }
        runner.skip()
        examRunner = runner
        guard !runner.isFinished else {
            chat.updateExamContext(runner.closingContext)
            settleExam(runner)
            return
        }
        // 没人作答 = 没有话头递给老师：这一问由考卷直接宣布（本地消息，零模型请求）。
        // 起表也在这里做 —— 宣布是同步的，题目从这一刻起就在学员眼前。
        guard let context = runner.turnContext else { return }
        chat.updateExamContext(context)
        chat.announceExamPrompt(context, reason: reason)
        runner.arm()
        examRunner = runner
    }

    /// 学员点「结束考试」（提前交卷）：剩余题目全部跳过，直接结算。
    public func finishExam() async {
        guard var runner = examRunner, !runner.isFinished else { return }
        // 老师可能正在念题：结束考试就该让它停下来 ——
        // 否则下一句会落到已经收场的考场上，留下一句没头没尾的问题。
        chat.cancel()
        runner.finishEarly()
        examRunner = runner
        chat.updateExamContext(nil)
        // 提前交卷：剩余题目都是「跳过」的，走的是目送那条路。
        settleExam(runner, abandoned: true)
    }

    /// 关闭结算卡：本轮考试到此为止（报告、示范答案一起收走）。
    public func dismissExamReport() {
        clearExamState()
        chat.endExam()
    }

    /// 用同一套考卷再来一次。
    public func retakeExam() async {
        guard let blueprint = examRunner?.blueprint else { return }
        dismissExamReport()
        await startExam(blueprint)
    }

    /// 重写一次示范答案（上次没拿到时给学员一个重试的出口）。
    public func retryExamSampleAnswers() {
        guard examRunner != nil, !examSampleTargets.isEmpty else { return }
        requestExamSampleAnswers()
    }

    /// 老师一轮结束（`ChatService.onTeacherTurnEnd`）：先做考试模式内外都要做的事，
    /// 考试模式下再额外做两件。
    ///
    /// ⚠️ 后两件事都**只能**发生在这里：起表要知道题目何时真正出现在学员眼前，
    /// 补记纠错要知道老师这一轮标了几处 —— 都在一次生成之后才知道。
    func handleTeacherTurnEnd(_ message: ChatMessage?, corrections: [GrammarCorrection]) {
        // ⓪ 批注实时进错题本（考试模式内外都要）：老师这轮标了几处，
        //    错题本当场就多几条 —— 不等学员进记录页才 loadRecords
        //    （#3 报障的正是「有卡片有复盘、错题本却空着」）。
        //    ⚠️ 顺序与口径都向数据库看齐：新 → 旧、上限 50、**不去重** ——
        //    同一处错再犯一次就再记一条（反复错误本来就按次数算）；
        //    ChatService 已保证回调触发前本轮纠错落库完成，这里的内存态
        //    与随后 loadRecords 读到的完全一致。
        //    「老师记住了你什么」跟着重算（读的也是已落库的同一份数据）。
        if !corrections.isEmpty {
            mistakes.insert(contentsOf: corrections.reversed(), at: 0)
            mistakes = Array(mistakes.prefix(50))
            Task { await refreshLearningMemory() }
        }
        guard var runner = examRunner else { return }
        // ① 老师这一轮没产出正文（模型没起来 / 回空）→ 这一问由考卷本地宣布。
        //    题目照出、整场不卡，而且学员仍然有可答的东西。
        if message == nil, !runner.isFinished, let context = runner.turnContext {
            chat.announceExamPrompt(context, reason: "老师这轮没接上")
        }
        // ② 题目此刻才在学员眼前：倒计时从这一刻起表。
        runner.arm()
        // ③ 老师标出的错误条数补记到刚答完的那一问（语法分的依据）。
        //    —— 收场那一轮不算：那时老师被要求不要评价，把它的「零条」记成
        //    「零错误」就是又一次把「没测到」说成「没问题」。没有正文时同理。
        if message != nil,
           chat.examContext?.isClosing != true,
           let number = runner.lastAnsweredQuestionNumber {
            runner.attachErrorCount(corrections.count, toQuestion: number)
        }
        examRunner = runner
    }

    /// 清掉考试的一切痕迹（学员换到别的事上、或关掉结算卡）。
    func clearExamState() {
        examSampleTask?.cancel()
        examSampleTask = nil
        isGeneratingExamSamples = false
        examSampleTargets = []
        examSampleAnswers = [:]
        examSampleNotice = nil
        examReport = nil
        examRunner = nil
    }

    /// 结算：出报告 + 请老师写示范答案（**一次请求**，写完之前不发第二次）。
    ///
    /// 报告里的分数**不经过模型**（`ExamScoring` 是纯函数），
    /// 所以报告一定出得来；示范答案是附加项，拿不到就如实说没拿到。
    func settleExam(_ runner: ExamRunner, abandoned: Bool = false) {
        let report = runner.report(pronunciation: nil)
        examReport = report
        // 两种收场，森林两种回应：**走完**是庆祝，**提前交卷**是目送你走。
        // ⚠️ 判据由调用点给（`finishExam` 是提前交卷，最后一问答完 / 跳完是走完），
        // 不在这里猜 —— 结算本身看不出是哪一种。
        forest.ingest(abandoned
                      ? .practiceAbandoned(module: .exam)
                      : .moduleCompleted(module: .exam))
        examSampleAnswers = [:]
        examSampleNotice = nil
        examSampleTargets = ExamSampleAnswerRule.items(
            for: ExamSampleAnswerRule.targets(session: runner.session, report: report),
            in: runner.session
        )
        // 每一问都答够了 → 不硬凑一份示范答案，也不发这一次请求。
        requestExamSampleAnswers()
    }

    func requestExamSampleAnswers() {
        guard let blueprint = examRunner?.blueprint, !examSampleTargets.isEmpty else { return }
        let targets = examSampleTargets
        let language = product.learningLanguage
        let nativeLanguage = product.nativeLanguage
        examSampleTask?.cancel()
        isGeneratingExamSamples = true
        examSampleTask = Task { [weak self] in
            guard let self else { return }
            let answers = await self.services.examSampleAnswers(
                examTitle: blueprint.title,
                targets: targets,
                learningLanguage: language,
                nativeLanguage: nativeLanguage
            )
            guard !Task.isCancelled else { return }
            self.isGeneratingExamSamples = false
            if answers.isEmpty {
                self.examSampleNotice = "示范答案这次没拿到（模型没起来，或返回里没有可用的答案行）。"
            } else {
                self.examSampleAnswers = answers
                self.examSampleNotice = nil
            }
        }
    }

    /// 收尾一段练习：**先复盘，再删流水**（需求 5）。
    ///
    /// 顺序不可颠倒 —— 复盘没成功就把流水删了，这一局说过的话就再也找不回来了。
    /// 复盘失败时**绝不删**，只留一句提示，练习内容继续留着。
    ///
    /// - Parameters:
    ///   - session: 要复盘的是哪一段。nil = 当前这段。
    ///     开屏流程必须显式传**恢复出来的那一段** —— 那时 `chat` 正要（或已经）换到新段，
    ///     读 `chat.sessionID` 会复盘错对象（把新段的招呼当成一整段练习）。
    ///   - messages: 那一段的消息快照。理由同上：换段后 `chat.messages` 已经被清空。
    /// - Returns: 这一步得到的复盘（没有可复盘的内容时为 nil）。
    @discardableResult
    public func concludeCurrentPractice(
        session sessionID: UUID? = nil,
        messages snapshot: [ChatMessage]? = nil
    ) async -> SessionReview? {
        let target = sessionID ?? chat.sessionID
        let messages = snapshot ?? chat.messages
        guard !messages.isEmpty else { return nil }

        let reviewedCount = await services.reviewedMessageCount(sessionID: target)
        guard PracticeReviewPolicy.shouldAutoReview(
            messageCount: messages.count, lastReviewedMessageCount: reviewedCount
        ) else {
            return await services.sessionReview(sessionID: target)
        }

        let duration = await services.sessionDuration(sessionID: target)
        // 纠错：手上有刚发生的就用（最全）；否则回库里取那一段的 ——
        // 恢复出来的会话在内存里没有纠错映射，只读内存会让「老师改过什么」永远是空的。
        let inMemory = snapshot == nil ? chat.correctionsByMessage.values.flatMap { $0 } : []
        let corrections = inMemory.isEmpty ? await services.corrections(sessionID: target) : inMemory
        let review = await services.makeSessionReview(
            sessionID: target, messages: messages, corrections: corrections, duration: duration
        )
        // 复盘里提到的新词立刻进词汇本（需求 5：复盘完词汇本自动更新）。
        await services.importVocabularyFromReviews()

        guard PracticeReviewPolicy.canPurgeSource(review) else {
            practiceNotice = AppNotice(text: "这次复盘没生成出来，练习内容先给你留着，稍后再试。")
            await loadReviews()
            return review
        }
        // ⚠️ 带**条数**去删：复盘是一次模型调用（几秒到几十秒），这期间学员完全可能又说了几句，
        // 那些话不在复盘里。条数对不上就不删（宁可留着重叠，也不能把人家的话静默丢掉）。
        let purged = await services.purgePracticeMessages(
            sessionID: target, expectedMessageCount: messages.count
        )
        // 回执带「去看复盘」：把目标**那一条**一起写进这个值里（跳转 + 自动展开），
        // 提示条上就没有第二处需要同步的状态了。学员开口说下一句时它会自己消失（见 `sendChat`）。
        practiceNotice = purged > 0
            ? AppNotice(
                text: "上一段练习已自动复盘，内容已收进学习记录。",
                action: NoticeAction(title: "去看复盘") { [weak self] in
                    Task { await self?.openRecords(focus: .sessionReview(target)) }
                }
            )
            : nil
        await loadRecords()
        return review
    }

    /// 启动时的「继续上次」（需求 6）：不再自动开新练习。
    ///
    /// 三条路：
    /// 1. 上一段流水还在（没走成复盘）→ 保留对话直接续，只把前情提要补上；
    /// 2. 流水已清（复盘成功）→ 看会话行：情景就续做任务，随口练就接着聊；
    /// 3. 第一次打开 → 老师给一句一般招呼，等学员开口。
    func resumeOrOpenPractice() async {
        // ① 流水还在：对话本身就是要接着用的东西，先别再动它。
        if !chat.messages.isEmpty {
            if let scenario = chat.scenarioProgress?.scenario {
                // 情景还没走完 —— 这段历史正是要接着练的那一段，揭开（它一恢复就被按住了）。
                chat.revealRestoredHistory()
                await prepareBriefing(for: scenario)
                return
            }
            // ⚠️ 这段对话**不接着用**（要复盘掉、换成新的一段），所以先把它从界面上撤下来再做。
            // 复盘要跑一次模型请求（实测好几秒），中间还夹着一次 `beginNewSession()` 的清空 ——
            // 不撤的话用户看到的就是「先闪一条学员问候，再变成老师的招呼」（实测报障）。
            //
            // ⚠️ 学员已经开口 → 这段会话归他：揭开、收工，一个字都不许动。
            guard !learnerEngagedThisLaunch else {
                chat.revealRestoredHistory()
                return
            }
            // ⚠️ 先把「要复盘的那一段」**快照**下来，再用快照去复盘。
            // 复盘是一次模型调用（几秒到几十秒），这段时间里 `chat` 的状态会被别人动
            // （学员说话、或者我们下面的换段）。拿 `chat.messages` 当复盘对象，
            // 等于对着一个还在变的靶子开枪。
            let previousSession = chat.sessionID
            let previousMessages = chat.messages
            chat.hideRestoredHistory()
            let review = await concludeCurrentPractice(session: previousSession, messages: previousMessages)
            // 复盘跑完再看一眼：这几秒到几十秒里学员完全可能已经开口了。
            guard !learnerEngagedThisLaunch else {
                chat.revealRestoredHistory()
                return
            }
            // ⚠️ 换段是**有守卫**的：这一段只要已经写过东西就拒绝换（见 `beginNewSession`）。
            // 实测事故：换段发生在学员那句话落库之后、老师的招呼之前 ——
            // 学员的话留在上一段的 id 里，招呼落在新段，一段对话被劈成两半，
            // 每次练习永远只有 1 条对话，复盘永远凑不够最低条数。
            guard chat.beginNewSession() else {
                chat.revealRestoredHistory()
                return
            }
            // 新段开好了：老师**带着刚出炉的复盘**开场（「每次打开应用接着上次聊」）。
            // 刚生成的这份最贴近刚才那段；它没内容时（条数不够、复盘失败）退回最近一份。
            let carryOver: SessionReview?
            if PracticeReviewPolicy.hasContent(review) {
                carryOver = review
            } else {
                carryOver = await latestReview()
            }
            await startCarryOverOpener(review: carryOver)
            return
        }
        // ② 流水已清：靠会话行判断上次在练什么（sessions 行永远留着）。
        guard let latest = await services.latestChatSession()?.session else {
            chat.greetIfNeeded()
            return
        }
        // ⚠️ 先查「那一关的主线任务是不是已经跑完」：跑完的这一关没有「没做完的事」可续，
        // 一律当空闲处理 —— 否则 `beginScenario` 会把已完成的主线清零重来，
        // 学员一启动就看到「主线 0/3」，而右边大树上那一格却写着「已过关」，两处自相矛盾。
        // 想重练是**主动**行为：去情景卡片点「开始任务」，那时才重置。
        let latestQuestComplete: Bool
        if let id = latest.scenarioID, !id.isEmpty {
            latestQuestComplete = await services.questProgress(scenarioID: id)?.isComplete == true
        } else {
            latestQuestComplete = false
        }
        switch PracticeResumeRule.action(
            latestScenarioID: latest.scenarioID,
            latestMode: latest.mode,
            questComplete: latestQuestComplete
        ) {
        case .resumeScenario(let id):
            guard let scenario = scenario(for: id) else {
                chat.greetIfNeeded()
                return
            }
            if product.practiceMode != .conversation {
                product.practiceMode = .conversation
                await persistProduct()
            }
            await beginScenario(scenario)
        case .resumeFreeTalk:
            if product.practiceMode != .freeTalk {
                product.practiceMode = .freeTalk
                await persistProduct()
            }
            chat.beginFreeTalk(review: await latestReview())
            chat.deliverOpener()
        case .idle:
            // ⚠️ **开屏续聊走的就是这一条路**（真实数据里所有会话 mode 都是 `conversation`）。
            // 以前这里无条件 `greetIfNeeded()`：老师每次开屏都只说一句与昨天无关的
            // 「欢迎回来」，「根据上次对话的复盘续聊」这条需求从来没有被实现过。
            await startCarryOverOpener(review: await latestReview())
        }
        // 走到这里说明这段历史**还留在对话里**（续做情景 / 接着聊 / 只是打个招呼）——
        // 它就是学员要接着看的内容，揭开。要换新一段的那条路已经在上面 `clear()` 掉了，
        // 这里会自然跳过（`revealRestoredHistory` 见空流水直接返回）。
        chat.revealRestoredHistory()
    }

    /// 最近一次练习的复盘（开屏续聊的依据；没有返回 nil）。
    private func latestReview() async -> SessionReview? {
        await services.recentReviews(limit: 1).first
    }

    /// 让老师「接着上次」开口；确实没有可续的内容时才退化成一句一般招呼。
    ///
    /// ⚠️ 判据走 `PracticeReviewPolicy.hasContent`：标题 / 优点 / 待改进一条都没有的复盘
    /// 拿去开场，只会让模型拿到一个空槽位 —— 那等于鼓励它编一段「上次」。
    private func startCarryOverOpener(review: SessionReview?) async {
        guard PracticeReviewPolicy.hasContent(review) else {
            chat.greetIfNeeded()
            return
        }
        chat.beginContinuation(review: review)
        chat.deliverOpener()
    }

    /// 实时把主线任务进度落库（学员每说完一句就调用，见 `ChatService.onLearnerTurn`）。
    ///
    /// ⚠️ **并集语义**：新完成的步骤与库里已有的取并集，只增不减 ——
    /// 上一局推到的第 2 步不会因为这一局没说到而退回去（断点续做的基础）。
    public func persistLiveQuestProgress() async {
        guard let scenario = chat.scenarioProgress?.scenario,
              let live = chat.briefing?.quest,
              live.total > 0
        else { return }
        let previous = await services.questProgress(scenarioID: scenario.id)
        let record = (previous ?? ScenarioQuestRecord(scenarioID: scenario.id)).merging(
            doneStepIDs: live.completedStepIDs,
            complete: live.isComplete,
            sessionID: chat.sessionID
        )
        await services.saveQuestProgress(record)
        briefing = chat.briefing
        await refreshQuestRecords()
    }

    /// 结束当前情景（对话内容保留），并按「主线任务 + 教学重点」判定是否过关。
    public func endScenario() async {
        guard let progress = chat.scenarioProgress else {
            chat.endScenario()
            return
        }
        // **必须在这一步之前取**：`endScenario()` 一执行，就再也分不清哪几句属于这一局。
        let utterances = chat.scenarioLearnerUtterances
        let plan = chat.briefing?.plan
        let alreadyDone = chat.briefing?.persistedStepIDs ?? []
        chat.endScenario()
        await settleScenario(progress, utterances: utterances, plan: plan, alreadyDone: alreadyDone)
    }

    /// 按 id 取场景（关卡绑定 / 记录页展示用）。场景在启动时已加载。
    public func scenario(for id: String?) -> Scenario? {
        guard let id else { return nil }
        return scenarios.first { $0.id == id }
    }

    /// 情景的母语标题（学习记录页展示用）。
    public func scenarioTitle(for id: String?) -> String? {
        scenario(for: id)?.titleZh
    }

    /// 立刻收起结算提示。
    public func dismissReward() {
        rewardDismissTask?.cancel()
        rewardDismissTask = nil
        lastReward = nil
        // 结算卡盖住了的今日庆祝现在补放（「防堆叠」的另一半：不是不放，是错开放）。
        if rewardCelebrationPending {
            Task { [weak self] in await self?.refreshTodayPanel(force: true) }
        }
    }

    /// 结算一次情景练习（需求 3 的新口径）：
    ///
    /// **通关 = 完成主线任务 + 教学重点达标**，两条都满足才点亮这一关；
    /// 星星只记「开口量」（参与度），不再决定胜负 —— 说满轮次却没说到点子上不算过关。
    ///
    /// 主线任务进度在这里再落一次库（并集），保证「哪怕中途退出也不丢已完成步骤」。
    func settleScenario(
        _ finished: ScenarioProgress,
        utterances: [String],
        plan: QuestPlan?,
        alreadyDone: Set<String>
    ) async {
        let scenario = finished.scenario
        let assessment = publishAssessment(
            scenario: scenario, utterances: utterances, plan: plan, alreadyDone: alreadyDone
        )
        await persistQuestProgress(scenario: scenario, assessment: assessment)
        briefing = nil

        let passed = assessment?.verdict.didPass ?? false
        let shortfall = assessment.map { Self.shortfallText($0) }

        guard let index = progress.levels.firstIndex(where: { $0.scenarioID == scenario.id }) else {
            // 场景没有绑定关卡：只给一句反馈，不动进度
            lastReward = ScenarioRewardRule.reward(
                scenarioTitle: scenario.titleZh, stars: 0, levelTitle: nil,
                didPass: passed, willCompleteLevel: false, shortfall: shortfall
            )
            scheduleRewardDismissal()
            return
        }
        let level = progress.levels[index]
        // 已通关的关卡重复练习不再重复加星，但照样给个反馈
        guard level.state != .completed else {
            lastReward = ScenarioReward(
                levelTitle: level.title, stars: 0, didCompleteLevel: false,
                message: "「\(scenario.titleZh)」又练了一遍，很稳！"
            )
            scheduleRewardDismissal()
            return
        }

        // 星星是「累计」的：本次按轮次给分，累加后封顶到本关需求（关卡最多就该拿满这么多星）。
        let scored = ScenarioRewardRule.stars(turnsUsed: finished.turnsUsed, maxTurns: scenario.maxTurns)
        let award = ScenarioRewardRule.award(earned: level.earnedStars, scored: scored, required: level.requiredStars)
        lastReward = ScenarioRewardRule.reward(
            scenarioTitle: scenario.titleZh, stars: award.gained, levelTitle: level.title,
            didPass: passed, willCompleteLevel: passed, shortfall: shortfall
        )
        if award.total != level.earnedStars {
            progress.levels[index].earnedStars = award.total
        }
        if passed {
            await completeLevel(level.id, earnedStars: award.total)
        } else {
            // 没通关也要在树上留下痕迹：这一关「正在学」。
            if level.state != .locked {
                progress.levels[index].state = .inProgress
            }
            progress.recalculateSummary()
            await services.saveProgress(progress)
            // 攒了星但没通关：小回应（新果实弹入），全套仪式留给通关那一刻。
            if award.gained > 0 {
                forest.ingest(.starsEarned(levelID: level.id, total: award.total, delta: award.gained))
            }
        }
        scheduleRewardDismissal()
    }

    /// 把主线任务进度落库（并集，只增不减）。
    func persistQuestProgress(scenario: Scenario, assessment: CurriculumAssessment?) async {
        guard let assessment, assessment.quest.total > 0 else { return }
        let previous = await services.questProgress(scenarioID: scenario.id)
        let record = (previous ?? ScenarioQuestRecord(scenarioID: scenario.id)).merging(
            doneStepIDs: assessment.quest.completedStepIDs,
            complete: assessment.quest.isComplete,
            sessionID: chat.sessionID
        )
        await services.saveQuestProgress(record)
        await refreshQuestRecords()
    }

    /// 没通关时的一句话原因（取第一条未达标项，直白可核对）。
    static func shortfallText(_ assessment: CurriculumAssessment) -> String {
        if !assessment.isQuestSatisfied {
            let remaining = assessment.quest.total - assessment.quest.doneCount
            let next = assessment.quest.currentText
            return next.isEmpty
                ? "主线任务还差 \(remaining) 步"
                : "主线任务还差 \(remaining) 步，下一步是「\(next)」"
        }
        if !assessment.isFocusSatisfied {
            let missing = assessment.focus.missingItems.prefix(2).map(\.text).joined(separator: "、")
            return missing.isEmpty ? "教学重点还差一点" : "教学重点还差：\(missing)"
        }
        return "再完整走一遍这一关"
    }

    /// 算一次判定并挂到 `lastAssessment`（既没有主线任务也没有教学重点的场景不产生判定卡 —— 没有可比的目标）。
    @discardableResult
    func publishAssessment(
        scenario: Scenario,
        utterances: [String],
        plan: QuestPlan? = nil,
        alreadyDone: Set<String> = []
    ) -> CurriculumAssessment? {
        let effectivePlan = plan ?? scenario.questPlan
        let hasTargets = effectivePlan.total > 0
            || !scenario.targetSentences.isEmpty
            || !scenario.targetVocabulary.isEmpty
        guard hasTargets else {
            lastAssessment = nil
            lastAssessedScenarioID = nil
            return nil
        }
        let assessment = CurriculumScorer.assess(
            scenario: scenario, utterances: utterances, questDone: alreadyDone
        )
        lastAssessedScenarioID = scenario.id
        lastAssessment = assessment
        scheduleAssessmentDismissal()
        return assessment
    }

    /// 立刻收起覆盖度判定卡。
    public func dismissAssessment() {
        assessmentDismissTask?.cancel()
        assessmentDismissTask = nil
        lastAssessment = nil
        lastAssessedScenarioID = nil
    }

    /// 判定卡字更多、要读一会儿，所以比奖励条（5 秒）多留一倍时间。
    func scheduleAssessmentDismissal() {
        assessmentDismissTask?.cancel()
        assessmentDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            withAnimation(.app(.reveal)) { self?.lastAssessment = nil }
        }
    }

    /// 课程阶梯（CEFR 分档 + 大树关卡挂档），供进度页展示。
    ///
    /// 纯计算、不落库：素材改档、绑定改表，这里立刻跟着变。
    ///
    /// 自己补一次绑定注入，**不假设 `start()` 已经跑过** ——
    /// `progress` 的初始值是 `.seed()`，那份数据里每一关的 `scenarioID` 都是 nil，
    /// 少了这一步，阶梯会全部显示成「未挂关」。
    /// 绑定表为空时**原样保留**现有绑定（不静默清空）。
    public var curriculumStages: [CurriculumStage] {
        var tree = progress
        if !levelBindings.isEmpty {
            tree.applyScenarioBindings(levelBindings)
        }
        return CurriculumLadder.stages(scenarios: scenarios, levels: tree.levels)
    }

    /// 整条课程阶梯的完成度 0...1。
    public var curriculumProgress: Double {
        CurriculumLadder.overallProgress(curriculumStages)
    }

    func scheduleRewardDismissal() {
        rewardDismissTask?.cancel()
        rewardDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.app(.reveal)) { self?.lastReward = nil }
            // 自动收起同样要给被盖住的庆祝一个补放机会。
            if self?.rewardCelebrationPending == true {
                await self?.refreshTodayPanel(force: true)
            }
        }
    }

    public func loadRecords() async {
        records = await services.recentSessions(limit: 20)
        mistakes = await services.recentCorrections(limit: 50)
        await loadReviews()
        reviewIndex = Dictionary(
            (await services.recentReviews(limit: 60)).map { ($0.sessionID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        await refreshLearningMemory()
        await refreshQuestRecords()
    }

    /// 某次练习的复盘（记录页展开卡片时用）。没有复盘返回 nil —— 界面据此显示「暂无复盘」。
    public func review(for sessionID: UUID) -> SessionReview? { reviewIndex[sessionID] }

    /// 重算学习记忆（纯本地库读取，不发起任何模型请求）。
    public func refreshLearningMemory() async {
        learningMemory = await services.learningMemory()
    }

    /// 清除学习记忆（**不可逆**）：删掉纠错 / 复盘 / 跟读 / 复习流水，单词本与对话记录保留。
    ///
    /// 清完立刻重算并刷新记录页，避免界面上还留着「已经删掉」的错题。
    public func clearLearningMemory() async {
        do {
            let cleared = try await services.clearLearningMemory()
            await loadRecords()
            learningMemoryNotice = cleared.total == 0
                ? "本来就没有可清除的学习记忆。"
                : "已清除 \(cleared.total) 条学习记忆（纠错 \(cleared.corrections) · 复盘 \(cleared.reviews) · 跟读 \(cleared.shadowing) · 复习流水 \(cleared.vocabularyReviews)）。单词本和对话记录都还在。"
        } catch {
            // 底层是「学习库尚未就绪」/「SQL 执行失败：…」，动作名已经有了；
            // 再补一句「清除失败：」就是「清除失败：数据库错误：SQL 执行失败：…」那串三冒号。
            learningMemoryNotice = error.localizedDescription
        }
    }

    public func loadReviews() async {
        reviews = await services.recentReviews(limit: 10)
        if let first = reviews.first {
            latestReview = first
        } else {
            latestReview = await services.sessionReview(sessionID: chat.sessionID)
        }
    }

    /// 生成本次练习的复盘总结（本地模型完成，失败时自动给规则版总结）。
    public func generateSessionReview() async {
        guard !isGeneratingReview else { return }
        isGeneratingReview = true
        defer { isGeneratingReview = false }
        let duration = await services.sessionDuration(sessionID: chat.sessionID)
        let corrections = chat.correctionsByMessage.values.flatMap { $0 }
        let review = await services.makeSessionReview(
            sessionID: chat.sessionID,
            messages: chat.messages,
            corrections: corrections,
            duration: duration
        )
        latestReview = review
        reviews = await services.recentReviews(limit: 10)
    }

}
