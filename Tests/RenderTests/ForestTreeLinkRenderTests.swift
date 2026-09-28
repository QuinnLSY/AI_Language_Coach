import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 树联动（批次一）的离屏渲染回归：
/// 「星星成果实 + 树冠随总进度变茂密」必须**真的画得出来**——
/// 数据链（事件 → 脉冲）全绿不等于画面有变化，所以这里直接看图。
///
/// ⚠️ 判据用**逐像素差异计数**并圈定树冠区域，不比色值（离屏过色彩空间换算）。
/// ⚠️ 注入 `reduceMotion` 冻结树冠常驻摇摆：否则两帧差异里混着摆动相位，
/// 信号判据就成了摆动噪声的奴隶（先有确定性，才谈得上灵敏度）。
@MainActor
final class ForestTreeLinkRenderTests: XCTestCase {

    private var window: NSWindow?
    private let canvas = CGSize(width: 340, height: 1080)

    // MARK: - 夹具

    private func makeProgress(allStarred: Bool) -> LearnerProgress {
        var progress = LearnerProgress.seed()
        if allStarred {
            for index in progress.levels.indices {
                progress.levels[index].earnedStars = progress.levels[index].requiredStars
            }
        }
        return progress
    }

    private func render(_ progress: LearnerProgress) throws -> NSBitmapImageRep {
        let saved = CuteAnimalView.animationsEnabled
        CuteAnimalView.animationsEnabled = false
        defer { CuteAnimalView.animationsEnabled = saved }

        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let host = NSHostingView(rootView: AnyView(
            TreeCanvas(theme: theme, progress: progress, studentAnimal: .bear)
                .environment(\.appMotion, AppMotionDescriptor(reduceMotion: true, reduceTransparency: false))
                .frame(width: canvas.width, height: canvas.height)
                .clipped()
        ))
        host.frame = NSRect(origin: .zero, size: canvas)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        // 等首帧布局与果实弹入动画（reduceMotion 下是短退化动画）走完
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// 两帧在树冠区（画布 y 40–400：五团圆叶 + 果实 + 深叶层都在这段）差多少个**点**。
    private func differencePoints(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep) -> Int {
        let width = lhs.pixelsWide, height = lhs.pixelsHigh
        guard let a = lhs.bitmapData, let b = rhs.bitmapData else { return 0 }
        let scale = Double(width) / Double(canvas.width)
        var count = 0
        for y in 40..<400 {
            let row = min(max(Int(Double(y) * scale), 0), height - 1)
            for x in 0..<width {
                let o = (row * width + x) * 4
                if abs(Int(a[o]) - Int(b[o])) > 8
                    || abs(Int(a[o + 1]) - Int(b[o + 1])) > 8
                    || abs(Int(a[o + 2]) - Int(b[o + 2])) > 8 {
                    count += 1
                }
            }
        }
        return Int(Double(count) / (scale * scale))
    }

    // MARK: - 用例

    /// 满星树冠与零星树冠必须**看得出区别**：果实挂枝 + 第六团圆叶 + 整体放大，
    /// 三样一起构成「树随你长」的可见证据。
    func testStarredCanopyLooksDenserAndFrutierThanBareCanopy() throws {
        let bare = try render(makeProgress(allStarred: false))
        let starred = try render(makeProgress(allStarred: true))

        let diff = differencePoints(bare, starred)
        XCTAssertGreaterThan(
            diff, 300,
            "满星与零星的树冠几乎没有区别（实测 \(diff) 点）—— 果实与茂密层没画出来，"
                + "「学习成果物化进风景」就只剩一句空话"
        )
        try dump(bare, name: "round56-tree-bare.png")
        try dump(starred, name: "round56-tree-starred.png")
    }

    /// reduceMotion 下同态两帧必须几乎一致——这是上一条信号判据的**可信度前提**：
    /// 噪声本身压不下去，信号再大也可能是摆动相位凑出来的。
    func testRenderIsDeterministicWhenMotionReduced() throws {
        let first = try render(makeProgress(allStarred: true))
        let second = try render(makeProgress(allStarred: true))
        let noise = differencePoints(first, second)
        XCTAssertLessThan(noise, 80, "reduceMotion 下树冠两帧差异过大（实测 \(noise) 点），信号判据不可信")
    }

    /// 落盘（人眼复核用）。
    private func dump(_ rep: NSBitmapImageRep, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]), "PNG 编码失败")
        try png.write(to: directory.appendingPathComponent(name))
    }
}
