import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 四季飞鸟群的离屏渲染回归（2026-10-23）。
///
/// 判据走**区域墨迹差**，不比色值（离屏过色彩空间换算）：
/// - 鸟群必须**画在上三分之一**（上带有差异、下带零差异）——飞到中间就是挡住树的贴纸；
/// - 四季四种鸟都画得出来，且**互不相同**（换色 = 季节白分）；
/// - 静态档两遍零差异（队形与姿态是纯函数，不许抖）；
/// - `reduceMotion` 下**冻结但还在**（关动效不许做成关内容）；
/// - 夜里也画得出来（夜空极暗，深剪影会糊掉 —— 所以夜里是提亮的那档色）。
@MainActor
final class ForestBirdsRenderTests: XCTestCase {

    private var window: NSWindow?

    private struct Render {
        var rep: NSBitmapImageRep
        var scale: CGFloat
    }

    /// 画布尺寸 = **两栏之和**的横向比例、整窗高的纵向比例。
    ///
    /// ⚠️ 高度带（上三分之一）的基准是 `windowHeight`（整窗高），而这一层的画布
    /// 只有窗高的 1/3 —— 这里传进去的 `windowHeight` 就是整画布高，
    /// 与真机上「画布 = 窗高/3、windowHeight = 窗高」是同一个比例关系。
    private let canvas = CGSize(width: 900, height: 760)
    private let layerHeight: CGFloat = 760.0 / 3

    private func makeHost(_ view: some View, size: CGSize) throws -> Render {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep, scale: CGFloat(rep.pixelsHigh) / max(size.height, 1))
    }

    /// 同一块白底上，画鸟群 / 不画鸟群。
    ///
    /// ⚠️ `still: true`（静态档）：鸟群在冻结档停在最远点，整群全在画面里 ——
    /// 不用 `still` 的话渲染到的进度取决于跑测试的那一刻，判据会偶发假绿。
    ///
    /// ⚠️ 例外是减弱动效那条：它要验的正是「**只靠 reduceMotion** 也能冻住」，
    /// 所以那里传 `still: false` —— 传 `true` 的话冻结是由 `still` 造成的，
    /// 判据连「reduceMotion 有没有被读」都验不到（实测：那样改坏也不红）。
    private func scene(kind: BirdKind, theme: ForestTheme,
                       reduceMotion: Bool = false, still: Bool = true,
                       birds: Bool = true,
                       ambientElapsed: Double? = nil) throws -> Render {
        var view: AnyView = AnyView(
            ZStack {
                Color.white
                if birds {
                    ForestSeasonBirds(
                        theme: theme, kind: kind, still: still,
                        windowHeight: canvas.height
                    )
                }
            }
            .environment(\.appMotion, AppMotionDescriptor(reduceMotion: reduceMotion,
                                                          reduceTransparency: true))
        )
        if let ambientElapsed {
            // 注入统一氛围钟并拨到指定相位（#651）：飞鸟层从此读环境里的 elapsed，
            // 不再自己起表。不注入时（其余各条用例）它退回自己起表的老路。
            let clock = ForestAmbientClock()
            clock.seed(elapsed: ambientElapsed)
            view = AnyView(view.environment(\.forestAmbientClock, clock))
        }
        return try makeHost(
            view.frame(width: canvas.width, height: layerHeight),
            size: CGSize(width: canvas.width, height: layerHeight)
        )
    }

    /// 两帧在给定区域内的不同像素个数（换算回点；nil = 整帧）。
    private func differencePoints(_ lhs: Render, _ rhs: Render, in rect: CGRect? = nil) -> Int {
        guard let a = lhs.rep.bitmapData, let b = rhs.rep.bitmapData else { return 0 }
        let width = lhs.rep.pixelsWide, height = lhs.rep.pixelsHigh
        let scale = lhs.scale
        let pixelRange: (x: Range<Int>, y: Range<Int>)
        if let rect {
            pixelRange = (
                x: Int(rect.minX * scale)..<min(Int(rect.maxX * scale), width),
                y: Int(rect.minY * scale)..<min(Int(rect.maxY * scale), height)
            )
        } else {
            pixelRange = (x: 0..<width, y: 0..<height)
        }
        var count = 0
        for y in pixelRange.y {
            for x in pixelRange.x {
                let o = (y * width + x) * 4
                if abs(Int(a[o]) - Int(b[o])) > 8
                    || abs(Int(a[o + 1]) - Int(b[o + 1])) > 8
                    || abs(Int(a[o + 2]) - Int(b[o + 2])) > 8 {
                    count += 1
                }
            }
        }
        return Int(Double(count) / (scale * scale))
    }

    private func theme(isNight: Bool = false) -> ForestTheme {
        // 鸟群自己不判季节（季节由 `MainView` 的挂载点判），这里只给日夜。
        ForestTheme(palette: isNight ? .night : .day, season: .autumn)
    }

    // MARK: - 位置上三分之一

    /// 鸟群画在该画的那一段：带内有墨迹、带外零差异。
    ///
    /// ⚠️ 画布高只有窗高的 1/3，而高度带的基准是**整窗高**（`windowHeight`）——
    /// 所以窗高 0.08…0.26 这一带换算到画布上是 0.24…0.78，加上队形外张与
    /// ±9pt 慢漂之后，实际落在画布的 0.30…0.70 一带。**别拿「画布的三分之一」
    /// 当带**（那是把基准搞反了，判据会一条都不中）。
    /// 真正的「不许飞到树冠那一带」由单测 `testEveryBirdStaysInTheTopThird` 钉。
    ///
    /// 反证（已实测）：把 `FlockLayout.altitude` 改成 0.6 → 整群落到窗高 60% 处
    /// （画布 1.8，直接出画布）→ 红在「带内没有鸟」。
    func testBirdsDrawnInsideTheSkyBand() throws {
        let withBirds = try scene(kind: .goose, theme: theme())
        let without = try scene(kind: .goose, theme: theme(), birds: false)
        let band = CGRect(x: 0, y: layerHeight * 0.25, width: canvas.width, height: layerHeight * 0.55)
        let beyond = CGRect(x: 0, y: layerHeight * 0.90,
                            width: canvas.width, height: layerHeight * 0.10)
        XCTAssertGreaterThan(differencePoints(withBirds, without, in: band), 40,
                             "该画鸟的那一段没有鸟（没画上去或画太小）")
        XCTAssertEqual(differencePoints(withBirds, without, in: beyond), 0,
                       "鸟飞到高度带之外去了")
    }

    // MARK: - 四季四种鸟

    /// 四季四种鸟都画得出来。
    func testAllFourKindsRender() throws {
        for kind in BirdKind.allCases {
            let frame = try scene(kind: kind, theme: theme())
            let blank = try scene(kind: kind, theme: theme(), birds: false)
            XCTAssertGreaterThan(differencePoints(frame, blank), 30,
                                 "\(kind.rawValue)：这一季根本没画出鸟来")
        }
    }

    /// 四种鸟的**墨迹面积**两两不同（与颜色无关的指纹）。
    ///
    /// ⚠️ 为什么不能比「两帧之间的差异」：羽色本来就按季节给（白鹭是白的、
    /// 家燕是黑的），比两帧的话，**把四季造型统一成同一种、只换色**也照样绿 ——
    /// 那正是「季节白分」的毛病（2026-10-23 实测踩到：四季全走雁造型，
    /// 那条判据 0 失败）。比「各自与空白底的差异面积」才与颜色无关，
    /// 只反映造型 + 队形 + 体型。
    func testTheFourKindsLeaveDifferentInkFootprints() throws {
        var ink: [BirdKind: Int] = [:]
        for kind in BirdKind.allCases {
            let frame = try scene(kind: kind, theme: theme())
            let blank = try scene(kind: kind, theme: theme(), birds: false)
            ink[kind] = differencePoints(frame, blank)
        }
        let sorted = BirdKind.allCases.compactMap { ink[$0] }.sorted()
        for index in sorted.indices {
            for other in sorted.indices where other > index {
                let lo = Double(sorted[index]), hi = Double(sorted[other])
                XCTAssertGreaterThan(hi, lo * 1.05,
                                     "有两种鸟的墨迹面积几乎一样（\(sorted[index]) vs "
                                       + "\(sorted[other])）—— 造型 / 队形 / 体型没分开")
            }
        }
    }

    /// 四季四种鸟**两两不同**（画面指纹，含颜色）。
    ///
    /// 反证：把 `BirdBody` 的 switch 里三季都走 goose 分支 → 红在「两两不同」。
    func testAllFourKindsLookDifferent() throws {
        var frames: [BirdKind: Render] = [:]
        for kind in BirdKind.allCases {
            frames[kind] = try scene(kind: kind, theme: theme())
        }
        let kinds = BirdKind.allCases
        for index in kinds.indices {
            for other in kinds.indices where other > index {
                let lhs = try XCTUnwrap(frames[kinds[index]])
                let rhs = try XCTUnwrap(frames[kinds[other]])
                XCTAssertGreaterThan(differencePoints(lhs, rhs), 20,
                                     "\(kinds[index].rawValue) 与 \(kinds[other].rawValue) "
                                       + "画出来是一样的（换色不分季节）")
            }
        }
    }

    // MARK: - 确定性

    /// 静态档渲染两遍零差异（队形与姿态是纯函数）。
    func testStillFrameIsDeterministic() throws {
        let first = try scene(kind: .egret, theme: theme())
        let second = try scene(kind: .egret, theme: theme())
        XCTAssertEqual(differencePoints(first, second), 0, "静态档不许有任何抖动")
    }

    // MARK: - 减弱动效

    /// `reduceMotion`：鸟群**还在**（不许做成关内容），且走冻结档。
    ///
    /// ⚠️ 走 `still: false`：冻结必须由 `reduceMotion` 单独造成，否则验的只是
    /// 「传了 still 就冻」。
    ///
    /// ⚠️ 判据是「与静态档**同一个姿态**」而不是「两遍一致」：离屏窗口里
    /// `TimelineView` 并不推进相位（实测：把 `frozen` 改坏后连拍两遍仍然一致，
    /// 那条断言是假绿）。拿已知冻结的静态档当尺，跑动档（进度 ≈ 0.18，
    /// 头鸟刚进场）与最远点一眼就能分开。
    ///
    /// 反证（已实测）：把组件里 `frozen` 的 `|| motion.reduceMotion` 删掉 →
    /// 红在「必须走冻结档」。
    /// 第一条（还在）的反证是另一回事：给 body 加
    /// `guard !motion.reduceMotion else { return AnyView(EmptyView()) }` → 红在第一条。
    func testReduceMotionKeepsBirdsFrozen() throws {
        let reduced = try scene(kind: .goose, theme: theme(), reduceMotion: true, still: false)
        let still = try scene(kind: .goose, theme: theme(), reduceMotion: false, still: true)
        let blank = try scene(kind: .goose, theme: theme(), reduceMotion: true, still: false,
                              birds: false)
        XCTAssertGreaterThan(differencePoints(reduced, blank), 40,
                             "关掉动效后鸟群不该消失（关动效 ≠ 关内容）")
        XCTAssertEqual(differencePoints(reduced, still), 0,
                       "减弱动效必须走冻结档（与静态档同一个姿态）")
    }

    // MARK: - 统一氛围钟（#651）

    /// 飞鸟层必须**真的读环境里的氛围钟**，而不是只把 `TimelineView` 换了名字。
    ///
    /// 判据：把钟拨到冻结档那个相位（`FlockLayout.frozenElapsed()`）、且 `still: false`，
    /// 出图必须与静态档**逐像素一致**。这条路同时钉住两件事：
    /// ① `AmbientTicker` 注入了钟就走钟、不起自己的表；
    /// ② 层在非冻结档用的是钟给的值（不是自己另算一个）。
    ///
    /// 反证（已实测）：把 `AmbientTicker` 里 `else if let ambient` 那条分支删掉
    /// （一律自起表）→ 红在「与静态档同一个姿态」。
    func testAmbientClockDrivesTheFlock() throws {
        let frozenPhase = FlockLayout.frozenElapsed()
        let driven = try scene(kind: .goose, theme: theme(), still: false,
                               ambientElapsed: frozenPhase)
        let still = try scene(kind: .goose, theme: theme(), still: true)
        XCTAssertGreaterThan(differencePoints(driven, try scene(
            kind: .goose, theme: theme(), still: false, birds: false)), 40,
            "注入了钟之后鸟群画不出来了（统一帧源把内容弄丢了）")
        XCTAssertEqual(differencePoints(driven, still), 0,
                       "注入了钟却与冻结档不同姿态 —— 钟给的值没被用上")
    }

    // MARK: - 夜档

    /// 夜里也看得见（夜空本身极暗，所以夜里走的是提亮那档色）。
    func testNightBirdsAreStillVisible() throws {
        for kind in BirdKind.allCases {
            let withBirds = try scene(kind: kind, theme: theme(isNight: true))
            let without = try scene(kind: kind, theme: theme(isNight: true), birds: false)
            XCTAssertGreaterThan(differencePoints(withBirds, without), 30,
                                 "\(kind.rawValue)：夜里的鸟群看不见")
        }
    }
}
