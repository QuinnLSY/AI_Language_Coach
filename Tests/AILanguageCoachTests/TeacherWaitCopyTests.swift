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
            isGenerating: false, isTeacherPreparing: false
        ))
    }

    /// ⚠️ 2026-10-14 报障反转的语义，写在这里：**装配期间就该显示引导卡**。
    ///
    /// 老版本钉的是「装配期不许显示引导卡」—— 那会儿开屏会自动开场，引导卡说
    /// 「和老师打个招呼」而老师马上自己就开口了，确实在说谎。现在开屏不再自动开场：
    /// 装配那几秒老师**根本没被叫来**，该显示的就是引导卡（话题卡 / 继续上次对话
    /// 都在，有得可点）；挂一张「老师正在准备…」反倒是无中生有一条与老师气泡同形的
    /// 假发言（用户实测「一打开老师先发起对话、过一会儿又被引导卡顶掉」）。
    ///
    /// ⚠️ 装配合格与否**不在这个函数的参数表里**：判据只认「老师真的被叫来了没有」。
    /// 装配期「不再挂等待卡」这件事由 `ChatView` 侧钉 —— 见
    /// `TeacherPreparingCardRenderTests.testBootingNoLongerSwapsTheGuideCardForAWaitCard`
    /// 的 `isBooting: true/false` 两帧一致断言。这里另加一条源码哨兵，防止
    /// 有人日后又把 `isBooting` 加回判据。
    func testBootingIsNotAnInputToTheEmptyStateRule() throws {
        let raw = try Self.source("Sources/AIDomain/ChatEmptyStateRule.swift")
        XCTAssertFalse(
            raw.contains("isBooting"),
            "装配不是空态判据的输入 —— 加回去开屏就会再冒一条假的「老师发言」"
        )
    }

    func testInvitationIsSuppressedWhileAnythingIsStreaming() {
        XCTAssertFalse(ChatEmptyStateRule.showsInvitation(
            messageCount: 0, hasStreamingText: true, hasStreamingReasoning: false,
            isGenerating: true, isTeacherPreparing: false
        ))
        XCTAssertFalse(ChatEmptyStateRule.showsInvitation(
            messageCount: 0, hasStreamingText: false, hasStreamingReasoning: true,
            isGenerating: true, isTeacherPreparing: false
        ))
        XCTAssertFalse(ChatEmptyStateRule.showsInvitation(
            messageCount: 0, hasStreamingText: false, hasStreamingReasoning: false,
            isGenerating: true, isTeacherPreparing: false
        ))
    }

    func testInvitationIsSuppressedOnceThereAreMessages() {
        XCTAssertFalse(ChatEmptyStateRule.showsInvitation(
            messageCount: 1, hasStreamingText: false, hasStreamingReasoning: false,
            isGenerating: false, isTeacherPreparing: false
        ))
    }

    /// 点「继续上次对话」之后：复盘不走 `chat` 的生成通道（`isGenerating` 是 false），
    /// 不认 `isTeacherPreparing` 的话引导卡会原封不动留在屏幕上 ——
    /// 用户以为那一下没点上（2026-10-14 改造的核心判据）。
    func testInvitationYieldsToTheContinueLastWait() {
        XCTAssertFalse(ChatEmptyStateRule.showsInvitation(
            messageCount: 0, hasStreamingText: false, hasStreamingReasoning: false,
            isGenerating: false, isTeacherPreparing: true
        ), "总结上次那几秒里，引导卡必须让位给等待卡")
    }

    /// 空态与等待卡**必须互斥**：否则会一半在请人打招呼、一半说在准备。
    func testPendingCardAndInvitationNeverCoexist() {
        for isGenerating in [true, false] {
            for isTeacherPreparing in [true, false] {
                let pending = ChatEmptyStateRule.showsPendingCard(
                    isGenerating: isGenerating, isTeacherPreparing: isTeacherPreparing
                )
                let invitation = ChatEmptyStateRule.showsInvitation(
                    messageCount: 0, hasStreamingText: false, hasStreamingReasoning: false,
                    isGenerating: isGenerating, isTeacherPreparing: isTeacherPreparing
                )
                XCTAssertFalse(
                    pending && invitation,
                    "isGenerating=\(isGenerating) isTeacherPreparing=\(isTeacherPreparing) 时两者同时出现"
                )
            }
        }
    }

    /// 等待卡只在**真的有人要说话**时出现：正在生成，或老师被叫来了
    /// （总结上次 / 写开场白 —— 两者共用 `isTeacherPreparing` 这一个输入）。
    func testPendingCardShowsForGenerationAndForTeacherPrep() {
        XCTAssertTrue(ChatEmptyStateRule.showsPendingCard(
            isGenerating: true, isTeacherPreparing: false
        ))
        XCTAssertTrue(ChatEmptyStateRule.showsPendingCard(
            isGenerating: false, isTeacherPreparing: true
        ), "复盘上次那段（isGenerating 还是 false）也必须有等待卡接住")
        XCTAssertFalse(ChatEmptyStateRule.showsPendingCard(
            isGenerating: false, isTeacherPreparing: false
        ))
    }

    /// 读源码并剥掉**整行注释** —— 说明「老版本怎么写」的注释里必然留着旧字样，
    /// 不剥的话判据会被自己的注释骗过去（同 `LaunchTodayPanelTests.code`）。
    private static func source(_ path: String) throws -> String {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
