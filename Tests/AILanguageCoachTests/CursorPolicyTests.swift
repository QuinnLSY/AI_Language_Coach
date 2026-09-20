import AIDomain
import AIInfrastructure
import AIServices
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 光标口径回归（#233 四轮定稿）。
///
/// 背景事故：划词卡片、选项圆圈、展开按钮上全是 I 型插入符。根因有两层：
/// ① `NSTextView` 默认给自己挂 I 型光标矩形，而 AppKit 在窗口级解析这些矩形时
/// **不理会视图遮挡** —— 按钮、卡片都在文本视图的矩形覆盖下；
/// ② 在卡片里垫箭头矩形**无效**：兄弟视图不在 `cursorUpdate` 的响应链上
/// （命中链只沿祖先走），实测四轮都没压住。
/// 定稿口径：整窗由 `CursorPolicy` 按**命中测试**裁决 —— 命中谁，谁说话。
@MainActor
final class CursorPolicyTests: XCTestCase {

    override func tearDown() {
        MainActor.assumeIsolated { CursorPolicy.resetAppliedMemory() }
        super.tearDown()
    }

    // MARK: 纯函数：命中视图 → 光标

    func testPlainViewGivesArrow() {
        XCTAssertTrue(CursorPolicy.cursor(forHitView: NSView()) === NSCursor.arrow)
        XCTAssertTrue(CursorPolicy.cursor(forHitView: nil) === NSCursor.arrow)
    }

    func testEditableTextViewKeepsIBeam() {
        let editor = NSTextView(frame: .zero)
        XCTAssertTrue(CursorPolicy.cursor(forHitView: editor) === NSCursor.iBeam, "输入框必须是插入符")
        let field = NSTextField(frame: .zero)
        XCTAssertTrue(CursorPolicy.cursor(forHitView: field) === NSCursor.iBeam, "单行输入框同理")
    }

    func testLookupTextViewFollowsItsOwnFlag() {
        let arrow = WordLookupTextView(frame: .zero)
        arrow.showsIBeamCursor = false
        XCTAssertTrue(CursorPolicy.cursor(forHitView: arrow) === NSCursor.arrow)

        let ibeam = WordLookupTextView(frame: .zero)
        ibeam.showsIBeamCursor = true
        XCTAssertTrue(CursorPolicy.cursor(forHitView: ibeam) === NSCursor.iBeam)
    }

    /// 命中链要往上走：命中的是文本视图的**子视图**（辅助视图）时也得认得出来。
    func testChildViewInheritsOwnerRule() {
        let owner = WordLookupTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        owner.showsIBeamCursor = false
        let child = NSView(frame: NSRect(x: 10, y: 10, width: 40, height: 20))
        owner.addSubview(child)
        XCTAssertTrue(CursorPolicy.cursor(forHitView: child) === NSCursor.arrow)
    }

    /// 声明了偏好的视图（自绘弹菜单命中区）优先于「文本 / 箭头」默认口径。
    func testPreferenceWinsOverDefaults() {
        final class PreferringView: NSView, CursorPreferenceProviding {
            var desiredCursor: NSCursor { .pointingHand }
        }
        let view = PreferringView(frame: .zero)
        XCTAssertTrue(CursorPolicy.cursor(forHitView: view) === NSCursor.pointingHand)
    }

    /// 事故的核心语义：正文（I 型）上面盖着卡片时，**卡片说话**。
    func testOverlappingCardBeatsTextBelowIt() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let text = WordLookupTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        text.showsIBeamCursor = true
        container.addSubview(text)
        let card = NSView(frame: NSRect(x: 20, y: 30, width: 120, height: 50))
        container.addSubview(card)

        let inCard = NSPoint(x: 60, y: 50)
        let hitInCard = container.hitTest(inCard)
        XCTAssertTrue(hitInCard === card, "卡片压在正文上时命中的必须是卡片")
        XCTAssertTrue(CursorPolicy.cursor(forHitView: hitInCard) === NSCursor.arrow)

        let inText = NSPoint(x: 250, y: 10)
        XCTAssertTrue(CursorPolicy.cursor(forHitView: container.hitTest(inText)) === NSCursor.iBeam)
    }

    // MARK: 命中坐标系（#233 第五轮的真根因）

    /// `NSView.hitTest(_:)` 的入参是**父视图的坐标系**，不是自己的 —— 与 UIKit 的
    /// `UIView.hitTest(_:with:)`（自己的坐标系）恰好相反，想当然就会写错。
    ///
    /// SwiftUI 的宿主内容视图是 flipped（y 自上而下），而它的父视图 `NSThemeFrame` 不是：
    /// 把「内容视图自身坐标」直接喂给 `hitTest` 会得到**沿竖直中线镜像**的那个点 ——
    /// 鼠标在题干上、命中的却是正文，于是光标全靠运气（连续五轮「改了没生效」的真原因）。
    func testHitTestExpectsSuperviewCoordinates() {
        final class FlippedView: NSView {
            override var isFlipped: Bool { true }
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        let content = FlippedView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        window.contentView = content
        // flipped 坐标系里「离顶 100」处放一块可命中的子视图。
        let target = NSView(frame: NSRect(x: 50, y: 100, width: 100, height: 40))
        content.addSubview(target)

        // 窗口坐标（非 flipped，原点在左下）：离顶 120（子视图竖向中心）处。
        let windowPoint = NSPoint(x: 100, y: 600 - 120)
        let hit = CursorPolicy.hitTest(in: content, atWindowPoint: windowPoint)
        XCTAssertTrue(hit === target, "命中点被竖直镜像了：拿到的不是「离顶 120」处那个视图")

        // 反过来，直接喂内容视图自身坐标（老写法）就会镜像 —— 这条断言把坑钉住。
        let mirrored = content.hitTest(NSPoint(x: 100, y: 120))
        XCTAssertFalse(mirrored === target, "旧写法本该是错的，这里却在正确位置命中了")
    }

    // MARK: 真实阅读页：只有正文保留 I 型

    private func makeReadingState() async -> AppState {
        let services = CoachServices(
            config: ConfigStore(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("cursor-policy-\(UUID().uuidString).json")),
            databasePath: ":memory:"
        )
        let passage = ReadingPassage(
            title: "Probe Passage",
            text: Array(repeating: "Marco bakes bread when it rains and the air is moist outside.", count: 12)
                .joined(separator: " "),
            questions: (0..<2).map { index in
                ReadingQuestion(
                    prompt: "What does Marco do when it rains? (\(index + 1))",
                    options: ["adds more water", "uses a longer fermentation time"],
                    correctIndex: 1,
                    quote: "Marco bakes bread when it rains.",
                    explain: "雨天湿度大。",
                    trap: "别把晴天做法套过来。"
                )
            },
            dayKey: WritingTopicPicker.dayKey(for: Date())
        )
        await services.saveReading(StoredReading(passage: passage, createdAt: Date()))
        let state = AppState(services: services)
        state.showingReading = true
        await state.openReading()
        return state
    }

    /// 阅读页里「除正文外全是箭头」：这条口径直接钉在视图开关上。
    func testReadingPageOnlyPassageKeepsIBeam() async throws {
        let state = await makeReadingState()
        try XCTSkipIf(state.readingPassage == nil, "没有短文就不校验口径")

        let host = NSHostingView(rootView: AnyView(ReadingView(state: state)))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 900)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        var textViews: [WordLookupTextView] = []
        func walk(_ view: NSView) {
            if let text = view as? WordLookupTextView { textViews.append(text) }
            for child in view.subviews { walk(child) }
        }
        walk(host)

        XCTAssertFalse(textViews.isEmpty, "阅读页得真有文本视图")
        // 正文 = 唯一关掉悬停划词的那个（`hoverLookupEnabled: false`）。
        let passages = textViews.filter { !$0.isHoverLookupEnabled }
        XCTAssertEqual(passages.count, 1, "正文只该有一处")
        for text in textViews {
            XCTAssertEqual(
                text.showsIBeamCursor, !text.isHoverLookupEnabled,
                "只有正文保留 I 型，其余全箭头：\(text.string.prefix(24))"
            )
        }
    }

    /// 窗口级联动：策略真的能把光标落到窗口上（正文 I 型、选项行右缘箭头）。
    func testPolicyAppliesToWindow() async throws {
        let state = await makeReadingState()
        try XCTSkipIf(state.readingPassage == nil, "没有短文就不校验口径")

        let host = NSHostingView(rootView: AnyView(ReadingView(state: state)))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 900)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        var passage: WordLookupTextView?
        var option: WordLookupTextView?
        var prompt: WordLookupTextView?
        func walk(_ view: NSView) {
            if let text = view as? WordLookupTextView {
                // 正文 = 关掉悬停划词那位；其余按首句取「题干 / 选项行」样本。
                if text.isHoverLookupEnabled {
                    if text.string.hasPrefix("What does Marco") { prompt = prompt ?? text }
                    option = option ?? text
                } else {
                    passage = text
                }
            }
            for child in view.subviews { walk(child) }
        }
        walk(host)

        // ⚠️ 断言的是**策略裁决**而不是 `NSCursor.current`：测试进程里没有活动窗口，
        // 系统不理会 `set()`，读回来的永远是默认值（实测）。真实光标由截屏验证。
        // ⚠️ 命中点必须走 `CursorPolicy.hitTest`（内含「换算到父视图坐标系」这一步），
        // 直接 `contentView.hitTest(自身坐标)` 会竖直镜像 —— 那正是要防的坑。
        func decision(at windowPoint: CGPoint) -> NSCursor {
            guard let content = window.contentView else { return .arrow }
            return CursorPolicy.cursor(
                forHitView: CursorPolicy.hitTest(in: content, atWindowPoint: windowPoint)
            )
        }

        let passageView = try XCTUnwrap(passage)
        let center = passageView.convert(
            NSPoint(x: passageView.bounds.midX, y: passageView.bounds.midY), to: nil
        )
        XCTAssertTrue(decision(at: center) === NSCursor.iBeam, "正文中部应是插入符")

        // 选项行右侧（✓ / ✕ 标记那一带）：不是文本视图，必须是箭头。
        let optionView = try XCTUnwrap(option)
        let rightOfOption = optionView.convert(
            NSPoint(x: optionView.bounds.maxX + 14, y: optionView.bounds.midY), to: nil
        )
        XCTAssertTrue(decision(at: rightOfOption) === NSCursor.arrow, "选项行右侧按钮区必须是箭头")

        // 题干行右端（展开 / 收起箭头那一带）同理 —— 用户实测报障的就是这里。
        let promptView = try XCTUnwrap(prompt)
        let rightOfPrompt = promptView.convert(
            NSPoint(x: promptView.bounds.maxX + 14, y: promptView.bounds.midY), to: nil
        )
        XCTAssertTrue(decision(at: rightOfPrompt) === NSCursor.arrow, "展开 / 收起按钮处必须是箭头")

        // 走一遍完整入口（守卫用的就是这个），确认不炸。
        CursorPolicy.resetAppliedMemory()
        CursorPolicy.apply(in: window, atWindowPoint: rightOfOption)
    }
}
