import AIDomain
import XCTest

/// 流式识别结果与输入框内容的合并规则（2026-09-27 报障修复）。
///
/// 这一组里最重要的是 `testUserEditSurvivesFollowingPartials` —— 它就是用户报的那个场景：
/// **录音期间手动改了识别出来的字，后面的推送立刻把改动冲回去**。
final class VoiceTranscriptMergeTests: XCTestCase {

    // MARK: - 基础拼接

    func testMergedKeepsTypedTextAndAppendsSpeech() {
        XCTAssertEqual(VoiceTranscriptMerge.merged(base: "", voice: "hello"), "hello")
        XCTAssertEqual(VoiceTranscriptMerge.merged(base: "I want", voice: "a coffee"), "I want a coffee")
        // 前后已有空白就不重复补空格。
        XCTAssertEqual(VoiceTranscriptMerge.merged(base: "I want ", voice: "a coffee"), "I want a coffee")
        // 识别为空（还没听清）时不动用户已有的内容。
        XCTAssertEqual(VoiceTranscriptMerge.merged(base: "typed only", voice: "  "), "typed only")
    }

    /// 识别结果两边的空白要被吃掉：`"  hello  "` 不该在输入框里留下前导空格。
    func testMergedTrimsSpeechButKeepsTypedTextVerbatim() {
        XCTAssertEqual(VoiceTranscriptMerge.merged(base: "I want", voice: "  a coffee  "), "I want a coffee")
        XCTAssertEqual(VoiceTranscriptMerge.merged(base: "已打好的字 ", voice: "后补的一句"),
                       "已打好的字 后补的一句")
    }

    // MARK: - 增量

    func testIncrementalReturnsOnlyTheNewTail() {
        XCTAssertEqual(VoiceTranscriptMerge.incremental(previous: "How do I", incoming: "How do I ask"), " ask")
        XCTAssertEqual(VoiceTranscriptMerge.incremental(previous: "How", incoming: "How are you"), " are you")
        // 没有新内容 → 增量为空（识别这一轮没听出更多）。
        XCTAssertEqual(VoiceTranscriptMerge.incremental(previous: "How are you", incoming: "How are you"), "")
        // 上一轮为空 = 整句都是新的。
        XCTAssertEqual(VoiceTranscriptMerge.incremental(previous: "", incoming: "hello"), "hello")
    }

    /// ⚠️ 公共前缀停在**词中间**时不能补空格：`"How ar"` → `"How are"` 的增量是 `"e"`，
    /// 补成 `" e"` 会把一个词写成两个。
    func testIncrementalDoesNotSplitAWordInHalf() {
        XCTAssertEqual(VoiceTranscriptMerge.incremental(previous: "How ar", incoming: "How are"), "e")
        XCTAssertEqual(VoiceTranscriptMerge.incremental(previous: "direc", incoming: "direction"), "tion")
    }

    /// 识别把前面的字改了（没有公共前缀）→ 退化成整句，宁可多写也不吞内容。
    func testIncrementalFallsBackToWholeSentenceWhenPrefixDiffers() {
        XCTAssertEqual(VoiceTranscriptMerge.incremental(previous: "How do I", incoming: "What time"), " What time")
    }

    // MARK: - 落到输入框（apply）

    func testApplyReplacesWholeVoiceSegmentWhenUserDidNotTouchIt() {
        // 录音前已打字，第一轮：前缀保留 + 识别结果。
        var outcome = VoiceTranscriptMerge.apply(
            VoiceMergeState(prefix: "I want"), incoming: "a coffee", current: "I want"
        )
        XCTAssertEqual(outcome.text, "I want a coffee")
        XCTAssertFalse(outcome.preservedUserEdit)

        // 第二轮：识别更长 —— **整段替换**，不会变成 "I want a coffee a coffee please"。
        outcome = VoiceTranscriptMerge.apply(
            outcome.state, incoming: "a coffee please", current: outcome.text
        )
        XCTAssertEqual(outcome.text, "I want a coffee please")
    }

    /// **报障场景的回归**：录音期间用户手动改了识别结果，后续推送必须保留他的改动。
    func testUserEditSurvivesFollowingPartials() {
        // ① 第一轮流式结果：识别听成了 "dark"（其实是 "duck"）。
        var outcome = VoiceTranscriptMerge.apply(
            VoiceMergeState(prefix: ""), incoming: "I saw a dark", current: ""
        )
        XCTAssertEqual(outcome.text, "I saw a dark")

        // ② 用户手动把 dark 改成 duck。
        let edited = "I saw a duck"

        // ③ 第三轮推送（识别又听清了后面的词）——以前这一步会整体覆盖成
        //    "I saw a dark in the pond"，用户刚改的 duck 没了。
        outcome = VoiceTranscriptMerge.apply(
            outcome.state, incoming: "I saw a dark in the pond", current: edited
        )
        XCTAssertTrue(outcome.preservedUserEdit, "用户改过就必须走「保留手改」这条路")
        XCTAssertTrue(outcome.text.hasPrefix("I saw a duck"), "用户改的字被冲掉了：\(outcome.text)")
        XCTAssertEqual(outcome.text, "I saw a duck in the pond")

        // ④ 识别再往后长，仍然接着用户那句走。
        outcome = VoiceTranscriptMerge.apply(
            outcome.state, incoming: "I saw a dark in the pond yesterday", current: outcome.text
        )
        XCTAssertEqual(outcome.text, "I saw a duck in the pond yesterday")
    }

    /// 用户把输入框整个清空 = 这一整段推倒重来：旧前缀与旧语音段都不再作数。
    func testClearingInputRestartsTheSegment() {
        let outcome = VoiceTranscriptMerge.apply(
            VoiceMergeState(prefix: "I want to say", lastVoice: "something"),
            incoming: "hello there",
            current: ""
        )
        XCTAssertEqual(outcome.text, "hello there")
        XCTAssertEqual(outcome.state.prefix, "")
    }

    /// 一旦用户动过手，本段就**一直**走「保留 + 追增量」：不能因为下一轮识别变长就
    /// 回头整段覆写 —— 那等于把他的改动第二次冲掉。
    /// （用户改字之后，`prefix + lastVoice` 已经拼不出他眼前的内容，无法再安全地整段替换。）
    func testOnceUserEditedItStaysInPreserveMode() {
        let first = VoiceTranscriptMerge.apply(VoiceMergeState(), incoming: "she go to school", current: "")
        XCTAssertEqual(first.text, "she go to school")
        XCTAssertFalse(first.state.userEdited)

        let edited = "she goes to school"
        let second = VoiceTranscriptMerge.apply(first.state, incoming: "she go to school now", current: edited)
        XCTAssertTrue(second.state.userEdited)
        XCTAssertEqual(second.text, "she goes to school now")

        let third = VoiceTranscriptMerge.apply(second.state, incoming: "she go to school now today",
                                              current: second.text)
        XCTAssertTrue(third.preservedUserEdit)
        XCTAssertEqual(third.text, "she goes to school now today")
    }

    /// **抖动保护**：识别改写句子中段时公共前缀变得很短，照搬增量会把整句再贴一遍，
    /// 在用户已改过的内容后面叠出「…duckee a dark」这种乱码。宁可这一轮不追加。
    func testIncrementalIgnoresRecognitionJitterInTheMiddle() {
        XCTAssertEqual(VoiceTranscriptMerge.incremental(previous: "I saw a dark", incoming: "I see a dark"), "")
        XCTAssertEqual(VoiceTranscriptMerge.incremental(previous: "she go to school", incoming: "she goes to school"), "")
        // 正常往后长的句子不受影响。
        XCTAssertEqual(VoiceTranscriptMerge.incremental(previous: "she go to school", incoming: "she go to school now"), " now")
    }

    /// 识别什么都没听出来时不改动输入框 —— 用户改到一半的内容不能因为一次空推送被清掉。
    func testEmptyIncomingLeavesEditedInputUntouched() {
        let outcome = VoiceTranscriptMerge.apply(
            VoiceMergeState(prefix: "base", lastVoice: "old"), incoming: "   ", current: "base user text"
        )
        XCTAssertEqual(outcome.text, "base user text")
    }
}
