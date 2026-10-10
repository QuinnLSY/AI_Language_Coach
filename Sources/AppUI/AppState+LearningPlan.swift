import AIDomain
import Foundation

// MARK: - AppState · 学习计划（① 个性化学习计划）
//
// 把「能力定位 + 今日任务 + 错题 + 顽固音素 + 到期词汇」聚合成一份计划，
// 并把领域层的 `LearningPlanFocus.Action` 映射到**已有的动作**上。
//
// ⚠️ 计划本身**零新表、零新真源**：每一块都来自它原本的取数口，
// 这里只做聚合；「重点」的排序与文案口径全在 `LearningPlanner` 的纯函数里（可脱机单测）。
extension AppState {

    /// 学习计划：阶段层（我在哪 → 要去哪 → 这个阶段练什么）+ 今日层（今天做什么）。
    public var learningPlan: LearningPlan {
        LearningPlanner.plan(
            estimate: placementEstimate,
            dailyPlan: dailyPlan,
            recurringErrorCount: pendingErrorCount,
            weakPhonemeCount: phonemeWeaknesses.count,
            dueVocabularyRemaining: dueVocabularyRemaining
        )
    }

    /// 让计划要用的两块**惰性数据**就位。
    ///
    /// ⚠️ 学习记忆（反复错）与顽固音素都是「进某个页面才加载」的：
    /// 前者只在记录页 / 改错练习 / 考试模式里刷新，后者只在跟读汇总时重算。
    /// 学习进度页从不碰它们 —— 不补这一步，计划卡的「重点」会**恒为空**（看着像练完了，其实是没取数）。
    ///
    /// ⚠️ 两块**各自有自己的在途锁**，这里只并发触发、不另加一把共用锁：
    /// 共用锁会让后到的那件被静默弹回，于是其中一块永远加载不出来（铁律「两件取数各管各的在途锁」）。
    public func prepareLearningPlan() async {
        async let memory: Void = refreshLearningMemory()
        async let phonemes: Void = refreshPhonemeWeaknesses()
        _ = await (memory, phonemes)
    }

    /// 还没练掉的反复错：学习记忆里的错题去掉「已攻克」的那些。
    ///
    /// ⚠️ 复用 `ErrorDrillSession.queue`（开一轮改错练习用的是**同一个**筛选），
    /// 不在这里另写一遍过滤 —— 记忆卡、改错练习、学习计划三处必须说同一个数。
    /// `limit` 传 `Int.max`：计划要报**总数**，不能被练习卡的上限（`maxCards` = 5 张）截断。
    var pendingErrorCount: Int {
        ErrorDrillSession.queue(
            from: learningMemory.recurringErrors,
            mastered: conqueredErrorIDs,
            limit: .max
        ).count
    }

    /// 今天起初到期、还没复习的词数。
    ///
    /// 口径与「今日任务」的复习项同源（`dueAtDayStart` 减去今天已复习的那批），
    /// 两处不会一个说「还剩 3 个」、另一个说「已完成」。
    var dueVocabularyRemaining: Int {
        let stats = vocabularyStats
        return max(stats.dueAtDayStart - stats.dueAtDayStartReviewed, 0)
    }

    /// 把计划里的一项送到对应的练习上。
    ///
    /// ⚠️ 只复用**已有**的动作，不新开练习入口：计划的价值在「把人送到该去的地方」，
    /// 不在于再长出一套平行链路（`open(_ kind:)` 之于今日任务也是这个路子）。
    public func performLearningPlanFocus(_ action: LearningPlanFocus.Action) async {
        switch action {
        case .errorDrill:
            await startErrorDrill()
        case .phonemeDrill:
            // 专项要指名一个音；计划报的是「有几个音要练」，这里挑排最前的那个
            // （`PhonemeWeaknessAnalyzer` 已按「错得多 + 分得低」排好序）。
            guard let weakness = phonemeWeaknesses.first else { return }
            startPhonemeDrill(for: weakness)
        case .vocabulary:
            await openVocabulary()
        case .shadowing:
            await openShadowing()
        case .conversation:
            await openPractice()
        }
    }
}
