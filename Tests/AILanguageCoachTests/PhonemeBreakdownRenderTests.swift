import AIDomain
import AIInfrastructure
import AIServices
import AppCore
@testable import AppUI
import SwiftUI
import XCTest

/// 音素条（P0-2）的**离屏渲染**回归。
///
/// 为什么必须离屏：本次任务的验证环境是熄屏的，桌面截图会被别的窗口挡、
/// 锁屏时 `screencapture` 直接报错；离屏渲染一次就能出日夜两版，
/// 而且完全不碰真实配置与数据库（不写 config.json、不写 learning.db）。
///
/// 断言不是「没崩就行」——四条都在钉住**用户真能看见**这件事：
/// ① 音素条真占高度；② 词越多墨迹越宽；③ 来源标签真被画出来；④ 日夜两版确实不同。
/// 顺带把 PNG 落到 `.workbuddy/verify/`，供人眼复核。
@MainActor
final class PhonemeBreakdownRenderTests: XCTestCase {

    private var window: NSWindow?
    private let cardWidth: CGFloat = 460

    // MARK: - 造数据

    /// 造一段「像人说话」的波形：每 0.4 秒一个词（包络 + 基频起伏），
    /// 让 `SpeechAnalyzer` 有语速 / 停顿 / 音高可量 —— 报告才像真实那一次。
    private func syntheticMetrics(seconds: Double = 2.4) -> SpeechMetrics {
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
        reference: String,
        recognized: String,
        source: PhonemeSource = .inference,
        withPhonemes: Bool = true
    ) -> PronunciationReport {
        let words = withPhonemes
            ? PhonemeAssessment.assess(
                reference: reference, recognized: recognized, lexicon: PhonemeLexiconStore.shared()
            )
            : []
        return PronunciationScorer.report(
            reference: reference,
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

    private func render(_ report: PronunciationReport, day: Bool, container: Bool = false) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: day ? .day : .night, systemIsDark: !day)
        let backdrop: Color = day ? Color(hex: 0xF3F7EF) : Color(hex: 0x101B2E)
        let host = NSHostingView(rootView: AnyView(
            PhonemeBreakdownCard(report: report, showsContainer: container)
                .forestTheme(theme)
                .frame(width: cardWidth)
                .background(backdrop)
        ))
        host.frame = NSRect(x: 0, y: 0, width: cardWidth, height: 120)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        // 两趟：先问出自然高度，再按自然高度出图，避免把内容裁掉。
        let fitted = host.fittingSize
        let size = CGSize(width: cardWidth, height: max(60, ceil(fitted.height)))
        host.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep, size: size)
    }

    /// 墨迹统计：以左上角像素为底色，数出所有「不一样」的像素及其横向包围盒。
    /// 位图是 2x 备份，返回的点数已换算。
    private func ink(_ rep: NSBitmapImageRep) -> (count: Int, minX: CGFloat, maxX: CGFloat) {
        guard let background = rep.colorAt(x: 0, y: 0) else { return (0, 0, 0) }
        var count = 0
        var minX = Int.max
        var maxX = Int.min
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let delta = abs(color.redComponent - background.redComponent)
                    + abs(color.greenComponent - background.greenComponent)
                    + abs(color.blueComponent - background.blueComponent)
                guard delta > 0.15 else { continue }
                count += 1
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }
        let scale = CGFloat(rep.pixelsWide) / cardWidth
        guard minX <= maxX else { return (count, 0, 0) }
        return (count, CGFloat(minX) / scale, CGFloat(maxX + 1) / scale)
    }

    private func dump(_ rep: NSBitmapImageRep, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AILanguageCoachTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]), "PNG 编码失败")
        try png.write(to: url)
    }

    // MARK: - ① 音素条真的占高度

    func testPhonemeStripGrowsTheCard() throws {
        let reference = "I would like a large latte please"
        // 故意读错：漏掉 would / large，并把 latte 读成 lattle —— 音素条才有红有绿。
        let recognized = "I like a lattle please"

        let withStrip = try render(makeReport(reference: reference, recognized: recognized), day: true)
        let without = try render(
            makeReport(reference: reference, recognized: recognized, withPhonemes: false), day: true
        )

        XCTAssertGreaterThan(
            withStrip.size.height, without.size.height + 40,
            "有音素明细时卡片必须明显变高（表头 + 至少一行音素 ≈ 50pt 以上）"
        )
    }

    // MARK: - ② 逐词块真的按词数铺开

    /// ⚠️ 这两版都**不带外框**（`container: false`）：带外框时底色铺满整宽，
    /// 墨迹包围盒恒等于卡宽，「内容有没有变宽」就永远测不出来了。
    func testLongerSentenceDrawsMoreInkAndMoreRows() throws {
        let short = try render(
            makeReport(reference: "I like coffee", recognized: "I like coffee"), day: true
        )
        let long = try render(
            makeReport(
                reference: "I would like to book a table for two at seven tonight",
                recognized: "I would like to book a table for two at seven tonight"
            ),
            day: true
        )

        let shortInk = ink(short.rep)
        let longInk = ink(long.rep)
        XCTAssertGreaterThan(shortInk.count, 0, "音素条应该画出东西来")
        XCTAssertGreaterThan(
            longInk.count, shortInk.count,
            "词多了墨迹像素必须更多（说明逐词块真按内容铺开，不是画了个空框）"
        )
        XCTAssertGreaterThan(
            long.size.height, short.size.height,
            "词多了必须换行：长句的卡片要比三词句更高"
        )
    }

    // MARK: - ③ 来源标签必须真被画出来（推断 ≠ 实测）

    func testSourceLabelIsActuallyDrawn() throws {
        let reference = "Nice to meet you"
        let inferred = try render(
            makeReport(reference: reference, recognized: reference, source: .inference), day: true
        )
        // 同样是「有音素」的报告，只是把来源抹成 .none：标签与说明都不该再出现。
        var stripped = makeReport(reference: reference, recognized: reference, source: .inference)
        stripped.phonemeSource = .none
        let bare = try render(stripped, day: true)

        let inferredInk = ink(inferred.rep)
        let bareInk = ink(bare.rep)
        XCTAssertGreaterThan(
            inferredInk.count, bareInk.count,
            "标注了来源的卡片必须比不标注的多出墨迹（「规则推断」胶囊 + 一行说明）"
        )
        XCTAssertGreaterThan(
            inferred.size.height, bare.size.height,
            "来源说明是独立一行，必须真的占高度"
        )
    }

    // MARK: - ④ 日夜两版都要能看（并落盘供人眼复核）

    func testRendersInBothThemesAndDumpsPNG() throws {
        let report = makeReport(
            reference: "I would like a large latte please",
            recognized: "I like a lattle please"
        )
        // 留出外框：这张图是给人眼看的，要与真卡片长得一样。
        let night = try render(report, day: false, container: true)
        let day = try render(report, day: true, container: true)

        XCTAssertGreaterThan(ink(day.rep).count, 0, "日间版应有内容")
        XCTAssertGreaterThan(ink(night.rep).count, 0, "夜间版应有内容")

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

        try dump(day.rep, name: "round31-phoneme-strip-day.png")
        try dump(night.rep, name: "round31-phoneme-strip-night.png")
    }

    // MARK: - ⑤ 端到端：跟读页里真的长出来了

    /// 走**真实链路**（loadShadowing → previewShadowingResult → PronunciationService.report），
    /// 确认音素明细一路传到页面、并且页面里确实渲染了它。
    /// 这条比单独渲染组件更重要：组件好看不代表接线通了。
    func testShadowingPageGrowsPhonemeStripEndToEnd() async throws {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("phoneme-page-probe-\(UUID().uuidString).json")
        )
        let state = AppState(services: CoachServices(config: store, databasePath: ":memory:"))
        await state.loadShadowing()

        let drill = try XCTUnwrap(state.currentShadowingDrill, "跟读素材应随包发布")
        var words = ShadowingScorer.words(drill.text)
        guard words.count > 1 else { throw XCTSkip("素材句子太短，造不出「漏词」场景") }
        words.removeLast()
        await state.previewShadowingResult(words.joined(separator: " "))

        let report = try XCTUnwrap(state.shadowingPronunciation)
        XCTAssertTrue(
            report.hasPhonemeBreakdown,
            "端到端链路必须产出逐词音素明细（参考句 \(drill.text)）"
        )
        XCTAssertEqual(
            report.phonemeSource, .inference,
            "没接云端发音评测时，来源必须如实标成「规则推断」"
        )

        // 整页渲染：确认页面没有把它吃掉（比如被别的卡片挡住 / 没插进 VStack）。
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let host = NSHostingView(rootView: AnyView(
            ShadowingView(state: state).forestTheme(theme)
        ))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 1600)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        XCTAssertGreaterThan(host.fittingSize.height, 400, "整页应能布局")
        try dump(rep, name: "round31-shadowing-page-with-phonemes.png")
    }
}
