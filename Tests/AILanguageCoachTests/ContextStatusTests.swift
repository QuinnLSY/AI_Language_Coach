import AIServices
import AppUI
import XCTest

/// 输入框下方模型/上下文状态栏的纯函数行为。
@MainActor
final class ContextStatusTests: XCTestCase {

    // ⚠️ **必须显式传 `:memory:`**：`CoachServices()` 的 `databasePath` 默认 nil，
    // 而 nil 会落到 `LearningDatabase.defaultURL()` —— 也就是**用户的真实学习库**。
    /// 这两条用例都在调 `send()`，于是每跑一次全量测试，用户的库里就多出两行
    /// 「Hello teacher, how are you today?」的孤儿会话（messages 里只有一条 user 消息、
    /// 没有老师回复），「最近练习」列表里一排 1 条对话的卡片就是它。
    private func makeService() -> ChatService {
        ChatService(services: CoachServices(databasePath: ":memory:"))
    }

    func testTokenCountAbbreviation() {
        XCTAssertEqual(ChatView.tokenCount(0), "0")
        XCTAssertEqual(ChatView.tokenCount(999), "999")
        XCTAssertEqual(ChatView.tokenCount(1234), "1.2k")
        XCTAssertEqual(ChatView.tokenCount(65536), "65.5k")
    }

    func testEstimatedContextTokensGrowsWithMessages() {
        let service = makeService()
        XCTAssertEqual(service.estimatedContextTokens, 0)
        service.send("Hello teacher, how are you today?")
        XCTAssertGreaterThan(service.estimatedContextTokens, 0)
        service.send("I am fine thank you and you?")
        XCTAssertGreaterThan(service.estimatedContextTokens, 10)
    }

    func testEstimatedContextTokensIsEmptyForWhitespaceOnly() {
        let service = makeService()
        // 空白输入不会产生消息
        service.send("   ")
        XCTAssertEqual(service.estimatedContextTokens, 0)
    }
}
