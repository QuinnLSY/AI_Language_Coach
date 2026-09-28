import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 学员气泡三颗图标的两件事（2026-09-23 用户报障）：
/// ① **删除那颗是红色的**（破坏性动作要一眼认得出来）；
/// ② **点垃圾桶不许直接删**，先弹确认框。
///
/// ⚠️ 为什么这两件都只能在「纯逻辑」这一层钉：
/// - 颜色：离屏渲染过一次色彩空间换算，断言里不能比色值（见技能 `macos-ui-verify`），
///   「用的是不是 `danger`」只能证到「选了哪个令牌」；
/// - 确认框：`confirmationDialog` 离屏出不了图，而合成 `NSEvent` 会 abort 整个测试进程 ——
///   「确认前不删」只能证到状态机。
/// 两处的**接线**（View 里调的是不是这两个口子）由人眼复核，与 `.help` 同类。
@MainActor
final class BubbleDeleteTests: XCTestCase {

    private let day = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
    private let night = ForestThemeResolver.resolve(mode: .night, systemIsDark: true)

    // MARK: - ① 删除那颗用 danger，另两颗保持中性

    func testOnlyTheDeleteIconCarriesTheDangerTint() {
        XCTAssertEqual(
            LearnerBubbleActionRow.tint(for: .delete, theme: day), day.danger,
            "删除是**不可逆**动作，得用 danger（正红）；用 accent 会和「编辑」长得一样"
        )
        XCTAssertEqual(LearnerBubbleActionRow.tint(for: .delete, theme: night), night.danger)
        // 另两颗刻意留空 = 沿用「次要文字 → accent」的默认口径。
        // 三颗都上色等于三颗都没上色，破坏性动作也就没了区分。
        XCTAssertNil(
            LearnerBubbleActionRow.tint(for: .edit, theme: day),
            "编辑不是破坏性动作，不该跟着上红色"
        )
        XCTAssertNil(LearnerBubbleActionRow.tint(for: .copy, theme: day))
    }

    /// 三颗图标各有一个动作，口径表必须**逐档**覆盖到 —— 漏一档就是静默退回中性色。
    func testTintTableCoversEveryAction() {
        for action in LearnerBubbleActionRow.Action.allCases {
            let tint = LearnerBubbleActionRow.tint(for: action, theme: day)
            if action == .delete {
                XCTAssertNotNil(tint, "\(action.rawValue) 必须显式选色")
            } else {
                XCTAssertNil(tint, "\(action.rawValue) 应当是中性（改口径要连带改这条断言）")
            }
        }
        XCTAssertEqual(
            LearnerBubbleActionRow.Action.allCases.count, 3, "学员气泡上是三颗（删除 / 编辑 / 复制）"
        )
    }

    // MARK: - ② 确认之前一个字节都不许删

    /// 点垃圾桶**只登记**：这一步绝不能顺手把 id 交出去。
    func testRequestingADeleteDeletesNothing() {
        var confirmation = DeleteConfirmation()
        let id = UUID()
        confirmation.request(id)

        XCTAssertTrue(confirmation.isPresented, "登记之后确认框就该弹出来")
        XCTAssertEqual(confirmation.pending, id)
        // 「登记 ≠ 删除」是这一整件的核心：把 pending 断言成 id 之后，
        // 只要谁把 request 改成顺手调一次删除，这条就会在 pending 上先红。
        XCTAssertNotNil(confirmation.pending)
    }

    /// 确认才交 id，并且**交完就清场**（不清的话第二次点垃圾桶会删掉上一个人的消息）。
    func testConfirmHandsOverTheIDExactlyOnce() {
        var confirmation = DeleteConfirmation()
        let id = UUID()
        confirmation.request(id)

        XCTAssertEqual(confirmation.confirm(), id, "确认时要把待删的那条交出来")
        XCTAssertFalse(confirmation.isPresented, "交完必须散场")
        XCTAssertNil(confirmation.confirm(), "第二次确认没有待删项 —— 不许把同一条再交一次")
    }

    /// 取消 / Esc：什么都没发生。
    func testCancelDropsTheRequest() {
        var confirmation = DeleteConfirmation()
        confirmation.request(UUID())
        confirmation.cancel()

        XCTAssertFalse(confirmation.isPresented)
        XCTAssertNil(confirmation.confirm(), "取消之后再确认也交不出东西来")
    }

    /// 没有待确认项时确认 → nil（对话框理论上弹不出来，但状态机自己得是闭的）。
    func testConfirmWithNothingPendingIsANoOp() {
        var confirmation = DeleteConfirmation()
        XCTAssertFalse(confirmation.isPresented)
        XCTAssertNil(confirmation.confirm())
    }

    /// 连点两条不同的消息：后一次必须**顶掉**前一次（对话框只有一个，pending 也只能有一个）。
    func testALaterRequestReplacesTheEarlierOne() {
        var confirmation = DeleteConfirmation()
        let first = UUID(), second = UUID()
        confirmation.request(first)
        confirmation.request(second)

        XCTAssertEqual(confirmation.pending, second)
        XCTAssertEqual(confirmation.confirm(), second)
        XCTAssertNil(confirmation.confirm(), "第一条不许在第二次确认时冒出来")
    }

    // MARK: - 确认框里那句文案

    func testPromptNamesWhatGoesAwayAndWhatStays() {
        let message = BubbleDeletePrompt.message(for: "I want to order a coffee, please.")
        XCTAssertTrue(
            message.contains("老师的那句回复"), "删除会连带紧邻的老师回复（见 ChatService.deleteMessage）：\(message)"
        )
        for kept in ["纠错", "复盘", "生词"] {
            XCTAssertTrue(message.contains(kept), "产物不动这件事要说清（\(kept)）：\(message)")
        }
        XCTAssertTrue(message.hasPrefix("「"), "摘要要用书名号括起来，一眼看出删的是哪句：\(message)")
    }

    /// 空正文（只有附件的那种消息）也要给出一句完整的话，而不是「「」和老师的那句回复…」。
    func testPromptHandlesAMessageWithoutText() {
        let message = BubbleDeletePrompt.message(for: "   \n  ")
        XCTAssertFalse(message.contains("「」"), "空正文不许留下一对空书名号：\(message)")
        XCTAssertTrue(message.contains("学习记录不受影响"), message)
    }

    /// 摘要：压掉换行与连续空白，超长才截断。
    func testPreviewFlattensWhitespaceAndTruncates() {
        // ⚠️ 这句刻意留在上限（24）以内 —— 压平之后是 20 个字，
        // 拿一句刚好超限的当「压平」的样本，测的其实是截断（踩过一次）。
        XCTAssertEqual(
            BubbleDeletePrompt.preview(of: "hello   world\nand\tsome"),
            "hello world and some"
        )
        let long = String(repeating: "a", count: BubbleDeletePrompt.previewLimit + 5)
        let preview = BubbleDeletePrompt.preview(of: long)
        XCTAssertTrue(preview.hasSuffix("…"), "超长要截断并留省略号：\(preview)")
        XCTAssertEqual(preview.count, BubbleDeletePrompt.previewLimit + 1)
        // 恰好等于上限时不该加省略号（差一个字就截，用户会以为话被吃掉了）。
        let exact = String(repeating: "b", count: BubbleDeletePrompt.previewLimit)
        XCTAssertEqual(BubbleDeletePrompt.preview(of: exact), exact)
    }

    /// 多行消息里的换行也要被压平：塞进一句话里，换行会变成一大坨空白。
    func testPreviewOfAMultilineMessageStaysOneLine() {
        let preview = BubbleDeletePrompt.preview(of: "first line\nsecond line")
        XCTAssertFalse(preview.contains("\n"), preview)
        XCTAssertEqual(preview, "first line second line")
    }

    // MARK: - 常驻透明度

    /// 三颗图标常驻时的透明度：0 是这次的病根，1 会抢正文。
    func testIdleOpacityIsFaintButVisible() {
        let value = ChatView.learnerActionIdleOpacity
        XCTAssertGreaterThan(value, 0, "0 就是「悬停才出现」，正是这次报障的毛病")
        XCTAssertLessThan(value, 0.6, "次要动作不该和正文抢注意力（实测定在 \(value)）")
    }
}
