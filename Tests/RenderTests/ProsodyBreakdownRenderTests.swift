import AIDomain
import AIInfrastructure
import AIServices
import AppCore
@testable import AppUI
import SwiftUI
import XCTest

/// 逐词韵律条（④ 的 UI，`ProsodyBreakdownCard`）的**离屏渲染**回归。
///
/// 为什么必须离屏：验证环境熄屏，`screencapture` 会报错；离屏一次出日夜两版，
/// 而且完全不碰真实配置与数据库（临时 config + `:memory:` 库）。
///
/// 每条断言都钉「用户真能看见」这件事，不是「没崩就行」：
/// ① 韵律条真占高度；② 词多了墨迹更多且会换行；③ 连读标记真被画出来；
/// ④ 日夜两版确实不同（并落盘供人眼复核）；⑤ 组件吃的是**分析器真产出的**那份；
/// ⑥ 端到端：跟读页里真的长出来了（撤掉挂载就会红）。
@MainActor
final class ProsodyBreakdownRenderTests: XCTestCase {

    private var window: NSWindow?
    private let cardWidth: CGFloat = 460
    private let pageWidth: CGFloat = 900
    private let pageHeight: CGFloat = 2000

    // MARK: - 造数据

    /// 造一段「像人说话」的波形并真的跑一遍 `ProsodyWindowAnalyzer` ——
    /// 用**分析器的产物**去渲染，而不是手搓一份 `ProsodyAnalysis`：
    /// 后者会让「分析器根本没产出东西」这种情况也照样通过。
    ///
    /// - 每个词一段带包络的正弦，时长长短不一（时间戳才不会被判成「按字符均摊」）；
    /// - 第 2 个词最响、第 4 个词最轻 → 有重读也有弱读；
    /// - 基频逐词抬升 → 轮廓不是平的。
    private func makeAnalysis(words: [String]) -> ProsodyAnalysis? {
        let sampleRate = 16_000.0
        var pcm: [Float] = []
        var samples: [ProsodyWordSample] = []
        var cursor = 0.0
        for (index, word) in words.enumerated() {
            let duration = 0.20 + 0.09 * Double(index % 3)
            let count = max(Int(duration * sampleRate), 512)
            // 全程用 Double 算：`Float * Double` 混算会让类型检查器在这行卡死（实测超时）。
            let amplitude: Double = index == 1 ? 0.9 : (index == 3 ? 0.15 : 0.4)
            let f0 = 130.0 + 12.0 * Double(index)
            for i in 0..<count {
                let t = Double(i) / sampleRate
                let envelope = sin(.pi * Double(i) / Double(count))
                pcm.append(Float(amplitude * envelope * sin(2 * .pi * f0 * t)))
            }
            samples.append(ProsodyWordSample(word: word, start: cursor, end: cursor + duration))
            cursor += duration
        }
        return ProsodyWindowAnalyzer.analysis(words: samples, pcm: pcm, sampleRate: sampleRate)
    }

    /// 手搓一份（用于「有 / 没有」这类对照，保证版式完全可控）。
    private func analysis(
        words: [String],
        stress: [WordStressMark] = [],
        linking: [LinkingSpan] = [],
        contour: IntonationContour? = nil
    ) -> ProsodyAnalysis {
        ProsodyAnalysis(words: words, stress: stress, contour: contour, linking: linking)
    }

    private func marks(_ words: [String]) -> [WordStressMark] {
        words.enumerated().map { index, word in
            let level: WordStressMark.Level = index == 1 ? .stressed : (index == 3 ? .reduced : .normal)
            let ratio = index == 1 ? 2.0 : (index == 3 ? 0.4 : 1.0)
            return WordStressMark(word: word, level: level, ratio: ratio)
        }
    }

    // MARK: - 离屏渲染

    private struct Render {
        var rep: NSBitmapImageRep
        var size: CGSize
    }

    /// 出一次图。⚠️ 冷启动那一次排版缓存没热，同一份输入两次出图能差几百像素
    /// → 对外一律先出一张废图「捂热」，再出真正要比的那张。
    private func render(
        _ analysis: ProsodyAnalysis,
        bonus: Double = 0,
        day: Bool,
        container: Bool = false,
        warmUp: Bool = true
    ) throws -> Render {
        if warmUp {
            _ = try? draw(analysis, bonus: bonus, day: day, container: container)
        }
        return try draw(analysis, bonus: bonus, day: day, container: container)
    }

    private func draw(
        _ analysis: ProsodyAnalysis,
        bonus: Double,
        day: Bool,
        container: Bool
    ) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: day ? .day : .night, systemIsDark: !day)
        let backdrop: Color = day ? Color(hex: 0xF3F7EF) : Color(hex: 0x101B2E)
        let host = NSHostingView(rootView: AnyView(
            ZStack(alignment: .top) {
                backdrop
                ProsodyBreakdownCard(analysis: analysis, bonus: bonus, showsContainer: container)
                    .frame(width: cardWidth)
            }
            .frame(width: cardWidth)
            .forestTheme(theme)
        ))
        host.frame = NSRect(x: 0, y: 0, width: cardWidth, height: 200)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        // 两趟：先问自然高度再按它出图，免得把内容裁掉。
        // ⚠️ 下限是 `max(1, …)` 不是 `max(60, …)`：垫出来的高度是**透明**的，
        // 会被当成墨迹，包围盒与墨量一起失真。
        let size = CGSize(width: cardWidth, height: max(1, ceil(host.fittingSize.height)))
        host.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep, size: size)
    }

    private func renderPage(_ state: AppState) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let host = NSHostingView(rootView: AnyView(
            ZStack(alignment: .top) {
                Color(hex: 0xF3F7EF)
                ShadowingView(state: state)
            }
            .frame(width: pageWidth)
            .forestTheme(theme)
        ))
        host.frame = NSRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep, size: host.frame.size)
    }

    /// 墨迹统计：以左上角像素为底色，数出「不一样」的像素。
    private func ink(_ rep: NSBitmapImageRep) -> Int {
        guard let background = rep.colorAt(x: 0, y: 0) else { return 0 }
        var count = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let delta = abs(color.redComponent - background.redComponent)
                    + abs(color.greenComponent - background.greenComponent)
                    + abs(color.blueComponent - background.blueComponent)
                if delta > 0.15 { count += 1 }
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

    // MARK: - ① 韵律条真的占高度

    func testProsodyStripGrowsTheCard() throws {
        let filled = try render(
            analysis(
                words: ["I", "want", "a", "large", "latte"],
                stress: marks(["I", "want", "a", "large", "latte"]),
                contour: IntonationContour(shape: .falling, slope: -1.4, points: [0, 1.2, 0.4])
            ),
            bonus: 7, day: true
        )
        let empty = try render(ProsodyAnalysis(), day: true)

        XCTAssertGreaterThan(
            filled.size.height, empty.size.height + 40,
            "有逐词韵律时卡片必须明显变高（表头 + 一行词 ≈ 50pt 以上）"
        )
    }

    // MARK: - ② 词多了墨迹更多、并且会换行

    func testMoreWordsDrawMoreInkAndWrap() throws {
        let short = try render(analysis(words: ["pick", "it", "up"], stress: marks(["pick", "it", "up"])),
                               day: true)
        let longWords = ["I", "would", "like", "to", "book", "a", "table", "for", "two", "at", "seven"]
        let long = try render(analysis(words: longWords, stress: marks(longWords)), day: true)

        XCTAssertGreaterThan(ink(short.rep), 0, "韵律条应该画出东西来")
        XCTAssertGreaterThan(ink(long.rep), ink(short.rep),
                             "词多了墨迹必须更多（说明逐词块真按内容铺开，不是画了个空框）")
        XCTAssertGreaterThan(long.size.height, short.size.height,
                             "十一个词在 460pt 宽里必须换行：卡片要比三词句更高")
    }

    // MARK: - ③ 连读标记真的被画出来

    /// 同一句、只有 `linking` 不同：多出来的墨迹只能是那两枚「连读弧」。
    /// ⚠️ 用三个词，保证加标记不会触发换行（否则量到的是行高不是笔画）。
    func testLinkingTiesAreActuallyDrawn() throws {
        var linked = analysis(words: ["pick", "it", "up"], stress: marks(["pick", "it", "up"]))
        linked.linking = [
            LinkingSpan(firstWord: "pick", secondWord: "it", gap: 0.01, didLink: true),
            LinkingSpan(firstWord: "it", secondWord: "up", gap: 0.02, didLink: true),
        ]
        let withTies = try render(linked, day: true)
        let plain = try render(
            analysis(words: ["pick", "it", "up"], stress: marks(["pick", "it", "up"])),
            day: true
        )

        XCTAssertEqual(withTies.size.height, plain.size.height,
                       "连读弧是行内的小笔画，不该改变行高（变了就说明换行了，这条判据失效）")
        XCTAssertGreaterThan(ink(withTies.rep), ink(plain.rep) + 10,
                             "该连读的位置必须真的画出来 —— 这是本次新增的全部视觉")
    }

    /// 同一句话的三个版本：没有连读候选 / 候选但没连上 / 连上了。
    /// 三者的墨迹必须**逐级变多** —— 这同时证明「虚线提示也画了」与「实线比虚线重」。
    ///
    /// ⚠️ 判据是**相对**的（实线 > 虚线 > 无），不是给单个数字配一个魔数阈值：
    /// 阈值调松一点这条就永远绿，写死了又会被抗锯齿的浮动打红。
    func testUnlinkedTieIsStillDrawnButFaint() throws {
        var linkedOnly = analysis(words: ["pick", "it"], stress: marks(["pick", "it"]))
        linkedOnly.linking = [LinkingSpan(firstWord: "pick", secondWord: "it", gap: 0.01, didLink: true)]
        var unlinkedOnly = analysis(words: ["pick", "it"], stress: marks(["pick", "it"]))
        unlinkedOnly.linking = [LinkingSpan(firstWord: "pick", secondWord: "it", gap: 0.40, didLink: false)]
        let bare = analysis(words: ["pick", "it"], stress: marks(["pick", "it"]))

        let linked = ink(try render(linkedOnly, day: true).rep)
        let unlinked = ink(try render(unlinkedOnly, day: true).rep)
        let none = ink(try render(bare, day: true).rep)

        XCTAssertGreaterThan(unlinked, none + 10, "没连上的那一处也仍然要画（否则用户永远看不到这个提示）")
        XCTAssertGreaterThan(linked, unlinked + 10, "连上了是实线、没连上是淡虚线：前者的墨必须更多")
    }

    // MARK: - ④ 日夜两版都要能看（并落盘供人眼复核）

    func testRendersInBothThemesAndDumpsPNG() throws {
        let words = ["I", "want", "a", "large", "latte"]
        let analysis = analysis(
            words: words,
            stress: marks(words),
            linking: [LinkingSpan(firstWord: "want", secondWord: "a", gap: 0.01, didLink: true)],
            contour: IntonationContour(shape: .falling, slope: -1.4, points: [0, 1.2, 0.4, -0.3, -1.1])
        )
        let night = try render(analysis, bonus: 7, day: false, container: true)
        let day = try render(analysis, bonus: 7, day: true, container: true)

        XCTAssertGreaterThan(ink(day.rep), 0, "日间版应有内容")
        XCTAssertGreaterThan(ink(night.rep), 0, "夜间版应有内容")

        /// 用 RGB 加权算亮度，不碰 `brightnessComponent`（位图取色未必是可转 HSB 的色彩空间）。
        func luma(_ rep: NSBitmapImageRep) throws -> CGFloat {
            let color = try XCTUnwrap(rep.colorAt(x: 0, y: 0))
            return color.redComponent * 0.3 + color.greenComponent * 0.6 + color.blueComponent * 0.1
        }
        let dayLuma = try luma(day.rep)
        let nightLuma = try luma(night.rep)
        XCTAssertGreaterThan(dayLuma, 0.5, "日间底色应偏亮")
        XCTAssertLessThan(nightLuma, 0.3, "夜间底色应偏暗")
        XCTAssertGreaterThan(dayLuma, nightLuma, "两版底色必须真的不同，否则主题没生效")

        try dump(day.rep, name: "round44-prosody-strip-day.png")
        try dump(night.rep, name: "round44-prosody-strip-night.png")
    }

    // MARK: - ⑤ 组件吃的是分析器真产出的那一份

    /// 走真的 `ProsodyWindowAnalyzer`（合成波形 + 词时间戳），确认页面上画的就是它的产物 ——
    /// 手搓一份 `ProsodyAnalysis` 会让「分析器根本产不出东西」也照样绿。
    func testAnalyzerOutputIsRenderable() throws {
        let produced = try XCTUnwrap(
            makeAnalysis(words: ["I", "want", "a", "large", "latte"]),
            "合成波形应当产出一份韵律分析（时间戳可信、有浊音词）"
        )
        XCTAssertFalse(produced.stress.isEmpty, "至少要判出重读/弱读")
        XCTAssertEqual(produced.words.count, 5, "词序列要完整留给 UI")

        let drawn = try render(produced, bonus: produced.linkedCount == nil ? 7 : 10, day: true, container: true)
        XCTAssertGreaterThan(ink(drawn.rep), 0, "分析器的产物必须能真的画出来")
        try dump(drawn.rep, name: "round44-prosody-strip-analyzer.png")
    }

    // MARK: - ⑥ 端到端：跟读页里真的长出来了

    /// 组件好看不代表接线通了 —— 这条钉的是「`ShadowingView` 真的把这块挂上了」。
    /// 撤掉挂载 → 两版墨迹相等 → 立刻红。
    ///
    /// ⚠️ 为什么比**墨迹**而不是比高度：整页在 `ScrollView` 里，加一块内容不改变页面高度
    /// （多出来的是可滚动的那一段），量高度会永远绿。
    func testShadowingPageDrawsTheStripEndToEnd() async throws {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("prosody-page-probe-\(UUID().uuidString).json")
        )
        let state = AppState(services: CoachServices(config: store, databasePath: ":memory:"))
        await state.loadShadowing()

        let drill = try XCTUnwrap(state.currentShadowingDrill, "跟读素材应随包发布")
        await state.previewShadowingResult(drill.text)
        XCTAssertNotNil(state.shadowingComparison, "预览一条跟读结果：发音卡只在有对齐结果时才显示")

        let metrics = SpeechMetrics(duration: 2, speechDuration: 2)
        let prosody = try XCTUnwrap(makeAnalysis(words: ["I", "want", "a", "large", "latte"]))
        state.shadowingPronunciation = PronunciationScorer.report(
            reference: drill.text, recognized: drill.text, metrics: metrics, prosody: prosody
        )
        let withStrip = try renderPage(state)

        state.shadowingPronunciation = PronunciationScorer.report(
            reference: drill.text, recognized: drill.text, metrics: metrics
        )
        let without = try renderPage(state)

        let withInk = ink(withStrip.rep)
        let withoutInk = ink(without.rep)
        // ⚠️ 阈值必须明显高过噪声：整页里有一只在动的动物（`.repeatForever`），
        // 撤掉卡片实测的差值是 **0**，而两次同样输入的自身抖动在 500 像素上下 ——
        // 阈值贴着 500 会被抖动吃掉，看着红其实是绿的（或反过来）。
        XCTAssertGreaterThan(withInk, withoutInk + 2_000,
                             "带韵律的页面必须明显多出墨迹（差值 \(withInk - withoutInk)）—— 说明卡片真的挂在页面上")

        try dump(withStrip.rep, name: "round44-shadowing-page-with-prosody.png")
        try dump(without.rep, name: "round44-shadowing-page-without-prosody.png")
    }
}
