import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import XCTest
@testable import AppUI

/// 复盘回执上的「去看复盘」（用户 2026-09-23 需求 2）：
/// 提示条里多一颗胶囊按钮，点了要**跳到那一条练习记录**并把它的复盘展开；
/// 学员开口说下一句时，这条回执自己消失。
///
/// ⚠️ 不配任何 provider：复盘走规则兜底（`SessionReviewService` 的 catch 分支），
/// 全程零网络请求，也不会碰到真实库（`databasePath: ":memory:"`）。
@MainActor
final class PracticeNoticeTests: XCTestCase {

    private func makeState() -> (AppState, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-notice-\(UUID().uuidString).json")
        return (AppState(services: CoachServices(config: ConfigStore(fileURL: url), databasePath: ":memory:")), url)
    }

    private func waitUntil(_ condition: @MainActor @escaping () -> Bool, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    /// 锚点值本身：跳哪一条 + 要不要展开，必须是同一个值里的两件事。
    func testReviewFocusCarriesAnchorAndExpandIntent() {
        let id = UUID()
        XCTAssertEqual(RecordsFocus.mistakes.anchorID, "records-mistakes", "错题本的锚点不能改名")
        XCTAssertNil(RecordsFocus.mistakes.expandingSession, "错题本不该顺手展开某条练习")
        XCTAssertEqual(
            RecordsFocus.sessionReview(id).anchorID, "records-session-\(id.uuidString)",
            "锚点要落在**那一条**上，不能只滚到「最近练习」这张卡"
        )
        XCTAssertEqual(RecordsFocus.sessionReview(id).expandingSession, id)
        XCTAssertNotEqual(RecordsFocus.sessionReview(id), .mistakes)
        XCTAssertNotEqual(
            RecordsFocus.sessionReview(id), .sessionReview(UUID()),
            "两条不同的练习不能算同一个跳转目标"
        )
    }

    /// 全链路：自动复盘 → 回执带「去看复盘」→ 点了带着**那一段的 id** 落到学习记录 → 学员开口收条。
    func testReceiptOffersJumpToThatSessionAndDisappearsWhenLearnerSpeaks() async throws {
        let (state, configURL) = makeState()
        defer { try? FileManager.default.removeItem(at: configURL) }
        let services = state.services

        let sessionID = UUID()
        let start = Date(timeIntervalSince1970: 1_772_000_000)
        let learner = ChatMessage(role: .user, content: "Hi teacher, I want to talk about my weekend.", createdAt: start)
        let teacher = ChatMessage(role: .assistant, content: "Sure! Tell me more.", createdAt: start.addingTimeInterval(90))
        await services.persistSession(
            ChatSession(id: sessionID, startedAt: start, mode: .conversation, scenarioID: nil)
        )
        await services.persistMessage(learner, sessionID: sessionID)
        await services.persistMessage(teacher, sessionID: sessionID)

        XCTAssertNil(state.practiceNotice, "还没复盘就不该有回执")

        _ = await state.concludeCurrentPractice(session: sessionID, messages: [learner, teacher])

        let notice = try XCTUnwrap(state.practiceNotice, "自动复盘之后必须给一句回执")
        XCTAssertTrue(notice.text.contains("自动复盘"), "回执要说清「刚才那一段已经收好了」")
        let action = try XCTUnwrap(
            notice.action,
            "回执必须自带跳转 —— 只说「收进学习记录了」，学员还得自己去记录页里翻"
        )
        XCTAssertEqual(action.title, "去看复盘")

        // 点它：意图落到 AppState 上（学习记录页是 if/else 新建的，接不住别的方式）。
        action.run()
        await waitUntil { state.recordsFocus != nil }
        XCTAssertEqual(
            state.recordsFocus, .sessionReview(sessionID),
            "跳的必须是**刚才被复盘的那一段**，不是最近一条、也不是错题本"
        )
        XCTAssertTrue(state.showingRecords, "点了「去看复盘」要真的切到学习记录页")

        // 学员开口说下一句：这条回执过期了（再挂着只会挡住对话）。
        XCTAssertTrue(state.sendChat("Let's continue."))
        XCTAssertNil(state.practiceNotice, "学员已经开口，回执该收了")
    }

    /// 反面：复盘没生成出来时，回执**不许**带跳转。
    ///
    /// 那种情况下学习记录里根本没有这一段的复盘，「去看复盘」点过去只会看到「暂无复盘」——
    /// 文案与动作绑成一个值的意义就在这里：这一条从构造上就没有动作可挂。
    func testFailureReceiptHasNoAction() async {
        let (state, configURL) = makeState()
        defer { try? FileManager.default.removeItem(at: configURL) }
        // 一条消息都没有 → `concludeCurrentPractice` 直接返回 nil，什么提示都不该有。
        _ = await state.concludeCurrentPractice(session: UUID(), messages: [])
        XCTAssertNil(state.practiceNotice, "没练过就没有回执")
    }
}
