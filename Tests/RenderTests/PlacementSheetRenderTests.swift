import AIDomain
import AIInfrastructure
import AIServices
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 入学定级两张界面的**离屏渲染**回归（进阶 ⑤）：
/// 进度页那张 `EntrancePlacementCard`，以及摸底浮层 `PlacementSheet` 的三个状态。
///
/// 断言一律用**布局高度差**，不比对绝对色值（离屏渲染过一道色彩空间换算，色值不可靠）。
/// 每条高度差背后都对应一个「用户真能看见的东西」：
/// 逐档明细、对照行、四个选项行、结果页的逐档表 —— 少画一块就变红。
///
/// ⚠️ 这里**不写 UserDefaults**：`AppState(services:)` 在 init 里会读一次
/// `placement.result`，所以我按测试需要**在内存里显式赋值**（`placementResult` /
/// `placementPaper` / `placementOutcome`），而不是往真实数据里塞一条。
/// 渲染用例绝不能碰开发机上的用户数据。
@MainActor
final class PlacementSheetRenderTests: XCTestCase {

    private var window: NSWindow?
    private let cardWidth: CGFloat = 640

    private struct Render {
        let rep: NSBitmapImageRep
        let size: CGSize
    }

    private func makeState() -> AppState {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("placement-render-\(UUID().uuidString).json")
        )
        return AppState(services: CoachServices(config: store, databasePath: ":memory:"))
    }

    // MARK: - 造数据

    /// 四档明细：A1/A2 过、B1 过、B2 没过 —— 于是定级停在 B1。
    private func scores(passed: [CEFRLevel], all: [CEFRLevel] = CEFRLevel.allCases)
        -> [PlacementLevelScore] {
        all.map { level in
            PlacementLevelScore(
                level: level,
                correct: passed.contains(level) ? 3 : 1,
                total: 3,
                isPassed: passed.contains(level)
            )
        }
    }

    private func result(
        level: CEFRLevel = .b1,
        perLevel: [PlacementLevelScore]? = nil
    ) -> PlacementResult {
        let scores = perLevel ?? scores(passed: [.a1, .a2, .b1])
        return PlacementResult(
            level: level,
            correct: scores.reduce(0) { $0 + $1.correct },
            total: scores.reduce(0) { $0 + $1.total },
            seed: 1,
            perLevel: scores
        )
    }

    private func vocabularyQuestion(prompt: String = "receipt") -> PlacementQuestion {
        PlacementQuestion(
            id: "a1-v1", level: .a1, kind: .vocabulary, prompt: prompt,
            options: ["收据", "行李", "登机口", "退票"], answer: 0,
            explain: "receipt 是「收据 / 小票」。"
        )
    }

    private func grammarQuestion(prompt: String = "She ___ here since 2019.") -> PlacementQuestion {
        PlacementQuestion(
            id: "b1-g1", level: .b1, kind: .grammar, prompt: prompt,
            options: ["works", "worked", "has worked", "working"], answer: 2,
            explain: "since + 时间点用现在完成时。"
        )
    }

    // MARK: - 离屏渲染

    private func render(_ view: AnyView, day: Bool = true, width: CGFloat? = nil) throws -> Render {
        let width = width ?? cardWidth
        let theme = ForestThemeResolver.resolve(mode: day ? .day : .night, systemIsDark: !day)
        let backdrop: Color = day ? Color(hex: 0xF3F7EF) : Color(hex: 0x101B2E)
        let host = NSHostingView(rootView: AnyView(
            view
                .fixedSize(horizontal: false, vertical: true)
                .forestTheme(theme)
                .frame(width: width)
                .background(backdrop)
        ))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 240)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        // 两趟：先问出自然高度，再按自然高度出图，避免把内容裁掉。
        let size = CGSize(width: width, height: max(40, ceil(host.fittingSize.height)))
        host.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep, size: size)
    }

    private func card(result: PlacementResult?, estimate: CEFRLevel? = nil, day: Bool = true) throws -> Render {
        try render(
            AnyView(EntrancePlacementCard(result: result, estimateLevel: estimate, onStart: {})),
            day: day
        )
    }

    /// 浮层：说明态（还没出卷）。
    private func introSheet(previousLevel: CEFRLevel?, day: Bool = true) throws -> Render {
        let state = makeState()
        state.placementResult = previousLevel.map { PlacementResult(level: $0, correct: 8, total: 12) }
        state.placementPaper = .empty
        return try render(AnyView(PlacementSheet(state: state, onClose: {})), day: day)
    }

    /// 浮层：答题态（给几道题就画几道题的第一道）。
    private func questionSheet(
        _ questions: [PlacementQuestion], index: Int = 0, day: Bool = true
    ) throws -> Render {
        let state = makeState()
        state.placementResult = nil
        state.placementPaper = PlacementPaper(questions: questions, seed: 1)
        state.placementIndex = index
        return try render(AnyView(PlacementSheet(state: state, onClose: {})), day: day)
    }

    /// 浮层：结果态（`placementOutcome` 一有值就切到结果页）。
    private func resultSheet(_ result: PlacementResult, day: Bool = true) throws -> Render {
        let state = makeState()
        state.placementPaper = PlacementPaper(
            questions: [vocabularyQuestion(), grammarQuestion()], seed: 1
        )
        state.placementOutcome = result
        return try render(AnyView(PlacementSheet(state: state, onClose: {})), day: day)
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

    private func changedPixels(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Int {
        guard lhs.pixelsWide == rhs.pixelsWide, lhs.pixelsHigh == rhs.pixelsHigh else {
            return Int.max
        }
        var count = 0
        for x in 0..<lhs.pixelsWide {
            for y in 0..<lhs.pixelsHigh {
                guard let a = lhs.colorAt(x: x, y: y), let b = rhs.colorAt(x: x, y: y) else { continue }
                if abs(a.redComponent - b.redComponent)
                    + abs(a.greenComponent - b.greenComponent)
                    + abs(a.blueComponent - b.blueComponent) > 0.15 { count += 1 }
            }
        }
        return count
    }

    // MARK: - ① 进度页卡片

    /// 做过摸底之后，卡片要多出「档位 + 逐档明细 + 建议」这一整块。
    func testCardGrowsOnceThereIsAResult() throws {
        let notTaken = try card(result: nil)
        let taken = try card(result: result())

        XCTAssertGreaterThan(notTaken.size.height, 60, "没做过也要有话说（说明 + 开始按钮）")
        XCTAssertGreaterThan(
            taken.size.height, notTaken.size.height + 40,
            "有结果时必须多出档位大字、逐档 chip、建议那几行"
        )
    }

    /// 逐档明细那一行**必须真的画出来**：把 `perLevel` 清空，卡片就该变矮。
    ///
    /// 这条钉的是「只给一个字母等于让人无条件相信它」—— 明细行是核对的唯一依据。
    func testLevelBreakdownRowIsActuallyDrawn() throws {
        let empty = try card(result: result(perLevel: []))
        let full = try card(result: result())

        XCTAssertGreaterThan(
            full.size.height, empty.size.height + 10,
            "四档明细没有画出来 —— 用户没法核对「为什么定在这」"
        )
    }

    /// 两把尺子不一致时才补对照行；一致时**一个字都不该多**。
    ///
    /// 两个断言成对：前一条证明对照行画得出来，后一条证明它不会到处乱冒。
    func testComparisonRowAppearsOnlyWhenTheTwoRulersDisagree() throws {
        let noEstimate = try card(result: result(level: .b1))
        let estimateBelow = try card(result: result(level: .b1), estimate: .a2)
        let estimateEqual = try card(result: result(level: .b1), estimate: .b1)

        XCTAssertGreaterThan(
            estimateBelow.size.height, noEstimate.size.height + 10,
            "自测 B1、实测 A2 —— 这句对照必须说出来"
        )
        XCTAssertEqual(
            estimateEqual.size.height, noEstimate.size.height, accuracy: 0.5,
            "两边同档时不许多一句话（那是废话）"
        )
    }

    // MARK: - ② 浮层：说明 / 答题

    /// 答题态要比说明态高出一截 —— 四个选项行 + 题干 + 进度条都在那。
    func testQuestionStateIsTallerThanIntro() throws {
        let intro = try introSheet(previousLevel: nil)
        let question = try questionSheet([vocabularyQuestion()])

        XCTAssertGreaterThan(
            question.size.height, intro.size.height + 60,
            "题干 + 四个选项行 + 进度条必须真的画出来"
        )
    }

    /// 词汇题是「词 → 义」，字号明显大于语法题的句子；这条差异不该被顺手抹平。
    func testVocabularyPromptIsVisuallyBiggerThanGrammarPrompt() throws {
        let vocabulary = try questionSheet([vocabularyQuestion(prompt: "receipt")])
        let grammar = try questionSheet([grammarQuestion(prompt: "She ___ here since 2019.")])

        XCTAssertGreaterThan(
            vocabulary.size.height, grammar.size.height + 16,
            "词汇题的词要按大字号画（30pt），语法题按句子字号（17pt）"
        )
    }

    /// 进度条随下标走、题干跟着换 —— 换到第 2 题时页面上画的已经不是第 1 题。
    func testProgressingChangesWhatIsDrawn() throws {
        let paper = [vocabularyQuestion(prompt: "receipt"), grammarQuestion(prompt: "She ___ here since 2019.")]
        let first = try questionSheet(paper, index: 0)
        let second = try questionSheet(paper, index: 1)

        XCTAssertGreaterThan(changedPixels(first.rep, second.rep), 500, "换题之后画面必须真的不同")
    }

    // MARK: - ③ 浮层：结果

    /// 结果页要把**每一档**摆出来（过了的 / 没过的），不是只丢一个字母。
    func testResultStateShowsEveryLevelRow() throws {
        let empty = try resultSheet(result(level: .b2, perLevel: []))
        let full = try resultSheet(result())

        XCTAssertGreaterThan(
            full.size.height, empty.size.height + 40,
            "四行逐档明细（含「过了 / 没过」）必须真的画出来"
        )
    }

    /// 结果页比说明页高：多了档位大字 + 四行逐档表 + 结论 + 三个按钮。
    ///
    /// ⚠️ 这里**不**跟答题页比高度：答题页有一行 30pt 的词 + 四个选项行，反而更高
    ///（实测 421 vs 360）—— 拿它当基准会写成一条「靠巧合通过」的断言。
    func testResultStateIsTallerThanIntro() throws {
        let intro = try introSheet(previousLevel: nil)
        let result = try resultSheet(result())

        XCTAssertGreaterThan(
            result.size.height, intro.size.height + 40,
            "档位大字 + 逐档表 + 结论 + 按钮必须真的占出高度"
        )
    }

    // MARK: - ④ 头部小字（文案，量不出高度，直接钉字符串）

    /// 三种状态各说各的，尤其**结果页不许再报题号**。
    ///
    /// 离屏出图抓到过：卷子已经判完，头部还挂着「第 1 / 2 题」——
    /// 那读起来像「还有题没做完」。像素上量不出文案差异，所以这条直接断言字符串。
    func testHeaderSubtitleMatchesTheThreeStates() {
        let state = makeState()

        // 说明态：还没出卷。
        state.placementPaper = .empty
        state.placementOutcome = nil
        XCTAssertEqual(
            PlacementSheet(state: state, onClose: {}).headerSubtitle,
            "几分钟摸个底，我按你的水平出题"
        )

        // 答题态：报题号。
        state.placementPaper = PlacementPaper(
            questions: [vocabularyQuestion(), grammarQuestion()], seed: 1
        )
        state.placementIndex = 1
        XCTAssertEqual(PlacementSheet(state: state, onClose: {}).headerSubtitle, "第 2 / 2 题")

        // 结果态：说「完成」，不再报题号。
        state.placementOutcome = result()
        let subtitle = PlacementSheet(state: state, onClose: {}).headerSubtitle
        XCTAssertEqual(subtitle, "摸底完成 · 共 2 题")
        XCTAssertFalse(subtitle.contains("第"), "判完了就不该再挂题号")
    }

    // MARK: - 出图（人眼复核）

    func testDumpsAllStates() throws {
        let notTakenDay = try card(result: nil)
        let notTakenNight = try card(result: nil, day: false)
        let takenDay = try card(result: result(), estimate: .a2)
        let takenNight = try card(result: result(), estimate: .a2, day: false)

        XCTAssertGreaterThan(changedPixels(notTakenDay.rep, notTakenNight.rep), 500, "日夜两档必然不同")

        let introDay = try introSheet(previousLevel: nil)
        let introNight = try introSheet(previousLevel: .a2, day: false)
        let questionDay = try questionSheet([vocabularyQuestion()])
        let questionNight = try questionSheet([grammarQuestion()], day: false)
        let resultDay = try resultSheet(result())
        let resultNight = try resultSheet(result(), day: false)

        try dump(notTakenDay.rep, name: "placement-card-not-taken-day.png")
        try dump(notTakenNight.rep, name: "placement-card-not-taken-night.png")
        try dump(takenDay.rep, name: "placement-card-taken-day.png")
        try dump(takenNight.rep, name: "placement-card-taken-night.png")
        try dump(introDay.rep, name: "placement-sheet-intro-day.png")
        try dump(introNight.rep, name: "placement-sheet-intro-night.png")
        try dump(questionDay.rep, name: "placement-sheet-question-day.png")
        try dump(questionNight.rep, name: "placement-sheet-question-night.png")
        try dump(resultDay.rep, name: "placement-sheet-result-day.png")
        try dump(resultNight.rep, name: "placement-sheet-result-night.png")
    }
}
