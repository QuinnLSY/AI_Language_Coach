import AIDomain
import AIInfrastructure
import XCTest

/// 「老师的回复必须接住学员上一句」这条口径的回归（用户 2026-09-24 报障）。
///
/// **现场**：同一段对话已经聊了三轮（巧克力蛋糕 → 葡式蛋挞），
/// 学员说「I am working now, not a student yet. So I will try them after work.」，
/// 老师却回：「Hello! It is great to see you back. I am checking our old notes on capital letters
/// — did you start your first sentence with a big letter last time?」
///
/// **根因**（对着 prompt 与流水逐句核出来的）：`continuation.txt` 当时写着
/// 「Follow up early on the "To work on" item: check whether it stuck」——
/// 下一句就要求老师**主动去追上次的改进项**；而上一次的 to-work-on 正是「句首要大写」，
/// 于是模型在对话中途掉头，用一个开场句把旧笔记拎出来问了一遍。
/// 更糟的是这与 `learning_memory.txt` 的口径**正好相反**（那份写着「当背景、绝不背笔记」），
/// 两块同时注入时模型只能挑一块听。
///
/// 修法：把续聊块的口径对齐学习记忆 —— 背景、不主动开场、当前对话永远优先。
/// 本文件钉住这三件事，避免以后有人「顺手」把那句 follow-up 加回来。
final class DialogueContinuityTests: XCTestCase {

    private func review(headline: String = "聊了喜欢的甜点", toWorkOn: String = "句首字母要大写") -> SessionReview {
        SessionReview(
            sessionID: UUID(),
            headline: headline,
            newWords: ["egg tart"],
            strengths: ["用了完整句"],
            improvements: [toWorkOn],
            suggestion: "下次试着描述做法"
        )
    }

    /// 续聊块里**不许**再命令老师「早点去追上次的改进项」——那句是脱节的直接来源。
    func testContinuationBlockDoesNotOrderAFollowUp() {
        let block = PromptBuilder.continuationBlock(review())
        XCTAssertFalse(block.isEmpty, "有复盘时应当有内容（夹具自检）")
        XCTAssertFalse(
            block.lowercased().contains("follow up early"),
            "「follow up early」会让老师在中途掉头去追旧笔记 —— 正是这次报障"
        )
        XCTAssertFalse(
            block.contains("check whether it stuck"),
            "同一句的另一种写法也要挡住"
        )
    }

    /// 反过来，必须明说「当前对话优先、你正在对话中间」。
    func testContinuationBlockMakesTheLiveConversationWin() {
        let block = PromptBuilder.continuationBlock(review())
        XCTAssertTrue(block.contains("always comes first"), "当前对话的优先级要写死")
        XCTAssertTrue(
            block.lowercased().contains("middle of a conversation"),
            "得点明「你正在对话中途」，否则模型会当成新一轮开场"
        )
        XCTAssertTrue(
            block.lowercased().contains("never open with it"),
            "明确禁止用旧笔记开场"
        )
    }

    /// 人设里的第 9 条：每一条回复都要接住学员上一句、留在同一条话题线上。
    func testTeacherSystemForbidsSwitchingTopics() {
        let prompt = PromptBuilder.teacherSystemPrompt(
            learningLanguage: "English",
            nativeLanguage: "Chinese",
            proficiency: "A2",
            practiceMode: .conversation
        )
        XCTAssertTrue(
            prompt.contains("ALWAYS CONTINUE THE CONVERSATION YOU ARE ALREADY IN"),
            "这条硬规则必须在人设里（它是所有模式的公共底线）"
        )
        XCTAssertTrue(prompt.contains("answer the learner's last message"))
        XCTAssertTrue(
            prompt.lowercased().contains("never open with a greeting"),
            "重新打招呼是这次报障最刺眼的表现"
        )
    }

    /// 规则 9 必须**豁免开场那一句**，否则它会和 `greeting.txt` / `continuation_opener.txt`
    /// （两份都要求热情打招呼）正面打架 —— 人设在**所有**轮次里都会注入（含开场轮）。
    ///
    /// 这正是本次报障的病根类型：两块口径相反的指令同时注入，模型只能挑一块听。
    /// 反过来的后果一样糟：开场不打招呼，用户看到的是开屏很生硬。
    func testRuleNineExemptsTheOpeningMessage() {
        let prompt = PromptBuilder.teacherSystemPrompt(
            learningLanguage: "English",
            nativeLanguage: "Chinese",
            proficiency: "A2",
            practiceMode: .conversation
        )
        XCTAssertTrue(
            prompt.lowercased().contains("once the conversation is under way"),
            "规则 9 要写明「对话进行中才适用」"
        )
        XCTAssertTrue(
            prompt.lowercased().contains("opening message at the start of a session"),
            "开场那一句必须被豁免，否则开场白不再打招呼"
        )
    }

    /// 开场白那条路径不受影响：`continuationOpenerPrompt` 仍然要求「接着上次说」。
    func testOpenerStillPicksTheThreadBackUp() {
        let prompt = PromptBuilder.continuationOpenerPrompt(review: review())
        XCTAssertTrue(prompt.contains("聊了喜欢的甜点"), "开场白仍要带上上次的复盘事实")
        XCTAssertTrue(prompt.contains("Write ONLY the single message"))
    }
}
