import AppKit
import AIDomain
@testable import AppUI
import SwiftUI
import XCTest

/// 白哈气（#628）的离屏渲染回归。
///
/// 判据走**墨迹差**（不比色值，离屏过色彩空间换算，见技能 macos-ui-verify）：
/// - 冬天的动物嘴边真的有一团雾（有 / 无哈气必须肉眼可辨）；
/// - 夏天 / 睡着了，一个点都不许有（不冷不喘）；
/// - 下雪天即便不在冬天也哈（规则在「冷」上，不在「季节标签」上）；
/// - 同一份配置渲染两遍必须逐像素一致（夹具关动画）。
///
/// ⚠️ 必须关 `CuteAnimalView.animationsEnabled`（离屏夹具）：眨眼与哈气定时器
/// 会让「两帧一致」这类确定性守卫永远不成立（同 AnimalSeasonOutfitRenderTests）。
@MainActor
final class ForestBreathRenderTests: XCTestCase {

    private var window: NSWindow?

    private struct Render {
        var rep: NSBitmapImageRep
        var scale: CGFloat
    }

    private let canvas = CGSize(width: 120, height: 120)

    /// ⚠️ `setUp` / `tearDown` 是**非隔离**的，碰 `@MainActor` 的
    /// `CuteAnimalView.animationsEnabled` 编译期就报 —— 整段包进
    /// `MainActor.assumeIsolated`，原值经静态槽搬去还原（同季节装扮那组）。
    nonisolated(unsafe) private static var savedAnimations = true

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            Self.savedAnimations = CuteAnimalView.animationsEnabled
            CuteAnimalView.animationsEnabled = false
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated { CuteAnimalView.animationsEnabled = Self.savedAnimations }
        super.tearDown()
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
        return Render(rep: rep, scale: CGFloat(rep.pixelsHigh) / max(size.height, 1))
    }

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

    /// 一只站在雪地里的小熊：`breath` 为 false 时出「同一只、不哈气」的对照图。
    private func animal(season: ForestSeason? = .winter, weather: ForestWeather? = nil,
                        isSleeping: Bool = false, breath: Bool = true) throws -> Render {
        try makeHost(
            ZStack {
                // 雪地底色：哈气是冷灰色的雾，白底上才读得出「一团气息」
                Color(red: 0.93, green: 0.96, blue: 0.98)
                CuteAnimalView(kind: .bear, isSleeping: isSleeping, size: 96, bobbing: false,
                               season: season, weather: weather, drawsBreath: breath)
                    .environment(\.appMotion,
                                 AppMotionDescriptor(reduceMotion: true, reduceTransparency: true))
            }
            .frame(width: canvas.width, height: canvas.height),
            size: canvas
        )
    }

    // MARK: - 判据

    /// 冬天的动物嘴边真的有一团雾（有 / 无哈气必须肉眼可辨）。
    ///
    /// 反证：把 `AnimalBreath.shows` 改成恒 `false` → 红。
    func testBreathIsDrawn() throws {
        let withBreath = try animal()
        let bare = try animal(breath: false)
        XCTAssertGreaterThan(differencePoints(withBreath, bare), 60,
                             "冬天的动物嘴边没有哈气")
    }

    /// 哈气在**嘴边**：下半身（肚子以下）一个点都不许变。
    ///
    /// 反证：把 `BreathPuff` 的 `offset(y:)` 改成 `+size * 0.3`（挪到肚子上）→ 红。
    func testBreathSitsAtTheMuzzle() throws {
        let withBreath = try animal()
        let bare = try animal(breath: false)
        let lower = CGRect(x: 0, y: canvas.height * 0.68,
                           width: canvas.width, height: canvas.height * 0.32)
        XCTAssertEqual(differencePoints(withBreath, bare, in: lower), 0,
                       "哈气画到肚子下面去了（不在嘴边）")
    }

    /// 夏天不哈（不冷不喘）。
    ///
    /// 反证：把 `AnimalBreath.shows` 的 `season == .winter` 改成恒 `true` → 红。
    func testNoBreathInSummer() throws {
        let summer = try animal(season: .summer, breath: true)
        let summerBare = try animal(season: .summer, breath: false)
        XCTAssertEqual(differencePoints(summer, summerBare), 0, "夏天的动物在哈气")
    }

    /// 睡着了不哈（Zzz 边上冒烟）。
    ///
    /// 反证：把 `AnimalBreath.shows` 开头的 `guard !isSleeping` 删掉 → 红。
    func testSleepingAnimalsHaveNoBreath() throws {
        let sleeping = try animal(season: .winter, isSleeping: true, breath: true)
        let sleepingBare = try animal(season: .winter, isSleeping: true, breath: false)
        XCTAssertEqual(differencePoints(sleeping, sleepingBare), 0,
                       "睡着的动物在哈气")
    }

    /// 下雪天即便不在冬天也哈（规则在「冷」上）。
    func testSnowyDayShowsBreathOffSeason() throws {
        let snowy = try animal(season: .summer, weather: .snow, breath: true)
        let snowyBare = try animal(season: .summer, weather: .snow, breath: false)
        XCTAssertGreaterThan(differencePoints(snowy, snowyBare), 60,
                             "下雪天不哈气")
    }

    /// 静态帧零抖动（夹具关动画后哈气必须定住）。
    func testStaticFrameIsDeterministic() throws {
        XCTAssertEqual(differencePoints(try animal(), try animal()), 0, "静态帧不许抖")
    }

    // MARK: - 出图（人眼复核）

    /// 出图：`.workbuddy/verify/`。「哈气飘得可不可爱」断言管不了 —— 人眼看。
    func testDumpsBreathForHumanReview() throws {
        try dump(try animal().rep, name: "breath-day-20261021.png")
        try dump(try animal(season: .summer, weather: .snow).rep,
                 name: "breath-snowy-summer-20261021.png")
        try dump(try animal(season: .winter, isSleeping: true).rep,
                 name: "breath-sleeping-20261021.png")
    }

    private func dump(_ rep: NSBitmapImageRep, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // RenderTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]), "PNG 编码失败")
        try png.write(to: directory.appendingPathComponent(name))
    }
}
