import AIDomain
import XCTest

/// 「学员在树上哪一格」的判据。
///
/// 用户口径：右边栏成长之树**每次打开要定位到学员当前所在的位置**，而不是停在树顶。
/// 于是有两件事必须同源：树上高亮哪一格、视口定位到哪一格。
/// 判据放在领域层（`LearnerProgress.currentLevelID`）就是为了避免两处各写一份、
/// 迟早出现「圈在这格、视口停在那格」。
final class TreeAnchorTests: XCTestCase {

    private func level(_ id: String, state: LevelState, climb: Double) -> TreeLevel {
        TreeLevel(id: id, title: id, subtitle: "", heightFraction: climb,
                  branch: .left, state: state, requiredStars: 3, earnedStars: 0,
                  scenarioID: nil)
    }

    /// 有「正在学」的关卡 → 就是它（不是第一个、也不是树顶那一个）。
    func testPicksTheInProgressLevel() {
        let progress = LearnerProgress(levels: [
            level("root", state: .completed, climb: 0.1),
            level("now", state: .inProgress, climb: 0.5),
            level("crown", state: .locked, climb: 0.9)
        ])
        XCTAssertEqual(progress.currentLevelID, "now")
    }

    /// 全新学员：一关都没开张 → 退回第一关（树根营地），不能是空的。
    func testFallsBackToTheFirstLevelWhenNobodyIsInProgress() {
        let progress = LearnerProgress(levels: [
            level("root", state: .unlocked, climb: 0.1),
            level("next", state: .locked, climb: 0.4)
        ])
        XCTAssertEqual(progress.currentLevelID, "root")
    }

    /// 多个「正在学」时取最靠前的那一个（顺序即关卡顺序），保证判据是确定的。
    func testTakesTheFirstInProgressWhenSeveralClaimIt() {
        let progress = LearnerProgress(levels: [
            level("a", state: .inProgress, climb: 0.2),
            level("b", state: .inProgress, climb: 0.6)
        ])
        XCTAssertEqual(progress.currentLevelID, "a")
    }

    /// 没有关卡（进度还没从库里读回来）→ 空串，不能崩。
    func testEmptyProgressHasNoCurrentLevel() {
        XCTAssertEqual(LearnerProgress().currentLevelID, "")
    }
}
