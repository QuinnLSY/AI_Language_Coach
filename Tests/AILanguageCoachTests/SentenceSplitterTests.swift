import AIInfrastructure
import XCTest

/// 分句器测试：朗读流水线的基础，切分质量直接决定首音延迟与朗读自然度。
final class SentenceSplitterTests: XCTestCase {

    func testSplitsOnSentenceTerminators() {
        let text = "Hello there, my friend! How are you doing today? I am doing very well, thanks."
        let out = SentenceSplitter.split(text)
        XCTAssertEqual(out.count, 3, "实际切分：\(out)")
        XCTAssertTrue(out[0].hasSuffix("!"))
        XCTAssertTrue(out[1].hasSuffix("?"))
    }

    func testMergesVeryShortFragments() {
        // 极短句不单独成片（"Yes." 单独朗读很突兀），应与相邻句合并
        let text = "Yes. I really like learning English with you every single day."
        let out = SentenceSplitter.split(text)
        XCTAssertEqual(out.count, 1, "实际切分：\(out)")
        XCTAssertTrue(out[0].contains("Yes."))
    }

    func testEmptyInputYieldsNoPieces() {
        XCTAssertTrue(SentenceSplitter.split("").isEmpty)
        XCTAssertTrue(SentenceSplitter.split("   \n\t  ").isEmpty)
    }

    func testNormalizesNewlinesAndMarkdown() {
        let out = SentenceSplitter.split("**Hello** my dear friend.\nThis is a longer `sentence` here.")
        XCTAssertEqual(out.count, 2, "实际切分：\(out)")
        XCTAssertFalse(out.joined().contains("*"), "markdown 强调符应被剥离")
        XCTAssertFalse(out.joined().contains("`"))
        XCTAssertFalse(out.joined().contains("\n"), "换行应归一为空格")
    }

    func testTrailingQuoteSticksToSentence() {
        let text = "He said \"I will be there soon.\" Then he walked away quickly."
        let out = SentenceSplitter.split(text)
        XCTAssertEqual(out.count, 2, "实际切分：\(out)")
        XCTAssertTrue(out[0].hasSuffix("\""), "收尾引号应吸附到本句：\(out)")
    }

    func testOverlongPieceIsBrokenDown() {
        let long = "I went to the park yesterday with my sister and we saw a beautiful bird, "
            + "and then we walked home slowly together, and after that we had a nice dinner at home."
        let out = SentenceSplitter.split(long, maxLength: 60, minLength: 10)
        XCTAssertGreaterThan(out.count, 1, "超长句必须再切：\(out)")
        // 允许末尾小尾巴并入前一片，故留出 1/3 余量
        XCTAssertTrue(out.allSatisfy { $0.count <= 80 }, "实际长度：\(out.map(\.count))")
    }

    func testTextWithoutPunctuationStillSplits() {
        let text = String(repeating: "word ", count: 40)   // 无任何标点
        let out = SentenceSplitter.split(text, maxLength: 60)
        XCTAssertGreaterThan(out.count, 1, "无标点长文本也必须切成多片")
    }

    func testEveryPieceIsNonEmptyAndTrimmed() {
        let text = "  First sentence here.   Second sentence here!  \n  Third one is here.  "
        let out = SentenceSplitter.split(text)
        XCTAssertFalse(out.isEmpty)
        XCTAssertTrue(out.allSatisfy { !$0.isEmpty && $0 == $0.trimmingCharacters(in: .whitespaces) })
    }

    // MARK: - 朗读文本清洗（避免 TTS 念出 markdown / emoji 杂音）

    func testStripsListMarkers() {
        let text = "- Use plain text with symbols\n- No complex codes here, just easy syntax\n1. Works in many tools"
        let out = SentenceSplitter.split(text)
        let joined = out.joined(separator: " ")
        XCTAssertFalse(joined.contains("- "), "行首列表符号应被剥离：\(out)")
        XCTAssertTrue(joined.contains("Use plain text"), "正文必须保留：\(out)")
    }

    func testStripsEmoji() {
        let text = "Great job today! 😊🌟 You did really well, my friend."
        let out = SentenceSplitter.split(text)
        let joined = out.joined()
        XCTAssertFalse(joined.contains("😊"))
        XCTAssertFalse(joined.contains("🌟"))
        XCTAssertTrue(joined.contains("Great job today!"))
    }

    func testKeepsPunctuationInsideParentheses() {
        // 括号内的句点不应断句
        let text = "It works in many tools (GitHub, Notion, etc.) which is convenient."
        let out = SentenceSplitter.split(text)
        XCTAssertEqual(out.count, 1, "括号内句点不应断句：\(out)")
        XCTAssertTrue(out[0].contains("etc."))
    }

    func testRemovesMarkdownLinkSyntax() {
        let text = "Check [the guide](https://example.com/docs) for more details on this."
        let out = SentenceSplitter.split(text)
        let joined = out.joined()
        XCTAssertFalse(joined.contains("https://"), "链接地址不应被朗读：\(out)")
        XCTAssertFalse(joined.contains("]("))
        XCTAssertTrue(joined.contains("the guide"))
    }
}
