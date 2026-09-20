import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 「展开的黑板**必须待在老师角落自己的 frame 里**」这条不变量的回归。
///
/// 为什么是这条：板曾经挂在座位的 `overlay` 上，而座位只有 `BlackboardLayout.seatHeight`
/// 那么高（109pt），板整个跑到座位 frame **之外**；座位身上又套着
/// `.contentShape(Rectangle())` —— 按 SwiftUI 的语义（Ole Begemann 在 macOS 13 上实测过），
/// `contentShape` 会把**整棵子树**的命中区裁成那个矩形。两者一叠加：
/// 板画得出来、任务行和右上角那两个按钮却**一个都点不到**（用户实测「点击无反应」）。
///
/// 命中本身没法离屏断言（`NSHostingView.hitTest` 对任何位置都返回宿主视图），
/// 但「板有没有跑出容器」是可量的 —— 而这正是当初坏掉的那一环：
/// 修好之后角落的 frame 与侧栏同高，板和气泡都在界内。
@MainActor
final class BlackboardContainmentTests: XCTestCase {

    private var window: NSWindow?

    private let canvasWidth: CGFloat = 196
    /// 侧栏那点高度：板（约 200~380pt）加板底偏移都得装得下。
    private let canvasHeight: CGFloat = 700

    private func plan() -> DailyPlan {
        let specs: [(DailyTask.Kind, Int, String)] = [
            (.conversation, 4, "轮"), (.shadowing, 3, "次"), (.review, 8, "个词"),
        ]
        return DailyPlan(
            day: Date(),
            tasks: specs.enumerated().map { index, spec in
                DailyTask(
                    kind: spec.0, title: "做 \(spec.1) \(spec.2)",
                    reason: index == 0 ? "每日目标 15 分钟，今天还没开口" : "有 \(spec.1) \(spec.2) 到期",
                    target: spec.1, progress: 0, unit: spec.2
                )
            }
        )
    }

    /// 把量出来的 frame 带出视图：`@State` 外面读不到，用个小对象接。
    @Observable
    final class Measurements {
        var corner: CGRect = .zero
        var board: CGRect = .zero
    }

    private struct Harness: View {
        let plan: DailyPlan
        let width: CGFloat
        let height: CGFloat
        let measurements: Measurements
        @State private var isExpanded: Bool

        init(plan: DailyPlan, width: CGFloat, height: CGFloat, expanded: Bool, measurements: Measurements) {
            self.plan = plan
            self.width = width
            self.height = height
            self.measurements = measurements
            self._isExpanded = State(initialValue: expanded)
        }

        var body: some View {
            // 与侧栏里一样：座位贴底，上面是留给板的空间。
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                TeacherCorner(
                    kind: .fox,
                    isSleeping: false,
                    todayTokens: 12_345,
                    plan: plan,
                    streakDays: 5,
                    due: 6,
                    reviewedToday: 2,
                    bubblesAllowed: false,
                    isExpanded: $isExpanded
                )
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .allowsHitTesting(false)
                            .onAppear { measurements.corner = proxy.frame(in: .global) }
                            .onChange(of: proxy.frame(in: .global)) { _, new in measurements.corner = new }
                    }
                )
            }
            .frame(width: width, height: height)
        }
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews {
            if let found = firstScrollView(in: sub) { return found }
        }
        return nil
    }

    /// 渲染一次并回报：角落自己的 frame、板上那个 `NSScrollView` 的 frame（都换成 SwiftUI 全局坐标）。
    /// 收起态没有板，`board` 为 nil。
    private func measure(expanded: Bool) throws -> (corner: CGRect, board: CGRect?) {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let measurements = Measurements()
        let host = NSHostingView(rootView: AnyView(
            Harness(
                plan: plan(), width: canvasWidth, height: canvasHeight,
                expanded: expanded, measurements: measurements
            )
            .forestTheme(theme)
        ))
        host.frame = NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        // 板的高度是「量出来 → 再定高」的两趟布局，还要等弹簧走完。
        for _ in 0..<12 {
            host.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
        }

        let scroll = firstScrollView(in: host)
        guard let scroll else { return (measurements.corner, nil) }
        let inWindow = scroll.convert(scroll.bounds, to: nil)
        // AppKit 的窗口坐标原点在左下，SwiftUI 的全局坐标原点在左上。
        let board = CGRect(
            x: inWindow.minX, y: canvasHeight - inWindow.maxY,
            width: inWindow.width, height: inWindow.height
        )
        return (measurements.corner, board)
    }

    func testCollapsedCornerFitsInsideTheCanvas() throws {
        let (corner, board) = try measure(expanded: false)
        print("[容器] 收起：角落 \(corner)")
        XCTAssertEqual(corner.width, canvasWidth, accuracy: 1, "收起态角落该占满容器宽")
        XCTAssertNil(board, "收起态不该有展开的板")
    }

    /// 核心断言：展开的板必须在角落自己的 frame 之内（不跑出去 = 点得到）。
    func testExpandedBoardStaysInsideTheCornerFrame() throws {
        let (corner, measuredBoard) = try measure(expanded: true)
        let board = try XCTUnwrap(measuredBoard, "展开态没画板")
        print("[容器] 展开：角落 \(corner) 板 \(board)")
        XCTAssertGreaterThan(corner.height, 300, "角落要撑满容器（只装座位就装不下板）")
        XCTAssertGreaterThanOrEqual(
            board.minY, corner.minY - 1,
            "板顶跑到角落 frame 之上 \(corner.minY - board.minY)pt —— 溢出容器就点不到"
        )
        XCTAssertLessThanOrEqual(
            board.maxY, corner.maxY + 1,
            "板底跑到角落 frame 之下 \(board.maxY - corner.maxY)pt"
        )
    }
}
