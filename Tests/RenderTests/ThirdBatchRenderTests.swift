import AIDomain
import AIInfrastructure
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 第三批（2026-09-27）的离屏渲染回归：骨架屏 + 等待卡阶段条。
///
/// 判据一律走**几何/墨迹**，不比色值（离屏过色彩空间换算，见技能 macos-ui-verify）。
/// 所有帧都注入「减弱动态」档（`.environment(\.appMotion, ...)`）并关掉动物动画：
/// 帧与帧之间必须**零随机差异**，差出来的每一点墨都是被测东西本身。
@MainActor
final class ThirdBatchRenderTests: XCTestCase {

    private var window: NSWindow?

    // MARK: - 渲染

    private struct Render {
        var rep: NSBitmapImageRep
        var scale: CGFloat
    }

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
        return Render(
            rep: rep,
            scale: CGFloat(rep.pixelsHigh) / max(size.height, 1)
        )
    }

    private let canvas = CGSize(width: 480, height: 480)

    private func skeleton(_ card: some View, reduceMotion: Bool) throws -> Render {
        try makeHost(
            card
                .environment(\.appMotion, AppMotionDescriptor(
                    reduceMotion: reduceMotion,
                    reduceTransparency: true
                ))
                .frame(width: canvas.width, height: canvas.height, alignment: .topLeading),
            size: canvas
        )
    }

    /// 最低一行墨的位置（pt，自上而下）。骨架的版式高度用「墨到哪」证明。
    private func lowestInkPt(_ render: Render) -> Int? {
        let rep = render.rep
        guard let background = rep.colorAt(x: 2, y: 2) else { return nil }
        var y = rep.pixelsHigh - 1
        while y >= 0 {
            var inked = 0
            var x = 0
            while x < rep.pixelsWide {
                if let color = rep.colorAt(x: x, y: y) {
                    let diff = abs(color.redComponent - background.redComponent)
                        + abs(color.greenComponent - background.greenComponent)
                        + abs(color.blueComponent - background.blueComponent)
                    if diff > 0.08 { inked += 1 }
                    if inked > 3 { return Int(Double(y) / render.scale) }
                }
                x += 2
            }
            y -= 1
        }
        return nil
    }

    /// `rows`（pt）里两帧不同像素的个数（换算回点）。
    private func differencePoints(
        _ lhs: Render, _ rhs: Render, rows: Range<Int>
    ) -> Int {
        let rep = lhs.rep
        guard let a = lhs.rep.bitmapData, let b = rhs.rep.bitmapData else { return 0 }
        let width = rep.pixelsWide, height = rep.pixelsHigh
        let first = max(Int(Double(rows.lowerBound) * lhs.scale), 0)
        let last = min(Int(Double(rows.upperBound) * lhs.scale), height - 1)
        var count = 0
        for y in first...last {
            for x in 0..<width {
                let o = (y * width + x) * 4
                if abs(Int(a[o]) - Int(b[o])) > 8
                    || abs(Int(a[o + 1]) - Int(b[o + 1])) > 8
                    || abs(Int(a[o + 2]) - Int(b[o + 2])) > 8 {
                    count += 1
                }
            }
        }
        return Int(Double(count) / (lhs.scale * lhs.scale))
    }

    // MARK: - ① 骨架版式与动效档位无关

    /// 「减弱动态效果」开与不开，骨架**静止但同版式**（AppSkeleton 纪律 2）。
    /// shimmer 是纯 overlay：若哪天有人把它写成参与布局的东西（加 padding、改 frame），
    /// 两档的墨底就会错开 —— 这条立刻红。
    func testSkeletonLayoutIsIdenticalAcrossMotionModes() throws {
        let saved = CuteAnimalView.animationsEnabled
        CuteAnimalView.animationsEnabled = false
        defer { CuteAnimalView.animationsEnabled = saved }

        let cases: [(String, AnyView)] = [
            ("reading", AnyView(SkeletonReadingCard())),
            ("shadowing", AnyView(SkeletonShadowingCard())),
        ]
        for (name, card) in cases {
            let still = try skeleton(card, reduceMotion: true)
            let animated = try skeleton(card, reduceMotion: false)
            let stillBottom = try XCTUnwrap(lowestInkPt(still), "\(name) 骨架没画出来")
            let animatedBottom = try XCTUnwrap(lowestInkPt(animated), "\(name) 骨架没画出来")
            XCTAssertLessThan(abs(stillBottom - animatedBottom), 2,
                              "\(name) 骨架版式随动效档位漂移了（\(stillBottom) vs \(animatedBottom)）")
            // 版式本身要立得起来：阅读骨架（标题+三段+选项）明显比一行字高。
            XCTAssertGreaterThan(stillBottom, 120, "\(name) 骨架太矮，版式可能塌了")
            try dump(still, name: "round34-skeleton-\(name)-day.png")
        }
    }

    /// PNG 落盘供人眼复核（与 TeacherPreparingCardRenderTests 同一目录）。
    private func dump(_ render: Render, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(render.rep.representation(using: .png, properties: [:]), "PNG 编码失败")
        try png.write(to: directory.appendingPathComponent(name))
    }

    // MARK: - ② 等待卡阶段条真的跟着阶段走

    /// 阶段条两帧差异必须**集中在阶段条所在的带区**，带区外零差异：
    /// - 带区内无差异 = stage 参数被无视（传成常量）→ 阶段条是摆设；
    /// - 带区外有差异 = 阶段切换引起了布局跳动 → 等待 30 秒的人会看到卡片闪一下。
    func testStageRowReactsToPhaseWithoutShiftingLayout() throws {
        let saved = CuteAnimalView.animationsEnabled
        CuteAnimalView.animationsEnabled = false
        defer { CuteAnimalView.animationsEnabled = saved }

        func render(stage: TeacherWaitStage) throws -> Render {
            try makeHost(
                TeacherPreparingCard(teacherKind: .panda, startedAt: Date(), stage: stage)
                    .environment(\.appMotion, AppMotionDescriptor(
                        reduceMotion: true,
                        reduceTransparency: true
                    ))
                    .frame(width: canvas.width, height: canvas.height, alignment: .topLeading),
                size: canvas
            )
        }
        let booting = try render(stage: .booting)
        let greeting = try render(stage: .greeting)

        // 阶段条带区（标题行 30pt 之下、解释行位置之上；两帧都只等 0 秒，无解释行）。
        let inBand = differencePoints(booting, greeting, rows: 30..<52)
        XCTAssertGreaterThan(inBand, 30, "阶段条没有跟着阶段变（带区 \(inBand) 点差异）——stage 参数被无视了？")

        // 标题行（头像/文案/点都冻结）与更下方：阶段切换不许引起任何布局位移。
        let titleBand = differencePoints(booting, greeting, rows: 0..<30)
        XCTAssertLessThan(titleBand, 12, "阶段切换不该动到标题行（\(titleBand) 点差异）")
        let belowBand = differencePoints(booting, greeting, rows: 52..<140)
        XCTAssertLessThan(belowBand, 12, "阶段切换不该引起卡片布局跳动（\(belowBand) 点差异）")
    }
}
