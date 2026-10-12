import Foundation

// MARK: - 菜单栏常驻助手（纯规则）
//
// 菜单栏那块小地方管的不是「再开一扇窗」，是**把「想起 → 打开」从两步压成一步**：
// 用户在任何应用里点一下状态栏图标，就该看到「今天还剩什么」和「现在该点哪个按钮」，
// 而不是又被拉去主窗口自己找。
//
// 因此这里只有三件事：一句话状态、一条建议、两三条备选。**绝不复制首页**
// （不需要图表、不需要今日任务卡的全部理由 —— 那是打开主窗口之后看的）。
//
// ⚠️ 本文件是纯函数：不 import SwiftUI、不认识 AppState。依赖全由参数给进来，
// 所以「没有数据时文案怎么说」「连胜几天的判定」这些边界能被单测逐个钉住。

public enum MenuBarAssistant {

    /// 除了「今天第一件还没做完的事」之外，最多再给几条备选。
    ///
    /// 三条是**一眼看得完、又不用纠结**的上限；再多就变成第二个首页了。
    public static let maxSecondaryCount = 2

    /// 面板上的一条动作。
    public struct Action: Sendable, Equatable, Identifiable {
        /// 点下去去哪一页。
        public let section: AppSection
        /// 做什么（真值插值：「跟读 3 句，逐音素纠音」）。
        public let title: String
        /// 还差多少（真值插值：「0 / 3 次」）；没有可说的就是空串。
        public let detail: String

        public var id: String { section.rawValue }

        public init(section: AppSection, title: String, detail: String = "") {
            self.section = section
            self.title = title
            self.detail = detail
        }
    }

    /// 面板这一屏的全部内容。
    public struct Snapshot: Sendable, Equatable {
        /// 一句话状态（「今日 1 / 3 项」）。
        public let headline: String
        /// 副行（「连续 5 天 · 12 分钟」）。
        public let detail: String
        /// 现在该按的那颗（nil = 没什么可建议的）。
        public let primary: Action?
        /// 剩下的备选。
        public let secondary: [Action]
        /// 今天的任务全做完了（面板语气换一套）。
        public let isAllDone: Bool
        /// 连续纪录今天就到头了（副行要提醒，不是年后才发现）。
        public let isStreakAtRisk: Bool

        public init(
            headline: String,
            detail: String,
            primary: Action?,
            secondary: [Action],
            isAllDone: Bool,
            isStreakAtRisk: Bool
        ) {
            self.headline = headline
            self.detail = detail
            self.primary = primary
            self.secondary = secondary
            self.isAllDone = isAllDone
            self.isStreakAtRisk = isStreakAtRisk
        }
    }

    /// 组装这一屏。
    ///
    /// - Parameters:
    ///   - plan: 今日计划（没排出来 = 还没数据，那时按「待安排」说，不谎报 0/3）。
    ///   - streakDays: 连续天数（0 天就不提，见 `MenuBarAssistant.streakText`）。
    ///   - todaySeconds: 今天练了多久。
    ///   - hasPracticeToday: 今天动过没有（断签判定）。
    public static func snapshot(
        plan: DailyPlan,
        streakDays: Int,
        todaySeconds: TimeInterval,
        hasPracticeToday: Bool
    ) -> Snapshot {
        let isAllDone = plan.isAllDone
        let primary: Action?
        let secondary: [Action]

        if let next = plan.nextTask {
            let rest = plan.tasks.filter { !$0.isDone }.dropFirst()
            primary = Action(
                section: AppSection(next.kind),
                title: next.title,
                detail: next.progressText
            )
            secondary = Array(rest.prefix(maxSecondaryCount).map { task in
                Action(section: AppSection(task.kind), title: task.title, detail: task.progressText)
            })
        } else if plan.totalCount > 0 {
            // 都做完了：再挂一个「去看战绩」就够了，不必再给三条任务。
            primary = Action(section: .practice, title: Self.idlePrimaryTitle, detail: "")
            secondary = [
                Action(
                    section: .progress,
                    title: "看今天练了多少",
                    detail: ProgressAggregator.durationText(todaySeconds)
                )
            ]
        } else {
            // 计划还没排出来：这时候**不要显示 0/3**，那是在告诉用户「你今天什么都没做」。
            primary = Action(section: .practice, title: "和老师聊两句", detail: "")
            secondary = [Action(section: .scenarios, title: "挑个情景练一段", detail: "")]
        }

        return Snapshot(
            headline: headline(plan),
            detail: [streakText(streakDays), ProgressAggregator.durationText(todaySeconds)]
                .compactMap { $0 }
                .joined(separator: " · "),
            primary: primary,
            secondary: secondary,
            isAllDone: isAllDone,
            isStreakAtRisk: streakDays >= 1 && !hasPracticeToday
        )
    }

    // MARK: 文案

    /// 今天做完了之后那颗主按钮的名字。
    private static let idlePrimaryTitle = "再多聊两句"

    /// 状态那一行。
    ///
    /// ⚠️ 与首屏今日卷轴（`TodayPanel.statusLine`）逐字同源：两处都在报同一件事，
    /// 一边说「2 / 3 项」、另一边说「还剩 1 项」，用户只会觉得有一边在胡说。
    /// 一致性由 `MenuBarAssistantTests.testHeadlineMatchesTodayPanel` 钉着。
    public static func headline(_ plan: DailyPlan) -> String {
        guard plan.totalCount > 0 else { return "今日 待安排" }
        return plan.isAllDone ? "今日 全部完成" : "今日 \(plan.progressText)"
    }

    /// 连续天数。**0 天时返回 nil** —— 挂一个「连续 0 天」等于把没坚持这件事天天念一遍。
    public static func streakText(_ streakDays: Int) -> String? {
        guard streakDays >= 1 else { return nil }
        return "连续 \(streakDays) 天"
    }
}
