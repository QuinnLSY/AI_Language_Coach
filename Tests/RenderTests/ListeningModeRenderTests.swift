import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import AppKit
import SwiftUI
@testable import AppUI
import XCTest

/// 听力三种形式的**离屏渲染**回归（#308 #309）。
///
/// 这组用例管「用户真的看得见 / 真的看不见什么」。三条最要紧的不变量：
///
/// ① **题型切换条三段都得画出来** —— 用系统 `Picker` / `Menu` 时 macOS 上连 label
///    都不渲染（项目里翻过车），所以这里按**墨迹宽度**量：只有一段时宽度会明显变窄。
/// ② **听句选义在作答之前不给原文** —— 换了原文、画面必须一个像素都不动；
///    作答之后必须动（对照组，证明前一条不是恒真）。
/// ③ **四个选项真的各占一行** —— 选项数变了，卡的高度必须跟着变。
///
/// ⚠️ 不比对绝对色值（离屏渲染过一道色彩空间换算）；一律用**布局差 / 像素差 / 墨迹范围**。
/// ⚠️ 不写 UserDefaults / 配置 / 数据库 —— 本文件只出图，不碰真实数据。
@MainActor
final class ListeningModeRenderTests: XCTestCase {

    private var window: NSWindow?
    private let width: CGFloat = 520

    private struct Render {
        let rep: NSBitmapImageRep
        let size: CGSize
    }

    // MARK: - 造数据

    private func translations(_ count: Int) -> [String] {
        (0..<count).map { "第 \($0) 句的释义" }
    }

    private func question(optionCount: Int = 4, correctIndex: Int = 0) -> MeaningQuestion {
        MeaningQuestion(
            drillID: "d0",
            options: Array(translations(optionCount).enumerated()).map {
                $0.offset == correctIndex ? "能给我一张收据吗" : $0.element
            },
            correctIndex: correctIndex
        )
    }

    private func capture(typed: String, reference: String = "The reservation is confirmed") -> KeywordCapture {
        ListeningKeywordRule.capture(
            drillID: "d0", reference: reference, translation: "预订确认了", typed: typed, playCount: 2
        )
    }

    // MARK: - 出图

    private func theme(day: Bool = true) -> ForestTheme {
        ForestThemeResolver.resolve(mode: day ? .day : .night, systemIsDark: !day)
    }

    private func backdrop(day: Bool = true) -> Color {
        day ? Color(hex: 0xF3F7EF) : Color(hex: 0x101B2E)
    }

    /// 固定宽度 + **按自然高度**出图（内容被裁掉的话断言会假绿）。
    private func render(_ view: some View, day: Bool = true) throws -> Render {
        let host = NSHostingView(rootView: AnyView(
            view.forestTheme(theme(day: day)).frame(width: width).background(backdrop(day: day))
        ))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 200)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        // 两趟：先问出自然高度，再按自然高度出图 —— 只摆一次会把内容裁掉。
        //
        // ⚠️ 下限只能是 1pt，**不能**像卡片那样写 `max(60, …)`：切换条本身只有 28pt 高，
        // 撑到 60pt 之后上下多出来的那两条**是透明的**，而 `colorAt` 会把透明像素读成
        // 纯黑 —— 于是「整幅图都是墨迹」，量出来的宽度永远等于整行。
        let size = CGSize(width: width, height: max(1, ceil(host.fittingSize.height)))
        host.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep, size: size)
    }

    private func renderModeSwitch(_ current: ListeningMode) throws -> Render {
        try render(ListeningModeSwitch(current: current, onSelect: { _ in }))
    }

    private func renderMeaning(
        question: MeaningQuestion,
        selection: Int?,
        reference: String,
        day: Bool = true
    ) throws -> Render {
        try render(
            ListeningMeaningCard(
                index: 0, total: 8, question: question, selection: selection, reference: reference,
                playCount: 1, isPlaying: false, isSlow: false, isLast: false,
                onPlay: {}, onToggleSlow: {}, onChoose: { _ in }, onAdvance: {}, onCancel: {}
            ),
            day: day
        )
    }

    private func renderDrillCard(
        mode: ListeningMode,
        attempt: ListeningAttempt? = nil,
        keyword: KeywordCapture? = nil,
        typed: String = "",
        day: Bool = true
    ) throws -> Render {
        try render(
            ListeningDrillCard(
                mode: mode, index: 0, total: 8, attempt: attempt, keyword: keyword,
                playCount: keyword == nil && attempt == nil ? 0 : 2,
                isPlaying: false, isSlow: false, isLast: false,
                typed: .constant(typed),
                onPlay: {}, onToggleSlow: {}, onSubmit: {}, onAdvance: {}, onCancel: {}
            ),
            day: day
        )
    }

    private func makeState() -> AppState {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("listening-render-\(UUID().uuidString)", isDirectory: true)
        let dictionaryBase = directory.appendingPathComponent("dict", isDirectory: true)
        return AppState(services: CoachServices(
            config: ConfigStore(fileURL: directory.appendingPathComponent("config.json")),
            databasePath: ":memory:",
            dictionaryStore: DictionaryBookStore(
                fileURL: dictionaryBase.appendingPathComponent("dictionaries.json"),
                booksDirectory: dictionaryBase.appendingPathComponent("books", isDirectory: true)
            )
        ))
    }

    // MARK: - 像素度量

    /// 外框那几圈不算内容：离屏那张图的上下会多出**一圈近白边**
    /// （宿主视图比它里面那块背景高），量墨迹时要跳过。
    private static let edgeInset = 4

    /// 墨迹 = 与背景**亮度**明显不同的**不透明**像素。
    ///
    /// ⚠️ 两条都踩过，别再合并回去：
    /// ① 不能用「与背景的色差」判 —— 那圈近白边与浅色背景的色差只有 0.14 上下，
    ///    门槛压到 0.12 它就进来了、压到 0.25 连浅灰的次要文字也一起漏掉。改按亮度 + 明暗方向。
    /// ② **透明像素必须先排除**：`colorAt` 把 alpha=0 读成纯黑，亮度 0 必然判成墨迹。
    ///    实测走过这条路：切换条只画了一段，`inkSpanX` 仍量出满行宽，
    ///    「三段并排」这条于是永远过不了、也永远不会红（假绿）。
    private func isInk(_ pixel: NSColor, backdropIsLight: Bool) -> Bool {
        guard pixel.alphaComponent > 0.5 else { return false }
        let luminance = 0.299 * pixel.redComponent
            + 0.587 * pixel.greenComponent
            + 0.114 * pixel.blueComponent
        return backdropIsLight ? luminance < 0.72 : luminance > 0.45
    }

    private func backdropIsLight(_ rep: NSBitmapImageRep) -> Bool {
        guard let corner = rep.colorAt(x: Self.edgeInset, y: Self.edgeInset) else { return true }
        let luminance = 0.299 * corner.redComponent
            + 0.587 * corner.greenComponent
            + 0.114 * corner.blueComponent
        return luminance > 0.5
    }

    /// 逐像素差（两张图之间）。⚠️ 只看有没有变，不看变成什么，所以不受色彩空间换算影响。
    private func differingPixels(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Int {
        guard lhs.pixelsWide == rhs.pixelsWide, lhs.pixelsHigh == rhs.pixelsHigh else {
            return Int.max
        }
        var count = 0
        for x in 0..<lhs.pixelsWide {
            for y in 0..<lhs.pixelsHigh {
                guard let a = lhs.colorAt(x: x, y: y), let b = rhs.colorAt(x: x, y: y) else { continue }
                let delta = abs(a.redComponent - b.redComponent)
                    + abs(a.greenComponent - b.greenComponent)
                    + abs(a.blueComponent - b.blueComponent)
                if delta > 0.12 { count += 1 }
            }
        }
        return count
    }

    /// 墨迹在横向上的**范围**（用来量「三段并排到底有多宽」）。
    private func inkSpanX(_ rep: NSBitmapImageRep) -> ClosedRange<Int>? {
        let backdropIsLight = backdropIsLight(rep)
        var low: Int?
        var high: Int?
        for x in Self.edgeInset..<(rep.pixelsWide - Self.edgeInset) {
            for y in Self.edgeInset..<(rep.pixelsHigh - Self.edgeInset) {
                guard let pixel = rep.colorAt(x: x, y: y) else { continue }
                if isInk(pixel, backdropIsLight: backdropIsLight) {
                    low = min(low ?? x, x)
                    high = max(high ?? x, x)
                    break
                }
            }
        }
        guard let low, let high else { return nil }
        return low...high
    }

    private func inkCount(_ rep: NSBitmapImageRep) -> Int {
        inkCount(rep, in: CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
    }

    /// 某块区域里墨迹（隔点采样）。
    private func inkCount(_ rep: NSBitmapImageRep, in rect: CGRect) -> Int {
        let backdropIsLight = backdropIsLight(rep)
        let minX = max(0, Int(rect.minX))
        let maxX = min(rep.pixelsWide, Int(rect.maxX))
        let minY = max(0, Int(rect.minY))
        let maxY = min(rep.pixelsHigh, Int(rect.maxY))
        var count = 0
        for x in stride(from: minX, to: maxX, by: 2) {
            for y in stride(from: minY, to: maxY, by: 2) {
                guard let pixel = rep.colorAt(x: x, y: y) else { continue }
                if isInk(pixel, backdropIsLight: backdropIsLight) { count += 1 }
            }
        }
        return count
    }

    private func dump(_ rep: NSBitmapImageRep, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // RenderTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]), "PNG 编码失败")
        try png.write(to: directory.appendingPathComponent(name))
    }

    // MARK: - ① 题型切换条：三段都在（不是系统 Picker 那种「只剩一个壳」）

    /// 三个胶囊横向排开 —— 墨迹必须横跨三段的宽度。
    ///
    /// 反证目标：把 `ForEach(ListeningMode.allCases)` 换成只画当前那一段。
    /// 那时墨迹宽度会掉到一百多像素（只剩一个胶囊），这条立刻红。
    func testModeSwitchDrawsAllThreeSegmentsSideBySide() throws {
        let rendered = try renderModeSwitch(.dictation)
        let span = try XCTUnwrap(inkSpanX(rendered.rep), "切换条上一片空白 —— 三段都没画出来")
        let spanPoints = CGFloat(span.count) / (CGFloat(rendered.rep.pixelsWide) / width)
        XCTAssertGreaterThan(
            spanPoints, 240,
            "三段并排的墨迹要横跨两百多点（实测 \(Int(spanPoints))pt）；只有一段时会明显变窄"
        )
        XCTAssertLessThan(spanPoints, width, "不该撑满整行")
    }

    /// 选中的那一段与未选中的**长得不一样**（底色 / 描边 / 字重都换了）。
    func testSelectedModeLooksDifferentFromTheOthers() throws {
        let dictation = try renderModeSwitch(.dictation)
        let keyword = try renderModeSwitch(.keyword)
        let meaning = try renderModeSwitch(.meaning)
        XCTAssertGreaterThan(differingPixels(dictation.rep, keyword.rep), 60, "切换选中项必须看得见")
        XCTAssertGreaterThan(differingPixels(keyword.rep, meaning.rep), 60)
        XCTAssertGreaterThan(differingPixels(dictation.rep, meaning.rep), 60)
    }

    // MARK: - ② 听句选义：作答前不给原文

    /// ⚠️ **本题最要紧的一条**：未作答时，原文对画面没有任何影响。
    ///
    /// 换个说法就是「答题时屏幕上看不到英文原文」—— 这句承诺没法靠读代码守住，
    /// 但可以靠这条断言守住：只要有人在未作答的分支里碰了 `reference`，两张图立刻不一样。
    func testUnansweredMeaningCardIgnoresTheReference() throws {
        let card = question()
        let long = try renderMeaning(
            question: card, selection: nil, reference: "Can I have a receipt for the flight please"
        )
        let other = try renderMeaning(
            question: card, selection: nil, reference: "Totally another sentence entirely"
        )
        XCTAssertEqual(
            differingPixels(long.rep, other.rep), 0,
            "作答之前原文根本不该上屏 —— 换一句原文，画面必须一个像素都不动"
        )
    }

    /// 对照组：作答**之后**原文必须亮出来 —— 否则上一条可能是「反正它什么都不画」而恒真。
    func testAnsweredMeaningCardRevealsTheReference() throws {
        let card = question()
        let answered = try renderMeaning(question: card, selection: card.correctIndex, reference: "Can I have a receipt")
        let unanswered = try renderMeaning(question: card, selection: nil, reference: "Can I have a receipt")
        XCTAssertGreaterThan(
            answered.size.height, unanswered.size.height + 20,
            "判完要停在这一句把原文与「下一句」一起亮出来"
        )

        let another = try renderMeaning(
            question: card, selection: card.correctIndex, reference: "Totally another sentence entirely"
        )
        XCTAssertGreaterThan(
            differingPixels(answered.rep, another.rep), 40,
            "答完之后原文必须真的上屏（换了原文画面就该变）"
        )
    }

    /// 判完的那一屏要能把「选对了」和「选错了」分开画出来。
    ///
    /// 反证目标：`optionRow` 里那段按 `selection` 上色的 tint。去掉它，
    /// 三种状态会是同一张图 → 用户看不出自己选了什么、哪一项才对。
    func testMeaningCardTintsCorrectAndWrongPicksDifferently() throws {
        let card = question(correctIndex: 2)
        let untouched = try renderMeaning(question: card, selection: nil, reference: "line")
        let correct = try renderMeaning(question: card, selection: 2, reference: "line")
        let wrong = try renderMeaning(question: card, selection: 0, reference: "line")

        XCTAssertGreaterThan(differingPixels(untouched.rep, correct.rep), 100, "选对了要看得见")
        XCTAssertGreaterThan(differingPixels(correct.rep, wrong.rep), 100, "选错的那一项与正确项画法不同")
    }

    /// 四个选项**各占一行**：选项数变了，卡的高度必须跟着变。
    func testMeaningCardGrowsWithTheNumberOfOptions() throws {
        let three = try renderMeaning(question: question(optionCount: 3), selection: nil, reference: "line")
        let four = try renderMeaning(question: question(optionCount: 4), selection: nil, reference: "line")
        XCTAssertGreaterThan(
            four.size.height, three.size.height + 20,
            "多一个选项就该多一行 —— 说明每一行都是真的按数据画出来的"
        )
    }

    // MARK: - ③ 关键词捕捉：提交前后是两屏

    /// 提交后多出「抓住了几 / 漏了哪几个 + 原文」那一块。
    func testKeywordFeedbackIsTallerThanTheKeywordPrompt() throws {
        let prompt = try renderDrillCard(mode: .keyword)
        let feedback = try renderDrillCard(mode: .keyword, keyword: capture(typed: "reservation"))
        XCTAssertGreaterThan(
            feedback.size.height, prompt.size.height + 40,
            "对照块（抓住了 1/2 + 漏掉的词 + 原文）必须真的画出来"
        )
    }

    /// 「整句全抓住」与「一个都没抓住」是两屏：颜色、图标、建议都得跟着换。
    ///
    /// 反证目标：`hitColor` / `hitSymbol` 那两处按命中率分档的取色。
    /// 一律用同一种颜色的话，两种结果会长得一模一样 —— 用户只能靠读数字。
    func testKeywordFeedbackDistinguishesFullCaptureFromNone() throws {
        let full = try renderDrillCard(
            mode: .keyword, keyword: capture(typed: "reservation confirmed")
        )
        let none = try renderDrillCard(mode: .keyword, keyword: capture(typed: "的"))
        XCTAssertEqual(full.size.height, none.size.height, "两种结果的版式一样，差别在画法上")
        XCTAssertGreaterThan(
            differingPixels(full.rep, none.rep), 200,
            "全抓住与一个没抓住必须看得出区别（颜色 / 图标 / 建议 / 「没抓住：…」那一行）"
        )
    }

    /// 提交后**必须**把原文亮出来（关键词模式也不是开卷考：只在交完之后给）。
    func testKeywordFeedbackRevealsTheReference() throws {
        let one = try renderDrillCard(
            mode: .keyword,
            keyword: capture(typed: "reservation", reference: "The reservation is confirmed")
        )
        let other = try renderDrillCard(
            mode: .keyword,
            keyword: capture(typed: "reservation", reference: "Where is the boarding gate")
        )
        XCTAssertGreaterThan(
            differingPixels(one.rep, other.rep), 40,
            "交了之后原文要真的上屏（换了原文画面就该变）"
        )
    }

    /// 精听与关键词共用同一张卡，但**说法不同**（标题 / 输入框引导 / 提交按钮都随模式变）。
    func testTheSameCardSpeaksEachModesLanguage() throws {
        let dictation = try renderDrillCard(mode: .dictation)
        let keyword = try renderDrillCard(mode: .keyword)
        XCTAssertGreaterThan(
            differingPixels(dictation.rep, keyword.rep), 60,
            "两种形式的文案不同，卡片不该长得一模一样"
        )
        XCTAssertEqual(dictation.size.height, keyword.size.height, "同一张卡的两种说法，版式是一样的")
    }

    // MARK: - ④ 整页：三种形式都画得出练习卡

    /// 整页渲染（固定视口，与跟读页那组同款做法）。
    private func renderPage(mode: ListeningMode, withMaterial: Bool = true, day: Bool = true) throws -> Render {
        let state = makeState()
        state.shadowingDrills = (0..<12).map {
            ShadowingDrill(id: "d\($0)", text: "line number \($0)", translation: "第 \($0) 句", topic: "测试")
        }
        if withMaterial {
            state.listeningRound = Array(state.shadowingDrills.prefix(6))
            state.listeningIndex = 0
            state.isListeningDrill = true
            state.listeningMode = mode
            if mode == .meaning { state.prepareMeaningQuestion() }
        }
        let host = NSHostingView(rootView: AnyView(
            ListeningView(state: state).forestTheme(theme(day: day))
        ))
        let viewport = CGSize(width: 780, height: 600)
        host.frame = NSRect(origin: .zero, size: viewport)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep, size: viewport)
    }

    /// 三种形式都要把练习卡画出来（不是空白页、也不是「找不到素材」）。
    ///
    /// ⚠️ 只数**卡片那一条带**的墨迹：页头本来就有字，把它算进来，一张空白页也能过。
    func testEveryModeDrawsItsPracticeCard() throws {
        for mode in ListeningMode.allCases {
            let page = try renderPage(mode: mode)
            let scale = CGFloat(page.rep.pixelsWide) / page.size.width
            // 页头 64pt + 切换条 + 卡头；取中段一条带就够看出「卡里有没有字」。
            let band = CGRect(x: 20 * scale, y: 180 * scale, width: 740 * scale, height: 160 * scale)
            let ink = inkCount(page.rep, in: band)
            XCTAssertGreaterThan(ink, 120, "\(mode.title) 这一页没把卡画出来（墨迹 \(ink)）")
        }
    }

    /// 没有素材时给的是**指路**的空态（有字、有按钮），不是一张白纸。
    func testPageWithoutMaterialShowsTheEmptyHint() throws {
        let page = try renderPage(mode: .dictation, withMaterial: false)
        XCTAssertGreaterThan(inkCount(page.rep), 200, "空态也要有话说，不能一片空白")
    }

    /// 三种形式是**三张不同的卡**（换形式的按钮不能是个摆设）。
    func testTheThreeModesRenderDifferently() throws {
        let dictation = try renderPage(mode: .dictation)
        let keyword = try renderPage(mode: .keyword)
        let meaning = try renderPage(mode: .meaning)
        XCTAssertGreaterThan(differingPixels(dictation.rep, meaning.rep), 1000, "默写与选义不是同一屏")
        XCTAssertGreaterThan(differingPixels(keyword.rep, meaning.rep), 1000)
        XCTAssertGreaterThan(differingPixels(dictation.rep, keyword.rep), 100, "至少说法不同（标题 / 引导语）")
    }

    // MARK: - 出图（人眼复核）

    func testDumpsEveryListeningScreen() throws {
        let switchBar = try renderModeSwitch(.keyword)
        let prompt = try renderDrillCard(mode: .keyword)
        let keywordFeedback = try renderDrillCard(mode: .keyword, keyword: capture(typed: "reservation serv"))
        let meaningUnanswered = try renderMeaning(
            question: question(), selection: nil, reference: "Can I have a receipt for the flight"
        )
        let meaningAnswered = try renderMeaning(
            question: question(), selection: 2, reference: "Can I have a receipt for the flight"
        )
        let meaningNight = try renderMeaning(
            question: question(), selection: nil, reference: "Can I have a receipt", day: false
        )
        let pageDictation = try renderPage(mode: .dictation)
        let pageKeyword = try renderPage(mode: .keyword)
        let pageMeaning = try renderPage(mode: .meaning)
        let pageEmpty = try renderPage(mode: .dictation, withMaterial: false)

        XCTAssertGreaterThan(differingPixels(meaningUnanswered.rep, meaningNight.rep), 200, "日夜两档必然不同")

        try dump(switchBar.rep, name: "listening-modes-switch.png")
        try dump(prompt.rep, name: "listening-keyword-prompt.png")
        try dump(keywordFeedback.rep, name: "listening-keyword-feedback.png")
        try dump(meaningUnanswered.rep, name: "listening-meaning-unanswered.png")
        try dump(meaningAnswered.rep, name: "listening-meaning-answered.png")
        try dump(pageDictation.rep, name: "listening-page-dictation.png")
        try dump(pageKeyword.rep, name: "listening-page-keyword.png")
        try dump(pageMeaning.rep, name: "listening-page-meaning.png")
        try dump(pageEmpty.rep, name: "listening-page-empty.png")
    }
}
