import AIDomain
import AIServices
import AppCore
import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - AppState · 学习记录 / 学习进度 / 定时提醒
// #267 自 AppState.swift 拆出（2026-09-20）：单文件 5136 行超载，按域切为扩展。
// 同模块 extension，语义与拆分前完全一致；成员访问级别已放宽到 internal。
extension AppState {
    // MARK: - 学习记录

    public func openRecords(focus: RecordsFocus? = nil) async {
        // 跳转目标先记下来、由学习记录页消费掉：视图是 `if/else` 切出来的，
        // 每次进来都是新建的实例，没法靠视图自己的状态接住这个意图。
        recordsFocus = focus
        applySection(.records)
        await loadRecords()
    }

    public func openPractice() async {
        applySection(.practice)
        // 回到对话页 = 已经看到老师开口了，左栏那个提示点该收了。
        teacherOpenerPending = false
        // 卷轴上的进度可能是刚才练出来的（本地聚合，有节流）。
        await refreshTodayPanel()
    }

    // MARK: - 学习进度（Dashboard，第 25 步）

    /// 进入学习进度页并汇总一次。星星与每日目标是产品层输入，记录折算在服务层。
    public func openProgress() async {
        applySection(.progress)
        await reloadProgress()
    }

    /// 重新汇总学习进度（切窗口 / 手动刷新 / 刚练完回来都走这里）。
    ///
    /// - Parameter includeAnnual: 是否顺带汇总**全年**记录卡。开屏的今日卷轴传 false ——
    ///   那张 53×7 热力图要回看一整年，不该挂在「打开应用第一眼」的关键路径上。
    public func reloadProgress(includeAnnual: Bool = true) async {
        // 重入保护：页面出现与卡片刷新可能同时触发，重复跑一遍全库汇总没有意义。
        guard !isLoadingProgress else { return }
        isLoadingProgress = true
        defer { isLoadingProgress = false }
        // 年度记录要回看一整年，取数量级远大于窗口 —— 两件事**并行**做，
        // 串起来会让进度页每次都等两遍查询。
        //
        // ⚠️ goalMinutes 用 `effectiveGoalMinutes`：保底档下判定口径就是 5 分钟
        // （目标环、goalReached 与黑板计划的量对得上 —— 达标判定与实际记录一致）。
        // 每周小结 / 月环比（#228）同样并行：它要看 63 天，不该串在窗口快照后面。
        async let insight = services.weeklyInsight()
        let snapshot: ProgressSnapshot
        if includeAnnual {
            async let recap = services.annualRecap(goalMinutes: effectiveGoalMinutes)
            snapshot = await services.progressSnapshot(
                days: progressWindowDays,
                totalStars: progress.totalStars,
                goalMinutes: effectiveGoalMinutes
            )
            annualRecap = await recap
        } else {
            snapshot = await services.progressSnapshot(
                days: progressWindowDays,
                totalStars: progress.totalStars,
                goalMinutes: effectiveGoalMinutes
            )
        }
        progressSnapshot = snapshot
        weeklyInsight = await insight
    }

    /// 能力定位（#229）：由进度快照 + 词汇量折出来的**估计值**，与课程进度无关。
    ///
    /// 词汇量优先用去重口径（设置页同一个数）；词汇页还没进过时退回快照的全量统计。
    public var placementEstimate: PlacementEstimate {
        let vocabularyCount = max(vocabularyUniqueWordCount, progressSnapshot.vocabulary.total)
        return PlacementEstimator.estimate(
            skills: progressSnapshot.skills,
            totalMessages: progressSnapshot.totalMessages,
            activeDays: progressSnapshot.activeDays,
            vocabularyCount: vocabularyCount,
            masteredCount: progressSnapshot.vocabulary.mastered
        )
    }

    /// 切换统计窗口（7 / 14 / 30 天）。
    public func setProgressWindow(_ days: Int) async {
        progressWindowDays = min(max(days, 7), 90)
        await reloadProgress()
    }

    /// 每日目标（分钟）——写产品配置（持久化）。
    public func setDailyGoalMinutes(_ minutes: Int) async {
        product.dailyGoalMinutes = min(max(minutes, 5), 180)
        await persistProduct()
        await reloadProgress()
    }

    /// 当前每日目标（分钟）。
    public var dailyGoalMinutes: Int { product.dailyGoalMinutes }

    /// 当前目标档位（保底 5 分钟 / 进阶）。
    public var dailyGoalMode: DailyGoalMode { product.dailyGoalMode }

    /// 切换目标档位（持久化）。
    public func setDailyGoalMode(_ mode: DailyGoalMode) async {
        guard mode != product.dailyGoalMode else { return }
        product.dailyGoalMode = mode
        await persistProduct()
        await reloadProgress()
    }

    /// 判定「今天目标达成」的时长口径（分钟）：
    /// 保底档固定 5（与保底计划的量对得上），进阶档用设置的目标值。
    var effectiveGoalMinutes: Int {
        product.dailyGoalMode == .baseline
            ? DailyGoalMode.baselineMinutes
            : product.dailyGoalMinutes
    }

    // MARK: 定时练习提醒（#226）

    /// 当前提醒开关 / 时刻（设置页读取）。
    public var practiceReminderEnabled: Bool { product.practiceReminderEnabled }
    public var practiceReminderHour: Int { product.practiceReminderHour }
    public var practiceReminderMinute: Int { product.practiceReminderMinute }

    /// 开关练习提醒（用户主动动作 → 允许弹系统授权框）。
    public func setPracticeReminderEnabled(_ enabled: Bool) async {
        product.practiceReminderEnabled = enabled
        await persistProduct()
        await syncPracticeReminder(requestIfNeeded: true)
    }

    /// 改提醒时刻（持久化 + 重排；已授权的话立即生效）。
    public func setPracticeReminderTime(hour: Int, minute: Int) async {
        product.practiceReminderHour = min(max(hour, 0), 23)
        product.practiceReminderMinute = min(max(minute, 0), 59)
        await persistProduct()
        await syncPracticeReminder(requestIfNeeded: false)
    }

    /// 把提醒配置同步给系统通知中心，并回写授权状态供设置页展示。
    func syncPracticeReminder(requestIfNeeded: Bool) async {
        let copy = TodayPanel.practiceReminderCopy(streakDays: progressSnapshot.streakDays)
        reminderAuthorizationDenied = await reminders.sync(
            enabled: product.practiceReminderEnabled,
            requestIfNeeded: requestIfNeeded,
            hour: product.practiceReminderHour,
            minute: product.practiceReminderMinute,
            title: copy.title,
            body: copy.body
        )
    }

}
