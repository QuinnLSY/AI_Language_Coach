import AIDomain
import AIServices
import XCTest

/// 朗读侧的 emoji / 装饰符号清洗。
///
/// 产品口径：emoji 只从**送去合成**的文本里去掉，正文与气泡一个字不动 ——
/// 那些符号在界面上是有意义的（语气、表情、打勾），不能拿视觉换听觉。
final class SpeechTextSanitizerTests: XCTestCase {

    // MARK: - 哪些码位不该被念

    func testKeepsLettersDigitsAndCJKPunctuation() {
        for scalar in "aZ09\u{4E2D}\u{3002}\u{FF01}\u{FF1F}\u{2014}".unicodeScalars {
            XCTAssertTrue(
                SpeechTextSanitizer.isSpeakable(scalar),
                "\(scalar) 是正常语言内容，不能被清洗掉"
            )
        }
    }

    /// ⚠️ 最关键的一条：数字 0-9 在 Unicode 里也带 `Emoji` 属性（它们有 emoji 写法）。
    /// 若按 `isEmoji` 一刀切，会把「I have 2 cats」念成「I have cats」。
    func testDigitsSurviveBecauseTheyAlsoCarryEmojiProperty() {
        XCTAssertTrue("2".unicodeScalars.allSatisfy(SpeechTextSanitizer.isSpeakable))
        XCTAssertEqual(SpeechTextSanitizer.strip("I have 2 cats"), "I have 2 cats")
    }

    func testDropsEmojiAndDecorations() {
        for scalar in "🌿✅😄🎉❤️👍".unicodeScalars {
            XCTAssertFalse(
                SpeechTextSanitizer.isSpeakable(scalar),
                "\(scalar) 不该被念出来"
            )
        }
        // 零宽连接符 / 变体选择符 / 区域指示符（国旗）/ 键帽尾巴
        XCTAssertFalse(SpeechTextSanitizer.isSpeakable("\u{200D}"))
        XCTAssertFalse(SpeechTextSanitizer.isSpeakable("\u{FE0F}"))
        XCTAssertFalse(SpeechTextSanitizer.isSpeakable("\u{1F1E8}"))
        XCTAssertFalse(SpeechTextSanitizer.isSpeakable("\u{20E3}"))
    }

    // MARK: - 整句清洗

    func testEmojiOnlyTextBecomesEmpty() {
        XCTAssertEqual(SpeechTextSanitizer.strip("🌿🌿"), "")
        XCTAssertEqual(SpeechTextSanitizer.strip("  🌿  "), "")
        // 读不出内容的文本不该产生空格噪音：调用方据此直接跳过朗读（`guard !cleaned.isEmpty`）。
        XCTAssertTrue(VoiceService.cleanForSpeech("🌿🌿").isEmpty)
    }

    func testEmojiBetweenWordsLeavesSingleSpace() {
        XCTAssertEqual(
            SpeechTextSanitizer.strip("Hello 🌿 world"),
            "Hello world",
            "去掉一个 emoji 会留下两个空格，必须收成一格，否则合成器会在那里顿一拍"
        )
        XCTAssertEqual(SpeechTextSanitizer.strip("Nice  😄   work"), "Nice work")
    }

    func testFamilyEmojiSequenceIsFullyRemoved() {
        // 👨‍👩‍👧 = 三个图形 + 两个零宽连接符：只按「图形」判断会漏掉连接符，留下碎音
        XCTAssertEqual(SpeechTextSanitizer.strip("Say 👨\u{200D}👩\u{200D}👧 hi"), "Say hi")
        XCTAssertEqual(SpeechTextSanitizer.strip("Flag: 🇨🇳"), "Flag:")
    }

    func testKeycapAndVariationSelectorCollapseToPlainCharacter() {
        XCTAssertEqual(SpeechTextSanitizer.strip("1️⃣"), "1")
        XCTAssertEqual(SpeechTextSanitizer.strip("❤️"), "")
        XCTAssertEqual(SpeechTextSanitizer.strip("I have 2️⃣ apples"), "I have 2 apples")
    }

    func testCJKTextWithEmojiSurvivesIntact() {
        XCTAssertEqual(
            SpeechTextSanitizer.strip("很好！继续保持 🌟 加油"),
            "很好！继续保持 加油"
        )
    }

    func testStripLeavesPlainTextUntouched() {
        let text = "I'd like a coffee, please. How much is it?"
        XCTAssertEqual(SpeechTextSanitizer.strip(text), text)
        XCTAssertEqual(SpeechTextSanitizer.strip(""), "")
    }

    // MARK: - 与朗读清洗的接线

    /// 朗读文本走的是同一个收口点（本地分句 / 云端整段都从这里取文本），
    /// 所以在这里断言一次就等于两条链路都覆盖了。
    func testCleanForSpeechDropsEmojiButKeepsWords() {
        let cleaned = VoiceService.cleanForSpeech("Great job! 🌿 See you tomorrow 😄")
        XCTAssertEqual(cleaned, "Great job! See you tomorrow")
    }

    /// 校正块与 emoji 同时出现时两者都要处理干净（结构清洗 + 字符清洗互不干扰）。
    func testCleanForSpeechHandlesCorrectionBlocksAndEmojiTogether() {
        let text = """
        Nice try! 🌿
        [[FIX]] I goed => I went => 动词过去式
        Try again! 😄
        """
        let cleaned = VoiceService.cleanForSpeech(text)
        XCTAssertEqual(cleaned, "Nice try! Try again!")
    }
}
