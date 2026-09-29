import AIDomain
import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - AppState · 今日作业（老师黑板）
// #267 自 AppState.swift 拆出（2026-09-20）：单文件 5136 行超载，按域切为扩展。
// 同模块 extension，语义与拆分前完全一致；成员访问级别已放宽到 internal。
/// 学习进度页上「点一下就滚过去」的那几张卡（一次性意图的目标）。
///
/// 收成枚举而不是再加一个 `xxxFocusTick` 布尔量：跳转意图的机制（tick + pending + 消费）
/// 只该有一套，多一个目标就多一处「忘了复位」的机会。
public enum ProgressFocusTarget: Sendable {
    /// 今日任务卡（黑板上的小图标点进来）。
    case dailyTasks
    /// 年度学习记录卡（侧栏火苗徽章点进来）。
    case annualRecap
}

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
        focusProgress(on: .dailyTasks)
    }

    /// 侧栏火苗徽章 → 切到「学习进度」页并滚到**年度学习记录卡**。
    ///
    /// 「连续 N 天」这个数字的全部上下文都在那张卡上（整年的练习热力图 + 达成天数），
    /// 点它就该直接看到那一年，而不是落在页面顶上再让人自己滚。
    ///
    /// ⚠️ 年度汇总是**开屏故意不跑**的那一个（`refreshTodayPanel` 只查窗口内 —
    /// 全年 53×7 的热力图不该挂在启动关键路径上）。所以这里要顺手把那年补齐，
    /// 否则用户点过去只会看到一张**空网格** —— 那比不跳还糟。
    /// 补齐走 `ensureAnnualRecapLoaded`（年度自己的在途锁），**不是** `reloadProgress`：
    /// 后者那道重入保护的锁是「窗口快照正在跑」，而开屏那一轮恰好只查窗口，
    /// 火苗点得早就会被它直接弹回、年度永远不加载（详见那个方法的注释）。
    public func openAnnualRecapInProgress() async {
        focusProgress(on: .annualRecap)
        await ensureAnnualRecapLoaded()
    }

    private func focusProgress(on target: ProgressFocusTarget) {
        applySection(.progress)
        progressFocusPending = target
        progressFocusTick += 1
    }

    /// 消费一次「滚到某张卡」的意图（返回要滚去哪；没有意图 → nil）。
    ///
    /// 与 `recordsFocus` 同一套道理：跳转是**这一次点击**的意图，不是这一页的默认行为 ——
    /// 页面读一次就该清掉，下次从侧栏正常进来不许自动跳。
    public func consumeProgressFocus() -> ProgressFocusTarget? {
        defer { progressFocusPending = nil }
        return progressFocusPending
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
        // ⚠️ 汇总完**立刻**抬高水位：这一刻的记录是今天最多的一刻。
        // 晚一步就晚了 —— 开屏这条路上，紧接着就会走「复盘上一段 + 清流水」，
        // 那时今天的对话数已经掉下去了（用户报障的时序正是这个）。
        raiseDailyTaskFloor()

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

    /// 把每日任务的三项完成量抬到「今天见过的最大值」（只增不减，`DailyTaskFloor`）。
    ///
    /// ⚠️ 用**不带高水位**的原始计划来抬：拿已经抬高过的计划去抬，高水位就失去了
    /// 「今天真实做到过多少」这个含义，只会滚成一条无法解释的曲线。
    /// ⚠️ 只在高水位真的变了的时候才写盘 —— 这个函数每轮对话末尾都会跑一次。
    func raiseDailyTaskFloor() {
        let dayKey = ShadowingDailyRule.dayKey()
        let raw = DailyPlanner.plan(
            snapshot: progressSnapshot,
            mode: product.dailyGoalMode,
            now: Date()
        )
        let raised = dailyTaskFloor.raising(raw, dayKey: dayKey)
        guard raised != dailyTaskFloor else { return }
        dailyTaskFloor = raised
    }

    /// 今日完成的收尾仪式（#227）：黑板升起 + 盖章（幂等）+ 大树小动物错落欢跳 + 森林烟花几秒。
    ///
    /// ⚠️ 黑板要**自己升起来**（2026-09-29 用户报障「黑板没有升起、盖章、放烟花了」）：
    /// 盖章与烟花都画在展开的板面上（`BlackboardPanel`），板收着的时候什么也看不见。
    /// 侧栏收起时先拉开侧栏再升板（两步与 `openBoardFromCollapsedSidebar` 同一套理由：
    /// 两个弹簧叠在一起会抖）。这是**一天一次**的庆祝，主动升起不算「抢界面」。
    func celebrateToday(dayKey: String) {
        // 一天只放一次（`dayKey` 落盘）：练完那一刻放，之后反复汇总都不再放。
        celebratedDayKey = dayKey
        rewardCelebrationPending = false
        celebrationTick += 1
        isCelebratingToday = true
        // 黑板升起（侧栏收着就先拉开侧栏）。
        withAnimation(.app(.panel)) {
            isSidebarExpanded = true
            isBlackboardExpanded = true
        }
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
