import AIDomain
import XCTest

/// 词形还原（划词查变体词的地基）。
///
/// 用户口径：划到变体（复数 / -ing / -ed…）要能查到本体，并说明这是什么形式。
/// 所以这里守两件事：① 常用变体都能还原出**正确**的本体；② 名称与本体对得上。
///
/// ⚠️ 断言用 `contains` 而不是 `first`：同一串字符可能是多个词的形式
/// （`leaves` = leaf / leave，`boxes` = box，`boxe` 是拼出来但没人用的假词），
/// 谁是**真的**由词库回答（`dictionaryBaseForm`），候选顺序只影响「先试哪个」。
/// 契约是「正确的那一个一定在候选里」——顺序稳不稳定不该由这里的断言来钉。
final class WordFormTests: XCTestCase {

    /// 「这个原形是不是真的存在」——用一个迷你词库代替真实词库。
    private let known: Set<String> = [
        "be", "have", "do", "go", "say", "make", "take", "come", "get", "give", "see", "know",
        "subtitle", "study", "box", "watch", "potato", "house", "leaf", "leave",
        "child", "foot", "person", "man", "woman",
        "listen", "make", "run", "lie", "pause", "stop", "agree", "try", "understand",
        "walk", "explain", "read", "buy",
        "happy", "big", "good", "bad", "far",
        "check-in",
    ]

    /// 模拟应用的做法：拿候选去问词库，第一个命中的就是本体。
    private func resolve(_ surface: String) -> WordForm.Candidate? {
        WordForm.candidates(of: surface).first { known.contains($0.lemma) }
    }

    // MARK: - 复数

    func testPluralForms() {
        XCTAssertEqual(resolve("subtitles")?.lemma, "subtitle")
        XCTAssertEqual(resolve("studies")?.lemma, "study")
        XCTAssertEqual(resolve("boxes")?.lemma, "box")
        XCTAssertEqual(resolve("watches")?.lemma, "watch")
        XCTAssertEqual(resolve("potatoes")?.lemma, "potato")
        XCTAssertEqual(resolve("houses")?.lemma, "house")
        XCTAssertEqual(resolve("subtitles")?.label, WordForm.Label.plural)
        XCTAssertNil(resolve("subtit"), "不是变体就不该硬还原：候选里没有一个真词")
    }

    func testPluralEndingInVesKeepsEveryPlausibleBase() {
        // leaves 既可能是 leaf 也可能是 leave，两个都要给（用户划一次就得查到）。
        let candidates = WordForm.candidates(of: "leaves").map(\.lemma)
        XCTAssertTrue(candidates.contains("leaf"), "\(candidates)")
        XCTAssertTrue(candidates.contains("leave"), "\(candidates)")
    }

    func testIrregularPlurals() {
        XCTAssertEqual(resolve("children")?.lemma, "child")
        XCTAssertEqual(resolve("feet")?.lemma, "foot")
        XCTAssertEqual(resolve("people")?.lemma, "person")
        XCTAssertEqual(resolve("children")?.label, WordForm.Label.plural)
    }

    // MARK: - -ing / -ed

    func testProgressiveAndPastForms() {
        XCTAssertEqual(resolve("listening")?.lemma, "listen")
        XCTAssertEqual(resolve("making")?.lemma, "make")
        XCTAssertEqual(resolve("running")?.lemma, "run")
        XCTAssertEqual(resolve("lying")?.lemma, "lie")
        XCTAssertEqual(resolve("paused")?.lemma, "pause")
        XCTAssertEqual(resolve("stopped")?.lemma, "stop")
        XCTAssertEqual(resolve("agreed")?.lemma, "agree")
        XCTAssertEqual(resolve("tried")?.lemma, "try")
        XCTAssertEqual(resolve("understood")?.lemma, "understand")
        XCTAssertEqual(resolve("explaining")?.lemma, "explain")
        XCTAssertEqual(resolve("listening")?.label, WordForm.Label.progressive)
        XCTAssertEqual(resolve("paused")?.label, WordForm.Label.past)
    }

    /// 三单 / be 动词这种「短到会被长度门槛挡掉」的：不规则表必须排在门槛前面。
    func testThirdPersonAndBeVerbs() {
        XCTAssertEqual(resolve("is")?.lemma, "be")
        XCTAssertEqual(resolve("am")?.lemma, "be")
        XCTAssertEqual(resolve("were")?.lemma, "be")
        XCTAssertEqual(resolve("has")?.lemma, "have")
        XCTAssertEqual(resolve("goes")?.lemma, "go")
        XCTAssertEqual(resolve("went")?.lemma, "go")
    }

    // MARK: - 比较级

    func testComparatives() {
        XCTAssertEqual(resolve("happier")?.lemma, "happy")
        XCTAssertEqual(resolve("happiest")?.lemma, "happy")
        XCTAssertEqual(resolve("bigger")?.lemma, "big")
        XCTAssertEqual(resolve("better")?.lemma, "good")
        XCTAssertEqual(resolve("worst")?.lemma, "bad")
        XCTAssertEqual(resolve("better")?.label, WordForm.Label.comparative)
    }

    // MARK: - 不该还原的东西

    func testPhrasesAndShortWordsAreLeftAlone() {
        XCTAssertTrue(WordForm.candidates(of: "of course").isEmpty, "短语没有原形")
        XCTAssertTrue(WordForm.candidates(of: "a").isEmpty)
        XCTAssertTrue(WordForm.candidates(of: "an").isEmpty)
    }

    /// `read` 的过去式与原型同形 —— 还原成它自己没有意义，候选表里不该出现它自己。
    func testWordThatEqualsItsOwnBaseYieldsNothing() {
        XCTAssertTrue(WordForm.candidates(of: "read").isEmpty, "\(WordForm.candidates(of: "read"))")
    }

    func testHyphenatedWordsOnlyReduceTheLastSegment() {
        let candidates = WordForm.candidates(of: "check-ins").map(\.lemma)
        XCTAssertEqual(candidates.first, "check-in", "\(candidates)")
    }

    // MARK: - 名称反推

    func testLabelIsDerivedBackFromSurfaceAndLemma() {
        // 模型自己判断出原形时，我们仍要能倒推名称（拿不到就返回 nil，绝不瞎编）。
        XCTAssertEqual(WordForm.label(surface: "subtitles", lemma: "subtitle"), WordForm.Label.plural)
        XCTAssertEqual(WordForm.label(surface: "reading", lemma: "read"), WordForm.Label.progressive)
        XCTAssertNil(WordForm.label(surface: "subtitles", lemma: "subtitley"))
        XCTAssertNil(WordForm.label(surface: "hello", lemma: "hell"))
    }
}
