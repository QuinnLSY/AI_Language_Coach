import AIDomain
@testable import AppUI
import XCTest

/// 语音输入阶段与主按钮语义的**真值表**（2026-09-27 报障修复）。
///
/// 报障的核心是一条**缺失的映射**：以前主按钮只有两个分支
/// （`if isRecording { 停止并识别 } else { 开始录音 }`），而「识别中」那一格
/// 落进了 `else` —— 用户按下去，得到的是「重新录一段」。
/// 这张真值表就是用来钉住「识别中 = 放弃这次识别」的。
final class VoiceInputPhaseTests: XCTestCase {

    func testPrimaryActionCoversAllThreePhases() {
        XCTAssertEqual(VoiceInputPhase.idle.primaryAction, .start, "空闲时点主按钮 = 开始录音")
        XCTAssertEqual(VoiceInputPhase.recording.primaryAction, .stopAndTranscribe,
                       "录音中点主按钮 = 停止并识别")
        XCTAssertEqual(VoiceInputPhase.transcribing.primaryAction, .cancelTranscribe,
                       "识别中点主按钮 = 放弃这次识别（不是重开麦克风）")
    }

    /// 三种动作**互不相同**：任何一个塌回另一个，报障就会以另一种形式回来
    /// （识别中退回 `start` = 「想停停不掉，反而重新开始录」）。
    func testPrimaryActionsAreDistinct() {
        let actions = VoiceInputPhase.allCases.map(\.primaryAction)
        XCTAssertEqual(Set(actions).count, VoiceInputPhase.allCases.count)
        XCTAssertEqual(VoiceInputPhase.allCases.count, 3)
    }

    /// 主按钮的文案随阶段走：识别中还说「停止并识别」会误导 ——
    /// 那时麦克风早已关闭，用户以为按下去才停麦，实际是放弃结果。
    func testMicButtonCopyTellsTheTruthInEveryPhase() {
        XCTAssertEqual(ChatView.micButtonHelp(.idle), "点击说话")
        XCTAssertEqual(ChatView.micButtonHelp(.recording), "停止并识别")
        XCTAssertEqual(ChatView.micButtonHelp(.transcribing), "放弃这次识别")

        XCTAssertEqual(ChatView.micButtonAccessibilityLabel(.idle), "语音输入")
        XCTAssertEqual(ChatView.micButtonAccessibilityLabel(.recording), "停止录音并识别")
        XCTAssertEqual(ChatView.micButtonAccessibilityLabel(.transcribing), "放弃这次识别")

        // 三档必须两两不同：塌成一档就等于有一档在说谎。
        for copy in [ChatView.micButtonHelp, ChatView.micButtonAccessibilityLabel] {
            let texts = VoiceInputPhase.allCases.map(copy)
            XCTAssertEqual(Set(texts).count, texts.count, "文案有重复：\(texts)")
        }
    }

    /// 只有录音中才有麦克风在采 —— 「取消录音」这句话只在这个窗口里成立。
    func testOnlyRecordingCountsAsCapturing() {
        XCTAssertTrue(VoiceInputPhase.recording.isCapturing)
        XCTAssertFalse(VoiceInputPhase.idle.isCapturing)
        XCTAssertFalse(VoiceInputPhase.transcribing.isCapturing,
                       "识别时麦克风早就关了，此时不该再说「正在录音」")
    }

    /// 只有识别中算「忙」：主按钮这时要显示进度而不是麦克风图标。
    func testOnlyTranscribingCountsAsBusy() {
        XCTAssertTrue(VoiceInputPhase.transcribing.isBusy)
        XCTAssertFalse(VoiceInputPhase.recording.isBusy,
                       "录音中的反馈是波形在动，不该再叠一个转圈")
        XCTAssertFalse(VoiceInputPhase.idle.isBusy)
    }
}
