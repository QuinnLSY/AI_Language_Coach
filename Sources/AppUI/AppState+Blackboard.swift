import AIDomain
import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - AppState · 今日作业（老师黑板）
// #267 自 AppState.swift 拆出（2026-09-20）：单文件 5136 行超载，按域切为扩展。
// 同模块 extension，语义与拆分前完全一致；成员访问级别已放宽到 internal。
extension AppState {
    // MARK: - 今日作业（老师黑板）

    /// 黑板上点某一项 → 直接去做（与「学习进度」页同一个去处，同一套口径）。
    public func openTodayTask(_ kind: DailyTask.Kind) async {
        switch kind {
        case .conversation: await openPractice()
        case .shadowing: await openShadowing()
        case .review: await openVocabulary()
        }
    }

    /// 黑板上的小图标 → 切到「学习进度」页并滚到今日任务卡。
    ///
    /// 板上放不下详情（宽度只有侧栏那么宽），所以要留一条「去哪儿看完整版」的路。
    ///
    /// ⚠️ 除了 `progressFocusTick`（**已经在这一页**时再点一次也要能滚）之外，还要落一个
    /// **一次性的意图标记**：页面是从别的页切过来的新实例，`onChange` 只对「变化」生效，
    /// 而 tick 在它出现之前就已经加过了 —— 光靠 tick 会「指令收到了，页面不动」。
    public func openTodayTasksInProgress() {
        applySection(.progress)
        progressFocusPending = true
        progressFocusTick += 1
    }

    /// 消费一次「滚到今日任务卡」的意图。
    ///
    /// 与 `recordsFocus` 同一套道理：跳转是**这一次点击**的意图，不是这一页的默认行为 ——
    /// 页面读一次就该清掉，下次从侧栏正常进来不许自动跳。
    public func consumeProgressFocus() -> Bool {
        guard progressFocusPending else { return false }
        progressFocusPending = false
        return true
    }

    /// 汇总今日作业需要的进度，并判定「今日全部完成」的庆祝。
    ///
    /// - Parameter force: true = 跳过节流（启动 / 手动刷新走这条）。
    ///
    /// ⚠️ 不跑年度汇总：开屏那一下只查窗口内的记录，全年 53×7 的那张热力图
    /// 留给真正打开进度页的人（见 `reloadProgress(includeAnnual:)`）。
    public func refreshTodayPanel(force: Bool = false) async {
        let now = Date()
        guard force || now.timeIntervalSince(lastTodayPanelRefreshAt) > 15 else {
            // 被节流吞掉的那一轮不许就此蒸发：收尾补刷一次（最多 15s），
            // 否则「做完最后一项」的那一刻可能永远等不到庆祝。
            scheduleTrailingRefresh()
            return
        }
        trailingRefreshTask?.cancel()
        trailingRefreshTask = nil
        lastTodayPanelRefreshAt = now
        await reloadProgress(includeAnnual: false)

        let key = ShadowingDailyRule.dayKey()
        if TodayPanel.shouldCelebrate(
            plan: dailyPlan,
            celebratedDayKey: celebratedDayKey,
            dayKey: key
        ) {
            if lastReward != nil {
                // 情景结算卡（+N 星 / 点亮关卡）还挂在最上层：先不放庆祝，
                // **也不盖章** —— 卡收起后的那次刷新会补放（dayKey 还没写，判定仍成立）。
                rewardCelebrationPending = true
            } else {
                celebrateToday(dayKey: key)
            }
        }

        // 开屏自动展开一次黑板：今天还没做完 → 打开就知道要交什么作业。
        // ⚠️ 只在本次启动里做一次，且 `dayKey` 落盘保证一天最多一次 ——
        // 用户手动收起之后不许再自己弹开（那是抢界面）。
        guard !didAutoExpandBoardThisLaunch,
              TodayPanel.shouldAutoExpand(
                plan: dailyPlan,
                autoExpandedDayKey: boardAutoExpandedDayKey,
                dayKey: key
              ) else { return }
        didAutoExpandBoardThisLaunch = true
        boardAutoExpandedDayKey = key
        Task { [weak self] in
            // 等主界面那一帧稳住再展开，否则动画会和开屏的布局一起抖。
            try? await Task.sleep(for: .seconds(0.6))
            self?.isBlackboardExpanded = true
        }
    }

    /// 今日完成的收尾仪式（#227）：盖章（幂等）+ 大树小动物欢跳 + 黑板烟花几秒。
    func celebrateToday(dayKey: String) {
        // 一天只放一次（`dayKey` 落盘）：练完那一刻放，之后反复汇总都不再放。
        celebratedDayKey = dayKey
        rewardCelebrationPending = false
        celebrationTick += 1
        isCelebratingToday = true
        // 烟花放几秒就撤 —— 开屏第一眼不该有东西一直在动。
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.isCelebratingToday = false
        }
    }

    /// 节流跳过后的收尾补刷（防抖：同一时刻只挂一个）。
    func scheduleTrailingRefresh() {
        guard trailingRefreshTask == nil else { return }
        trailingRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.trailingRefreshTask = nil
            await self?.refreshTodayPanel(force: true)
        }
    }


}
