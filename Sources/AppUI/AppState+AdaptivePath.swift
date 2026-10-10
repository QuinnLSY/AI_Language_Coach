import AIDomain
import Foundation

// MARK: - AppState · 自适应学习路径（⑤）
//
// 把「纠错密度趋势 + 发音走势 + 短板数量 + 档位可信度」聚成一句**当下该做什么**。
//
// ⚠️ 与 `learningPlan` 的分工：那份说**阶段与今天**（我在哪 → 练什么 → 今天还差几项），
// 这份说**最近的走向**（趋势在变，建议也跟着变）。两个都是纯派生、零新表；
// 「该练什么」的排序与措辞全在 `AdaptivePathRule` 的纯函数里（可脱机单测）。
//
// ⚠️ 数量一律**复用**计划那一侧已经算好的口径（`pendingErrorCount` / `dueVocabularyRemaining`），
// 不在这里再算一遍 —— 计划卡、今日任务、这张卡必须报同一个数。
extension AppState {

    /// 自适应建议：**纯派生**（零新表、零新真源）。
    ///
    /// 取数说明：
    /// - 纠错密度趋势 → `learningMemory.practiceTrend`（`LearningMemory` 算好的）
    /// - 发音走势 → `progressSnapshot.pronunciationTrend`（按天、由旧到新；没练的日子不在序列里）
    /// - 短板 → `pendingErrorCount` / `phonemeWeaknesses.count` / `dueVocabularyRemaining`
    /// - 档位可信度 → `placementEstimate.isConfident`
    ///
    /// ⚠️ 这三块里有两块是**惰性**的（学习记忆与顽固音素只在进某些页面时才加载），
    /// 取数由 `prepareLearningPlan()` 一并触发 —— 建议卡与计划卡同页，不再另起一个触发点
    /// （另起一把共用锁会让后到的那件被静默弹回，铁律「两件取数各管各的在途锁」）。
    public var adaptivePath: AdaptivePath {
        AdaptivePathRule.evaluate(
            AdaptivePathSignals(
                trend: learningMemory.practiceTrend,
                pendingErrors: pendingErrorCount,
                weakPhonemes: phonemeWeaknesses.count,
                dueVocabulary: dueVocabularyRemaining,
                isPlacementConfident: placementEstimate.isConfident,
                pronunciationPoints: progressSnapshot.pronunciationTrend
            )
        )
    }

    /// 顺着建议去练：**复用**计划那一侧已有的动作映射，不为同一件事开第二套入口。
    public func performAdaptivePathAction(_ action: LearningPlanFocus.Action) async {
        await performLearningPlanFocus(action)
    }
}
