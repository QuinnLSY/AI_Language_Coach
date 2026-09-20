import AIDomain
import AIInterfaces
import AIServices
import AIInfrastructure
import AppCore
import XCTest

/// 启动恢复的历史**默认不上屏**这条语义。
///
/// 用户实测报障：「打开应用先闪一条学员打招呼，再变成老师的招呼」。
/// 根因是恢复出来的历史被立刻画了上去，而它马上要被复盘掉、换成新的一段 ——
/// 复盘要跑一次模型请求（好几秒），这几秒里旧内容就露在屏幕上了。
///
/// 现在改成：恢复只放到内存里，**看不看得见由续做决策说了算**（`revealRestoredHistory`）。
/// 这一支钉的就是这条分界，免得日后有人"顺手"把它改回上屏。
@MainActor
final class RestoredHistoryVisibilityTests: XCTestCase {

    private func makeServices() async throws -> (CoachServices, URL) {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-restore-\(UUID().uuidString).json")
        let store = ConfigStore(fileURL: fileURL)
        try await store.updateProvider(
            ProviderConfig(id: "ollama.llm", kind: .llm, enabled: true, runtime: .mock, model: "mock-model")
        )
        try await store.selectModel("mock-model", for: .llm)
        return (CoachServices(config: store, databasePath: ":memory:"), fileURL)
    }

    /// 造一段「上次练到一半」的会话：同一份 services（同一个内存库）上先聊一句。
    ///
    /// ⚠️ 等的必须是**库里落齐两条**，不是内存里两条：`ChatService.persist(_:)` 是
    /// fire-and-forget 的 `Task`，内存里已经 2 条时库里常常还只有学员那一句，
    /// 紧接着 `restoreLastSessionIfNeeded()` 读库就只拿到 1 条 ——
    /// 这个偶发红过两次（三处断言全挂在 1 vs 2），被误判成「偶发、不用管」。
    /// 等库是**可观察的事实**，等内存只是恰好在多数时候足够快。
    private func seedPreviousSession(_ services: CoachServices) async -> ChatService {
        // ⚠️ 备**两句**：`testClearResetsTheHidingFlag` 在新一段里还要再 `send` 一次，
        // 只给一句的话那次拿不到回复，「等到 2 条」就只能干等满 5 秒超时
        // （断言仍然绿 —— 学员那句已经上屏了 —— 但那 5 秒纯属白等，还会掩盖「回复根本没来」）。
        let provider = ScriptedLLMProvider(scripts: [
            "Welcome back! What shall we practice today?",
            "Sure, let's start with something easy.",
        ])
        try? await services.bootstrapLLM()
        await services.llm.register(provider)
        let chat = ChatService(services: services)
        chat.send("Hello teacher, how are you today?")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let restored = await services.latestChatSession(), restored.messages.count >= 2 { break }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return chat
    }

    func testRestoredHistoryStaysHiddenUntilRevealed() async throws {
        let (services, fileURL) = try await makeServices()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let first = await seedPreviousSession(services)
        XCTAssertEqual(first.messages.count, 2, "先造出一段有内容的会话")

        // 重新启动一个 ChatService（等价于关掉应用再打开）
        let chat = ChatService(services: services)
        await chat.restoreLastSessionIfNeeded()
        XCTAssertEqual(chat.messages.count, 2, "内容确实恢复了（引擎上下文要用）")
        XCTAssertTrue(chat.visibleMessages.isEmpty, "但**一个气泡都不许上屏** —— 这一刻还不知道要不要它")

        chat.revealRestoredHistory()
        XCTAssertEqual(chat.visibleMessages.count, 2, "决定接着用之后才揭开")

        chat.hideRestoredHistory()
        XCTAssertTrue(chat.visibleMessages.isEmpty, "决定换新一段就重新按住")
        XCTAssertEqual(chat.messages.count, 2, "按住只影响显示，数据仍在（复盘要用）")
    }

    /// 换新一段（`clear()`）时隐藏标记要一起复位，否则下一段会被误按。
    func testClearResetsTheHidingFlag() async throws {
        let (services, fileURL) = try await makeServices()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        _ = await seedPreviousSession(services)

        let chat = ChatService(services: services)
        await chat.restoreLastSessionIfNeeded()
        XCTAssertTrue(chat.visibleMessages.isEmpty)

        chat.beginNewSession()
        XCTAssertTrue(chat.visibleMessages.isEmpty, "新一段当然还是空的")
        chat.send("Let's start a new one.")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, chat.messages.count < 2 {
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        XCTAssertFalse(chat.visibleMessages.isEmpty, "新一段的对话必须照常上屏")
    }

    /// 没有历史可恢复时什么都不该发生（第一次打开应用）。
    func testRestoreDoesNothingWithoutAPreviousSession() async throws {
        let (services, fileURL) = try await makeServices()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let chat = ChatService(services: services)
        await chat.restoreLastSessionIfNeeded()
        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertTrue(chat.visibleMessages.isEmpty)
    }
}
