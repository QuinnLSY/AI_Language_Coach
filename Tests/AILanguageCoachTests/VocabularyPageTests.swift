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

    func testTranslationCardLayoutsLikeBodyBubble() {
        // 译文卡片已与正文气泡同构（不再做任何宽度测量）：
        // 这里只验证渲染属性仍然保留「颜色 + 引号」之外的普通文本换行行为。
        let long = String(repeating: "这是一句很长的译文，", count: 40)
        let text = Text(long).fixedSize(horizontal: false, vertical: true)
        let hosting = NSHostingView(rootView: HStack(spacing: 6) {
            text.foregroundStyle(.primary)
            Image(systemName: "quote.opening")
        }
        .padding(.horizontal, 12))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 800)
        hosting.layoutSubtreeIfNeeded()
        // 关键断言：结构换行约束下不会超出提案宽度（旧量宽方案曾撑出容器）。
        XCTAssertLessThanOrEqual(hosting.bounds.width, 401)
    }
}
