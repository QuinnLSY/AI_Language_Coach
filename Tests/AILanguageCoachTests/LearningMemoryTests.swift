@testable import AIServices
import AppCore
import XCTest

/// 纠错提取（[[FIX]] 行解析）与缓存值类型。
final class LearningMemoryTests: XCTestCase {

    // MARK: - [[FIX]] 解析

    func testExtractsSingleFixLine() {
        let text = """
        Great try! Yesterday we talked about the weekend.
        [[FIX]] I go to school yesterday => I went to school yesterday => 过去式
        What did you do last Sunday?
        """
        let result = ChatService.extractCorrections(text)

        XCTAssertEqual(result.corrections.count, 1)
        XCTAssertEqual(result.corrections.first?.original, "I go to school yesterday")
        XCTAssertEqual(result.corrections.first?.corrected, "I went to school yesterday")
        XCTAssertEqual(result.corrections.first?.explanation, "过去式")

        XCTAssertFalse(result.cleanText.contains("[[FIX]]"), "纠错标记不得进入聊天正文")
        XCTAssertTrue(result.cleanText.contains("What did you do last Sunday?"))
    }

    func testNoFixLineKeepsTextIntact() {
        let text = "Sounds good! Where would you like to go?"
        let result = ChatService.extractCorrections(text)
        XCTAssertTrue(result.corrections.isEmpty)
        XCTAssertEqual(result.cleanText, text)
    }

    func testMultipleFixLines() {
        let text = """
        Nice effort!
        [[FIX]] She don't like it => She doesn't like it => 三单
        [[FIX]] a apple => an apple => 冠词
        """
        let result = ChatService.extractCorrections(text)
        XCTAssertEqual(result.corrections.count, 2)
        XCTAssertEqual(result.cleanText, "Nice effort!")
    }

    func testMalformedFixLineDropped() {
        let text = "Hello!\n[[FIX]] broken line without arrows"
        let result = ChatService.extractCorrections(text)
        XCTAssertTrue(result.corrections.isEmpty, "缺 => 的坏行应被丢弃")
        XCTAssertEqual(result.cleanText, "Hello!")
    }

    // MARK: - 缓存值类型

    func testCacheSnapshotByteCount() {
        XCTAssertTrue(CacheSnapshot.byteCount(0).contains("0"))
        let display = CacheSnapshot.byteCount(1_048_576)
        XCTAssertTrue(display.contains("MB") || display.contains("字节") || display.contains("bytes"))
    }
}
