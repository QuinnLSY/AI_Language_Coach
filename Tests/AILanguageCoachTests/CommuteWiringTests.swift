import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import XCTest

@testable import AppUI

/// ⑦-D 通勤连播的**接线**：队列来自真素材、起点是当前这句、段落模式不给连播、
/// 教师语音没开时按下去要说一句为什么。
///
/// ⚠️ 播放循环本身跑不起来（要真 TTS），这里只钉**进入循环之前**的那几件事 ——
/// 那段恰恰是最容易「按下去什么都没发生」的地方。
@MainActor
final class CommuteWiringTests: XCTestCase {

    // MARK: - ① 队列来自真素材

    func testPreviewIsBuiltFromTheRealDrills() {
        let state = makeState()
        state.shadowingDrills = Self.drills

        let preview = try? XCTUnwrap(state.commutePreview)
        XCTAssertEqual(preview?.count, Self.drills.count, "队列大小必须是今天素材的真数")
        XCTAssertEqual(preview?.index, 0)
    }

    /// 起点是「练到第几句」，不是永远从头 —— 从第 3 句按连播就该从第 3 句放。
    func testPreviewStartsFromTheCurrentSentence() {
        let state = makeState()
        state.shadowingDrills = Self.drills
        state.shadowingIndex = 2

        XCTAssertEqual(state.commutePreview?.index, 2)
        XCTAssertEqual(state.commutePreview?.progressText, "第 3 / 5 句")
    }

    func testNoDrillsMeansNoQueue() {
        let state = makeState()
        XCTAssertNil(state.commutePreview, "今天没有句子就不该有那张卡")
    }

    /// 段落模式不给连播：段落本身就是一次读完一整段，再叠一层是重复盖楼。
    func testPassageModeHasNoCommute() async {
        let state = makeState()
        state.shadowingDrills = Self.drills
        await state.setShadowingMode(.passage)

        XCTAssertNil(state.commutePreview)
        await state.startCommute()
        XCTAssertFalse(state.isCommuteRunning, "段落模式下 startCommute 必须原地不动")
        XCTAssertNil(state.commuteQueue)
    }

    // MARK: - ② 教师语音没开 → 说一句为什么

    /// 按下去什么都没发生是最坏的结果：要么放，要么说清楚为什么不放。
    func testStartWithoutTeacherVoiceExplains() async {
        let state = makeState()
        state.shadowingDrills = Self.drills

        await state.startCommute()

        XCTAssertFalse(state.isCommuteRunning)
        XCTAssertNotNil(state.shadowingNotice, "教师语音没开时连播必须给出理由，不能默默什么都不做")
    }

    // MARK: - ③ 停止

    func testStopClearsTheRunningFlag() async {
        let state = makeState()
        state.commuteQueue = CommuteQueue.build(drills: Self.drills)
        state.isCommuteRunning = true
        state.commuteToken = UUID()

        await state.stopCommute()

        XCTAssertFalse(state.isCommuteRunning)
        XCTAssertNil(state.commuteToken, "令牌必须作废：循环里那次朗读随后跑完时别再回写状态")
        // ⚠️ 队列**不清**：结束后界面还要显示「停在第几句」，再按开始也从这句接着放。
        XCTAssertNotNil(state.commuteQueue)
    }

    // MARK: - 工装

    private static let drills: [ShadowingDrill] = [
        ShadowingDrill(id: "d1", text: "Hi.", translation: "你好。", topic: "问候", difficulty: 1, focus: ""),
        ShadowingDrill(id: "d2", text: "How are you?", translation: "你好吗？", topic: "问候", difficulty: 1, focus: ""),
        ShadowingDrill(id: "d3", text: "Nice to meet you.", translation: "很高兴认识你。", topic: "问候", difficulty: 2, focus: ""),
        ShadowingDrill(id: "d4", text: "I would like a coffee please.", translation: "我要一杯咖啡。", topic: "点单", difficulty: 2, focus: ""),
        ShadowingDrill(id: "d5", text: "See you tomorrow.", translation: "明天见。", topic: "告别", difficulty: 1, focus: "")
    ]

    private func makeState() -> AppState {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("alc-commute-\(UUID().uuidString).json")
        )
        // ⚠️ 必须 `:memory:`：裸 `CoachServices()` 的库路径是 nil，会落到真实学习库上。
        return AppState(services: CoachServices(config: store, databasePath: ":memory:"))
    }
}
