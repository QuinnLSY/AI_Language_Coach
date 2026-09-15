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
        makeAppState(databasePath: ":memory:")
    }

    /// 指定库文件的 AppState：需要「另一个连接直接写库」时用（见 ⑦ 的释义同步那条）。
    private func makeAppState(databasePath: String) -> AppState {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("vocab-review-probe-\(UUID().uuidString).json")
        )
        return AppState(services: CoachServices(config: store, databasePath: databasePath))
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
    ///
    /// ⚠️ 页面级的**逐像素比较**必须先钉住页面自己会异步改的那份数据
    /// （词汇页的 `.task` 会去加载每日推荐，加载前后整页差 20% 的像素）。
    /// 见 ⑦ 的退出复习那条。
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

    // MARK: - ⑦ 没有释义就地查 + 退出复习（用户实测提的两条）

    /// 只有 coffee 一个词、且**没有释义**。
    private func bareSession() -> VocabularyReviewSession {
        VocabularyReviewSession(
            entries: [VocabularyEntry(word: "coffee", meaning: "", mastery: 0)], now: now
        )
    }

    /// 控件单独渲染：底色只铺在控件**外面**（外层 `background`），
    /// 这样墨迹包围盒量到的就是控件自己，而不是整块画布。
    private func renderControl(_ view: AnyView, day: Bool = true) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: day ? .day : .night, systemIsDark: !day)
        let host = NSHostingView(rootView: AnyView(
            view.forestTheme(theme).padding(16).background(theme.surface)
        ))
        let size = CGSize(width: 220, height: 80)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep, size: size)
    }

    /// 墨迹包围盒（点）：以左上角像素为底色基准，统计明显不同的像素。
    ///
    /// ⚠️ 不用 `size(withAttributes:)` 当基准 —— 那是排版推进宽度，与真画出来的墨迹对不上
    /// （本项目已固化过这条教训）。位图可能是 1x 也可能是 2x，所以按画布宽度折算回点。
    private func ink(_ render: Render) throws -> (width: CGFloat, height: CGFloat, pixels: Int) {
        let rep = render.rep
        let background = try XCTUnwrap(rep.colorAt(x: 1, y: 1))
        var minX = rep.pixelsWide, maxX = -1, minY = rep.pixelsHigh, maxY = -1, count = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let delta = abs(color.redComponent - background.redComponent)
                    + abs(color.greenComponent - background.greenComponent)
                    + abs(color.blueComponent - background.blueComponent)
                guard delta > 0.12 else { continue }
                count += 1
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard count > 0 else { return (0, 0, 0) }
        let scale = CGFloat(rep.pixelsWide) / render.size.width
        return (CGFloat(maxX - minX + 1) / scale, CGFloat(maxY - minY + 1) / scale, count)
    }

    /// 「退出复习」必须是一个有分量的胶囊，不是一行 11pt 小灰字。
    ///
    /// 用户实测反馈「进了复习就回不去词表了」—— 原来那里的出口就是一行灰色「结束」，
    /// 挤在进度与剩余数之间，看着不像出口。这条用墨迹尺寸钉住「它现在是个按钮」。
    func testExitButtonIsAPillNotABareLabel() throws {
        let render = try renderControl(AnyView(VocabularyReviewExitButton()))
        let bounds = try ink(render)
        // 按设计推：「退出复习」四个字 11pt 半粗 ≈ 44pt 宽，加箭头与左右各 10pt 内边距 ≈ 74pt；
        // 高度是 11pt 字加上下各 5pt 内边距 ≈ 21pt —— 一行裸标签只有约 8pt 高。
        XCTAssertGreaterThan(bounds.width, 60, "文字 + 箭头 + 内边距必须撑出这个宽度")
        XCTAssertGreaterThan(bounds.height, 16, "胶囊的上下内边距一定比一行小字高")
        try dump(render.rep, name: "round36-review-exit-button.png")
    }

    /// 「查释义」也是一个看得见的控件，而且加载态看得出来（不然用户不知道点了没反应）。
    func testDefineButtonIsAVisibleControl() throws {
        let idle = try renderControl(AnyView(VocabularyReviewDefineButton()))
        let busy = try renderControl(AnyView(VocabularyReviewDefineButton(isDefining: true)))
        let bounds = try ink(idle)
        XCTAssertGreaterThan(bounds.width, 50, "「查释义」三个字加图标与内边距")
        XCTAssertGreaterThan(bounds.height, 13, "胶囊的上下内边距一定比一行小字高")
        XCTAssertGreaterThan(
            diff(busy.rep, idle.rep).count, 20, "「正在查…」与「查释义」必须肉眼可分"
        )
        try dump(idle.rep, name: "round36-review-define-button.png")
    }

    /// 翻面后没有释义 → 就地有「查释义」，不必退出复习。
    func testRevealedCardWithoutDefinitionOffersInlineLookup() throws {
        let session = bareSession()
        let idle = try render(AnyView(VocabularyReviewCard(session: session, revealed: true)), day: true)
        let busy = try render(
            AnyView(VocabularyReviewCard(session: session, revealed: true, isDefining: true)), day: true
        )
        // 差分非零 = 这个控件确实画在卡里（没画的话两版一模一样）。
        XCTAssertGreaterThan(
            diff(busy.rep, idle.rep).count, 20, "翻面里必须真的有「查释义」，并且加载态可见"
        )
        try dump(idle.rep, name: "round36-review-card-without-definition.png")
    }

    /// 反过来：已经有释义的词上不该出现「查释义」。
    /// （若那里也画了，`isDefining` 一开一关就会让画面变样 —— 差分必须是零。）
    func testCardWithDefinitionDrawsNoLookupButton() throws {
        let session = coffeeSession()
        let idle = try render(AnyView(VocabularyReviewCard(session: session, revealed: true)), day: true)
        let busy = try render(
            AnyView(VocabularyReviewCard(session: session, revealed: true, isDefining: true)), day: true
        )
        XCTAssertLessThan(
            diff(busy.rep, idle.rep).count, 5, "已经有释义的词不该再出现「查释义」入口"
        )
    }

    /// 历史数据（只有一整段非结构化释义）**不算**「没有释义」。
    ///
    /// 判错会骗人再花一次模型调用，而且那句「可以回词表点查释义」本身就是假话。
    func testLegacyDefinitionIsNotTreatedAsMissing() throws {
        let legacy = VocabularyEntry(
            word: "coffee", meaning: "咖啡，咖啡豆（早年只存了整段中文，没有音标与例句）", mastery: 0
        )
        let definition = VocabularyDefinitionRule.decodeStored(legacy.meaning)
        XCTAssertTrue(definition.legacyText.isEmpty == false, "这条数据必须真的是老格式，否则没在测它")

        let session = VocabularyReviewSession(entries: [legacy], now: now)
        let idle = try render(AnyView(VocabularyReviewCard(session: session, revealed: true)), day: true)
        let busy = try render(
            AnyView(VocabularyReviewCard(session: session, revealed: true, isDefining: true)), day: true
        )
        XCTAssertLessThan(
            diff(busy.rep, idle.rep).count, 5, "老数据有释义可看，不该出现「还没有释义 / 查释义」"
        )
    }

    /// 退出复习必须**真的回到原来那张词表**：不是回不去，也不是回到一个变了样的页面。
    func testExitReviewReturnsToTheSameWordList() async throws {
        let state = makeAppState()
        _ = await state.services.vocabulary.add(
            word: "coffee", meaning: definition("/ˈkɒfi/", pos: "n.", senses: "咖啡")
        )
        await state.reloadVocabulary()
        // ⚠️ 先钉住每日推荐：词汇页的 `.task` 会自己去加载它，加载前后整页能差出 20% 的像素 ——
        // 那样比出来的「页面变了」全是噪声，等于没验。加载过一次之后视图那边就是空操作。
        await state.loadDailyWordsIfNeeded()
        XCTAssertFalse(state.dailyWords.isEmpty, "每日推要先备好，下面的逐像素比较才有意义") 

        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let before = try renderPage(state: state, theme: theme)
        // 同一份数据连抓两次的噪声，作为「页面没变」的容许量（实测为 0）。
        let noise = diff(before.rep, try renderPage(state: state, theme: theme).rep).count

        await state.startVocabularyReview()
        XCTAssertNotNil(state.vocabularyReview, "有到期的词就该开起来")
        let during = try renderPage(state: state, theme: theme)
        let switched = diff(during.rep, before.rep).count
        XCTAssertGreaterThan(switched, noise + 50_000, "复习模式必须真的换了样子")

        await state.finishVocabularyReview()
        XCTAssertNil(state.vocabularyReview, "退出复习后必须回到词表模式")
        XCTAssertEqual(state.vocabularyEntries.count, 1, "词表还在，没被复习吃掉")
        let after = try renderPage(state: state, theme: theme)
        let restored = diff(after.rep, before.rep).count
        XCTAssertLessThanOrEqual(
            restored, noise + 200,
            "退出后要回到**同一张**词表（一个词都没判分，页面不该有变化）；实测差分 \(restored)，噪声 \(noise)"
        )
        try dump(after.rep, name: "round36-vocabulary-list-after-exit.png")
    }

    /// 复习途中查到的释义要同时落到两处：**卡上**（翻面立刻可见）与**词表**。
    ///
    /// 走真的库文件：`AppState` 连一个库，测试再用同一个文件开一个连接写释义
    /// （模型那一跳在测试里不跑；`updateVocabularyDefinition` 就是查释义成功后的落库动作）。
    func testDefinitionFoundDuringReviewLandsOnTheCardAndTheList() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocab-review-def-\(UUID().uuidString).db").path
        let state = makeAppState(databasePath: path)
        _ = await state.services.vocabulary.add(word: "coffee")
        await state.reloadVocabulary()
        let entry = try XCTUnwrap(state.vocabularyEntries.first)
        XCTAssertTrue(entry.meaning.isEmpty, "这个词一开始确实没有释义")

        await state.startVocabularyReview()
        state.revealVocabularyReviewCard()
        let beforeSession = try XCTUnwrap(state.vocabularyReview)
        XCTAssertTrue(beforeSession.current?.meaning.isEmpty == true)
        let beforeCard = try render(
            AnyView(VocabularyReviewCard(session: beforeSession, revealed: true)), day: true
        )

        let database = try LearningDatabase(path: path)
        try await database.updateVocabularyDefinition(
            id: entry.id,
            meaning: definition("/ˈkɒfi/", pos: "n.", senses: "咖啡"),
            example: "I would like a cup of coffee, please."
        )
        await state.reloadVocabulary()

        XCTAssertFalse(
            (state.vocabularyEntries.first?.meaning ?? "").isEmpty, "词表必须同步到新释义"
        )
        let afterSession = try XCTUnwrap(state.vocabularyReview)
        XCTAssertFalse(
            (afterSession.current?.meaning ?? "").isEmpty,
            "复习卡上这一张也要同步（队列里是值拷贝，不回填就还是「还没有释义」）"
        )
        XCTAssertEqual(afterSession.reviewed, 0, "同步资料不影响这一轮的进度")
        XCTAssertEqual(afterSession.total, 1, "队列还是这一张，没被重排")
        XCTAssertEqual(state.vocabularyStats.due, 1, "待复习数不该因此变化")

        // 而且翻面真的多出整块释义（不是只在数据里对了、画面上还是空的）。
        let afterCard = try render(
            AnyView(VocabularyReviewCard(session: afterSession, revealed: true)), day: true
        )
        XCTAssertGreaterThan(
            afterCard.size.height, beforeCard.size.height + 40,
            "翻了面就要多出「词性 + 义项 + 解释 + 例句 + 译文 + 近义」一整块"
        )
        try dump(afterCard.rep, name: "round36-review-card-defined-inline.png")
    }

    /// 就地查释义：**要么真查到（词表与卡上同步），要么如实说清为什么没查到**。
    ///
    /// 这一条不假设测试机上有模型在跑 —— 只钉不变式：查到了不许再报错，
    /// 没查到不许静默（静默会让人以为按钮坏了），两种情况下加载态都必须收干净。
    func testInlineLookupEitherDefinesOrSaysWhy() async throws {
        let state = makeAppState()
        _ = await state.services.vocabulary.add(word: "coffee")
        await state.reloadVocabulary()
        await state.startVocabularyReview()
        state.revealVocabularyReviewCard()
        XCTAssertNil(state.vocabularyReviewNotice, "刚开始复习时没有要说的")
        XCTAssertTrue(state.vocabularyReview?.current?.meaning.isEmpty == true)

        await state.defineVocabularyReviewWord()

        let meaning = state.vocabularyReview?.current?.meaning ?? ""
        let notice = state.vocabularyReviewNotice
        if meaning.isEmpty {
            XCTAssertNotNil(notice, "没查到就必须说一声，不能静默（否则用户以为按钮坏了）")
        } else {
            XCTAssertNil(notice, "查到了就不该再报错：\(notice ?? "")")
            XCTAssertEqual(
                state.vocabularyEntries.first?.meaning ?? "", meaning,
                "词表与卡上必须是同一份 —— 这是「查完不用回词表」的全部意义"
            )
        }
        XCTAssertTrue(state.isDefiningVocabulary.isEmpty, "加载态必须收干净（否则按钮永远转圈）")
        XCTAssertEqual(state.vocabularyStats.due, 1, "查释义不该动复习进度")
    }
}
