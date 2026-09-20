import AIDomain
@testable import AIServices
import XCTest

/// 纠错行（`[[FIX]] 原句 => 改正 => 说明`）的识别与容错。
///
/// 背景：用户实测「纠错卡片之前有、现在没有了」。库里最近一条纠错停在 6 天前，
/// 而聊天里老师明明在口头纠正 —— 也就是说**标记写歪了就没救**。这里守三件事：
/// ① 各种歪写法都还认得出来；② 认不出的行照样当正文；③ 朗读侧用的是同一份判据。
final class GrammarCorrectionLineTests: XCTestCase {

    // MARK: - 容错识别

    func testAcceptsDecorationVariants() {
        let variants = [
            "[[FIX]] a => b => c",
            "[FIX] a => b => c",
            "【FIX】 a => b => c",
            "**[FIX]** a => b => c",
            "- [[FIX]] a => b => c",
            "> [[FIX]] a => b => c",
            "[[FIX]]: a => b => c",
            "[[FIX]]：a => b => c",
            "  `[[FIX]]` a => b => c  ",
            "[[fix]] a => b => c",
        ]
        for line in variants {
            let corrections = ChatService.extractCorrections(line).corrections
            XCTAssertEqual(corrections.count, 1, "认不出来的写法：\(line)")
            XCTAssertEqual(corrections.first?.original, "a", "原句被装饰带偏了：\(line)")
            XCTAssertEqual(corrections.first?.corrected, "b", "改正被装饰带偏了：\(line)")
            XCTAssertEqual(corrections.first?.explanation, "c", "说明被装饰带偏了：\(line)")
        }
    }

    func testAcceptsArrowSeparators() {
        // 模型偶尔用箭头代替 `=>`；分隔符认多了不会误伤（正文里出现 `→` 极罕见，
        // 而且必须**同时**有标记才算纠错行）。
        let result = ChatService.extractCorrections("[[FIX]] I goed → I went → 过去式")
        XCTAssertEqual(result.corrections.first?.corrected, "I went")
        XCTAssertEqual(result.corrections.first?.explanation, "过去式")
    }

    func testTwoPartLineIsStillACorrection() {
        let result = ChatService.extractCorrections("[[FIX]] a apple => an apple")
        XCTAssertEqual(result.corrections.count, 1)
        XCTAssertTrue(result.corrections[0].explanation.isEmpty, "只给两段时说明为空，不该硬造一句")
    }

    // MARK: - 不误伤

    func testPlainSentenceIsLeftUntouched() {
        let text = "That is a smart habit! Do you pause the movie?"
        let result = ChatService.extractCorrections(text)
        XCTAssertTrue(result.corrections.isEmpty)
        XCTAssertEqual(result.cleanText, text)
    }

    func testMalformedTaggedLineIsDroppedFromTheBody() {
        // 认得出标记但切不出三段：**整行丢掉**，不能以「[[FIX]] …」的样子给用户看见。
        let result = ChatService.extractCorrections("Hello!\n[[FIX]] broken line without arrows")
        XCTAssertTrue(result.corrections.isEmpty)
        XCTAssertEqual(result.cleanText, "Hello!")
    }

    func testLineWithTheWordFixIsNotACorrection() {
        // 正文里说到「fix」这个词不能被当成标记（标记必须带括号形态）。
        let result = ChatService.extractCorrections("I will fix it tomorrow => promise")
        XCTAssertTrue(result.corrections.isEmpty)
        XCTAssertEqual(result.cleanText, "I will fix it tomorrow => promise")
    }

    // MARK: - 朗读侧同一份判据

    func testSpeechCleaningUsesTheSamePredicate() {
        // 卡片认出来了、朗读也念了一遍 —— 这种「半修」最难发现，所以两边必须共用一份判据。
        let spoken = "Good job!\n**[FIX]** I goed => I went => 过去式"
        XCTAssertFalse(
            VoiceService.cleanForSpeech(spoken).contains("I went"),
            "纠错行不该被念出来"
        )
    }

    // MARK: - 英文重说丢块时的补回

    func testCorrectionLinesRoundTrip() {
        let corrections = [
            GrammarCorrection(original: "a apple", corrected: "an apple", explanation: "冠词"),
            GrammarCorrection(original: "I goed", corrected: "I went", explanation: ""),
        ]
        let text = ChatService.correctionLines(corrections)
        let roundTripped = ChatService.extractCorrections(text).corrections
        // 比字段而不是比 `Equatable`：`GrammarCorrection` 带一个每次解析都新生成的 id。
        XCTAssertEqual(roundTripped.map(\.original), corrections.map(\.original))
        XCTAssertEqual(roundTripped.map(\.corrected), corrections.map(\.corrected))
        XCTAssertEqual(roundTripped.map(\.explanation), corrections.map(\.explanation))
    }
}
