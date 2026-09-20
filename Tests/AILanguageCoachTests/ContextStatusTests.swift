import AIServices
import AppUI
import XCTest

/// 输入框下方模型/上下文状态栏的纯函数行为。
@MainActor
final class ContextStatusTests: XCTestCase {

    func testTokenCountAbbreviation() {
        XCTAssertEqual(ChatView.tokenCount(0), "0")
        XCTAssertEqual(ChatView.tokenCount(999), "999")
        XCTAssertEqual(ChatView.tokenCount(1234), "1.2k")
        XCTAssertEqual(ChatView.tokenCount(65536), "65.5k")
    }

    func testEstimatedContextTokensGrowsWithMessages() {
        let service = ChatService(services: CoachServices())
        XCTAssertEqual(service.estimatedContextTokens, 0)
        service.send("Hello teacher, how are you today?")
        XCTAssertGreaterThan(service.estimatedContextTokens, 0)
        service.send("I am fine thank you and you?")
        XCTAssertGreaterThan(service.estimatedContextTokens, 10)
    }

    func testEstimatedContextTokensIsEmptyForWhitespaceOnly() {
        let service = ChatService(services: CoachServices())
        // 空白输入不会产生消息
        service.send("   ")
        XCTAssertEqual(service.estimatedContextTokens, 0)
    }
}
