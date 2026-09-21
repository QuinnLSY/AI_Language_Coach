import AIDomain
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 划词气泡**走浮层那条路**时的回归（2026-09-21 阅读页报障）。
///
/// 事故：阅读短文里「划第一个词不翻译，划第二个词才翻译」。逐层取证查出**两个各自独立**的缺陷：
///
/// **① 页面刚挂上时的那次划词会被静默吞掉。**
/// `updateTrackingAreas` 在挂载 / 改尺寸时会抖出一次 `mouseExited`，而它当时不分种类地
/// `cancelDwell()` —— 把刚起的「拖选落定后取内容」那个计时器一起掐了。
/// 悬停与拖选共用一条计时链，但取消理由完全不同：鼠标移出视图只该掐悬停那一个
/// （拖选本来就可以拖到视图外松手）。→ `testFirstSelectionSurvivesTrackingAreaChurn`
///
/// **② 卡是异步来的，回来之后没人重算锚点。**
/// 探测那一刻 `presenter.request` 还是 nil（本地词库 / 模型都要等），`anchorPreference`
/// 那次算出来的锚点是 nil；等卡到了、`request` 变成「这一句的」，没有任何东西会让句子重算
/// 锚点，浮层手上只有一个陈旧的 nil → 气泡拿不到位置 → **永远不出现**。
/// → `testAnchorIsReportedAfterCardArrives`（根因）+ `testBubbleAppearsEvenWhenCardArrivesLate`（端到端）
///
/// ⚠️ 为什么以前的渲染测试没挡住：它们渲染的是**没有浮层**的句子（`presenter == nil`），
/// 走句内 `localBubble` 兜底那条路 —— 那条只读 `probe` @State，压根不碰锚点。
/// 这里特意把浮层装上，走用户真实走的那条路。
///
/// ⚠️ **别用合成 `NSEvent` 去调 `mouseExited(with:)`**（第一版就是那么写的）：那只有
/// AppKit 拿真实 tracking-area 事件驱动时才合法，合成事件会抛 `Invalid message sent to event`，
/// 而且是在 AppKit 的帧里抛 —— 实测直接把整个测试进程 `abort`（`signal 6`），
/// 连同一套件里排在后面的用例都跑不完。要打这条纪律就打它抽出来的那个接缝（`endHoverTracking`）。
@MainActor
final class ReadingLookupBubbleRenderTests: XCTestCase {

    /// 上报记录（用例内读，所以用引用类型；数组是值类型，闭包里 append 只会改到副本上）。
    private final class ProbeLog {
        var probes: [String] = []
        var anchorOwners: [Bool] = []
    }

    private var window: NSWindow?

    private struct Harness {
        let host: NSHostingView<AnyView>
        let presenter: WordLookupBubblePresenter
        let textView: WordLookupTextView
        let log: ProbeLog
    }

    private static let passage =
        "Weather-Following Baker. For most bakers, a rainy day just means a quiet shop."

    /// 结构与 `MainView` 一致：句子 → `wordLookupBubbleOverlay()` → 注入 presenter。
    ///
    /// `card` 一律返回 nil（「还没有结果」），内容由用例稍后手动送 —— 这正是线上那一拍的形状。
    private func makeHarness(width: CGFloat = 620, observeAnchors: Bool = false) throws -> Harness {
        let presenter = WordLookupBubblePresenter()
        let log = ProbeLog()
        let context = WordLookupContext(
            card: { _ in nil },
            onProbe: { text in log.probes.append(text) }
        )
        let attributed = ReadingParagraphText.make(
            Self.passage, fontSize: 13, color: .black, lineSpacing: 4
        )
        var root = AnyView(
            VStack(alignment: .leading, spacing: 10) {
                WordLookupSentence(
                    attributed: attributed, context: context, hoverLookupEnabled: false
                )
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        )
        if observeAnchors {
            root = AnyView(
                root.onPreferenceChange(WordLookupAnchorKey.self) { anchor in
                    log.anchorOwners.append(anchor != nil)
                }
            )
        }
        let styled = root
            .wordLookupBubbleOverlay()
            .environment(\.wordLookupPresenter, presenter)
            .forestTheme(ForestThemeResolver.resolve(mode: .day, systemIsDark: false))
            .frame(width: width, height: 220)
            .background(Color.white)

        let host = NSHostingView(rootView: AnyView(styled))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 220)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        settle(host)

        let textView = try XCTUnwrap(firstTextView(in: host), "正文应当是 AppKit 可划词文本视图")
        return Harness(host: host, presenter: presenter, textView: textView, log: log)
    }

    private func firstTextView(in host: NSView) -> WordLookupTextView? {
        if let tv = host as? WordLookupTextView { return tv }
        for child in host.subviews {
            if let found = firstTextView(in: child) { return found }
        }
        return nil
    }

    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        window?.layoutIfNeeded()
    }

    /// 划一段（等价于用户拖选落定）：`setSelectedRange` 与 delegate 回调一并发。
    private func dragSelect(_ view: WordLookupTextView, _ range: NSRange) {
        view.setSelectedRange(range)
        view.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: view)
        )
    }

    /// 造一次「指针已经离开视图」——挂载 / 改尺寸时 `updateTrackingAreas` 就会抖出这么一拍。
    ///
    /// ⚠️ **不能用合成 `NSEvent` 去调 `mouseExited(with:)`**：那只有 AppKit 拿真实
    /// tracking-area 事件驱动时才合法，合成事件会被 AppKit 判为
    /// `Invalid message sent to event` —— 实测这一抛**直接把整个测试进程 abort 掉**
    /// （`signal 6` / `freed pointer was not the last allocation`），连套件里其它用例都跑不完。
    /// 所以要验的不是「事件怎么来」，而是**取消纪律**（谁该掐谁的计时器）——
    /// 那部分住在 `endHoverTracking()` 里，`mouseExited` 只是转调它（`super` 那一句没有逻辑）。
    private func pokeMouseExit(_ view: WordLookupTextView) {
        view.endHoverTracking()
    }

    private func render(_ host: NSView) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// 两张图的差异像素数（隔点采样）。
    private func diff(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        var count = 0
        for x in stride(from: 0, to: min(a.pixelsWide, b.pixelsWide), by: 2) {
            for y in stride(from: 0, to: min(a.pixelsHigh, b.pixelsHigh), by: 2) {
                guard let ca = a.colorAt(x: x, y: y), let cb = b.colorAt(x: x, y: y) else { continue }
                if abs(ca.redComponent - cb.redComponent) > 0.02
                    || abs(ca.greenComponent - cb.greenComponent) > 0.02
                    || abs(ca.blueComponent - cb.blueComponent) > 0.02 {
                    count += 1
                }
            }
        }
        return count
    }

    /// 送一次内容（线上是 `wordLookupCard.didSet → presenter.updateCard`）。
    private func deliverCard(_ harness: Harness, word: String, translation: String) async throws {
        harness.presenter.updateCard(WordLookupCard(text: word, translation: translation))
        try await Task.sleep(nanoseconds: 400_000_000)
        settle(harness.host)
    }

    // MARK: - 缺陷 ①：挂载时的那一次划词不许被吞掉

    /// 划完立刻来一次「指针离开视图」（挂载 / 改尺寸时的 tracking area 抖动），这次划词仍须上报。
    ///
    /// 撤掉修复（`endHoverTracking` 里改回无条件 `cancelDwell()`）时这条会红。
    func testFirstSelectionSurvivesTrackingAreaChurn() async throws {
        let harness = try makeHarness()

        dragSelect(harness.textView, NSRange(location: 0, length: 7))
        // 计时器还没到点（0.28s）就抖一次 mouseExited —— 线上那一拍就是这样。
        pokeMouseExit(harness.textView)
        try await Task.sleep(nanoseconds: 500_000_000)
        settle(harness.host)

        XCTAssertEqual(
            harness.log.probes, ["Weather"],
            "鼠标移出视图只该掐掉悬停计时器，不该把刚起的拖选计时器一起掐掉"
        )

        try await deliverCard(harness, word: "Weather", translation: "天气")
        XCTAssertNotNil(harness.presenter.request, "这次划词应当真的送到浮层上")
    }

    // MARK: - 缺陷 ②：锚点必须跟着「谁拥有气泡」重算（根因）

    /// 卡到达之后必须重报一次**非 nil** 的锚点 —— 否则浮层无处摆位、气泡永远不出现。
    func testAnchorIsReportedAfterCardArrives() async throws {
        let harness = try makeHarness(observeAnchors: true)
        try await Task.sleep(nanoseconds: 300_000_000)

        dragSelect(harness.textView, NSRange(location: 0, length: 7))
        try await Task.sleep(nanoseconds: 500_000_000)
        settle(harness.host)
        // 探测已上报、卡还没到：这一刻锚点只能是 nil。
        harness.log.anchorOwners.removeAll()

        try await deliverCard(harness, word: "Weather", translation: "天气")
        XCTAssertTrue(
            harness.log.anchorOwners.contains(true),
            "卡到了之后必须重报一次非 nil 的锚点，否则浮层拿不到位置、气泡永远不出现"
        )
    }

    // MARK: - 缺陷 ②：端到端 —— 卡晚到，气泡也必须出现在浮层里

    /// 划第一个词 → 卡**晚一点**才到 → 浮层里必须真的多出一块气泡。
    ///
    /// 撤掉修复（把 anchorPreference 里的 owner 改回现读 `presenter.request`）时这条会红：
    /// 卡到了之后画面几乎没变化 —— 那正是用户看到的「划了没反应」。
    func testBubbleAppearsEvenWhenCardArrivesLate() async throws {
        let harness = try makeHarness()
        // 用户是在页面上待了一会儿才去划词的（不是在挂载那一瞬间）。
        try await Task.sleep(nanoseconds: 300_000_000)

        dragSelect(harness.textView, NSRange(location: 0, length: 7))
        try await Task.sleep(nanoseconds: 500_000_000)
        settle(harness.host)

        let probed = try render(harness.host)
        try await deliverCard(harness, word: "Weather", translation: "天气")

        let after = try render(harness.host)
        XCTAssertGreaterThan(
            diff(probed, after), 2_000,
            "卡回来之后气泡必须出现：词在句首、卡又是异步到的，这条正是报障那一步"
        )
        XCTAssertNotNil(harness.presenter.request, "前提：浮层这时确实拿着这一句的请求")
    }
}
