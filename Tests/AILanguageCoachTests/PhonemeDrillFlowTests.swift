import AIDomain
import AIInfrastructure
import AIServices
import AppCore
@testable import AppUI
import XCTest

/// 顽固音素专项在 AppState 上的接线回归（进阶 ③）。
///
/// Domain 那一层（聚合 / 词表 / 出题）由 `PhonemeDrillTests` 覆盖；这里只管
/// 「点了之后页面会变成什么样」—— 而这一层最容易出的错是**素材换不干净**：
/// 专项顶掉今日句子、退出时又得换回来，两头都能静默留下错的那一批。
@MainActor
final class PhonemeDrillFlowTests: XCTestCase {

    /// ⚠️ 配置一律写临时文件：`ConfigStore(fileURL: nil)` 落在用户的真实配置上，测试不许碰。
    private func makeState() -> AppState {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("phoneme-drill-\(UUID().uuidString).json")
        )
        return AppState(services: CoachServices(config: store, databasePath: ":memory:"))
    }

    private func thWeakness() -> PhonemeWeakness {
        PhonemeWeakness(phoneme: "TH", missCount: 5, sampleCount: 8, averageScore: 0.2)
    }

    func testStartPhonemeDrillReplacesTheMaterial() {
        let state = makeState()

        state.startPhonemeDrill(for: thWeakness())

        XCTAssertTrue(state.isPhonemeDrill, "要标记为专项（页头的来源说明据此另说一句）")
        XCTAssertEqual(state.phonemeDrillFocus, "TH")
        XCTAssertEqual(state.phonemeDrillFocusDisplay, "θ")
        XCTAssertTrue(state.showingShadowing, "要切到跟读页")
        // 2 个词对 × 两边各一句。
        XCTAssertEqual(state.shadowingDrills.map(\.text), ["Think", "Sink", "Three", "Tree"])
        XCTAssertFalse(
            state.shadowingIsDailyGenerated,
            "专项素材不是「今日」的 —— 标成今日会让页头说谎"
        )
    }

    /// 词表里没有对应词对的音素：宁可不动，也不要硬凑一对（凑出来的不是最小对立对）。
    func testPhonemeWithoutPairsDoesNotStartADrill() {
        let state = makeState()
        let noPairs = PhonemeWeakness(phoneme: "HH", missCount: 9, sampleCount: 9, averageScore: 0.1)

        state.startPhonemeDrill(for: noPairs)

        XCTAssertFalse(state.isPhonemeDrill, "没有词对就不该进专项")
        XCTAssertNil(state.phonemeDrillFocus)
        XCTAssertTrue(state.shadowingDrills.isEmpty, "素材也不该被换成空列表")
    }

    /// 退出要把素材换回来。
    ///
    /// ⚠️ 关键在 `exitPhonemeDrill` **先清空再重载**：`loadShadowing` 见素材非空就不加载了，
    /// 不清的话专项那四句会一直留在页面上，看着像「今天的句子只有这四句」。
    func testExitPhonemeDrillClearsTheFlag() async {
        let state = makeState()
        state.startPhonemeDrill(for: thWeakness())
        XCTAssertTrue(state.isPhonemeDrill, "前提：确实进了专项")

        await state.exitPhonemeDrill()

        XCTAssertFalse(state.isPhonemeDrill)
        XCTAssertNil(state.phonemeDrillFocus)
        XCTAssertNotEqual(
            state.shadowingDrills.map(\.text), ["Think", "Sink", "Three", "Tree"],
            "退出后不能再留着专项那几句"
        )
    }

    /// 库里没数据时，名单必须是空 —— 而不是报一批凭空来的音素。
    func testNoHistoryMeansNoWeaknesses() async {
        let state = makeState()

        await state.refreshPhonemeWeaknesses()

        XCTAssertTrue(state.phonemeWeaknesses.isEmpty)
    }
}
