import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 「继续上次对话」按钮（2026-10-14 引导卡改造）的**离屏渲染**回归。
///
/// 钉的三件用户真看得见的事：
/// - **给了依据才画**：`canContinueLast: false` 时必须和不画的那一版是同一张图
///   （第一次打开、库里什么都没有，凑一颗点下去只会收到一句泛泛招呼的按钮，比没有更糟）；
/// - **窄聊天区不溢出**：与话题卡同一条规矩（宽度是上限不是定宽，340pt 提案宽里
///   必须收起来贴边）；
/// - **底色 / 悬停色与话题卡完全同源**（2026-10-14 第二次报障）——
///   比的是「两边的卡面底色是不是同一份」，用**众数色**取，不写死坐标。
///
/// 「排在第一位」不由渲染钉：空态是垂直居中的，多一块内容整排都会移位，
/// 度量对「谁在上谁在下」不敏感 —— 顺序改由 `LaunchTodayPanelTests` 的
/// 源码哨兵按**源码位置先后**钉住。
///
/// ⚠️ 比色**只比两张卡之间**（同一张图上过同一次色彩空间转换，差值抵消），
/// 绝不与写死的色值比 —— 离屏渲染的色彩空间换算会让写死的值必然失配。
/// ⚠️ 合成点击测不了（技能 `macos-ui-verify` 的「测不了三样」）——
/// 点了之后走什么流程由 `LaunchTodayPanelTests` 的行为用例钉。
@MainActor
final class ContinueLastButtonRenderTests: XCTestCase {

    private var window: NSWindow?
    private let canvas = CGSize(width: 440, height: 360)

    private struct Render {
        var rep: NSBitmapImageRep
        var scale: CGFloat
    }

    // MARK: - ① 没依据不画

    /// 反证：把 ChatView 里那句 `if canContinueLast` 删成「永远不画」→
    /// 两版变成同一张图、差异掉到噪声地板 → 红。
    func testNoContinuationDrawsNothing() throws {
        let off = try renderEmptyState(canContinueLast: false)
        let on = try renderEmptyState(canContinueLast: true)
        let changed = difference(off, on)
        XCTAssertGreaterThan(
            changed, 1500,
            "亮了「继续上次对话」时那一块必须真的画出来（实测只差 \(changed) 像素）"
        )
        // 同一份输入连渲两次应当完全一致（噪声地板）：差异本身这点波动要远小于
        // 「多一颗按钮」的量级，否则这条度量就是假的。
        let noise = difference(off, try renderEmptyState(canContinueLast: false))
        XCTAssertLessThan(noise, 60, "两次渲染同一输入应当一致（噪声地板 \(noise)）")
        XCTAssertGreaterThan(changed, noise * 10, "按钮的差异必须远大于渲染噪声")
    }

    /// 关掉时并非整屏空白 —— 空态（小动物 + 问候）照样在，
    /// 只是那颗按钮没画。漏了空态的话这条比谁都红。
    func testGuideCardStaysVisibleWithoutTheButton() throws {
        let off = try renderEmptyState(canContinueLast: false)
        XCTAssertGreaterThan(ink(off), 800, "没有「上次」时引导卡本身仍要画出来（实测 \(ink(off))）")
    }

    // MARK: - ② 窄聊天区不溢出

    /// 反证：把按钮的 `.frame(maxWidth:)` 改回定宽 `.frame(width:)` →
    /// 340pt 提案宽里卡片会探出来，右侧留白带上沾上卡面底色，这条红。
    func testNarrowContainerDoesNotOverflow() throws {
        let narrow = try renderEmptyState(canContinueLast: true, proposalWidth: AppLayoutMetrics.chatMinWidth)
        XCTAssertEqual(
            stripInk(narrow, from: 350, to: canvas.width - 5), 0,
            "提案宽只有 \(AppLayoutMetrics.chatMinWidth) 时，350pt 以右必须是留白 —— 按钮探出来了"
        )
        try dump(narrow, name: "round58-continue-last-narrow.png")
    }

    /// 常规宽度下的样子（留档人眼复核：按钮在问候下面、话题卡上面）。
    func testRegularWidthSnapshot() throws {
        let on = try renderEmptyState(canContinueLast: true, kickoffs: Self.twoCards)
        try dump(on, name: "round58-continue-last-button.png")
        XCTAssertGreaterThan(ink(on), 1500, "常规宽度下按钮 + 话题卡都要画出来（实测 \(ink(on))）")
    }

    // MARK: - ③ 底色与悬停色必须和话题卡是同一份（2026-10-14 第二次报障）

    /// 「继续上次对话」的**底色**要与话题卡完全一致。
    ///
    /// 报障原话：「把继续上次对话的按钮的背景色和 hover 选中换色改成和今天聊什么的按钮一致」。
    /// 之前它用强调色（accent）打底，同一屏里两种底色的卡并排，看着像两套控件。
    ///
    /// 反证：把 `continueLastButton` 的 `.fill(...)` 改回 `theme.accent.opacity(0.12)`
    /// → 两边众数色不同 → 红。
    func testButtonFillMatchesTheKickoffCard() throws {
        // 两帧各只有**一张**卡在场（按钮 / 话题卡），互不遮挡。
        // 底色一律用「有这块 vs 没这块」的差分取，避开空态居中和整帧背景两个坑。
        let buttonFill = try fillOfTheChangedArea(
            without: try renderEmptyState(canContinueLast: false),
            with: try renderEmptyState(canContinueLast: true)
        )
        let cardFill = try fillOfTheChangedArea(
            without: try renderEmptyState(canContinueLast: false),
            with: try renderEmptyState(canContinueLast: false, kickoffs: [Self.firstCard])
        )

        let distance = fillDistance(buttonFill, cardFill)
        XCTAssertLessThan(
            distance, 0.04,
            "两卡底色必须同一份（实测差 \(String(format: "%.3f", distance))）"
        )
        try dump(try renderEmptyState(canContinueLast: true), name: "round58-continue-last-idle.png")
    }

    /// **悬停色**同理，而且悬停必须真的换色（参数被无视的话这条红）。
    func testHoverTintMatchesTheKickoffCardAndReallyChangesTheFill() throws {
        let buttonIdle = try renderEmptyState(canContinueLast: true)
        let buttonHover = try renderEmptyState(
            canContinueLast: true, forcedHoveredContinueLast: true
        )
        let cardIdle = try renderEmptyState(canContinueLast: false, kickoffs: [Self.firstCard])
        let cardHover = try renderEmptyState(
            canContinueLast: false,
            kickoffs: [Self.firstCard],
            forcedHoveredKickoffID: Self.firstCard.id
        )

        let idleFill = try fillOfTheChangedArea(without: buttonIdle, with: buttonHover)
        let cardHoverFill = try fillOfTheChangedArea(without: cardIdle, with: cardHover)

        // 悬停后的底色与「不悬停」的底色必须**真的不同**（否则悬停参数被无视了）。
        let buttonIdleFill = try fillOfTheChangedArea(
            without: try renderEmptyState(canContinueLast: false),
            with: buttonIdle
        )
        let changed = fillDistance(buttonIdleFill, idleFill)
        XCTAssertGreaterThan(
            changed, 0.04,
            "悬停必须真的换底色（实测只差 \(String(format: "%.3f", changed))）—— 悬停参数被无视了？"
        )

        let distance = fillDistance(idleFill, cardHoverFill)
        XCTAssertLessThan(
            distance, 0.04,
            "悬停色必须与话题卡的悬停色一致（实测差 \(String(format: "%.3f", distance))）"
        )
        try dump(buttonHover, name: "round58-continue-last-hover.png")
    }

    // MARK: - 渲染与度量

    /// 空对话的对话区（引导卡那一屏）。
    private func renderEmptyState(
        canContinueLast: Bool,
        kickoffs: [KickoffSuggestion] = [],
        proposalWidth: CGFloat? = nil,
        forcedHoveredContinueLast: Bool = false,
        forcedHoveredKickoffID: String? = nil
    ) throws -> Render {
        let chat = makeChat()
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let savedAnimalAnimations = CuteAnimalView.animationsEnabled
        CuteAnimalView.animationsEnabled = false
        defer { CuteAnimalView.animationsEnabled = savedAnimalAnimations }

        let inner = proposalWidth ?? (canvas.width - 40)
        let host = NSHostingView(rootView: AnyView(
            ChatView(
                chat: chat,
                modelName: "mock-model",
                health: .connected(model: "mock-model"),
                teacherKind: .fox,
                studentKind: .rabbit,
                kickoffs: kickoffs,
                onKickoff: { _ in },
                forcedHoveredKickoffID: forcedHoveredKickoffID,
                canContinueLast: canContinueLast,
                onContinueLast: {},
                forcedHoveredContinueLast: forcedHoveredContinueLast
            )
            .frame(width: inner, alignment: .topLeading)
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
            .buttonStyle(.appPressable)
            .forestTheme(theme)
        ))
        host.frame = NSRect(origin: .zero, size: canvas)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let rep: NSBitmapImageRep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep, scale: CGFloat(rep.pixelsHigh) / max(canvas.height, 1))
    }

    /// 空会话的 `ChatService`（`:memory:` 库，不碰真实数据）：
    /// 走的是 false 那一档 config-less 路径，一条消息都没有 —— 空态判据才成立。
    private func makeChat() -> ChatService {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("alc-continue-last-\(UUID().uuidString).json")
        )
        return ChatService(services: CoachServices(config: store, databasePath: ":memory:"))
    }

    /// 两张图逐像素的差异数 —— 与 `ink` 不同，这张量的是「某块地方换了内容」。
    ///
    /// ⚠️ 判据含 alpha：视图没铺到的地方是**全透明**（`colorAt` 会给 0,0,0），
    /// 只比 RGB 的话「透明」会被当成纯黑，和任何底色都算「有差异」。
    private func difference(_ a: Render, _ b: Render) -> Int {
        let height = min(a.rep.pixelsHigh, b.rep.pixelsHigh)
        let width = min(a.rep.pixelsWide, b.rep.pixelsWide)
        var count = 0
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                guard let left = a.rep.colorAt(x: x, y: y), let right = b.rep.colorAt(x: x, y: y) else { continue }
                if left.alphaComponent == 0, right.alphaComponent == 0 { continue }
                if delta(left, right) > 0.08 { count += 1 }
            }
        }
        return count
    }

    /// 全图「与底色不同」的像素数（背景取左上角，那里永远是留白）。
    ///
    /// ⚠️ 全透明像素（视图没铺到）直接跳过：那是**没有内容**，不是「与底色不同」。
    private func ink(_ render: Render) -> Int {
        let rep = render.rep
        guard let background = rep.colorAt(x: 1, y: 1) else { return 0 }
        var count = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0 else { continue }
                if delta(color, background) > 0.08 { count += 1 }
            }
        }
        return count
    }

    /// 只数某一条**竖带**（pt 区间）里的「与底色不同」的像素数 ——
    /// `testNarrowContainerDoesNotOverflow` 专用：按钮探出提案宽时会在右侧留白带上
    /// 留下卡面底色，整图墨迹度量对这点宽度不敏感，竖带一量就露出来。
    private func stripInk(_ render: Render, from fromPt: CGFloat, to toPt: CGFloat) -> Int {
        let rep = render.rep
        guard let background = rep.colorAt(x: 1, y: 1) else { return 0 }
        let scale = render.scale
        let from = Int((fromPt * scale).rounded())
        let to = min(Int((toPt * scale).rounded()), rep.pixelsWide - 1)
        var count = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: from, to: to, by: 2) {
                guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0 else { continue }
                if delta(color, background) > 0.08 { count += 1 }
            }
        }
        return count
    }

    /// 两个像素的差异（含 alpha）。
    private func delta(_ left: NSColor, _ right: NSColor) -> CGFloat {
        abs(left.redComponent - right.redComponent)
            + abs(left.greenComponent - right.greenComponent)
            + abs(left.blueComponent - right.blueComponent)
            + abs(left.alphaComponent - right.alphaComponent)
    }

    /// 取「这张卡本身」的底色：在**有这块 / 没这块**两帧的差异像素里，数 `with` 那一帧的众数色。
    ///
    /// ⚠️ 为什么不直接数整帧众数，也不写死坐标（两次踩过的坑）：
    /// - 写死坐标必假失败 —— 空态是**垂直居中**的，卡片位置随内容多少浮动；
    /// - 整帧众数会被大块的空态背景吃掉 —— 实测两帧明明是不同的底色，众数却都取到背景色，
    ///   差 0.000，看着「一致」其实是**假绿**。
    ///
    /// 差分法两头都避开了：差异像素必然是卡片自己（底色 + 它内部的文字/图标），
    /// 其中底色占绝大多数，众数即是它。
    private func fillOfTheChangedArea(without: Render, with: Render) throws -> NSColor {
        let a = without.rep
        let b = with.rep
        let height = min(a.pixelsHigh, b.pixelsHigh)
        let width = min(a.pixelsWide, b.pixelsWide)
        var counts: [String: (n: Int, c: NSColor)] = [:]
        for y in stride(from: 0, to: height, by: 1) {
            for x in stride(from: 0, to: width, by: 1) {
                guard let left = a.colorAt(x: x, y: y),
                      let right = b.colorAt(x: x, y: y) else { continue }
                // 阈值压到 0.05：悬停换色是「浅底上再叠一层浅色」，差异本来就细。
                guard delta(left, right) > 0.05, right.alphaComponent > 0 else { continue }
                let key = String(
                    format: "%.2f %.2f %.2f",
                    right.redComponent, right.greenComponent, right.blueComponent
                )
                counts[key] = ((counts[key]?.n ?? 0) + 1, right)
            }
        }
        return try XCTUnwrap(
            counts.max(by: { $0.value.n < $1.value.n })?.value.c,
            "两帧之间没有任何差异像素 —— 这块内容根本没画出来？"
        )
    }

    /// 两个色值的距离（RGB 逐通道绝对差之和）—— 专门比「是不是同一份底色」。
    private func fillDistance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        abs(a.redComponent - b.redComponent)
            + abs(a.greenComponent - b.greenComponent)
            + abs(a.blueComponent - b.blueComponent)
    }

    private func dump(_ render: Render, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(render.rep.representation(using: .png, properties: [:]), "PNG 编码失败")
        try png.write(to: directory.appendingPathComponent(name))
    }

    // MARK: - 工装

    private static let firstCard = KickoffSuggestion(
        kind: .todayWord,
        title: "用今天这个词开口",
        detail: "resilient",
        action: .send(text: "Can you help me use the word \"resilient\" in a sentence?")
    )

    private static let secondCard = KickoffSuggestion(
        kind: .smallTalk,
        title: "不知道说什么？来这句",
        detail: "Can you help me order a coffee like a local?",
        action: .send(text: "Can you help me order a coffee like a local?")
    )

    private static var twoCards: [KickoffSuggestion] { [firstCard, secondCard] }
}
