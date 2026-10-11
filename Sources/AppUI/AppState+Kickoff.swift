import AIDomain
import Foundation

// MARK: - 开屏话题卡（⑦-B①）
//
// 这里只做两件事：**算卡片**（把各处状态收成纯函数的入参）与**执行卡片**（把动作翻成
// 已有的动作）。判据与文案一律在 `AIDomain/TopicKickoff`，本文件不重写任何一句。
//
// ⚠️ 「只算不存」：`kickoffSuggestions` 是派生值。
// 它依赖的三样东西（上次练到哪 / 今天有什么词 / 句库）随时会变，
// 存一份就等于接受了「卡片和真实进度对不上」这件事。

extension AppState {

    /// 重算话题卡。
    ///
    /// 与今日面板同一批数据（都已经过真实记录），所以在 `refreshTodayPanel` 里顺手刷；
    /// 纯计算、不发请求，多刷几次没有代价。
    public func refreshKickoffs(now: Date = Date()) {
        kickoffSuggestions = TopicKickoff.plan(
            TopicKickoff.Context(
                priorPractice: priorPractice(now: now),
                todayWords: dailyWords.map(\.word),
                smallTalkPool: starterQuestions,
                dayKey: ShadowingDailyRule.dayKey(now),
                language: learningLanguage,
                wordPromptTemplate: Self.kickoffWordPromptTemplate
            )
        )
    }

    /// 点一张卡。
    ///
    /// ⚠️ 卡片点了必须有反应：找不到目标情景时要**把提示说出来并立刻重算** ——
    /// 留着一张点不动的卡在屏幕上，比没有卡更让人困惑。
    @MainActor
    public func performKickoff(_ suggestion: KickoffSuggestion) async {
        switch suggestion.action {
        case .send(let text):
            _ = sendChat(text)
        case .openScenario(let id):
            await resumeKickoffScenario(id: id)
        }
    }

    // MARK: - 内部

    /// 「请用这个词造个句」这句用学习语言怎么说。
    ///
    /// 由这里（而不是领域层）决定：句子是**学习语言**的，而只有通过配置才知道在学哪门语言。
    /// ⚠️ 当前版本只做英语（`LanguageOptions` 已锁定），将来加语言在这里按
    /// `LearningLanguage.primaryTag` 分派 —— 不要在别处另写一份模板。
    static let kickoffWordPromptTemplate = "Can you help me use the word \"%@\" in a sentence?"

    /// 上次练过的情景：**最晚被推进过、且现在还找得到素材**的那一个。
    ///
    /// 「找得到」是硬条件：素材被删掉（或换过素材包）之后，
    /// 那张卡点下去只能是一次沉默 —— 这种情况跳过它，往下一条记录看。
    private func priorPractice(now: Date) -> PriorPractice? {
        let candidates = questRecords.values
            .filter { !$0.doneStepIDs.isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }

        for record in candidates {
            guard let scenario = scenarios.first(where: { $0.id == record.scenarioID }) else { continue }
            let plan = ScenarioQuestRule.plan(for: scenario)
            guard plan.total > 0 else { continue }
            return PriorPractice(
                scenarioID: record.scenarioID,
                scenarioTitle: scenario.titleZh,
                // ⚠️ 记录里的步数可能比计划多（素材换过、上线加装过步数）：
                // 「完成 5/3」这种数字一露面，整张卡的可信度就没了。
                doneSteps: min(record.doneStepIDs.count, plan.total),
                totalSteps: plan.total,
                hoursAgo: max(Int(now.timeIntervalSince(record.updatedAt) / 3600), 0),
                isComplete: record.isComplete
            )
        }
        return nil
    }

    @MainActor
    private func resumeKickoffScenario(id: String) async {
        guard let scenario = scenarios.first(where: { $0.id == id }) else {
            // 素材没了：说清楚 + 立刻重算，别留一张点不动的卡。
            practiceNotice = AppNotice(text: "那个情景的素材已经不在了，重新挑一个开始吧。")
            refreshKickoffs()
            return
        }
        await startScenario(scenario)
    }
}
