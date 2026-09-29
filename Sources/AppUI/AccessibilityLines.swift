import AIDomain

/// 读屏（VoiceOver）一句话文案的唯一出处（批次七 · G）。
///
/// 为什么收拢：读屏文案散在各个 View 里，改口径要满仓库找；收成纯函数后单测可以
/// 逐字钉住四种关卡状态、两种连胜状态的措辞，View 只管挂 `.accessibilityLabel`。
///
/// 口径纪律（与「用户可见文案」铁律一致）：说事实，不说形容词 ——
/// 「尚未解锁」而不是「很遗憾还没解锁」；风险态先说「今天还没练」再说天数。
enum AccessibilityLines {

    // MARK: - 关卡节点

    /// 关卡节点的读屏一句话。
    ///
    /// 顺序是「先说这是什么、再说学到哪」：标题 → 星数 → 状态 → 情景归属。
    /// locked 也报星数（0/3）—— 让读屏用户知道目标长什么样，而不是只听到「锁着」。
    static func levelLine(level: TreeLevel, note: TreeLevelNote?) -> String {
        let stateLine: String
        switch level.state {
        case .locked: stateLine = "尚未解锁"
        case .unlocked: stateLine = "可以开始"
        case .inProgress: stateLine = "正在进行"
        case .completed: stateLine = "已完成"
        }
        var line = "\(level.title)，已得 \(level.earnedStars) 颗星，共需 \(level.requiredStars) 颗，\(stateLine)"
        let summary = note?.summaryLine ?? ""
        if !summary.isEmpty { line += "。\(summary)" }
        return line
    }

    /// 关卡节点的读屏提示（锁定与可进各一句）。
    static func levelHint(isLocked: Bool) -> String {
        isLocked ? "继续练习解锁这一关" : "点按进入这一关的练习"
    }

    // MARK: - 连胜徽章

    /// 连胜徽章的读屏一句话。
    ///
    /// 风险态（今天还没练）把「要断了」说在前面 —— 这正是徽章亮警示色的原因，
    /// 读屏用户不该只听到一个平静的「7 天」。
    static func streakLine(badge: TodayPanel.StreakBadge) -> String {
        badge.isAtRisk
            ? "连续学习 \(badge.days) 天，但今天还没练习，别断签啦"
            : "已连续学习 \(badge.days) 天"
    }
}
