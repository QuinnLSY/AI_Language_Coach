import AIDomain
@testable import AppUI
import XCTest

/// 批次七 · G：读屏一句话文案的逐字钉子（文案唯一出处 `AccessibilityLines`）。
///
/// 为什么逐字钉：读屏文案是最容易被「顺手润色」的东西，而 VoiceOver 用户
/// 对每个字的依赖远高于明眼用户 —— 改一个字就该是一次有意识的决策。
final class AccessibilityLinesTests: XCTestCase {

    // MARK: - 关卡节点

    /// locked 也报星数：让读屏用户知道目标长什么样，而不是只听到「锁着」。
    func testLockedLevelStatesTheStarsItNeeds() {
        let level = TreeLevel(id: "l1", title: "初见森林", subtitle: "",
                              heightFraction: 0.1, branch: .left,
                              state: .locked, requiredStars: 3, earnedStars: 0)
        XCTAssertEqual(
            AccessibilityLines.levelLine(level: level, note: nil),
            "初见森林，已得 0 颗星，共需 3 颗，尚未解锁"
        )
    }

    /// 进行中 + 有情景归属：一句话把「这是什么、学到哪、对应哪个情景」说全。
    func testInProgressLevelIncludesNoteSummary() {
        let level = TreeLevel(id: "l2", title: "点单对话", subtitle: "",
                              heightFraction: 0.4, branch: .right,
                              state: .inProgress, requiredStars: 3, earnedStars: 2)
        let note = TreeLevelNote(scenarioTitle: "点咖啡", questSummary: "主线 2/3")
        XCTAssertEqual(
            AccessibilityLines.levelLine(level: level, note: note),
            "点单对话，已得 2 颗星，共需 3 颗，正在进行。点咖啡 · 主线 2/3"
        )
    }

    /// 已过关的说法。
    func testCompletedLevelSaysItIsDone() {
        let level = TreeLevel(id: "l3", title: "晨间问候", subtitle: "",
                              heightFraction: 0.7, branch: .left,
                              state: .completed, requiredStars: 3, earnedStars: 3)
        XCTAssertEqual(
            AccessibilityLines.levelLine(level: level, note: nil),
            "晨间问候，已得 3 颗星，共需 3 颗，已完成"
        )
    }

    /// unlocked 档与 hint：未锁的关卡要读得出「能进」与「怎么进」。
    func testUnlockedLevelAndHint() {
        let level = TreeLevel(id: "l4", title: "自我介绍", subtitle: "",
                              heightFraction: 0.2, branch: .right,
                              state: .unlocked, requiredStars: 3, earnedStars: 0)
        XCTAssertEqual(
            AccessibilityLines.levelLine(level: level, note: nil),
            "自我介绍，已得 0 颗星，共需 3 颗，可以开始"
        )
        XCTAssertEqual(AccessibilityLines.levelHint(isLocked: false), "点按进入这一关的练习")
        XCTAssertEqual(AccessibilityLines.levelHint(isLocked: true), "继续练习解锁这一关")
    }

    // MARK: - 连胜徽章

    /// 风险态把「要断了」说在前面 —— 这正是徽章亮警示色的原因，
    /// 读屏用户不该只听到一个平静的「7 天」。
    func testStreakAtRiskSaysTheDangerFirst() {
        let badge = TodayPanel.StreakBadge(days: 7, isAtRisk: true)
        XCTAssertEqual(
            AccessibilityLines.streakLine(badge: badge),
            "连续学习 7 天，但今天还没练习，别断签啦"
        )
    }

    /// 安心态只报天数，不制造焦虑。
    func testStreakSafeLineIsCalm() {
        let badge = TodayPanel.StreakBadge(days: 3, isAtRisk: false)
        XCTAssertEqual(AccessibilityLines.streakLine(badge: badge), "已连续学习 3 天")
    }
}
