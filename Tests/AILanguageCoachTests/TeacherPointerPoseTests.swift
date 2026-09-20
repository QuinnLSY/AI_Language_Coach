import SwiftUI
@testable import AppUI
import XCTest

/// 老师教棍的姿态（尤其是**往哪边敲**）。
///
/// 2026-09-19 用户实测反馈：「展开时老师敲黑板的方向反了，应该往右敲」——
/// 原来敲击角是 −46°（棍梢往左扫过自己的脑袋），现在是 +46°（往右上抬）。
/// 这套符号很容易在重构里被顺手改回负数（`-18` 挥动的那个看着更像），
/// 而**动画截图看不出对错**，只能钉住姿态本身。
final class TeacherPointerPoseTests: XCTestCase {

    /// SwiftUI 的 y 轴朝下 → 正角 = 顺时针 = 棍梢往右。敲击角必须是正的。
    func testKnockingSwingsTheStickToTheRight() {
        let knocking = PointerPose.make(knocking: true, waving: false)
        XCTAssertGreaterThan(knocking.degrees, 0, "敲黑板要往右敲（正角），实为 \(knocking.degrees)°")
        XCTAssertGreaterThan(knocking.tipOffsetXRatio, 0, "棍梢横向位移必须往右")
        XCTAssertGreaterThan(
            knocking.tipOffsetXRatio, PointerPose.stickLengthRatio * 0.6,
            "要真抬起来敲（棍梢横扫幅度 ≥ 60% 棍长），不是蹭一下：\(knocking.tipOffsetXRatio)"
        )
    }

    /// 随手挥 / 立着这两种姿态是「讲课的节奏感」，与敲击方向相反（往左一点点）—— 顺手钉住，别混。
    func testIdleAndWavingLeanTheOtherWayFromTheKnock() {
        let idle = PointerPose.make(knocking: false, waving: false)
        let waving = PointerPose.make(knocking: false, waving: true)
        let knocking = PointerPose.make(knocking: true, waving: false)

        XCTAssertGreaterThan(idle.degrees, 0, "立着时棍梢朝右一点点（不是斜在自己身上）")
        XCTAssertLessThan(waving.degrees, 0, "随手挥是往左的小幅动作，与敲击相反")
        XCTAssertLessThan(waving.degrees, idle.degrees, "挥动要离开立着的角度")
        XCTAssertGreaterThan(knocking.degrees, idle.degrees, "敲击幅度最大")
        XCTAssertGreaterThan(
            PointerPose.make(knocking: true, waving: true).degrees, waving.degrees,
            "敲击优先于挥动：两个都置位时看敲击"
        )
    }

    /// 棍身长度只有一处定义（画棍子和算方向用的是同一个数）。
    func testStickLengthIsShared() {
        XCTAssertEqual(PointerPose.stickLengthRatio, 0.40, accuracy: 0.0001)
    }
}
