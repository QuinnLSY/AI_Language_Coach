import AIDomain
import XCTest

/// 老师的语言闸门（用户口径：学员可以用中文问，老师必须且只能用英文答）。
///
/// 这一支测的是**兜底路径的两道判据**：判出母语 → 才去重写；重写结果可信 → 才敢用。
/// 两道都错一次，用户就会看到「学员问了话，老师不回答却又打了个招呼」（实测报障）。
final class TeacherLanguageGuardTests: XCTestCase {

    // MARK: - 判「有没有母语」

    func testDetectsChineseCharactersAndPunctuation() {
        XCTAssertTrue(TeacherLanguageGuard.containsNativeScript("那真是太好了！(That's great!)"))
        XCTAssertTrue(
            TeacherLanguageGuard.containsNativeScript("Nice work! 「乐器」 is called an instrument."),
            "只引用了中文词、整句仍是英文，也算跑出母语"
        )
        XCTAssertTrue(TeacherLanguageGuard.containsNativeScript("全角逗号，也算"))
    }

    func testLeavesPureEnglishAlone() {
        XCTAssertFalse(TeacherLanguageGuard.containsNativeScript("Welcome back! What shall we practice today?"))
        XCTAssertFalse(TeacherLanguageGuard.containsNativeScript("It's a nice day — isn't it?"))
        XCTAssertFalse(TeacherLanguageGuard.containsNativeScript(""))
    }

    // MARK: - 判「重写结果可不可信」

    /// 正常重写（与历史回复都不同）→ 可信。
    func testAcceptsGenuineRewrite() {
        let rewritten = "That's great! Though we usually say \"hands\" or \"fingers\" when playing."
        XCTAssertTrue(TeacherLanguageGuard.isCredibleRewrite(
            rewritten,
            earlierReplies: ["Welcome back to our cozy forest corner. What are you feeling like practicing today?"]
        ))
    }

    /// ⚠️ 重点用例：把历史里的开场白照抄回来当重写结果 —— 必然不可信。
    ///
    /// 这正是实测发生的那个失败（弱模型面对「把你上一条重说一遍」会去抄别处的英文），
    /// 一旦放行，界面上就是「学员问了一句，老师没有回答，反而又打了个招呼」。
    func testRejectsCopyOfAnEarlierReply() {
        let greeting = "Welcome back to our cozy forest corner. What are you feeling like practicing today?"
        XCTAssertFalse(TeacherLanguageGuard.isCredibleRewrite(greeting, earlierReplies: [greeting]))
        // 只差大小写/多空格也算同一句
        XCTAssertFalse(TeacherLanguageGuard.isCredibleRewrite(
            "  welcome  back to our cozy forest corner.   What are you feeling like practicing today? ",
            earlierReplies: [greeting]
        ))
    }

    /// 空结果与「历史里没有可抄的」要分清楚：前者永远不可信，后者不该被误伤。
    func testEmptyIsNeverCredibleAndNoHistoryIsFine() {
        XCTAssertFalse(TeacherLanguageGuard.isCredibleRewrite("   ", earlierReplies: ["anything"]))
        XCTAssertTrue(TeacherLanguageGuard.isCredibleRewrite("Sure — let's try that again.", earlierReplies: []))
    }

    /// ⚠️ 短回复不参与查重：`Good job!` 这种一节课里说好几遍很正常，
    /// 拿它判「抄了历史」会误伤 —— 误伤的结果是原文（带母语）被留下，正好是这条规则要治的病。
    func testShortRepliesAreNotTreatedAsCopies() {
        XCTAssertTrue(TeacherLanguageGuard.isCredibleRewrite("Good job!", earlierReplies: ["Good job!"]))
        XCTAssertTrue(TeacherLanguageGuard.isCredibleRewrite("Try again.", earlierReplies: ["Try again."]))
        // 够长的照旧要查（开场白被抄回来是实测发生过的失败）。
        let greeting = "Welcome back to our cozy forest corner. What are you feeling like practicing today?"
        XCTAssertFalse(TeacherLanguageGuard.isCredibleRewrite(greeting, earlierReplies: [greeting]))
    }
}
