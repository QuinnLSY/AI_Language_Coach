import AIDomain
import XCTest

@testable import AppUI

/// 第三批令牌的纯函数测试（2026-09-27）：阴影档位 + 老师等待阶段。
///
/// 档位系统的价值在「同层级同参数」—— 所以这里钉的**不是**某个调用点，
/// 而是档位本身的关系与取值：谁比谁高、每档的参数是不是文档里那组。
/// 调用点接线由 `ThirdBatchWiringTests` 的源码哨兵管。
final class ThirdBatchTokensTests: XCTestCase {

    // MARK: - AppElevation 档位关系

    /// 四档必须严格分层：任何两档在 radius 与 y 上都不可同值 ——
    /// 两档同值等于少了一档信息（同 `warning`/`accent` 撞色的老教训）。
    func testElevationLevelsAreStrictlyOrdered() {
        let levels = AppElevation.allCases
        let radii = levels.map { $0.style.radius }
        let ys = levels.map { $0.style.y }
        XCTAssertEqual(Set(radii).count, levels.count, "radius 撞档：\(radii)")
        XCTAssertEqual(Set(ys).count, levels.count, "y 撞档：\(ys)")
        XCTAssertEqual(radii, radii.sorted(), "radius 必须按档位单调递增")
        XCTAssertEqual(ys, ys.sorted(), "y 必须按档位单调递增")
    }

    /// 文档里写的参数（card 8/3、raised 10/4、overlay 14/6、sheet 30/14）
    /// 就是收编时全项目的主流值 —— 改这里等于改全应用的层级观感，必须显式。
    func testElevationStyleValuesMatchTheDocumentedOnes() {
        XCTAssertEqual(AppElevation.card.style, AppElevationStyle(radius: 8, y: 3))
        XCTAssertEqual(AppElevation.raised.style, AppElevationStyle(radius: 10, y: 4))
        XCTAssertEqual(AppElevation.overlay.style, AppElevationStyle(radius: 14, y: 6))
        XCTAssertEqual(AppElevation.sheet.style, AppElevationStyle(radius: 30, y: 14))
    }

    // MARK: - TeacherWaitStage（真实阶段，不是编的时间档）

    /// 只有两个**真实存在**的阶段：总结上次 → 生成开场白。多编一个就是编造进度
    /// （违反 `TeacherWaitCopy` 第 1 条铁律）。
    ///
    /// ⚠️ 原来的「装配」档已删（2026-10-14 报障）：开屏不再自动开场，装配那几秒老师
    /// 根本没被叫来 —— 挂「老师正在准备…」等于无中生有一条老师发言（那张卡与老师的
    /// 消息气泡同形），用户看到的就是「一打开老师先发起对话、过一会儿又被引导卡顶掉」。
    func testTeacherWaitStageHasExactlyTheTwoRealStages() {
        XCTAssertEqual(TeacherWaitStage.allCases, [.reviewing, .greeting])
        for stage in TeacherWaitStage.allCases {
            XCTAssertFalse(stage.displayName.isEmpty)
        }
    }

    /// 阶段条「走到哪步哪个亮」的判据靠 Comparable：reviewing < greeting，
    /// 且已走过的阶段（`step <= stage`）与当前阶段都能被正确判定。
    func testTeacherWaitStageOrdering() {
        XCTAssertLessThan(TeacherWaitStage.reviewing, TeacherWaitStage.greeting)
        XCTAssertTrue(TeacherWaitStage.reviewing <= TeacherWaitStage.reviewing)
        XCTAssertTrue(TeacherWaitStage.greeting >= TeacherWaitStage.reviewing)
        XCTAssertFalse(TeacherWaitStage.reviewing >= TeacherWaitStage.greeting)
    }
}
