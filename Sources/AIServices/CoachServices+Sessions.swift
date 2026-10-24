import AIDomain
import AIInfrastructure
import AIInterfaces
import AppCore
import Foundation

// MARK: - CoachServices · 会话持久化与练习复盘
//
// #660 自 CoachServices.swift 拆出（2026-10-24）：原文件 3165 行单 actor 超载，按域切为扩展。
// 同模块 extension，语义与拆分前完全一致；跨文件调用的成员已从 private 放宽到
// internal（模块内可见，跨模块零影响，public API 不变）。
extension CoachServices {
// MARK: - 会话持久化（ChatService 使用）

/// 学习记录现在存得进去吗（false = 本轮的对话 / 复盘 / 错题都不会落库）。
///
/// ⚠️ 这个布尔必须被 UI 读，不能只留作内部判断：库打不开时应用照常能聊，
/// 于是「存不住」这件事**没有任何天然症状** —— 只有退出重进才发现历史是空的。
public var isPersistenceAvailable: Bool { learning != nil }

/// 首次发消息时登记会话（已存在则不动，避免把 message_count 归零）。
public func persistSession(_ session: ChatSession) async {
    guard let learning else {
        await recordPersistenceFailure("保存这段对话", nil)
        return
    }
    do {
        try await learning.createSessionIfAbsent(session)
    } catch {
        await recordPersistenceFailure("保存这段对话", error)
    }
}

/// 把会话标记为「在练某个情景」（进入情景时调用，重启后可接着练）。
/// 传 `nil` 表示退出情景（回到普通练习）。
public func attachScenario(_ scenarioID: String?, to sessionID: UUID, mode: PracticeMode) async {
    guard let learning else {
        await recordPersistenceFailure("记录这个情景", nil)
        return
    }
    do {
        try await learning.setSessionScenario(
            id: sessionID, scenarioID: scenarioID, mode: mode, startedAt: Date()
        )
    } catch {
        await recordPersistenceFailure("记录这个情景", error)
    }
}

/// 某会话进行的情景 id（nil = 普通练习）。
public func sessionScenarioID(_ sessionID: UUID) async -> String? {
    guard let learning else { return nil }
    return (try? await learning.sessionScenarioID(id: sessionID)) ?? nil
}

public func persistMessage(_ message: ChatMessage, sessionID: UUID) async {
    guard let learning else {
        await recordPersistenceFailure("保存这条消息", nil)
        return
    }
    do {
        try await learning.appendMessage(message, sessionID: sessionID)
    } catch {
        await recordPersistenceFailure("保存这条消息", error)
    }
}

/// 删掉若干条消息（气泡上的「删除」）。失败不清空界面 —— 上层据此决定要不要弹提示。
///
/// - Returns: 真的删掉的行数；nil = 没有可用数据库。
@discardableResult
public func deleteMessages(ids: [UUID], sessionID: UUID) async -> Int? {
    guard let learning else {
        await recordPersistenceFailure("删除这几条消息", nil)
        return nil
    }
    do {
        return try await learning.deleteMessages(ids: ids, sessionID: sessionID)
    } catch {
        await recordPersistenceFailure("删除这几条消息", error)
        return nil
    }
}

/// 改写一条消息的正文（气泡内编辑后重发）。
@discardableResult
public func updateMessageContent(id: UUID, content: String) async -> Bool {
    guard let learning else {
        await recordPersistenceFailure("改写这条消息", nil)
        return false
    }
    do {
        // 底层是 `throws` 无返回值：能走完这一行就是改成了（原来靠 `try?` 包出
        // Optional<Void> 再判 nil，那是个会触发「拿 () 比 nil」警告的绕法）。
        try await learning.updateMessageContent(id: id, content: content)
        return true
    } catch {
        await recordPersistenceFailure("改写这条消息", error)
        return false
    }
}

public func finishSession(_ sessionID: UUID) async {
    guard let learning else {
        await recordPersistenceFailure("结束这段对话", nil)
        return
    }
    do {
        try await learning.finishSession(id: sessionID)
    } catch {
        await recordPersistenceFailure("结束这段对话", error)
    }
}

public func persistCorrection(_ correction: GrammarCorrection, sessionID: UUID) async {
    guard let learning else {
        await recordPersistenceFailure("保存这条纠错", nil)
        return
    }
    do {
        try await learning.appendCorrection(correction, sessionID: sessionID)
    } catch {
        await recordPersistenceFailure("保存这条纠错", error)
    }
}

public func recentCorrections(limit: Int = 50) async -> [GrammarCorrection] {
    guard let learning else { return [] }
    return (try? await learning.recentCorrections(limit: limit)) ?? []
}

/// 历史纠错**原始记录**（时间新 → 旧）。语法分析判重与教学决策都用它。
///
/// 与 `recentCorrections` 的区别：带上时间戳与原句上下文，
/// 「同一个错犯了几次」要按记录算，不能先丢时间信息再回头猜。
public func recentCorrectionRecords(limit: Int = 100) async -> [CorrectionRecord] {
    guard let learning else { return [] }
    return (try? await learning.correctionRecords(since: .distantPast, limit: limit)) ?? []
}

public func recentSessions(limit: Int = 20) async -> [SessionSummary] {
    guard let learning else { return [] }
    return (try? await learning.recentSessions(limit: limit)) ?? []
}

public func sessionSummary(id: UUID) async -> SessionSummary? {
    guard let learning else { return nil }
    return try? await learning.sessionSummary(id: id)
}

/// 在对话正文里搜关键词（#414 全局搜索）。
///
/// 库不可用 / SQL 出错都返回空：**搜索失败不该弹错误框**，它是锦上添花的那一路，
/// 静默少一个来源，好过吓用户一跳。
public func searchMessages(query: String, limit: Int = 30) async -> [GlobalSearchMessage] {
    guard let learning else { return [] }
    return (try? await learning.searchMessages(query: query, limit: limit)) ?? []
}

// MARK: - 练习复盘（学习记忆）

/// 会话时长（秒）：**末条消息 − 开始**，再夹取到单次会话上限。
///
/// ⚠️ 以前是 `Date() - startedAt`（向「此刻」敞口）。会话在正常使用里不会被显式结束，
/// 于是「昨天开的那一段」今天算出来是 1180 分钟，而且每刷新一次还在涨 ——
/// 最近练习里每一条时长都在说谎。
public func sessionDuration(sessionID: UUID) async -> TimeInterval {
    guard let summary = await sessionSummary(id: sessionID) else { return 0 }
    let span = summary.endedAt.timeIntervalSince(summary.startedAt)
    return min(max(span, 0), ProgressAggregator.sessionDurationCap)
}

/// 某一段练习里的纠错（复盘用）。
///
/// ⚠️ 开屏复盘必须用这个，而不是内存里的 `correctionsByMessage`：
/// 恢复出来的会话在内存里没有纠错映射，「老师改过什么」会永远是空的。
public func corrections(sessionID: UUID) async -> [GrammarCorrection] {
    guard let learning else { return [] }
    return (try? await learning.corrections(sessionID: sessionID)) ?? []
}

/// 生成一次练习复盘并落库（模型不可用时自动退化为规则总结）。
public func makeSessionReview(
    sessionID: UUID,
    messages: [ChatMessage],
    corrections: [GrammarCorrection],
    duration: TimeInterval,
    proficiency: String = "beginner"
) async -> SessionReview {
    let configuration = await config.current
    let provider = configuration.resolvedProvider(for: .llm)
    let options = SessionReviewService.ReviewOptions(
        model: await currentLLMModel(),
        temperature: provider?.temperature,
        // 复盘是短 JSON：推理模型会吞掉预算，给足上限（配置优先）。
        maxTokens: provider?.maxTokens,
        learningLanguage: promptLanguage(configuration),
        nativeLanguage: configuration.product.nativeLanguage,
        proficiency: proficiency
    )
    return await reviewer.makeReview(
        sessionID: sessionID,
        messages: messages,
        corrections: corrections,
        duration: duration,
        options: options
    )
}

/// 某会话已有的复盘（未生成则 nil）。
public func sessionReview(sessionID: UUID) async -> SessionReview? {
    await reviewer.review(sessionID: sessionID)
}

/// 最近的复盘列表（学习记录页展示）。
public func recentReviews(limit: Int = 10) async -> [SessionReview] {
    await reviewer.recentReviews(limit: limit)
}

/// 某会话最近一次复盘覆盖到的消息数（判断「有没有新内容需要复盘」）。
public func reviewedMessageCount(sessionID: UUID) async -> Int {
    guard let learning else { return 0 }
    return (try? await learning.reviewedMessageCount(sessionID: sessionID)) ?? 0
}

/// 删掉某会话的**练习流水**（消息 + 纠错），保留会话行与复盘。
///
/// ⚠️ 调用方必须先拿到复盘并确认可用（`PracticeReviewPolicy.canPurgeSource`）：
/// 复盘失败还把流水删了，这一局的对话就永远看不到了。
///
/// - Parameter expectedMessageCount: 复盘时看到的条数。**同一个事务内**比对，
///   对不上就不删（-1）—— 复盘期间学员新说的话不在复盘里，不能连它一起删。
@discardableResult
public func purgePracticeMessages(sessionID: UUID, expectedMessageCount: Int? = nil) async -> Int {
    guard let learning else { return 0 }
    return (try? await learning.purgeSessionMessages(sessionID: sessionID, expectedCount: expectedMessageCount)) ?? 0
}
}
