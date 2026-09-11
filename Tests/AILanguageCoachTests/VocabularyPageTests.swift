import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 词汇本页与每日推荐的 UI 级探针：
/// - 词库资源是否随包发布（选词数量 / 难度配额）；
/// - 词汇本页（含每日推荐板块）能否真实布局；
/// - 译文卡片宽度上限是否随消息区宽度动态推算（与正文气泡一致）。
@MainActor
final class VocabularyPageTests: XCTestCase {

    private func makeAppState() -> AppState {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("vocab-probe-\(UUID().uuidString).json")
        )
        return AppState(services: CoachServices(config: store, databasePath: ":memory:"))
    }

    func testDailyPickUsesBundledBankWithIeltsQuota() async {
        let bank = VocabularyWordBank.load()
        XCTAssertGreaterThanOrEqual(bank.count, 100, "词库资源应随包发布且不少于 100 词")
        let picked = DailyWordPicker.pick(from: bank)
        XCTAssertEqual(picked.count, 10, "每次推荐 10 个词")
        XCTAssertEqual(picked.filter { $0.difficulty == 1 }.count, 3, "3 个简单")
        XCTAssertEqual(picked.filter { $0.difficulty == 2 }.count, 5, "5 个中等")
        XCTAssertEqual(picked.filter { $0.difficulty == 3 }.count, 2, "2 个困难")
    }

    func testVocabularyPageLayoutsDailySectionAndEntries() async {
        let state = makeAppState()
        _ = await state.services.vocabulary.add(word: "a substantial effort")
        await state.loadDailyWordsIfNeeded()
        XCTAssertFalse(state.dailyWords.isEmpty, "每日推荐应该抽到词")

        let hosting = NSHostingView(rootView: VocabularyView(state: state))
        hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 900)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hosting.fittingSize.width, 0)
        XCTAssertGreaterThan(hosting.fittingSize.height, 0, "词汇本页（含每日推荐 + 常驻添加框）应可布局")
    }

    func testTranslationCardWidthRespectsDynamicCap() {
        let long = String(repeating: "这是一句很长的译文，", count: 40)
        // 窄消息区：卡片顶到「净宽 − 100」的上限，与该窗口下正文气泡的最大宽一致。
        let narrow = ChatView.translationCardWidth(for: long, maxWidth: 400)
        XCTAssertEqual(narrow, 400)
        // 宽消息区：同一句可以更宽，不再被旧的 320 硬编码提前折行。
        let wide = ChatView.translationCardWidth(for: long, maxWidth: 700)
        XCTAssertEqual(wide, 700)
        // 短句仍是「文字实际占宽」的小卡片，不会被撑满。
        let short = ChatView.translationCardWidth(for: "好的", maxWidth: 700)
        XCTAssertLessThan(short, 120)
    }
}
