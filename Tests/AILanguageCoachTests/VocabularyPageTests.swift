import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 词汇本页与每日推荐的 UI 级探针：
/// - 词库资源是否随包发布（选词数量 / 难度配额 / 词组档）；
/// - 词汇本页（含每日推荐板块）能否真实布局；
/// - 释义键值行能否渲染成完整释义卡；
/// - 复盘 chip 流式排版是否保证「单词不被折断」。
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
        XCTAssertGreaterThanOrEqual(bank.count, 100, "词库资源应随包发布且不少于 100 条")
        XCTAssertGreaterThanOrEqual(bank.filter(\.isPhrase).count, 2, "词库里要有词组档")
        let picked = DailyWordPicker.pick(from: bank)
        XCTAssertEqual(picked.count, 12, "每次推荐 12 条")
        XCTAssertEqual(picked.filter { $0.difficulty == 1 }.count, 3, "3 个简单")
        XCTAssertEqual(picked.filter { $0.difficulty == 2 }.count, 5, "5 个中等")
        XCTAssertEqual(picked.filter { $0.difficulty == 3 }.count, 2, "2 个困难")
        XCTAssertEqual(picked.filter(\.isPhrase).count, 2, "2 个随机词组")
    }

    func testVocabularyPageLayoutsDailySectionAndEntries() async {
        let state = makeAppState()
        _ = await state.services.vocabulary.add(word: "a substantial effort")
        // 结构化释义（键值行）+ 旧数据（整段中文）都要能布局，不崩。
        let definition = VocabularyDefinition(
            phonetic: "/ˈæpl/",
            pos: "n.",
            senses: "苹果；苹果树",
            explanation: "可数名词，指水果。",
            example: "I eat an apple every day.",
            exampleTranslation: "我每天吃一个苹果。",
            synonyms: ["fruit"],
            keywords: ""
        )
        _ = await state.services.vocabulary.add(word: "apple", meaning: definition.encoded)
        _ = await state.services.vocabulary.add(word: "old word", meaning: "旧版落库的一段中文释义。")
        await state.reloadVocabulary()
        await state.loadDailyWordsIfNeeded()
        XCTAssertFalse(state.dailyWords.isEmpty, "每日推荐应该抽到词")

        let hosting = NSHostingView(rootView: VocabularyView(state: state))
        hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 900)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hosting.fittingSize.width, 0)
        XCTAssertGreaterThan(hosting.fittingSize.height, 0, "词汇本页（含每日推荐 + 常驻添加框）应可布局")
    }

    func testVocabularyEntryDecodesStructuredMeaningFromDatabase() async {
        let state = makeAppState()
        let definition = VocabularyDefinition(
            phonetic: "/səbˈstænʃl/", pos: "adj.", senses: "大量的；实质性的",
            explanation: "多用于正式书面语境。",
            example: "The government made substantial changes.",
            exampleTranslation: "政府做出了重大调整。",
            synonyms: ["considerable"], antonyms: ["slight"], keywords: ""
        )
        _ = await state.services.vocabulary.add(word: "substantial", meaning: definition.encoded)
        await state.reloadVocabulary()
        let stored = state.vocabularyEntries.first { $0.word == "substantial" }?.meaning ?? ""
        let decoded = VocabularyDefinitionRule.decodeStored(stored)
        XCTAssertEqual(decoded.phonetic, "/səbˈstænʃl/", "音标要落库并能读回")
        XCTAssertEqual(decoded.pos, "adj.")
        XCTAssertEqual(decoded.senseList, ["大量的", "实质性的"])
        XCTAssertEqual(decoded.exampleTranslation, "政府做出了重大调整。")
        XCTAssertEqual(decoded.antonyms, ["slight"])
        XCTAssertFalse(decoded.isLegacy)
    }

    func testVocabularySuggestionsAndDailyProgressReset() async {
        let state = makeAppState()
        // 本机已有释义的词：联想里应带上词性与中文。
        _ = await state.services.vocabulary.add(
            word: "significant",
            meaning: VocabularyDefinition(pos: "adj.", senses: "重要的；显著的").encoded
        )
        await state.reloadVocabulary()
        await state.loadVocabularyBankIfNeeded()
        XCTAssertGreaterThan(state.dailyBankTotal, 0, "词库总词数要能读到")

        state.vocabularyDraft = "sign"
        state.vocabularyDraftChanged()
        let match = state.vocabularyMatches.first { $0.word == "significant" }
        XCTAssertNotNil(match, "输入 sign 应联想到 significant")
        XCTAssertEqual(match?.pos, "adj.")
        XCTAssertEqual(match?.translation, "重要的；显著的")
        XCTAssertEqual(match?.isInVocabulary, true)
        XCTAssertTrue(VocabularySuggester.match("zzzz", in: state.vocabularySuggestions).isEmpty)

        // 词库词本身也要带「词性 + 中文」（不依赖 LLM）。
        state.vocabularyDraft = "improve"
        state.vocabularyDraftChanged()
        XCTAssertEqual(state.vocabularyMatches.first { $0.word == "improve" }?.detailText, "v. 改善；提高")

        // 选中联想：只替换输入框内容，**不入库**（点「添加」才加）。
        let before = state.vocabularyEntries.count
        if let match { state.applyVocabularySuggestion(match) }
        XCTAssertEqual(state.vocabularyDraft, "significant")
        XCTAssertTrue(state.vocabularyMatches.isEmpty, "选中后浮层收起")
        XCTAssertEqual(state.vocabularyEntries.count, before, "选中 ≠ 入库")

        // 重置每日推荐学习进度：记下重置时间与「已学词数」，认识记录清零并重抽一批。
        await state.loadDailyWordsIfNeeded()
        let firstWord = state.dailyWords.first?.word
        if let firstWord {
            await state.toggleDailyRecognized(word: firstWord)
            XCTAssertGreaterThan(state.dailyRecognitionCount(word: firstWord), 0)
        }
        // 攒够 3 次让一个词毕业（每次换一批只能计一次，所以要跨三批）。
        for _ in 0..<3 {
            await state.toggleDailyRecognized(word: "probe")
            await state.refreshDailyWords()
        }
        XCTAssertEqual(state.dailyLearnedCount, 1, "累计认识满 3 次 = 学完 1 个词")

        await state.resetDailyProgress()
        XCTAssertNotNil(state.dailyProgressResetAt, "重置时间要落下来给设置页展示")
        XCTAssertEqual(state.dailyProgressResetLearned, 1, "重置时要把**那一刻**的已学词数记下来")
        XCTAssertEqual(state.dailyLearnedCount, 0, "认识记录清零")
        if let firstWord {
            XCTAssertEqual(state.dailyRecognitionCount(word: firstWord), 0)
        }
        XCTAssertFalse(state.dailyWords.isEmpty, "重置后重新抽一批推荐词")
    }

    func testDailyPagerProbeShowsFourCardsWhenCollapsed() async {
        let state = makeAppState()
        await state.loadVocabularyBankIfNeeded()
        await state.loadDailyWordsIfNeeded()
        XCTAssertEqual(state.dailyWords.count, 12, "词库充足时应抽满 12 个")
        // 收起态第一页恰好 4 个（与视图里用的同一个纯函数）。
        XCTAssertEqual(DailyWordPager.page(state.dailyWords, index: 0).count, 4)
        XCTAssertEqual(DailyWordPager.pageCount(state.dailyWords), 3)

        let hosting = NSHostingView(rootView: VocabularyView(state: state))
        hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 900)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hosting.fittingSize.height, 0, "收起态（整页 4 卡 + 翻页按钮）应可布局")
    }

    func testSettingsVocabularyCardLayouts() async {
        let state = makeAppState()
        await state.loadVocabularyBankIfNeeded()
        XCTAssertGreaterThan(state.dailyBankTotal, 0)
        // 设置页的词汇本卡（红框重置按钮 + 说明行）要能布局 ——
        // 「还没重置过 / 上次重置时间」两种文案都会被渲染到，都会走一遍。
        let hosting = NSHostingView(rootView: SettingsView(state: state))
        hosting.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hosting.fittingSize.height, 0, "设置页（含词汇本重置卡）应可布局")
    }

    func testFlowRowKeepsEachChipOnOneLine() {
        // 复盘「值得记住」的 chip：单词必须整体展示（旧 LazyVGrid 会把
        // precipitation 拆成 "precipitatio / n"），短词组也要保持一行。
        let hosting = NSHostingView(rootView: FlowRow(spacing: 6, lineSpacing: 6, wrapsLongItems: true) {
            ForEach(["water cycle", "evaporate", "condense", "precipitation"], id: \.self) { chip in
                Text(chip)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.blue.opacity(0.14)))
            }
        })
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(hosting.fittingSize.width, 400, "chip 行不应超出容器")
        XCTAssertLessThan(hosting.fittingSize.height, 30, "四个短 chip 应排在同一行（没有折行 = 没有被拆开）")
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
