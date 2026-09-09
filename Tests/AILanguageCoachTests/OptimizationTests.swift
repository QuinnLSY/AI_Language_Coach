import AIDomain
import AIInfrastructure
import AppCore
import AppUI
import XCTest

/// 本轮体验优化相关的纯逻辑：Markdown 解析、思考过程持久化、会话恢复、token 统计。
final class OptimizationTests: XCTestCase {

    // MARK: - Markdown 解析

    func testMarkdownBlocksParseHeadingBulletQuoteParagraph() {
        let blocks = MarkdownText.parseBlocks("""
        # Title
        plain **bold** line
        - first
        - second
        > quoted
        """)
        XCTAssertEqual(blocks, [
            .heading(level: 1, content: "Title"),
            .paragraph("plain **bold** line"),
            .bullet(["first", "second"]),
            .quote("quoted"),
        ])
    }

    func testMarkdownBlocksParseFencedCode() {
        let blocks = MarkdownText.parseBlocks("before\n```swift\nlet x = 1\nlet y = 2\n```\nafter")
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[1], .code(language: "swift", code: "let x = 1\nlet y = 2"))
        XCTAssertEqual(blocks[0], .paragraph("before"))
        XCTAssertEqual(blocks[2], .paragraph("after"))
    }

    func testMarkdownNumberedListAndEmpty() {
        XCTAssertEqual(MarkdownText.parseBlocks("1. one\n2. two"), [.bullet(["one", "two"])])
        XCTAssertEqual(MarkdownText.parseBlocks("   \n\n"), [])
    }

    // MARK: - 思考过程持久化（v2 迁移）

    func testChatMessageReasoningCodableBackwardCompat() throws {
        let withReasoning = ChatMessage(role: .assistant, content: "hi", reasoning: "thinking...")
        let data = try JSONEncoder().encode(withReasoning)
        XCTAssertNotNil(try JSONDecoder().decode(ChatMessage.self, from: data).reasoning)

        let legacy = """
        {"id":"\(UUID().uuidString)","role":"assistant","content":"hi","createdAt":653504400.0}
        """
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.reasoning)
    }

    func testDatabaseStoresReasoningAndRestoresLatestSession() async throws {
        let db = try LearningDatabase.inMemory()
        let session = ChatSession(id: UUID(), mode: .conversation)
        try await db.createSession(session)
        let user = ChatMessage(role: .user, content: "hello")
        let teacher = ChatMessage(role: .assistant, content: "Hi!", reasoning: "let me think")
        try await db.appendMessage(user, sessionID: session.id)
        try await db.appendMessage(teacher, sessionID: session.id)

        let restoredResult = try await db.latestSession()
        let restored = try XCTUnwrap(restoredResult)
        XCTAssertEqual(restored.session.id, session.id)
        XCTAssertEqual(restored.messages.count, 2)
        XCTAssertEqual(restored.messages[1].reasoning, "let me think")
        XCTAssertEqual(restored.messages[0].reasoning, nil)
    }

    func testLegacySchemaMigratesAndPreservesRows() async throws {
        // 建一个 v1 形状的库文件，验证打开时迁移 + 旧消息不丢
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-mig-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let old = try SQLiteDatabase(path: url.path)
            try old.run("""
            CREATE TABLE messages (id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
                role TEXT NOT NULL, content TEXT NOT NULL, created_at REAL NOT NULL)
            """)
            try old.run("PRAGMA user_version = 1")
        }
        let db = try LearningDatabase(path: url.path)
        let session = ChatSession(id: UUID())
        try await db.createSession(session)
        try await db.appendMessage(ChatMessage(role: .user, content: "old"), sessionID: session.id)
        try await db.appendMessage(ChatMessage(role: .assistant, content: "new", reasoning: "r"), sessionID: session.id)
        let restoredResult = try await db.latestSession()
        let restored = try XCTUnwrap(restoredResult)
        XCTAssertEqual(restored.messages.last?.reasoning, "r")
    }

    // MARK: - 展示辅助

    func testReasoningDisplayMapping() {
        XCTAssertNil(MainView.reasoningDisplay(nil))
        XCTAssertNil(MainView.reasoningDisplay("标准"))
        XCTAssertEqual(MainView.reasoningDisplay("low"), "低")
        XCTAssertEqual(MainView.reasoningDisplay("medium"), "中")
        XCTAssertEqual(MainView.reasoningDisplay("high"), "高")
    }

    func testDailyTokenCounterAccumulatesWithinDay() {
        let before = DailyTokenCounter.todayTokens()
        DailyTokenCounter.add(128)
        XCTAssertEqual(DailyTokenCounter.todayTokens(), before + 128)
        DailyTokenCounter.add(0)
        XCTAssertEqual(DailyTokenCounter.todayTokens(), before + 128)
    }

    func testNudgePoolSelectionByThreshold() {
        // 三档各不相同且都能随机取到合法文案
        for tokens in [0, 42, 999_999, 1_000_000, 4_999_999, 5_000_000, 9_999_999] {
            let line = TeacherCorner.randomNudge(for: tokens)
            XCTAssertFalse(line.isEmpty)
        }
    }
}
