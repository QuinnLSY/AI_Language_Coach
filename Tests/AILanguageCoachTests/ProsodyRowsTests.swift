import AIDomain
import XCTest

/// `ProsodyAnalysis.rows`（④ 逐词展示行）的纯函数测试。
///
/// 钉的是**对齐口径** —— 这一层错的表现不是崩，而是「重音标在隔壁那个词上」：
/// 界面上看不出任何异常，学员照着改就把重音改坏了。所以这些断言必须能单独跑。
final class ProsodyRowsTests: XCTestCase {

    private func analysis(
        words: [String],
        stress: [WordStressMark],
        linking: [LinkingSpan] = []
    ) -> ProsodyAnalysis {
        ProsodyAnalysis(words: words, stress: stress, linking: linking)
    }

    private func mark(_ word: String, _ level: WordStressMark.Level) -> WordStressMark {
        WordStressMark(word: word, level: level, ratio: level == .stressed ? 2 : (level == .reduced ? 0.4 : 1))
    }

    // MARK: - ① 行按句子排，不按重音那份子集排

    /// `stress` 是 `words` 滤掉静音词后的**子集**。行数必须跟着句子走，
    /// 否则「I」静音 → 后面每个词的重音整体左移一格。
    func testRowsFollowTheSentenceNotTheStressSubset() {
        let rows = analysis(
            words: ["I", "want", "a", "latte"],
            // 模拟「I」被绝对底噪滤掉：stress 从 want 开始。
            stress: [mark("want", .normal), mark("a", .reduced), mark("latte", .stressed)]
        ).rows

        XCTAssertEqual(rows.map(\.word), ["I", "want", "a", "latte"], "行数与词序必须是句子原本的那一串")
        XCTAssertNil(rows[0].level, "没量到的词不许补一个档位 —— 那是把「没量到」谎报成「读得刚好」")
        XCTAssertEqual(rows[1].level, .normal)
        XCTAssertEqual(rows[2].level, .reduced)
        XCTAssertEqual(rows[3].level, .stressed, "游标要一路走到最后，不能因为前面缺一个就整体错位")
    }

    /// 同一个词在句子里出现两次，而**只剩后一个量到了**：
    /// 按「词名查表」会把两个都标上档位（前面那个根本没量到），
    /// 按「顺序子集」对才只标后一个 —— 这就是「重音标错词」的真实形态。
    ///
    /// ⚠️ 这条不可省：只测「每个词各出现一次」的句子时，按名字查与按位次对**结果完全一样**，
    /// 那条判据是个假闸，撤掉正确实现也照样绿。
    func testRepeatedWordAlignsByPositionNotByName() {
        let rows = analysis(
            words: ["it", "is", "it"],
            stress: [mark("is", .normal), mark("it", .reduced)]
        ).rows

        XCTAssertEqual(rows.map(\.level), [nil, .normal, .reduced],
                       "前面那个 it 没量到 → nil；只有末尾那个 it 该带档位")
    }

    /// 中间那个词静音（而不是开头）：同样只留 nil，后面照旧对得上。
    func testSilentWordInTheMiddleKeepsTheRestAligned() {
        let rows = analysis(
            words: ["pick", "it", "up"],
            stress: [mark("pick", .stressed), mark("up", .normal)]
        ).rows

        XCTAssertEqual(rows.map(\.level), [.stressed, nil, .normal])
    }

    // MARK: - ② 连读挂在正确的那一对之间

    func testLinkIsAttachedToTheEarlierWordOnly() {
        let rows = analysis(
            words: ["pick", "it", "up"],
            stress: [],
            linking: [
                LinkingSpan(firstWord: "pick", secondWord: "it", gap: 0.01, didLink: true),
                LinkingSpan(firstWord: "it", secondWord: "up", gap: 0.30, didLink: false),
            ]
        ).rows

        XCTAssertEqual(rows[0].linkAfter?.secondWord, "it", "连读标在**前一个词**上，才不会换行时孤立掉")
        XCTAssertEqual(rows[1].linkAfter?.secondWord, "up")
        XCTAssertNil(rows[2].linkAfter, "最后一个词后面没有连读")
        XCTAssertTrue(rows[0].linkAfter?.didLink == true)
        XCTAssertFalse(rows[1].linkAfter?.didLink == true, "没连上的那一处也要标出来（只提示，不扣分）")
    }

    /// 相邻却**不该**连读的一对（都是辅音开头之类）不许出现标记。
    func testNoPhantomLinkBetweenNonLinkingWords() {
        let rows = analysis(
            words: ["I", "want", "to"],
            stress: [],
            linking: [LinkingSpan(firstWord: "want", secondWord: "zebra", gap: 0.01, didLink: true)]
        ).rows

        XCTAssertTrue(rows.allSatisfy { $0.linkAfter == nil },
                      "词对不在句子里相邻 → 不许画连读（查表按相邻词对，不是按词名）")
    }

    // MARK: - ③ 退化路径

    /// 老数据 / 只有重音的那份：`words` 为空时退回 `stress` 的词序，至少还能画重音。
    func testFallsBackToStressWordsWhenSequenceIsMissing() {
        let rows = analysis(
            words: [],
            stress: [mark("want", .normal), mark("a", .reduced), mark("latte", .stressed)]
        ).rows

        XCTAssertEqual(rows.map(\.word), ["want", "a", "latte"])
        XCTAssertEqual(rows.map(\.level), [.normal, .reduced, .stressed])
    }

    func testEmptyAnalysisHasNoRows() {
        XCTAssertTrue(ProsodyAnalysis().rows.isEmpty)
    }

    // MARK: - ④ 读屏口径

    func testAccessibilitySaysLevelAndLinking() {
        let rows = analysis(
            words: ["pick", "it"],
            stress: [mark("pick", .stressed), mark("it", .reduced)],
            linking: [LinkingSpan(firstWord: "pick", secondWord: "it", gap: 0.01, didLink: true)]
        ).rows

        XCTAssertEqual(rows[0].accessibilityLabel, "pick，重读，与后一个词连读")
        XCTAssertEqual(rows[1].accessibilityLabel, "it，弱读")
    }

    /// 没量到的词在读屏里也要说得出来（「未量到」不是沉默）。
    func testAccessibilityMentionsUnmeasuredWords() {
        let rows = analysis(words: ["I"], stress: []).rows
        XCTAssertEqual(rows[0].accessibilityLabel, "I", "没有档位就不编，读屏只报词本身")
    }
}
