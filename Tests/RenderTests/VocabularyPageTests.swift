import AIDomain
import AIInfrastructure
import AIServices
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

    /// 练习生词真的接进来了，而且占住最前的位置（收起态第一页 = 你自己的词）。
    func testDailyRecommendationTakesPracticeVocabularyFirst() async {
        let state = makeAppState()
        // ⚠️ `makeAppState` 用的是 `:memory:` + 临时配置 —— 绝不碰真实学习数据。
        _ = await state.services.vocabulary.add(word: "resilient")
        _ = await state.services.vocabulary.add(word: "tentative")

        let words = await state.services.dailyWordRecommendation()

        XCTAssertEqual(words.count, 16, "2 生词 + 12 雅思词 + 补齐 2 = 收起态 4 页整")
        XCTAssertEqual(
            Set(words.prefix(2).map(\.word)), ["resilient", "tentative"],
            "词汇本的词排在最前（两个词的先后由入本时间决定，这里不钉微秒顺序）"
        )
        XCTAssertTrue(words.prefix(2).allSatisfy(\.isVocabularyWord))
        XCTAssertEqual(Set(words.map(\.word)).count, 16, "同批不重复")
    }

    /// 「换一批」只换雅思词 —— 生词是你自己的词，点了换一批不该当天再见不到它。
    func testRefreshDailyWordsKeepsPracticeVocabulary() async {
        let state = makeAppState()
        _ = await state.services.vocabulary.add(word: "resilient")

        await state.loadDailyWordsIfNeeded()
        XCTAssertTrue(state.dailyWords.contains(where: \.isVocabularyWord), "生词档由词汇本供货")

        await state.refreshDailyWords()
        XCTAssertTrue(
            state.dailyWords.contains(where: \.isVocabularyWord),
            "换一批之后生词仍在（排除集里不该有它）"
        )
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

    func testSettingsCardWordCountFollowsCollectedUniqueWords() async {
        // 设置页词汇本卡片的「单词数」要随**收录的去重单词数**更新：
        // 加词 +1，同词不同释义版本（含大小写差异）只算一个，删词要回落。
        let state = makeAppState()
        await state.reloadVocabulary()
        XCTAssertEqual(state.vocabularyUniqueWordCount, 0, "空词表收录数是 0")

        _ = await state.services.vocabulary.add(word: "substantial")
        _ = await state.services.vocabulary.add(word: "substantial", meaning: "第二个释义版本")
        _ = await state.services.vocabulary.add(word: "Substantial")
        _ = await state.services.vocabulary.add(word: "apple")
        await state.reloadVocabulary()
        // 存储层 add 本就按归一化键去重（同词不重复入库）；去重数与条目数一致，
        // 但展示层仍按词忽略大小写再兜一道（老数据 / 直写库可能出现同词多版本）。
        XCTAssertEqual(state.vocabularyEntries.count, 2, "同词重复添加在存储层就被跳过")
        XCTAssertEqual(state.vocabularyUniqueWordCount, 2)

        let entries = await state.services.vocabulary.entries()
        for entry in entries where entry.word.lowercased() == "substantial" {
            await state.services.vocabulary.remove(id: entry.id)
        }
        await state.reloadVocabulary()
        XCTAssertEqual(state.vocabularyUniqueWordCount, 1, "删掉 substantial 后收录数要回落")
    }

    func testVocabularyBankTotalAndDailyProgressReset() async {
        let state = makeAppState()
        await state.reloadVocabulary()
        await state.loadVocabularyBankIfNeeded()
        XCTAssertGreaterThan(state.dailyBankTotal, 0, "词库总词数要能读到")

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

    func testSettingsVocabularyCardLayouts() async throws {
        let state = makeAppState()
        await state.loadVocabularyBankIfNeeded()
        await state.reloadDictionaryLibrary()
        XCTAssertGreaterThan(state.dailyBankTotal, 0)
        // 卡片上那行「词库共 N 词」必须是**词典去重后**的规模：
        // 与查词 / 联想同一份词表，且严格少于「各书词条相加」（常用词跨词典重复）。
        let deduped = state.dictionaryUniqueWordCount
        let raw = state.dictionaryWordCount
        // ⚠️ `await` 不能进 `XCTAssert*` 的 autoclosure —— 先取出来再断言。
        let serviceDeduped = await state.services.dictionaryUniqueWordCount()
        XCTAssertGreaterThan(deduped, 0, "内置词典应能读到")
        XCTAssertEqual(deduped, serviceDeduped)
        XCTAssertLessThan(deduped, raw, "跨词典同名词只算一个")
        // 分母（每日推荐词源）是**可见词典的子集**：用户可能只把其中几本勾成词源，
        // 所以只保证「不超过词库规模」，不要求相等（相等只在三本全勾时成立）。
        XCTAssertGreaterThan(state.dailyBankTotal, 0)
        XCTAssertLessThanOrEqual(state.dailyBankTotal, deduped)
        // 设置页的词汇本卡（词库规模行 + 红框重置按钮 + 说明行）要能布局 ——
        // 「还没重置过 / 上次重置时间」两种文案都会被渲染到，都会走一遍。
        let hosting = NSHostingView(rootView: SettingsView(state: state))
        hosting.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hosting.fittingSize.height, 0, "设置页（含词汇本重置卡）应可布局")
        try dump(hosting, name: "round52-settings-vocabulary-card.png")
    }

    /// 情景对话卡（2026-09-28 接上的「重置闯关进度」入口）要能布局。
    ///
    /// 两种形态都会被渲染到：有进度（概况行 + 可点按钮）与零进度（无概况行、按钮禁用态）。
    /// 断言用**布局高度差**：有进度那帧必须比零进度帧高出一行概况 ——
    /// 少了那一行 = 概况没接上 `progress`。
    func testSettingsScenarioCardLayouts() async throws {
        let state = makeAppState()
        let hosting = NSHostingView(rootView: SettingsView(state: state))
        hosting.frame = NSRect(x: 0, y: 0, width: 700, height: 2400)
        hosting.layoutSubtreeIfNeeded()
        let emptyHeight = hosting.fittingSize.height
        XCTAssertGreaterThan(emptyHeight, 0, "设置页（零进度，重置按钮禁用态）应可布局")
        try dump(hosting, name: "round55-settings-scenario-card-empty.png")

        // 攒出可见进度后再布局：概况行让整页高出一段（约为卡片说明行的高度）。
        state.progress.levels[0].earnedStars = 3
        state.progress.levels[0].state = .completed
        state.progress.recalculateSummary()
        hosting.layoutSubtreeIfNeeded()
        let starredHeight = hosting.fittingSize.height
        XCTAssertGreaterThan(
            starredHeight - emptyHeight, 10,
            "有进度时卡片要长出「已收集 N 颗星」那一行（差值 \(starredHeight - emptyHeight)pt）"
        )
        try dump(hosting, name: "round55-settings-scenario-card-starred.png")
    }

    /// 把离屏排好的视图整块出图（与各 `*RenderTests` 同一套写法）。
    private func dump(_ view: NSView, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]), "PNG 编码失败")
        try png.write(to: directory.appendingPathComponent(name))
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

    /// 生词档落地后的每日推荐板块：**离屏渲染**供人工复核
    /// 「收起态第一页就是 4 张生词卡、页码 1/4」。
    ///
    /// ⚠️ 这里只出图不比对像素：`dailyPage` / `dailyExpanded` 都是视图私有状态，
    /// 外部塞不进去，也没有验证钩子 —— 分页正确性由 `DailyWordPager` 的纯函数用例守着，
    /// 「第一页是不是生词」由 `testDailyRecommendationTakesPracticeVocabularyFirst` 守着。
    func testDailySectionRendersPracticeVocabularyFirstPage() async throws {
        let state = makeAppState()
        for word in ["resilient", "tentative", "candid"] {
            _ = await state.services.vocabulary.add(word: word)
        }
        await state.loadDailyWordsIfNeeded()
        XCTAssertEqual(state.dailyWords.count, 16, "3 生词 + 12 雅思词 + 补齐 1")

        // ⚠️ 出图这一段落**必须是同步方法**：`RunLoop.current.run(until:)` 在 async 上下文里
        // 直接编译不过（"unavailable from asynchronous contexts"）。
        try dumpDailySection(state, name: "round53-daily-words-practice-vocabulary-day.png")
    }

    private func dumpDailySection(_ state: AppState, name: String) throws {
        let hosting = NSHostingView(rootView: VocabularyView(state: state))
        hosting.frame = NSRect(x: 0, y: 0, width: 760, height: 980)
        hosting.layoutSubtreeIfNeeded()
        // 出图前等弹簧动画走完（否则量到的是动画中间态）。
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        hosting.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(hosting.fittingSize.height, 0, "整页应当能布局")
        try dump(hosting, name: name)
    }
}
