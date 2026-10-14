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

    // MARK: - 幻觉纠错（GrammarCorrectionSanity）

    /// 真实教学事故的形状。库里有铁证：学员原句本就大写、老师也回了 You did it!，
    /// 模型仍输出「大写句 => 小写句 => 句首字母要大写」—— 无中生有、方向还反。
    func testReversedSentenceInitialCapitalIsDropped() {
        // 只差句首一个字母、原句本就大写 → 丢。
        XCTAssertTrue(
            GrammarCorrectionSanity.isHallucinated(
                original: "I like eating Portuguese egg tarts.",
                corrected: "i like eating Portuguese egg tarts."
            )
        )
        // 通篇改小写同样丢（改完反而少了句首大写）。
        XCTAssertTrue(
            GrammarCorrectionSanity.isHallucinated(
                original: "I like eating Portuguese egg tarts.",
                corrected: "i like eating portuguese egg tarts."
            )
        )
        // 走解析层整条不出现；正文照样剥干净，不能把 [[FIX]] 行漏给用户。
        let result = ChatService.extractCorrections(
            "You did it!\n[[FIX]] I like eating Portuguese egg tarts. => i like eating Portuguese egg tarts. => 句首字母要大写"
        )
        XCTAssertTrue(result.corrections.isEmpty, "幻觉纠错不该变成卡片 / 错题本")
        XCTAssertEqual(result.cleanText, "You did it!")
    }

    func testExactCopyIsDropped() {
        // 库里另一条铁证：把一整段要求原句原样标成纠错。
        XCTAssertTrue(
            GrammarCorrectionSanity.isHallucinated(
                original: "Please explain the water cycle in detail.",
                corrected: "Please explain the water cycle in detail."
            )
        )
        // 排版差异（多空白）不算改了什么。
        XCTAssertTrue(GrammarCorrectionSanity.isHallucinated(original: "a  apple", corrected: "a apple"))
    }

    func testGenuineCorrectionsAreKept() {
        // 学员真写错句首 → 正经纠错，必须保留。
        XCTAssertFalse(
            GrammarCorrectionSanity.isHallucinated(original: "i like tea", corrected: "I like tea")
        )
        // 喊叫体改回正常大小写：句首被改小写，但那是去喊叫，不是幻觉。
        XCTAssertFalse(
            GrammarCorrectionSanity.isHallucinated(original: "I LIKE TEA", corrected: "I like tea")
        )
        // 词形纠错、标点纠错、更自然的说法 —— 全都放行。
        XCTAssertFalse(
            GrammarCorrectionSanity.isHallucinated(original: "what happend today?", corrected: "what happened today?")
        )
        XCTAssertFalse(
            GrammarCorrectionSanity.isHallucinated(original: "Hi teacher!", corrected: "Hello!")
        )
        // 句首大小写不动、只改中间一处大小写（如标题式误大写）—— 拿不准，放行。
        XCTAssertFalse(
            GrammarCorrectionSanity.isHallucinated(original: "I Like Tea", corrected: "I like tea")
        )
    }

    func testMixedGenuineAndHallucinatedLinesKeepOnlyTheGenuineOne() {
        let result = ChatService.extractCorrections(
            "Nice!\n[[FIX]] i love apples => I love apples => 句首字母要大写\n[[FIX]] I love apples => i love apples => 句首字母要大写"
        )
        XCTAssertEqual(result.corrections.count, 1)
        XCTAssertEqual(result.corrections.first?.original, "i love apples", "正经纠错要留下")
        XCTAssertEqual(result.corrections.first?.corrected, "I love apples")
    }

    // MARK: - 陈旧纠错（原句不是本轮说过的话）

    /// 用户 2026-10-14 报障的形状：学员说 "I am eating watermelon."，
    /// 老师却把两轮前的 "I has no idea about what to chat." 又纠了一遍，
    /// 卡片挂在与最新一句毫无关系的回复下（错题本 / 学习记忆一并被污染）。
    func testStaleCorrectionFromAnEarlierTurnIsDropped() {
        XCTAssertTrue(
            GrammarCorrectionSanity.isUnrelatedToLatestMessage(
                original: "I has no idea about what to chat.",
                learnerText: "I am eating watermelon."
            ),
            "原句与本轮消息用词几乎不重合 → 陈旧"
        )
        // 走解析层：不产卡片、不进错题本；正文剥干净，[[FIX]] 不许漏给用户。
        let result = ChatService.extractCorrections(
            "Watermelon is a perfect summer treat! It is sweet and juicy.\n"
                + "[[FIX]] I has no idea about what to chat. => I have no idea what to chat about. => has 改为 have",
            learnerText: "I am eating watermelon."
        )
        XCTAssertTrue(result.corrections.isEmpty, "陈旧纠错不该变成卡片")
        XCTAssertEqual(result.cleanText, "Watermelon is a perfect summer treat! It is sweet and juicy.")
        XCTAssertFalse(result.didConclude, "陈旧行不算交代过 —— 这一轮仍欠一次收尾，追问照常")
    }

    /// 换个说法、但仍是另一句的陈旧纠错（内容词重合 1/2 < 0.6）。
    func testStaleCorrectionWithSimilarWordingIsStillDropped() {
        XCTAssertTrue(
            GrammarCorrectionSanity.isUnrelatedToLatestMessage(
                original: "I has no idea what to chat about.",
                learnerText: "I have no time to chat."
            )
        )
    }

    /// 真纠错的原句是**逐字引用**本轮原话 → 必须留下。
    func testGenuineCorrectionsQuotingThisTurnAreKept() {
        // 整句引用。
        XCTAssertFalse(
            GrammarCorrectionSanity.isUnrelatedToLatestMessage(
                original: "I eat fruit at my dinner today.",
                learnerText: "I eat fruit at my dinner today."
            )
        )
        // 多句消息里只纠其中一句（引片段）。
        XCTAssertFalse(
            GrammarCorrectionSanity.isUnrelatedToLatestMessage(
                original: "I eat fruit at my dinner today.",
                learnerText: "I think fruit is healthy. I eat fruit at my dinner today."
            )
        )
        // 只标句子里出错的那个词（片段级原句）。
        XCTAssertFalse(
            GrammarCorrectionSanity.isUnrelatedToLatestMessage(
                original: "has",
                learnerText: "I has no idea about what to chat."
            )
        )
        // 「再练一次」：学员把旧错句原样重说一遍 → 这是本轮的话，必须留。
        XCTAssertFalse(
            GrammarCorrectionSanity.isUnrelatedToLatestMessage(
                original: "I has no idea about what to chat.",
                learnerText: "I has no idea about what to chat."
            )
        )
        // 大小写 / 标点差异不算换句。
        XCTAssertFalse(
            GrammarCorrectionSanity.isUnrelatedToLatestMessage(
                original: "i eat fruit at my dinner today",
                learnerText: "I eat fruit at my dinner today."
            )
        )
        // 中文逐字引用（CJK 按字切，整句当一个词就没法比了）。
        XCTAssertFalse(
            GrammarCorrectionSanity.isUnrelatedToLatestMessage(
                original: "我昨天去了商店。",
                learnerText: "我昨天去了商店，买了苹果。"
            )
        )
        // 中文换了一句 → 陈旧。
        XCTAssertTrue(
            GrammarCorrectionSanity.isUnrelatedToLatestMessage(
                original: "我喜欢吃苹果。",
                learnerText: "我想喝咖啡。"
            )
        )
        // 单个内容词对不上（搭了一个偶然撞上的单词）→ 陈旧。
        XCTAssertTrue(
            GrammarCorrectionSanity.isUnrelatedToLatestMessage(
                original: "has",
                learnerText: "I am eating watermelon."
            )
        )
    }

    /// 判不了就放行：原句全是功能词 / 学员消息是空的。
    func testStalenessFilterPassesWhenItCannotJudge() {
        XCTAssertFalse(
            GrammarCorrectionSanity.isUnrelatedToLatestMessage(original: "I am.", learnerText: "I am eating watermelon."),
            "原句剥完一个内容词都不剩 → 不判"
        )
        XCTAssertFalse(
            GrammarCorrectionSanity.isUnrelatedToLatestMessage(original: "I has no idea.", learnerText: "   "),
            "没有学员消息可比对 → 不判"
        )
    }

    /// 没有比对基准（老师开场那类轮次）时不做这个判断 —— 向后兼容旧调用。
    func testNoLearnerTextMeansNoStalenessFilter() {
        let result = ChatService.extractCorrections(
            "[[FIX]] I has no idea about what to chat. => I have no idea what to chat about. => has 改为 have"
        )
        XCTAssertEqual(result.corrections.count, 1, "没有 learnerText 就不做陈旧判断")
    }

    /// 同一轮里既有真纠错又有陈旧纠错：只留真的，且算交代过（不触发追问）。
    func testMixedRealAndStaleLinesKeepOnlyTheRealOne() {
        let result = ChatService.extractCorrections(
            "Good try!\n"
                + "[[FIX]] I eat fruit at my dinner today. => I ate fruit for dinner today. => 过去发生用 ate；for dinner\n"
                + "[[FIX]] I has no idea about what to chat. => I have no idea what to chat about. => has 改为 have",
            learnerText: "I eat fruit at my dinner today."
        )
        XCTAssertEqual(result.corrections.count, 1)
        XCTAssertEqual(result.corrections.first?.original, "I eat fruit at my dinner today.", "本轮这条要留下")
        XCTAssertTrue(result.didConclude, "有真纠错 = 交代过了")
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
