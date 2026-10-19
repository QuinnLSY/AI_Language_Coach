import AIDomain
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// #601「成长之树从幼苗开始」的离屏渲染回归。
///
/// 判据只走**墨差 / 墨迹量**，不比色值（离屏过色彩空间换算，见技能 macos-ui-verify）：
/// - 幼苗档的树干必须真的更细（第一屏信号）、树冠必须真的更小；
/// - 嫩苗必须只出现在全新学员的画面上（长成即撤）；
/// - 同态两帧必须逐像素一致（`DriftingLeaves` 的种子随机不许引入抖动）。
///
/// 「满星与从前逐像素相同」这条**不在这里判**——渲染测试没有从前的图可比，
/// 它由 `TreeGrowthTests` 的精确值恒等钉（0.24 / 0.10 / 1.03 三个常数）。
/// 本文件判的是另一半：换算层算对了，画面必须真的照着画。
@MainActor
final class TreeGrowthRenderTests: XCTestCase {

    private var window: NSWindow?
    private let canvas = CGSize(width: 340, height: 1080)
    private let midX: CGFloat = 170

    // MARK: - 夹具

    /// 得星比例 → 进度（`climbFraction` 保持 0：学员站在树底，与既有的
    /// `ForestTreeLinkRenderTests` 同口径，测的是树不是学员）。
    private func progress(starFraction: Double) -> LearnerProgress {
        var progress = LearnerProgress.seed()
        for index in progress.levels.indices {
            let required = Double(progress.levels[index].requiredStars)
            progress.levels[index].earnedStars = Int((required * starFraction).rounded())
            progress.levels[index].state = starFraction >= 1 ? .completed : .unlocked
        }
        return progress
    }

    private func render(_ progress: LearnerProgress, night: Bool = false) throws -> NSBitmapImageRep {
        let saved = CuteAnimalView.animationsEnabled
        CuteAnimalView.animationsEnabled = false
        defer { CuteAnimalView.animationsEnabled = saved }

        let theme = ForestThemeResolver.resolve(
            mode: night ? .night : .day, systemIsDark: false,
            hour: night ? 22 : 12, month: 6,
            followsClock: false, followsSeason: false
        )
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
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func scale(of rep: NSBitmapImageRep) -> Double {
        Double(rep.pixelsWide) / Double(canvas.width)
    }

    /// 若干矩形里的墨迹量（半透明也算墨：树冠是半透明的大色块）。
    private func ink(_ rep: NSBitmapImageRep, in rects: [CGRect]) -> Int {
        guard let data = rep.bitmapData else { return 0 }
        let scale = scale(of: rep)
        var count = 0
        for rect in rects {
            let px = Int(rect.minX * scale)..<min(Int(rect.maxX * scale), rep.pixelsWide)
            let py = Int(rect.minY * scale)..<min(Int(rect.maxY * scale), rep.pixelsHigh)
            guard !px.isEmpty, !py.isEmpty else { continue }
            for y in py {
                for x in px {
                    if data[y * rep.bytesPerRow + x * 4 + 3] > 8 { count += 1 }
                }
            }
        }
        return Int(Double(count) / (scale * scale))
    }

    /// 两帧在若干矩形里差多少个**点**。
    private func difference(_ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep, in rects: [CGRect]) -> Int {
        let width = lhs.pixelsWide, height = lhs.pixelsHigh
        guard let a = lhs.bitmapData, let b = rhs.bitmapData else { return 0 }
        let scale = scale(of: lhs)
        var count = 0
        for rect in rects {
            let px = Int(rect.minX * scale)..<min(Int(rect.maxX * scale), width)
            let py = Int(rect.minY * scale)..<min(Int(rect.maxY * scale), height)
            guard !px.isEmpty, !py.isEmpty else { continue }
            for y in py {
                for x in px {
                    let o = y * width + x
                    let pa = o * 4, pb = o * 4
                    if abs(Int(a[pa]) - Int(b[pb])) > 8
                        || abs(Int(a[pa + 1]) - Int(b[pb + 1])) > 8
                        || abs(Int(a[pa + 2]) - Int(b[pb + 2])) > 8 {
                        count += 1
                    }
                }
            }
        }
        return Int(Double(count) / (scale * scale))
    }

    /// 树干柱（画布中段，躲开树根一带的学员 / 嫩苗 / l1 与顶上的树冠）。
    private var trunkBand: [CGRect] {
        [CGRect(x: midX - 45, y: 500, width: 90, height: 400)]
    }

    /// 树冠区，**挖掉树干柱**（否则树干变粗的墨会冒充树冠变大的证据 ——
    /// 反证「冠幅不改」时会因为树干照样变粗而绿，判据就成了摆设）。
    private var crownBand: [CGRect] {
        [
            CGRect(x: 0, y: 40, width: midX - 41, height: 360),
            CGRect(x: midX + 41, y: 40, width: 340 - (midX + 41), height: 360)
        ]
    }

    /// 嫩苗区：树根右侧、成年树干的右沿（midX+41=211）之外、伙伴（midX+54=224，
    /// 且更靠下）之前。这片唯一的变量就是嫩苗本人 —— 判据因此走**墨差**
    /// （`DriftingLeaves` 的落点两帧相同，相减即消；绝对墨迹里可能混进一片落叶）。
    private var sproutBand: [CGRect] {
        [CGRect(x: 213, y: 902, width: 20, height: 36)]
    }

    /// 树干尖一带（中列 ±20pt）：树干尖钉在 y=130，树冠缩小后尖会从这里戳出来。
    /// 宽 40pt 罩得住最细的苗期树干（顶宽 0.055×340≈19pt）。
    private var tipBand: [CGRect] {
        [CGRect(x: midX - 20, y: 40, width: 40, height: 280)]
    }

    /// 一片区域里**首个**满足谓词的 y（画布坐标；没有则 nil）。
    private func topmost(_ rep: NSBitmapImageRep, in rects: [CGRect],
                         matching: (UInt8, UInt8, UInt8, UInt8) -> Bool) -> Int? {
        guard let data = rep.bitmapData else { return nil }
        let scale = scale(of: rep)
        for rect in rects {
            let px = Int(rect.minX * scale)..<min(Int(rect.maxX * scale), rep.pixelsWide)
            let py = Int(rect.minY * scale)..<min(Int(rect.maxY * scale), rep.pixelsHigh)
            guard !px.isEmpty, !py.isEmpty else { continue }
            for y in py {
                for x in px {
                    let o = y * rep.bytesPerRow + x * 4
                    if matching(data[o], data[o + 1], data[o + 2], data[o + 3]) {
                        return Int((Double(y) / scale).rounded())
                    }
                }
            }
        }
        return nil
    }

    /// 叶绿：绿色明显压过红与蓝（叶片 135/195/133；树干 147/107/61 是红多绿少，
    /// 夜色下叶片变暗但这个关系不变 —— 日夜两档都实测成立）。
    private func isLeaf(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> Bool {
        a > 60 && Int(g) > Int(r) + 15 && Int(g) > Int(b) + 15
    }

    /// 不透明裸树干：红多绿少的暖褐（`theme.trunk` 147/107/61）。
    /// 半透明的不算 —— 叶缝里透出的一点树干不算「戳出来」。
    private func isBareTrunk(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> Bool {
        a > 60 && r > 90 && r > g && Int(r) - Int(b) > 30
    }

    // MARK: - 用例

    /// 幼苗档的树干必须真的更细 —— 新用户第一屏（树冠在屏幕上沿之外）的
    /// 「年轻」信号全在这根柱子上。
    ///
    /// 反证：`trunkWidths` 恒返回成年值 → 墨差塌到 ~0 → 红。
    func testYoungTrunkIsThinnerThanMatureTrunk() throws {
        let young = try render(progress(starFraction: 0))
        let mature = try render(progress(starFraction: 1))

        let diff = difference(young, mature, in: trunkBand)
        XCTAssertGreaterThan(diff, 5000,
                            "幼苗与成年的树干中段几乎没有区别（实测 \(diff) 点）—— 树没有跟着进度长")

        let youngInk = ink(young, in: trunkBand)
        let matureInk = ink(mature, in: trunkBand)
        XCTAssertGreaterThan(matureInk, youngInk + 3000,
                            "成年树干的墨迹（\(matureInk)）没有明显多过幼苗（\(youngInk)）—— 细的那根不是树干？")
    }

    /// 幼苗档的树冠必须真的更小（爬上去才看得见的那一半）。
    ///
    /// ⚠️ 判据走**比例**不走「有差别」：冠幅缩到 0.64 时墨量只剩成年的 ~59%
    /// （实测 35602 / 59924），而**旧行为**那 3% 的微缩也能量出 ~91% ——
    /// 只断言「有差别」的话，这条测试在加这个功能**之前**就是绿的（假闸，
    /// 实测过：把 `crownScale` 换回 `0.97 + g * 0.06` 时它照样通过）。
    /// 所以这里钉的是「幼苗的冠不到成年的四分之三」。
    ///
    /// 反证：`crownScale` 恒返回 1.03（完全不缩）或退回 `0.97 + g * 0.06` → 红。
    func testYoungCrownIsSmallerThanMatureCrown() throws {
        let young = try render(progress(starFraction: 0))
        let mature = try render(progress(starFraction: 1))

        let diff = difference(young, mature, in: crownBand)
        XCTAssertGreaterThan(diff, 2500,
                            "树冠区（已挖掉树干）几乎没有区别（实测 \(diff) 点）—— 幼苗的冠没有缩起来")

        let youngInk = ink(young, in: crownBand)
        let matureInk = ink(mature, in: crownBand)
        let ratio = Double(youngInk) / Double(max(matureInk, 1))
        XCTAssertLessThan(ratio, 0.75,
                          "幼苗冠幅是成年的 \(Int((ratio * 100).rounded()))%（\(youngInk) / \(matureInk)）"
                          + " —— 缩得不够，「幼苗」看着还是成年树")
    }

    /// 嫩苗只出现在全新学员的画面上：0 星有、长成即撤。
    ///
    /// 判据走**墨差**：嫩苗只在幼苗那帧出现，两帧相减剩下的就是它本身；
    /// 「长成即撤」由 `difference(过半, 成年) == 0` 钉 —— 除了嫩苗，
    /// 那片区域不该有第二个随成熟度变的变量。
    ///
    /// 反证：`sproutOpacity` 恒 1（淡出失效）→ 过半那帧苗区也有墨 → 红。
    func testSproutShowsOnlyForBrandNewTrees() throws {
        let young = try render(progress(starFraction: 0))
        let mature = try render(progress(starFraction: 1))
        let halfway = try render(progress(starFraction: 0.3))

        let sproutInk = difference(young, mature, in: sproutBand)
        XCTAssertGreaterThan(sproutInk, 40,
                            "全新学员的画面上没有嫩苗（苗区墨差 \(sproutInk) 点）—— 「从幼苗开始」少了一半")
        XCTAssertGreaterThan(ink(young, in: sproutBand), ink(mature, in: sproutBand) + 40,
                            "幼苗帧苗区的墨迹没有多过成年帧 —— 嫩苗画倒了？")
        XCTAssertEqual(difference(halfway, mature, in: sproutBand), 0,
                       "过半进度的画面与成年画面在苗区还有差异 —— 除了嫩苗，那片不该有第二个变量")
    }

    /// 树干尖不许从树冠上方戳出来（用户 2026-10-19 报障：「树冠顶部的树干都突出来了」）。
    ///
    /// ⚠️ 判据是**两条上沿比高低**，不是「尖上面有没有棕色」—— 树冠里本来就有
    /// 棕色枝干，颜色判据分不清「枝干」与「戳出来的树干尖」。比的是：中列一带
    /// **叶绿像素**的最高处，必须不高于**不透明裸树干**像素的最高处。
    /// 实测（修好后）：幼苗 108 vs 168、中段 61 vs 140、成年 40 vs 117，日夜同结论；
    /// 修之前幼苗是 146 vs 132 —— 尖高出叶子 14pt。
    ///
    /// 反证：`crownLift` 恒 0 → 幼苗态叶边上沿高于树干 → 红。
    func testTrunkTipNeverPokesAboveTheCrown() throws {
        for (name, fraction) in [("young", 0.0), ("mid", 0.5), ("mature", 1.0)] {
            for (night, tag) in [(false, "day"), (true, "night")] {
                let rep = try render(progress(starFraction: fraction), night: night)
                let leafTop = topmost(rep, in: tipBand, matching: isLeaf)
                let trunkTop = topmost(rep, in: tipBand, matching: isBareTrunk)
                XCTAssertNotNil(leafTop, "\(name)/\(tag)：树冠顶上一片叶子都没有？")
                guard let leafTop, let trunkTop else { continue }
                XCTAssertLessThanOrEqual(
                    leafTop, trunkTop,
                    "\(name)/\(tag)：树干尖（y=\(trunkTop)）从树冠（叶边 y=\(leafTop)）上方戳出来了"
                    + " —— 把树冠整体往上抬（`TreeGrowth.crownLift`）")
            }
        }
    }

    /// reduceMotion 下同态两帧必须逐像素一致（`DriftingLeaves` 种子随机 +
    /// 风场冻结的前提；没有它，上面三条信号判据都可能是噪声凑出来的）。
    func testGrowthRendersDeterministically() throws {
        let first = try render(progress(starFraction: 0))
        let second = try render(progress(starFraction: 0))
        let noise = difference(first, second,
                               in: [CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)])
        XCTAssertEqual(noise, 0, "同态两帧差了 \(noise) 点 —— 信号判据不可信")
    }

    /// 日夜两版 × 幼苗 / 成年 dump 成 PNG，供人工复核（「像不像一株苗」
    /// 是断言救不了的那一半）。
    func testDumpsGrowthStagesForHumanReview() throws {
        for (name, fraction) in [("young", 0.0), ("mid", 0.5), ("mature", 1.0)] {
            let variants: [(Bool, String)] = [(false, "day"), (true, "night")]
            for (night, tag) in variants {
                let rep = try render(progress(starFraction: fraction), night: night)
                let png = try XCTUnwrap(
                    rep.representation(using: .png, properties: [NSBitmapImageRep.PropertyKey: Any]()),
                    "PNG 编码失败"
                )
                try dump(png, name: "tree-growth-\(name)-\(tag)-20261019.png")
            }
        }
    }

    private func dump(_ png: Data, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // RenderTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(name))
    }
}
