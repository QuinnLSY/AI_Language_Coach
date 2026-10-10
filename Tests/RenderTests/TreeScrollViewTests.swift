import AIDomain
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 「开屏把学员摆到一眼看得见的位置」—— **真的滚一遍**的回归。
///
/// 用户报障（09-18）：每次打开应用，右边栏大树没把学员小动物摆到可见处，
/// 它缩在底部林间地面带后面。根子是**滚动被内容底边钳住**（细节见 `TreeViewport`）。
///
/// 为什么要挂进窗口测，而不是只测纯函数：纯函数只能证明算式对不对，
/// 证明不了「视图照做了」—— 上一轮就是算式看着对、实机没生效。这里把
/// `TreeScrollView` 挂进一个**已知高度**的窗口，直接读 `NSScrollView` 的真实滚动位置。
@MainActor
final class TreeScrollViewTests: XCTestCase {

    private var window: NSWindow?
    private let panelWidth: CGFloat = 340

    // MARK: - 挂窗口

    private func seed(climb: Double) -> LearnerProgress {
        var progress = LearnerProgress.seed()
        progress.climbFraction = climb
        return progress
    }

    /// 把 `TreeScrollView` 挂进一个 `panelWidth × viewportHeight` 的窗口，等它把开屏滚动做完。
    private func host(viewportHeight: CGFloat, climb: Double) async throws -> NSScrollView {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let host = NSHostingView(rootView: AnyView(
            TreeScrollView(theme: theme, progress: seed(climb: climb))
                .forestTheme(theme)
                .frame(width: panelWidth, height: viewportHeight)
        ))
        host.frame = NSRect(x: 0, y: 0, width: panelWidth, height: viewportHeight)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        // `.task` 里除了首帧那次，还有一拍 80ms 的补滚 —— 等它跑完再断言。
        try await Task.sleep(for: .milliseconds(600))
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        return try XCTUnwrap(Self.firstScrollView(in: host), "没找到 ScrollView")
    }

    /// 真实滚动量：内容相对视口往上移动了多少点（SwiftUI 的文档视图是翻转坐标，从顶算）。
    private func scrolledOffset(_ scroll: NSScrollView) -> CGFloat {
        scroll.contentView.bounds.origin.y
    }

    // MARK: - ① 全新学员（进度 0，学员压在树底）—— 报障现场

    func testFreshLearnerIsScrolledUpAboveTheGroundBand() async throws {
        let height: CGFloat = 735
        let scroll = try await host(viewportHeight: height, climb: 0)

        let offset = scrolledOffset(scroll)
        let target = TreeViewport.learnerTargetY(viewportHeight: height)
        let learnerContentY = TreeScrollView.topPadding + TreeCanvas.learnerY(for: 0, progress: seed(climb: 0))
        let learnerViewportY = learnerContentY - offset

        XCTAssertGreaterThan(
            offset, 0,
            "全新学员站在树底，视口必须真的往上滚一段；实测滚动量 \(offset)pt（= 没滚）"
        )
        XCTAssertEqual(
            learnerViewportY, target, accuracy: 6,
            "学员最终落在视口的 \(learnerViewportY)pt 处，目标该是 \(target)pt —— 又被内容底边钳住了"
        )
        XCTAssertLessThanOrEqual(
            target + 32, height - TreeViewport.groundBandHeight,
            "学员的脚（\(target + 32)pt）必须露在林带上沿（\(height - TreeViewport.groundBandHeight)pt）之上"
        )
    }

    /// 内容底部必须补出足够的留白，滚动才够得着目标位置。
    func testContentCarriesTheBottomPaddingThatMakesItReachable() async throws {
        let height: CGFloat = 735
        let scroll = try await host(viewportHeight: height, climb: 0)

        let expected = TreeScrollView.topPadding
            + TreeCanvas.canvasHeight(for: seed(climb: 0))
            + TreeViewport.bottomPadding(viewportHeight: height, climbFraction: 0, progress: seed(climb: 0))
        let actual = scroll.documentView?.frame.height ?? 0
        XCTAssertEqual(
            actual, expected, accuracy: 6,
            "内容总高 \(actual)pt，应当是 顶距 + 画布 + 底部留白 = \(expected)pt"
        )
        XCTAssertGreaterThan(
            TreeViewport.bottomPadding(viewportHeight: height, climbFraction: 0, progress: seed(climb: 0)), 0,
            "全新学员压在树底时必须补底部留白"
        )
    }

    // MARK: - ② 已经爬上去的学员：不越滚，同样停在林带之上

    func testClimbedLearnerStaysVisibleWithoutOverScrolling() async throws {
        let height: CGFloat = 735
        let scroll = try await host(viewportHeight: height, climb: 0.6)

        let offset = scrolledOffset(scroll)
        let target = TreeViewport.learnerTargetY(viewportHeight: height)
        let learnerViewportY = TreeScrollView.topPadding + TreeCanvas.learnerY(for: 0.6, progress: seed(climb: 0.6)) - offset

        XCTAssertGreaterThanOrEqual(
            offset, 0,
            "滚动量不能是负的（内容顶部不该被顶出视口）"
        )
        // 学员已经爬得够高时本来就不需要滚（内容顶部已经在视口顶了），
        // 所以这里钉的是「不许比他该在的位置更低」——低了就往林带那边沉。
        XCTAssertLessThanOrEqual(
            learnerViewportY, target + 8,
            "学员落在视口 \(learnerViewportY)pt，比目标线 \(target)pt 还低"
        )
        XCTAssertLessThanOrEqual(
            learnerViewportY + 32, height - TreeViewport.groundBandHeight,
            "学员的脚（\(learnerViewportY + 32)pt）必须露在林带之上（\(height - TreeViewport.groundBandHeight)pt）"
        )
        XCTAssertEqual(
            TreeViewport.bottomPadding(viewportHeight: height, climbFraction: 0.6, progress: seed(climb: 0.6)), 0, accuracy: 0.001,
            "学员已经爬高，底部不该再补留白"
        )
    }

    // MARK: - ③ 视口很矮时也不能把学员推出屏幕

    func testShortViewportKeepsTheLearnerOnScreen() async throws {
        let height: CGFloat = 420
        let scroll = try await host(viewportHeight: height, climb: 0)

        let offset = scrolledOffset(scroll)
        let learnerViewportY = TreeScrollView.topPadding + TreeCanvas.learnerY(for: 0, progress: seed(climb: 0)) - offset
        XCTAssertGreaterThanOrEqual(learnerViewportY, 0, "学员被滚到视口上方去了")
        XCTAssertLessThanOrEqual(
            learnerViewportY + 32, height - TreeViewport.groundBandHeight,
            "学员的脚沉进林带了（视口 \(height)）"
        )
    }

    // MARK: - 小件

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }
}
