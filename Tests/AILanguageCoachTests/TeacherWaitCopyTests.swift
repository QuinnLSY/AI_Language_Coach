import AIDomain
import XCTest

/// 冷启动等待态的两条纯逻辑：文案分档 + 空态判据。
///
/// 这两块是本次修复最容易被日后改坏的地方（延迟分秒、状态多加一个），
/// 所以都做成纯函数钉住。
final class TeacherWaitCopyTests: XCTestCase {

    // MARK: - 文案分档

    func testTitleHidesSecondsAtTheVeryBeginning() {
        // 一上来就蹦秒数会像倒计时出了错 —— 前两秒只说「正在准备」。
        XCTAssertEqual(TeacherWaitCopy.title(seconds: 0), "老师正在准备…")
        XCTAssertEqual(TeacherWaitCopy.title(seconds: 2), "老师正在准备…")
    }

    func testTitleReportsElapsedSecondsOnceItHasWaited() {
        XCTAssertEqual(TeacherWaitCopy.title(seconds: 3), "老师正在准备…（已等待 3 秒）")
        XCTAssertEqual(TeacherWaitCopy.title(seconds: 47), "老师正在准备…（已等待 47 秒）")
    }

    func testDetailIsSilentUntilTheWaitIsActuallyLong() {
        // ⚠️ 刚等两秒就说「第一次会慢」像在给卡顿找借口；要等真久了才解释。
        XCTAssertNil(TeacherWaitCopy.detail(seconds: 0))
        XCTAssertNil(TeacherWaitCopy.detail(seconds: TeacherWaitCopy.explainFrom - 1))
    }

    func testDetailExplainsTheColdStartOnceItIsLong() {
        let detail = TeacherWaitCopy.detail(seconds: TeacherWaitCopy.explainFrom)
        XCTAssertNotNil(detail)
        XCTAssertTrue(detail?.contains("第一次") == true, "解释必须说清这是**第一次**才慢，不是一直这么慢")
    }

    /// 文案里绝不出现进度类措辞：没有进度可报就不能编。
    func testCopyNeverPretendsToKnowProgress() {
        for seconds in [0, 1, 5, 30, 120] {
            let text = TeacherWaitCopy.title(seconds: seconds) + (TeacherWaitCopy.detail(seconds: seconds) ?? "")
            for banned in ["%", "还有", "剩余", "即将完成"] {
                XCTAssertFalse(text.contains(banned), "等待文案出现了假进度措辞「\(banned)」：\(text)")
            }
        }
    }

    // MARK: - 空态判据

    func testInvitationOnlyShowsWhenNothingIsComing() {
        XCTAssertTrue(ChatEmptyStateRule.showsInvitation(
            messageCount: 0, hasStreamingText: false, hasStreamingReasoning: false,
            isGenerating: false, isBooting: false
        ))
    }

    /// 这次修的正是这条：启动装配期间不能显示「和老师打个招呼」。
    func testInvitationIsSuppressedWhileBooting() {
        XCTAssertFalse(ChatEmptyStateRule.showsInvitation(
            messageCount: 0, hasStreamingText: false, hasStreamingReasoning: false,
            isGenerating: false, isBooting: true
        ), "启动还没接上模型时说「打个招呼」是在说谎")
    }

    func testInvitationIsSuppressedWhileAnythingIsStreaming() {
        XCTAssertFalse(ChatEmptyStateRule.showsInvitation(
            messageCount: 0, hasStreamingText: true, hasStreamingReasoning: false,
            isGenerating: true, isBooting: false
        ))
        XCTAssertFalse(ChatEmptyStateRule.showsInvitation(
            messageCount: 0, hasStreamingText: false, hasStreamingReasoning: true,
            isGenerating: true, isBooting: false
        ))
        XCTAssertFalse(ChatEmptyStateRule.showsInvitation(
            messageCount: 0, hasStreamingText: false, hasStreamingReasoning: false,
            isGenerating: true, isBooting: false
        ))
    }

    func testInvitationIsSuppressedOnceThereAreMessages() {
        XCTAssertFalse(ChatEmptyStateRule.showsInvitation(
            messageCount: 1, hasStreamingText: false, hasStreamingReasoning: false,
            isGenerating: false, isBooting: false
        ))
    }

    /// 空态与等待卡**必须互斥**：否则启动那几秒会一半在请人打招呼、一半说在准备。
    func testPendingCardAndInvitationNeverCoexist() {
        for isGenerating in [true, false] {
            for isBooting in [true, false] {
                let pending = ChatEmptyStateRule.showsPendingCard(
                    isGenerating: isGenerating, isBooting: isBooting
                )
                let invitation = ChatEmptyStateRule.showsInvitation(
                    messageCount: 0, hasStreamingText: false, hasStreamingReasoning: false,
                    isGenerating: isGenerating, isBooting: isBooting
                )
                XCTAssertFalse(pending && invitation,
                               "isGenerating=\(isGenerating) isBooting=\(isBooting) 时两者同时出现")
            }
        }
    }

    func testPendingCardShowsForBootAndForGeneration() {
        XCTAssertTrue(ChatEmptyStateRule.showsPendingCard(isGenerating: false, isBooting: true))
        XCTAssertTrue(ChatEmptyStateRule.showsPendingCard(isGenerating: true, isBooting: false))
        XCTAssertFalse(ChatEmptyStateRule.showsPendingCard(isGenerating: false, isBooting: false))
    }
}
