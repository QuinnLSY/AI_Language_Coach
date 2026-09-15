import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 词汇复习卡（P1-3 复习闭环）的**离屏渲染**回归。
///
/// 与同目录另几支渲染测试同款理由：验证环境熄屏，一律离屏出图；断言只钉
/// 「用户真能看见」这件事 —— 高度变化 + 逐像素差分，不钉具体色值
/// （离屏过一次色彩空间换算，绝对色值本来也不可靠）。
///
/// 四条断言各自对应一条产品口径：
/// ① 翻面后释义真的多占一块；② 朗读后音素明细真的长出来；
/// ③ 「规则推断」与「声学实测」长得不一样（不能把推断说成实测）；
/// ④ 结算里的「忘了的词今天仍到期」那句话真的会出现 —— 那是用户最容易误会的点。
@MainActor
final class VocabularyReviewRenderTests: XCTestCase {

    private var window: NSWindow?
    private let cardWidth: CGFloat = 620

    private let now = Date(timeIntervalSince1970: 1_789_000_000)

    // MARK: - 造数据

    private func definition(_ phonetic: String, pos: String, senses: String) -> String {
        VocabularyDefinition(
            phonetic: phonetic,
            pos: pos,
            senses: senses,
            explanation: "日常口语高频词，注意重音在第一个音节。",
            example: "I would like a cup of coffee, please.",
            exampleTranslation: "我想要一杯咖啡，谢谢。",
            synonyms: ["espresso (n.) 浓缩咖啡"],
            antonyms: [],
            keywords: ""
        ).encoded
    }

    private func entries() -> [VocabularyEntry] {
        [
            VocabularyEntry(
                word: "coffee", meaning: definition("/ˈkɒfi/", pos: "n.", senses: "咖啡；咖啡豆"),
                mastery: 1, reviewCount: 2, lastReviewedAt: now.addingTimeInterval(-2 * 86_400)
            ),
            VocabularyEntry(
                word: "sustainable", meaning: definition("/səˈsteɪnəbl/", pos: "adj.", senses: "可持续的"),
                mastery: 0
            ),
            VocabularyEntry(
                word: "book a table", meaning: definition("", pos: "phrase", senses: "订位；预订餐桌"),
                mastery: 0
            )
        ]
    }

    /// 只含 coffee 一个词的一轮 —— 让当前卡就是 coffee，
    /// 这样下面那些「coffee 的朗读报告」和卡上的词对得上（否则出图会显示成
    /// 「book a table 的发音是 coffee」，图就不像真的了）。
    private func coffeeSession() -> VocabularyReviewSession {
        VocabularyReviewSession(entries: [entries()[0]], now: now)
    }

    /// 造一段「像人说话」的波形（与 P0-2 的音素条渲染测试同一套手法）：
    /// 让 `SpeechAnalyzer` 有语速 / 停顿 / 音高可量，报告才像真实那一次。
    private func syntheticMetrics(seconds: Double = 1.6) -> SpeechMetrics {
        let sampleRate = 16_000.0
        let count = Int(seconds * sampleRate)
        var samples: [Float] = []
        samples.reserveCapacity(count)
        for index in 0..<count {
            let t = Double(index) / sampleRate
            let local = t.truncatingRemainder(dividingBy: 0.4)
            let envelope = sin(.pi * local / 0.4)
            let f0 = 130.0 + 20.0 * sin(2 * .pi * 0.3 * t)
            samples.append(Float(0.6 * envelope * sin(2 * .pi * f0 * t)))
        }
        return SpeechAnalyzer.analyze(samples: samples, sampleRate: sampleRate)
    }

    private func makeReport(
        word: String,
        recognized: String,
        source: PhonemeSource = .inference,
        withPhonemes: Bool = true
    ) -> PronunciationReport {
        let words = withPhonemes
            ? PhonemeAssessment.assess(
                reference: word, recognized: recognized, lexicon: PhonemeLexiconStore.shared()
            )
            : []
        return PronunciationScorer.report(
            reference: word,
            recognized: recognized,
            metrics: syntheticMetrics(),
            phonemeWords: words,
            phonemeSource: words.isEmpty ? .none : source
        )
    }

    // MARK: - 离屏渲染

    private struct Render {
        var rep: NSBitmapImageRep
        var size: CGSize
    }

    private func render(_ view: AnyView, day: Bool, width: CGFloat? = nil) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: day ? .day : .night, systemIsDark: !day)
        let backdrop: Color = day ? Color(hex: 0xE9EFE4) : Color(hex: 0x101B2E)
        let target = width ?? cardWidth
        let host = NSHostingView(rootView: AnyView(
            view.forestTheme(theme).frame(width: target).background(backdrop)
        ))
        host.frame = NSRect(x: 0, y: 0, width: target, height: 200)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        // 两趟：先问出自然高度，再按自然高度出图，避免把内容裁掉。
        let size = CGSize(width: target, height: max(80, ceil(host.fittingSize.height)))
        host.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep, size: size)
    }

    /// 与基准图的逐像素差异（只统计真的变了的像素）与变化像素个数。
    ///
    /// ⚠️ 用**差分**而不是绝对色值：两版里相同的标题、按钮、进度点一相减就没了，
    /// 也就不必猜位图坐标原点、更不会把琥珀色标题算成「内容变了」。
    private func diff(_ rep: NSBitmapImageRep, _ baseline: NSBitmapImageRep) -> (mean: Double, count: Int) {
        let width = min(rep.pixelsWide, baseline.pixelsWide)
        let height = min(rep.pixelsHigh, baseline.pixelsHigh)
        var sum = 0.0
        var count = 0
        for x in 0..<width {
            for y in 0..<height {
                guard let a = rep.colorAt(x: x, y: y), let b = baseline.colorAt(x: x, y: y) else { continue }
                let delta = abs(a.redComponent - b.redComponent)
                    + abs(a.greenComponent - b.greenComponent)
                    + abs(a.blueComponent - b.blueComponent)
                guard delta > 0.12 else { continue }
                sum += delta
                count += 1
            }
        }
        return (count == 0 ? 0 : sum / Double(count), count)
    }

    private func luma(_ rep: NSBitmapImageRep) throws -> CGFloat {
        let color = try XCTUnwrap(rep.colorAt(x: 2, y: 2))
        return color.redComponent * 0.3 + color.greenComponent * 0.6 + color.blueComponent * 0.1
    }

    private func dump(_ rep: NSBitmapImageRep, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AILanguageCoachTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]), "PNG 编码失败")
        try png.write(to: directory.appendingPathComponent(name))
    }

    // MARK: - ① 正面 / 翻面

    /// 正面只给词，翻面才给释义 —— 而且翻面后卡片**真的变高**（释义确实画出来了）。
    func testRevealedCardDrawsTheDefinition() throws {
        let session = VocabularyReviewSession(entries: entries(), now: now)
        let front = try render(AnyView(VocabularyReviewCard(session: session)), day: true)
        let back = try render(
            AnyView(VocabularyReviewCard(session: session, revealed: true)), day: true
        )

        XCTAssertGreaterThan(
            back.size.height, front.size.height + 40,
            "翻面后要多出「词性 + 义项 + 解释 + 例句 + 译文 + 近义」一整块，高度必须明显增加"
        )
        let changes = diff(back.rep, front.rep)
        XCTAssertGreaterThan(changes.count, 2_000, "两版之间应有大量像素变化（真的画了释义）")
    }

    // MARK: - ② 朗读后音素明细真的长出来（P0-2 复用）

    func testSpokenReportGrowsThePhonemeStrip() throws {
        let session = coffeeSession()
        let withoutReport = try render(AnyView(VocabularyReviewCard(session: session, revealed: true)), day: true)

        // 故意读串了词：coffee 被系统听成 copy → 音素条才有红有绿，不是一条全绿。
        let report = makeReport(word: "coffee", recognized: "copy")
        XCTAssertTrue(report.hasPhonemeBreakdown, "端到端必须拿到逐词音素明细")
        let withReport = try render(
            AnyView(
                VocabularyReviewCard(
                    session: session, revealed: true, report: report, recognized: "copy"
                )
            ),
            day: true
        )

        XCTAssertGreaterThan(
            withReport.size.height, withoutReport.size.height + 50,
            "朗读结果要比「只有释义」多出：分数行 + 系统听成 + 音素明细条"
        )
        XCTAssertGreaterThan(
            diff(withReport.rep, withoutReport.rep).count, 3_000,
            "朗读那一块必须真的画出东西来"
        )
    }

    /// 没拿到录音的报告（音素为空）不该硬画一条空明细。
    func testReportWithoutPhonemesDoesNotDrawTheStrip() throws {
        let session = coffeeSession()
        let bare = makeReport(word: "coffee", recognized: "copy", withPhonemes: false)
        XCTAssertFalse(bare.hasPhonemeBreakdown)

        let withStrip = try render(
            AnyView(VocabularyReviewCard(session: session, report: makeReport(word: "coffee", recognized: "copy"))),
            day: true
        )
        let withoutStrip = try render(
            AnyView(VocabularyReviewCard(session: session, report: bare)), day: true
        )
        XCTAssertGreaterThan(
            withStrip.size.height, withoutStrip.size.height + 30,
            "有音素明细才该多占一块高度"
        )
    }

    // MARK: - ③ 推断 ≠ 实测：两种来源必须长得不一样

    func testInferredAndAcousticSourcesAreLabelledDifferently() throws {
        let session = coffeeSession()
        let inferred = try render(
            AnyView(
                VocabularyReviewCard(
                    session: session,
                    report: makeReport(word: "coffee", recognized: "coffee", source: .inference)
                )
            ),
            day: true
        )
        let acoustic = try render(
            AnyView(
                VocabularyReviewCard(
                    session: session,
                    report: makeReport(word: "coffee", recognized: "coffee", source: .acoustic)
                )
            ),
            day: true
        )

        // 卡片高度一致（同一套结构、同一段文字行数），差异只可能来自来源标注。
        let changes = diff(acoustic.rep, inferred.rep)
        XCTAssertGreaterThan(
            changes.count, 30,
            "「声学实测」与「规则推断」的标注必须肉眼可分 —— 把推断说成实测是撒谎"
        )
    }

    // MARK: - ④ 结算：忘了的词今天仍到期，这句话必须出现

    func testSummaryShowsTheStillDueNoteOnlyWhenSomethingIsStillDue() throws {
        // 甲：整轮都对 → 无事可说，不该多一行。
        var clean = VocabularyReviewSession(entries: entries(), now: now)
        clean.grade(remembered: true, now: now)
        clean.grade(remembered: true, now: now)
        clean.grade(remembered: true, now: now)
        XCTAssertTrue(clean.isFinished)

        // 乙：有一个掌握度归零（忘了 + 原本就是 0）→ 今天仍然到期，必须明说。
        var messy = VocabularyReviewSession(entries: entries(), now: now)
        messy.grade(remembered: false, now: now)
        messy.grade(remembered: true, now: now)
        messy.grade(remembered: true, now: now)
        XCTAssertGreaterThan(messy.summary.stillDue, 0, "这一版必须真的还有到期的词")

        let cleanRender = try render(AnyView(VocabularyReviewCard(session: clean)), day: true)
        let messyRender = try render(AnyView(VocabularyReviewCard(session: messy)), day: true)
        XCTAssertGreaterThan(
            messyRender.size.height, cleanRender.size.height,
            "「忘了的 N 个词今天仍留在待复习里」必须是独立一行，占真实高度"
        )
    }

    // MARK: - ⑤ 日夜两版都能看（并落盘供人眼复核）

    func testRendersInBothThemesAndDumpsPNG() throws {
        let session = coffeeSession()
        let report = makeReport(word: "coffee", recognized: "copy")

        let day = try render(
            AnyView(VocabularyReviewCard(session: session, revealed: true, report: report, recognized: "copy")),
            day: true
        )
        let night = try render(
            AnyView(VocabularyReviewCard(session: session, revealed: true, report: report, recognized: "copy")),
            day: false
        )
        XCTAssertGreaterThan(try luma(day.rep), 0.5, "日间底色应偏亮")
        XCTAssertLessThan(try luma(night.rep), 0.3, "夜间底色应偏暗")

        var graded = VocabularyReviewSession(entries: entries(), now: now)
        graded.grade(remembered: false, pronunciationScore: 62, phonemeSource: .inference, now: now)
        graded.grade(remembered: true, now: now)
        let summary = try render(AnyView(VocabularyReviewCard(session: graded)), day: true)

        try dump(day.rep, name: "round35-vocabulary-review-card-day.png")
        try dump(night.rep, name: "round35-vocabulary-review-card-night.png")
        try dump(summary.rep, name: "round35-vocabulary-review-summary.png")
    }

    // MARK: - ⑥ 端到端：真实数据库 → 服务 → AppState → 页面

    private func makeAppState() -> AppState {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("vocab-review-probe-\(UUID().uuidString).json")
        )
        return AppState(services: CoachServices(config: store, databasePath: ":memory:"))
    }

    /// 走真实链路：入库 → 开一轮 → 判分 → 待复习数真的降下来 → 页面里真的画出复习卡。
    /// 这条比单独渲染组件更重要：组件好看不代表接线通了。
    func testReviewSessionMovesRealDataAndThePageDrawsIt() async throws {
        let state = makeAppState()
        _ = await state.services.vocabulary.add(word: "coffee", meaning: definition("/ˈkɒfi/", pos: "n.", senses: "咖啡"))
        _ = await state.services.vocabulary.add(word: "sustainable", meaning: definition("/səˈsteɪnəbl/", pos: "adj.", senses: "可持续的"))
        await state.reloadVocabulary()
        XCTAssertEqual(state.vocabularyStats.due, 2, "新词当天全部到期")

        // 先按普通词表模式出一次图，作为「切换真的发生了」的基准。
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let listMode = try renderPage(state: state, theme: theme)

        await state.startVocabularyReview()
        let session = try XCTUnwrap(state.vocabularyReview, "有到期的词就必须开起一轮")
        XCTAssertEqual(session.total, 2)
        XCTAssertEqual(session.current?.word.isEmpty, false)

        let reviewMode = try renderPage(state: state, theme: theme)
        XCTAssertGreaterThan(
            diff(reviewMode.rep, listMode.rep).count, 5_000,
            "进入复习模式后页面必须真的换了样子（词表让位给复习卡）"
        )
        try dump(reviewMode.rep, name: "round35-vocabulary-page-review-mode.png")

        while let current = state.vocabularyReview?.current {
            state.revealVocabularyReviewCard()
            XCTAssertTrue(current.word.isEmpty == false)
            await state.gradeVocabularyReviewCard(remembered: true)
        }
        XCTAssertEqual(state.vocabularyReview?.isFinished, true, "走完了就该结算")
        XCTAssertEqual(state.vocabularyStats.due, 0, "全部记住 → 今天不再有到期的词")
        XCTAssertEqual(state.vocabularyStats.mastered, 0, "掌握度 1 还没到「已掌握」")

        let summaryMode = try renderPage(state: state, theme: theme)
        try dump(summaryMode.rep, name: "round35-vocabulary-page-review-summary.png")

        await state.finishVocabularyReview()
        XCTAssertNil(state.vocabularyReview, "结束后回到普通词表模式")
    }

    /// 整页离屏渲染（词汇页是「顶栏 + 滚动区」，自然高度不可靠，所以铺满固定画布）。
    private func renderPage(state: AppState, theme: ForestTheme) throws -> Render {
        let page = NSHostingView(rootView: AnyView(VocabularyView(state: state).forestTheme(theme)))
        page.frame = NSRect(x: 0, y: 0, width: 900, height: 1400)
        let window = NSWindow(
            contentRect: page.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = page
        self.window = window
        page.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        XCTAssertGreaterThan(page.fittingSize.width, 0, "词汇页应能布局")
        let rep = try XCTUnwrap(page.bitmapImageRepForCachingDisplay(in: page.bounds))
        page.cacheDisplay(in: page.bounds, to: rep)
        return Render(rep: rep, size: page.frame.size)
    }

    /// 没有到期的词就不硬开一个空会话（空的进度条只会让人以为坏了）。
    func testStartWithoutDueWordsKeepsTheSessionClosed() async {
        let state = makeAppState()
        _ = await state.services.vocabulary.add(word: "coffee")
        await state.reloadVocabulary()
        let entry = state.vocabularyEntries.first
        await state.gradeVocabulary(id: entry?.id ?? UUID(), remembered: true)
        XCTAssertEqual(state.vocabularyStats.due, 0, "复习过一次后今天不再到期")

        await state.startVocabularyReview()
        XCTAssertNil(state.vocabularyReview, "没有到期的词就不该开一轮")
        XCTAssertNotNil(state.vocabularyNotice, "要如实说明「今天没有到期的词」")
    }
}
