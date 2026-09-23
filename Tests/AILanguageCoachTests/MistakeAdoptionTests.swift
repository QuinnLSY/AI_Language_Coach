import AIDomain
import AIInfrastructure
import AIServices
import AppCore
@testable import AppUI
import XCTest

/// 老师批注实时进错题本（#3）的接线回归。
///
/// 报障原话：对话里明明出现了「改一改」卡片、复盘里也有总结，
/// 错题本却没更新；「老师记住了你什么」卡片也不动。
/// 根因有两个（各有各的用例钉住）：
/// ① 清流水顺手删纠错 —— 数据库层，见 `LearningDatabaseTests` 的清流水用例；
/// ② 错题本只在进记录页时 `loadRecords` —— 这里的接线用例管这一半。
@MainActor
final class MistakeAdoptionTests: XCTestCase {

    // MARK: - 夹具

    /// 隔离库：测试进程绝不能碰真实学习数据。
    private func makeState() throws -> (AppState, CoachServices, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mistake-adoption-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        let services = CoachServices(
            config: store, databasePath: directory.appendingPathComponent("learning.db").path
        )
        return (AppState(services: services), services, directory)
    }

    private static let tense = GrammarCorrection(original: "I go", corrected: "I went", explanation: "过去式")
    private static let article = GrammarCorrection(original: "a apple", corrected: "an apple", explanation: "冠词")

    // MARK: - 实时进错题本

    func testTeacherCorrectionsLandInTheMistakeListImmediately() throws {
        let (state, _, directory) = try makeState()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 一轮老师回复标了两处。学员**不进记录页**，错题本当场就要有。
        state.handleTeacherTurnEnd(
            ChatMessage(role: .assistant, content: "好多了！"),
            corrections: [Self.tense, Self.article]
        )
        XCTAssertEqual(state.mistakes.count, 2)
        // 与数据库同口径：新 → 旧。同一轮里后落的库排前面。
        XCTAssertEqual(state.mistakes.first?.corrected, "an apple")
        XCTAssertEqual(state.mistakes.last?.corrected, "I went")
    }

    func testNoCorrectionsLeavesTheMistakeListAlone() throws {
        let (state, _, directory) = try makeState()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 老师这轮没标错（包括没接上的空轮）→ 错题本不该凭空动。
        state.handleTeacherTurnEnd(ChatMessage(role: .assistant, content: "Nice!"), corrections: [])
        state.handleTeacherTurnEnd(nil, corrections: [])
        XCTAssertTrue(state.mistakes.isEmpty)
    }

    func testMergeCapsAtTheSameLimitAsLoadRecords() throws {
        let (state, _, directory) = try makeState()
        defer { try? FileManager.default.removeItem(at: directory) }

        // loadRecords 取最近 50 条；实时并入不能悄悄越界，否则同一条数据
        // 「练习中看得到、进了记录页就没了」。
        let batch = (0..<60).map {
            GrammarCorrection(original: "w\($0)", corrected: "W\($0)", explanation: "")
        }
        state.handleTeacherTurnEnd(ChatMessage(role: .assistant, content: "ok"), corrections: batch)
        XCTAssertEqual(state.mistakes.count, 50)
        XCTAssertEqual(state.mistakes.first?.corrected, "W59", "截断要保住最新的那头")
    }

    // MARK: - 「老师记住了你什么」跟着更新

    func testLearningMemoryRefreshPicksUpThePersistedCorrections() async throws {
        let (state, services, directory) = try makeState()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 生产链路里 ChatService 在回调触发**前**已把纠错落库；
        // 测试不经过 ChatService，得自己补上这一步（模拟已完成的前半段）。
        // ⚠️ corrections.session_id 有外键 —— 会话行必须先存在，否则插入被吞。
        let session = ChatSession()
        try await services.learning?.createSession(session)
        await services.persistCorrection(Self.tense, sessionID: session.id)
        state.handleTeacherTurnEnd(
            ChatMessage(role: .assistant, content: "好多了！"),
            corrections: [Self.tense]
        )
        // 刷新是回调里起的 Task；这里轮询等它把记忆算出来 ——
        // 等不到就是接线断了，不是机器慢。
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if state.learningMemory.totalCorrections > 0 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(state.learningMemory.totalCorrections, 1, "「老师记住了你什么」要看到新批注")
    }
}
