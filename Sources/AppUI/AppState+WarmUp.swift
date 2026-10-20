import AIDomain
import AIServices
import AppCore
import Foundation

// MARK: - 碎片热身（⑦-B②）
//
// 这里只做三件事：**排一轮**（把各处状态收成纯函数的入参）、**执行每一步**
//（判词走 `services.vocabulary`，跟读 / 开口走 shadowing 那套录音与评测，
// 发出去走 `sendChat`）、**把结果摆到字段上**。
//
// 步骤编排、推进判据、结算文案一律在 `AIDomain/WarmUp`，本文件不重写任何一句。
//
// ⚠️ **复用而不是复制**：到期队列直接取 `VocabularyReviewSession.queue`
// （间隔规则仍然只在 `ReviewScheduler` 那一处），录音 / 评测走的是词汇复习卡
// 同一条链路 —— 各写一份的结果一定是「两处对同一件事给出不同的分」。

extension AppState {

    /// 重算这一轮热身能做什么。
    ///
    /// 与话题卡同款：纯派生（外加一次随包素材读取，**不发模型请求**），
    /// 所以放在今日面板那批数据后面顺手重算。
    ///
    /// ⚠️ **跑着的一轮不换题**：中途换掉会让「第 2 步」指向另一件事，
    /// 而且已经判过的分记在前一批词名下 —— 那是数据错，不只是界面错。
    public func refreshWarmUp() async {
        guard warmUp == nil else { return }

        let due = VocabularyReviewSession.queue(
            from: vocabularyEntries,
            now: Date(),
            limit: WarmUpPlan.defaultWordCount
        )
        let dayKey = ShadowingDailyRule.dayKey()
        let language = learningLanguage
        // 跟读句：今日素材优先（用户本来就在练这一批），没进过跟读页就退回随包素材。
        let today = shadowingDrills.map(\.text)
        let pool = today.isEmpty ? await services.shadowing.drills().map(\.text) : today
        let sentence = WarmUpPlan.pickSentence(from: pool, dayKey: dayKey, language: language)
        let prompt = WarmUpPlan.pickPrompt(from: starterQuestions, dayKey: dayKey, language: language)
        let plan = WarmUpPlan.plan(dueEntries: due, shadowSentence: sentence, speakPrompt: prompt)
        // 一步都排不出来时不留空壳：一张「热身一轮」点下去没反应，比没有这张卡更糟。
        warmUpPlan = plan.isEmpty ? nil : plan
    }

    /// 开一轮。
    ///
    /// 起手先重排一次：上一次排的可能是几分钟前的事，那批词也许刚在别处判过
    /// （词汇本里点了几下），再拿旧单子开一轮就会让人连着认两遍同一个词。
    public func startWarmUp() async {
        await refreshWarmUp()
        guard let plan = warmUpPlan, !plan.isEmpty else { return }
        await stopSpeaking()
        warmUp = WarmUpProgress(plan: plan, now: Date())
        warmUpNotice = nil
        warmUpStepScore = nil
        warmUpHeardText = nil
        isWarmUpRecording = false
        isWarmUpBusy = false
    }

    /// 给当前这个词判「记得 / 忘了」并前进。
    ///
    /// 判分落的是 `services.vocabulary.grade` —— 与词汇复习卡同一把尺子
    /// （间隔怎么变由 `ReviewScheduler` 决定，热身不另立规则）。
    public func gradeWarmUpWord(remembered: Bool) async {
        guard let step = warmUp?.currentStep, case let .word(entryID, _) = step else { return }
        guard warmUp?.gradeCurrentWord(remembered: remembered) == true else { return }
        _ = await services.vocabulary.grade(id: entryID, remembered: remembered)
        warmUpNotice = nil
        await reloadVocabulary()
        // 判一个词就要让黑板跟着走（force 跳过节流）：热身是今日作业的一部分，
        // 走完了黑板上还写着「0/8」就是在骗人。
        await refreshTodayPanel(force: true)
        sealWarmUpIfFinished()
    }

    /// 听示范（跟读那一步）。
    public func playWarmUpSentence() async {
        guard let step = warmUp?.currentStep, case let .shadow(sentence) = step else { return }
        await speak(sentence)
    }

    /// 当前这一步的录音：点一下开始，再点一下停止并出结果。
    ///
    /// 跟读与开口两个步共用这一条路 —— 差别只在结果怎么用（评分 / 当原话）。
    public func toggleWarmUpRecording() async {
        if isWarmUpRecording {
            await finishWarmUpRecording()
        } else {
            await startWarmUpRecording()
        }
    }

    /// 「继续」：把这一步的结果记进那一轮，前进到下一步。
    ///
    /// 为什么要单独一颗按钮（而不是读完就自动跳）：分数 / 听到的原话得先摆出来
    /// 让人看一眼 —— 自动跳等于「读了，但不知道读成什么样」。
    public func continueWarmUp() async {
        guard let step = warmUp?.currentStep else { return }
        switch step.kind {
        case .word:
            return   // 词这一步靠判分推进，没有「继续」这回事
        case .shadow:
            guard warmUp?.markShadow(score: warmUpStepScore) == true else { return }
            warmUpStepScore = nil
        case .speak:
            guard warmUp?.markSpoken(warmUpHeardText) == true else { return }
            warmUpHeardText = nil
        }
        warmUpNotice = nil
        sealWarmUpIfFinished()
    }

    /// 跳过当前这一步（不想读 / 认不出都走这里）。**不计成绩**。
    public func skipWarmUpStep() async {
        if isWarmUpRecording { await cancelWarmUpRecording() }
        await services.shadowing.stopAudio()
        guard warmUp?.skipCurrent() == true else { return }
        warmUpStepScore = nil
        warmUpHeardText = nil
        warmUpNotice = nil
        sealWarmUpIfFinished()
    }

    /// 结算卡上的「发给老师」：把开口那一步**真说出来的**那句发出去。
    ///
    /// ⚠️ 发的是识别到的原话，不是提示句 —— 发提示句等于替用户说了一句他没说过的话，
    /// 老师接到的也就不是他刚开口说的那句。
    public func sendWarmUpSpokenText() {
        guard let text = warmUp?.spokenText,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        // 与打字发送同一条路（#618）：先收声再发送 —— `sendChat` 如今是 async 的，
        // 整段挪进 Task（`warmUp` 只在发送真的被接受后才收，失败要留着让人重来）。
        Task {
            guard await sendChat(text) else { return }
            warmUp = nil
            warmUpNotice = nil
        }
    }

    /// 收起（结算卡上的「完成」，以及中途退出）。
    public func dismissWarmUp() async {
        if isWarmUpRecording { await cancelWarmUpRecording() }
        await services.shadowing.stopAudio()
        warmUp = nil
        warmUpNotice = nil
        warmUpStepScore = nil
        warmUpHeardText = nil
        isWarmUpBusy = false
        await refreshWarmUp()
    }

    /// 离开对话页时收尾：视图没了，麦克风不能跟着走（与跟读页 / 复习卡同一条纪律）。
    public func cancelWarmUpIfRecording() async {
        guard isWarmUpRecording else { return }
        isWarmUpRecording = false
        await services.shadowing.cancelRecording()
    }

    public func dismissWarmUpNotice() {
        warmUpNotice = nil
    }

    // MARK: - 内部

    private func startWarmUpRecording() async {
        guard warmUp?.currentStep != nil else { return }
        // ⚠️ 识别 / 评分期间不重开麦克风（同跟读页与复习卡）：上一段的识别还在跑就开新录，
        // 两次识别在串行的语音服务上排队，先回来的那次会把结果挂到**当前这一步**上。
        guard !isWarmUpBusy else { return }
        // ⚠️ 真源而非界面快照：巡检挂起后快照会过期（「设置里开着、一用就连不上」的老毛病）。
        _ = (try? await services.resumeIfSuspended(.asr)) ?? false
        await syncModelRunStates()
        guard await services.isModelRunning(.asr) else {
            warmUpNotice = AppNotice(
                text: "\(await services.modelLabel(for: .asr)) 已关闭，请在设置里点绿色的「启动」后再读。",
                action: .retry { [weak self] in
                    guard let self else { return }
                    Task { await self.startWarmUpRecording() }
                }
            )
            return
        }
        warmUpNotice = nil
        warmUpStepScore = nil
        warmUpHeardText = nil
        // 录音前先停掉示范 / 朗读，别把喇叭里的老师声音也录进去。
        await stopSpeaking()
        await services.shadowing.stopAudio()
        await services.shadowing.startRecording(language: ShadowingService.practiceLanguage)
        isWarmUpRecording = await services.voice.isRecording
        if !isWarmUpRecording {
            warmUpNotice = AppNotice(
                text: await services.shadowing.lastError() ?? "麦克风没能打开，检查一下系统权限。",
                action: .retry { [weak self] in
                    guard let self else { return }
                    Task { await self.startWarmUpRecording() }
                }
            )
        }
    }

    private func finishWarmUpRecording() async {
        guard let step = warmUp?.currentStep else { return }
        // 只有真在录音时才收尾：重入拿到的是空音频，会换回一句假的「没有听清」。
        guard isWarmUpRecording else { return }
        isWarmUpRecording = false
        isWarmUpBusy = true
        let recognized = await services.shadowing.finishRecording(language: ShadowingService.practiceLanguage)
        voiceTranscript = nil
        guard let recognized, !recognized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isWarmUpBusy = false
            warmUpNotice = AppNotice(
                text: await services.shadowing.lastError() ?? "没有听清，凑近麦克风再说一次。",
                action: .retry { [weak self] in
                    guard let self else { return }
                    Task { await self.startWarmUpRecording() }
                }
            )
            return
        }
        switch step.kind {
        case .word:
            break   // 词这步没有录音入口（按钮不出现），走到这里是状态错位，不动
        case .shadow:
            let report = await services.shadowing.evaluateSpeech(reference: step.text, recognized: recognized)
            warmUpStepScore = report?.overall
            if report == nil {
                // 没拿到音频就不给分数：宁可少一项，也不拿 0 分冒充「读得很差」。
                warmUpNotice = AppNotice(
                    text: "这次没拿到录音，所以没算分（发音是通过录音量出来的，识别文本替代不了）。",
                    action: .retry { [weak self] in
                        guard let self else { return }
                        Task { await self.startWarmUpRecording() }
                    }
                )
            }
        case .speak:
            warmUpHeardText = recognized
        }
        isWarmUpBusy = false
    }

    private func cancelWarmUpRecording() async {
        guard isWarmUpRecording else { return }
        isWarmUpRecording = false
        await services.shadowing.cancelRecording()
    }

    /// 最后一步做完就钉住结束时刻（用时从此不再往后长），并让林子知道练过了。
    private func sealWarmUpIfFinished() {
        guard warmUp?.isFinished == true, warmUp?.finishedAt == nil else { return }
        warmUp?.finish(now: Date())
        // 一轮热身至少认过一个词才报「词汇练过」：一步没走（全跳过）也去点一圈林子，
        // 那就是拿没发生的事去换一场演出。
        guard (warmUp?.remembered ?? 0) + (warmUp?.forgotten ?? 0) > 0 else { return }
        forest.ingest(.moduleCompleted(module: .vocabulary))
    }
}
