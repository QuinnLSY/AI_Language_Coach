import AIDomain
import AIInfrastructure
import AIInterfaces
import AppCore
import Foundation

// MARK: - CoachServices · 学习进度与每周小结（第 25 步 / #228）
//
// #660 自 CoachServices.swift 拆出（2026-10-24）：原文件 3165 行单 actor 超载，按域切为扩展。
// 同模块 extension，语义与拆分前完全一致；跨文件调用的成员已从 private 放宽到
// internal（模块内可见，跨模块零影响，public API 不变）。
extension CoachServices {
// MARK: - 学习进度（数据库）

/// 读进度；首次启动（无记录）时写入种子关卡并返回。
/// 返回前统一注入「关卡 → 情景」绑定（绑定表来自资源文件，不落库）。
public func loadProgress() async -> LearnerProgress {
    var progress: LearnerProgress
    if let learning, let saved = try? await learning.loadProgress() {
        progress = saved
    } else {
        progress = .seed()
        await saveProgress(progress)
    }
    progress.applyScenarioBindings(LevelBindingCatalog.bundled())
    return progress
}

public func saveProgress(_ progress: LearnerProgress) async {
    guard let learning else {
        await recordPersistenceFailure("保存学习进度", nil)
        return
    }
    // 星星与关卡进度是**不可逆累积**的成果：写不进去必须让用户知道（否则练一天全白练）。
    do {
        try await learning.saveProgress(progress)
    } catch {
        await recordPersistenceFailure("保存学习进度", error)
    }
}

// MARK: - 学习进度快照（第 25 步 Dashboard）

/// 汇总一份学习进度快照（今日 / 时长 / 纠错 / 词汇 / 发音 / 目标 + 六类趋势）。
/// 星星与每日目标由产品层传入 —— 本服务只负责「记录折算」这一件事。
public func progressSnapshot(
    days: Int = ProgressAggregator.defaultDays,
    totalStars: Int = 0,
    goalMinutes: Int = ProgressAggregator.defaultGoalMinutes,
    preloadedVocabulary: [VocabularyEntry]? = nil
) async -> ProgressSnapshot {
    await progress.snapshot(
        days: days, totalStars: totalStars, goalMinutes: goalMinutes,
        preloadedVocabulary: preloadedVocabulary
    )
}

/// 近一年的练习分布（年度记录卡）。与 `progressSnapshot` 同层：这里只做取数编排。
public func annualRecap(
    now: Date = Date(),
    goalMinutes: Int = ProgressAggregator.defaultGoalMinutes,
    preloadedVocabulary: [VocabularyEntry]? = nil
) async -> AnnualRecap {
    await progress.annualRecap(now: now, goalMinutes: goalMinutes, preloadedVocabulary: preloadedVocabulary)
}

// MARK: - 每周小结 / 月环比（#228）

/// 「本周小结」卡的数字（取数与折算都在 `ProgressService` / `ProgressAggregator`）。
public func weeklyInsight(preloadedVocabulary: [VocabularyEntry]? = nil) async -> WeeklyInsight? {
    await progress.weeklyInsight(preloadedVocabulary: preloadedVocabulary)
}

/// 进度页三件套共用的**一次**词汇全量读取（`reloadProgress` 取一遍传三处，
/// 免得 snapshot / weeklyInsight / annualRecap 各自全表扫 vocabulary_items 三遍）。
public func progressVocabulary() async -> [VocabularyEntry] {
    guard let learning else { return [] }
    return (try? await learning.allVocabulary()) ?? []
}
}
