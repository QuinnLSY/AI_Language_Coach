import AppKit
import CoreGraphics
@testable import AppUI
import XCTest

/// 划词气泡挡住滚动：滚轮该转交给谁（纯判据）。
///
/// 实测报障：鼠标停在气泡上时页面滚不动。气泡是挂在滚动容器之外的兄弟浮层，
/// 它一吃事件，下面的 `ScrollView` 就永远收不到滚轮 —— 于是要替它找「下方那个滚动视图」。
final class ScrollWheelRoutingTests: XCTestCase {

    /// 候选里只有盖住鼠标点、而且真的能纵向滚的才算数。
    func testSkipsCandidatesThatMissThePointer() {
        let index = ScrollWheelRouting.bestIndex(
            contains: [false, true],
            scrollsVertically: [true, true],
            depth: [0, 1]
        )
        XCTAssertEqual(index, 1, "鼠标不在里面的容器不该被选中")
    }

    /// ⚠️ 这条是重点：**能纵向滚**优先于**更深**。
    ///
    /// 气泡下面常常压着一个只会横向滚的容器（推荐词条、横向 chip），它比外层的纵向滚动区更深。
    /// 若只按深度挑，纵向滚轮就被丢给横向容器了 —— 用户看到的就是「滚不动」。
    func testPrefersVerticallyScrollableOverDeeper() {
        let index = ScrollWheelRouting.bestIndex(
            contains: [true, true],
            scrollsVertically: [true, false],
            depth: [0, 5]
        )
        XCTAssertEqual(index, 0, "横向容器更深也不许抢纵向滚轮")
    }

    /// 都是纵向滚动区时，取最深的那个（里层的，而不是包着它的那一层）。
    func testPicksDeepestAmongScrollable() {
        let index = ScrollWheelRouting.bestIndex(
            contains: [true, true, true],
            scrollsVertically: [true, true, true],
            depth: [0, 2, 1]
        )
        XCTAssertEqual(index, 1)
    }

    /// 一个能纵向滚的目标都没有 → 不介入，事件原样放行。
    ///
    /// 宁可什么都不做，也不能乱吃事件：把别人的滚动（横向、或压根没有滚动）吃掉，
    /// 只会换一种「滚不动」。
    func testDoesNotInterveneWhenNothingScrollsVertically() {
        XCTAssertNil(ScrollWheelRouting.bestIndex(
            contains: [true, true],
            scrollsVertically: [false, false],
            depth: [0, 1]
        ))
        XCTAssertNil(ScrollWheelRouting.bestIndex(
            contains: [], scrollsVertically: [], depth: []
        ))
    }
}

/// 判据之上那步「在真实视图树里找目标」也要验：纯函数对了、
/// 树遍历写错（比如拿 `frame` 当 `bounds` 用、或把隐藏的视图也算上）一样是白搭。
@MainActor
final class ScrollWheelTargetLookupTests: XCTestCase {

    private func window() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        return window
    }

    /// 外层能纵向滚、里层（更深）只会横向滚 → 必须选外层。
    func testLookupPrefersOuterVerticalScrollViewOverDeeperHorizontalOne() throws {
        let window = window()
        let root = try XCTUnwrap(window.contentView)

        let outer = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        outer.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 3000))
        root.addSubview(outer)

        // 更深，但内容与视口一样高 —— 纵向滚不动。
        let inner = NSScrollView(frame: NSRect(x: 20, y: 20, width: 200, height: 40))
        inner.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 40))
        outer.addSubview(inner)
        root.layoutSubtreeIfNeeded()

        let overInner = NSPoint(x: 100, y: 40)
        XCTAssertTrue(
            ScrollWheelPassthrough.Coordinator.scrollTarget(at: overInner, in: window) === outer,
            "横向容器再深也不该抢走纵向滚轮"
        )
        XCTAssertNil(
            ScrollWheelPassthrough.Coordinator.scrollTarget(
                at: NSPoint(x: 2_000, y: 2_000), in: window
            ),
            "点根本不在任何滚动区上时不要乱认一个目标"
        )
    }

    /// 视口内只有一个「内容比视口高」的滚动区时才认得出来；全都滚不动就返回 nil（不介入）。
    func testLookupIgnoresScrollViewsThatCannotScrollVertically() throws {
        let window = window()
        let root = try XCTUnwrap(window.contentView)

        let flat = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        flat.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 120))
        root.addSubview(flat)
        root.layoutSubtreeIfNeeded()

        XCTAssertNil(
            ScrollWheelPassthrough.Coordinator.scrollTarget(at: NSPoint(x: 300, y: 200), in: window),
            "滚不动的滚动区不该被当成目标"
        )
    }
}
