import SwiftUI
import XCTest

@testable import AppUI

/// 动效 token 的纯函数测试（2026-09-25 第一批）。
///
/// 钉的是**档位关系与退化行为**，不是具体毫秒数 —— 具体数值将来微调是允许的，
/// 但「press 必须比 emphasis 快」「减弱动态效果下一切 ≤120ms」这两条关系不能变：
/// 前者是手感的分层，后者是系统偏好的语义。
final class AppMotionTokenTests: XCTestCase {

    // MARK: - 档位关系

    /// 四档必须**依次变慢**。这条关系就是分层的全部意义：
    /// 如果 press 和 emphasis 一样长，按压就不再是「即时回应」。
    func testTokensGetSlowerInOrder() {
        XCTAssertLessThan(AppMotion.press.nominalDuration, AppMotion.reveal.nominalDuration)
        XCTAssertLessThan(AppMotion.reveal.nominalDuration, AppMotion.panel.nominalDuration)
        XCTAssertLessThan(AppMotion.panel.nominalDuration, AppMotion.emphasis.nominalDuration)
    }

    /// 按压必须快到像本能。150ms 以上人就开始感觉到「等我一下」。
    func testPressStaysBelowThePerceptionThreshold() {
        XCTAssertLessThanOrEqual(
            AppMotion.press.nominalDuration, 0.15,
            "按压超过 150ms 就从反馈变成延迟，实测 \(AppMotion.press.nominalDuration)s"
        )
    }

    // MARK: - 常规档

    /// 常规档：每档保留自己的时长（没有互相被覆盖）。
    func testStandardDescriptorKeepsEachTokenItsOwnDuration() {
        let motion = AppMotionDescriptor.standard
        for token in AppMotion.allCases {
            XCTAssertEqual(
                motion.duration(token), token.nominalDuration,
                "\(token.rawValue) 档的时长应为 \(token.nominalDuration)s"
            )
        }
    }

    // MARK: - 减弱动态效果

    /// 「减弱动态效果」下**每一档**都必须塌到 ≤120ms 的一小段 ——
    /// 系统偏好的语义是「别让我看到东西动」，不是「让它动快一点」，
    /// 所以 emphasis 那种 550ms 的过冲尤其必须被压住。
    func testReducedModeFlattensEveryTokenToOneShortFade() {
        let motion = AppMotionDescriptor(reduceMotion: true)
        for token in AppMotion.allCases {
            XCTAssertLessThanOrEqual(
                motion.duration(token), 0.12,
                "减弱动态效果下 \(token.rawValue) 仍要 \(motion.duration(token))s，没被压住"
            )
        }
    }

    /// 常驻循环动画在「减弱动态效果」下必须**完全停摆**（nil = 值直接跳到终值后静止），
    /// 而不是照跑不误。
    ///
    /// 反证：把 `loopAnimation` 里 `reduceMotion ? nil : animation` 改回恒返回 animation → 红。
    func testLoopAnimationStopsUnderReduceMotion() {
        let reduced = AppMotionDescriptor(reduceMotion: true)
        XCTAssertNil(
            reduced.loopAnimation(.linear(duration: 60)),
            "星星自转 / 树叶摇曳这类常驻动画在减弱动态效果下必须停"
        )

        let standard = AppMotionDescriptor.standard
        XCTAssertNotNil(
            standard.loopAnimation(.linear(duration: 60)),
            "没开减弱动态效果时循环动画照常"
        )
    }

    /// `Animation.app(_:)` 是给 `@Observable` class 走的那条路 —— 它直接查系统偏好，
    /// 不依赖 SwiftUI 环境。取得到、不崩，就是它的全部契约。
    func testAnimationHelperIsUsableOutsideAView() {
        XCTAssertNotNil(Animation.app(.panel))
    }
}
