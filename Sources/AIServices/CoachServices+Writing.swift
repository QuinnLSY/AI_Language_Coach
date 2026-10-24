import AIDomain
import AIInfrastructure
import AIInterfaces
import AppCore
import Foundation

// MARK: - CoachServices · 写作批改与短文阅读（#230 / #231 / #233）
//
// #660 自 CoachServices.swift 拆出（2026-10-24）：原文件 3165 行单 actor 超载，按域切为扩展。
// 同模块 extension，语义与拆分前完全一致；跨文件调用的成员已从 private 放宽到
// internal（模块内可见，跨模块零影响，public API 不变）。
extension CoachServices {
// MARK: - 写作批改（#230）

/// 批改一篇写作。与释义同一条门：模型在跑 + 就绪后一次请求出全部结果。
/// 任何失败返回 nil（UI 给提示，不抛错）。
public func reviewWriting(topic: WritingTopic, essay: String) async -> WritingReview? {
    guard isModelRunning(.llm) else { return nil }
    try? await ensureLLMReady()
    let configuration = await config.current
    return await writing.review(
        topic: topic,
        essay: essay,
        learningLanguage: promptLanguage(configuration),
        nativeLanguage: configuration.product.nativeLanguage,
        model: await currentLLMModel()
    )
}

/// 出今天的短文阅读（`level` 传 CEFR 档位名，如 "B1"；unknown 传空串由服务兜底）。
/// 任何失败返回 nil（UI 给可操作的提示）。判分不在模型侧 —— 生成时答案已随文下发。
public func generateReading(level: String) async -> ReadingPassage? {
    guard isModelRunning(.llm) else { return nil }
    try? await ensureLLMReady()
    let configuration = await config.current
    return await reading.generate(
        theme: ReadingThemeLibrary.theme(for: Date()),
        level: level,
        learningLanguage: promptLanguage(configuration),
        nativeLanguage: configuration.product.nativeLanguage,
        model: await currentLLMModel()
    )
}

// MARK: - 写作 / 阅读记录持久化（#233）

/// 交卷批改成功后落一行写作记录（学习记录页的「写作练习」卡与每周小结都吃它）。
public func recordWritingSubmission(topic: WritingTopic, essay: String, review: WritingReview) async {
    guard let learning else {
        await recordPersistenceFailure("保存这篇作文", nil)
        return
    }
    let words = ShadowingScorer.words(essay).count
    // 这一步紧跟一次已付费的 LLM 批改：作文改完了却没记下来，用户看到分数是假的。
    do {
        try await learning.appendWritingEntry(
            title: topic.title,
            score: review.score.map(Double.init),
            wordCount: words,
            createdAt: Date()
        )
    } catch {
        await recordPersistenceFailure("保存这篇作文", error)
    }
}

/// 某一天已生成的短文（旧 → 新；重启后回看的唯一来源）。
public func todaysReadings(dayKey: Int) async -> [StoredReading] {
    guard let learning else { return [] }
    return (try? await learning.readings(dayKey: dayKey)) ?? []
}

/// 最近读过的短文（新 → 旧）：跨页搜索的「阅读」来源（#414）。
///
/// ⚠️ 不读 AppState 内存里的 `readingEntries`：那只有今天那一两篇，且没进过
/// 阅读页时是空的 —— 搜索承诺的是「读过的短文」，不是「今天这篇」。
public func recentReadings() async -> [StoredReading] {
    guard let learning else { return [] }
    return (try? await learning.recentReadings()) ?? []
}

/// 落一篇短文（生成成功 / 作答变化都整体覆盖写）。
public func saveReading(_ entry: StoredReading) async {
    guard let learning else {
        await recordPersistenceFailure("保存这次阅读", nil)
        return
    }
    // 页面承诺「每一步选择都落库，中途退出也不丢」—— 静默失败等于食言。
    do {
        try await learning.saveReading(entry)
    } catch {
        await recordPersistenceFailure("保存这次阅读", error)
    }
}
}
