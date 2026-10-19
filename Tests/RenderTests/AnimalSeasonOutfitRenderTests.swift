import AppKit
import AIDomain
@testable import AppUI
import SwiftUI
import XCTest

/// 小动物四季装扮与降水行为（#605）的离屏渲染回归。
///
/// 判据走**墨迹差**（不比色值，离屏过色彩空间换算，见技能 macos-ui-verify）：
/// - 四季各一件装扮，与「没有季节」的画面必须可见地不同；
/// - 雨天（伞）与雪天（哆嗦位移）与「没有天气」的画面必须不同；
/// - 同一份配置渲染两遍必须逐像素一致（夹具关动画 + 种子相位恒定）。
///
/// ⚠️ 必须关 `CuteAnimalView.animationsEnabled`（离屏夹具）：眨眼的 0.14s 与
/// 常驻浮动会让「两帧一致」这类确定性守卫永远不成立（同 ChatBubbleWidthRenderTests）。
@MainActor
final class AnimalSeasonOutfitRenderTests: XCTestCase {

    private var window: NSWindow?

    private struct Render {
        var rep: NSBitmapImageRep
        var scale: CGFloat
    }

    private let canvas = CGSize(width: 120, height: 120)

    override func setUp() {
        super.setUp()
        let saved = CuteAnimalView.animationsEnabled
        CuteAnimalView.animationsEnabled = false
        addTeardownBlock { CuteAnimalView.animationsEnabled = saved }
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

    private func animal(season: ForestSeason? = nil, weather: ForestWeather? = nil) throws -> Render {
        try makeHost(
            CuteAnimalView(kind: .bear, isSleeping: false, size: 96, bobbing: false,
                           season: season, weather: weather)
                .environment(\.appMotion, AppMotionDescriptor(reduceMotion: true, reduceTransparency: true))
                .frame(width: canvas.width, height: canvas.height),
            size: canvas
        )
    }

    // MARK: - 四季装扮

    /// 四季各一件装扮：与「没有季节」的画面必须可见地不同（装扮真的画上去了）。
    ///
    /// 反证：把 `SeasonOutfit` 的 switch 换成 `default: EmptyView()`（一件都不画）→ 红。
    func testEachSeasonOutfitChangesThePicture() throws {
        let plain = try animal()
        for season in ForestSeason.allCases {
            let dressed = try animal(season: season)
            XCTAssertGreaterThan(differencePoints(plain, dressed), 40,
                                 "\(season.displayName)季装扮没有画上去")
        }
    }

    /// 四季画面两两不同（四件装扮不是同一件换了位置）。
    func testSeasonOutfitsAreMutuallyDistinct() throws {
        let spring = try animal(season: .spring)
        let summer = try animal(season: .summer)
        let autumn = try animal(season: .autumn)
        let winter = try animal(season: .winter)
        XCTAssertGreaterThan(differencePoints(spring, summer), 40, "春与夏的装扮看起来一样")
        XCTAssertGreaterThan(differencePoints(summer, autumn), 40, "夏与秋的装扮看起来一样")
        XCTAssertGreaterThan(differencePoints(autumn, winter), 40, "秋与冬的装扮看起来一样")
        XCTAssertGreaterThan(differencePoints(spring, winter), 40, "春与冬的装扮看起来一样")
    }

    // MARK: - 降水行为

    /// 雨天：小伞撑在身侧，画面与晴天必须不同。
    ///
    /// 反证：把 `if behavior == .umbrella` 的 `LittleUmbrella` 换成 `EmptyView()` → 红。
    func testRainUmbrellaChangesThePicture() throws {
        let plain = try animal()
        let raining = try animal(weather: .rain)
        XCTAssertGreaterThan(differencePoints(plain, raining), 40, "雨天小伞没有画上去")
    }

    /// 雪天：哆嗦位移让整个身体挪了一个身位，画面与晴天必须不同。
    ///
    /// 反证：把 `shiverOffset` 改成恒 0（哆嗦不挪）→ 红。
    func testSnowShiverChangesThePicture() throws {
        let plain = try animal()
        let snowing = try animal(weather: .snow)
        XCTAssertGreaterThan(differencePoints(plain, snowing), 40, "雪天哆嗦没有让身体挪位")
    }

    /// 晴（`.clear`）不配道具：画面与「没有天气」一致（天好着打把伞才是怪的）。
    func testClearWeatherChangesNothing() throws {
        let plain = try animal()
        let clear = try animal(weather: .clear)
        XCTAssertEqual(differencePoints(plain, clear), 0, "晴天不许有任何道具或位移")
    }

    // MARK: - 确定性

    /// 同一份配置渲染两遍必须零差异（装扮 / 伞都是纯几何，哆嗦在夹具下也静止）。
    func testOutfitAndGearRenderDeterministically() throws {
        let first = try animal(season: .winter, weather: .rain)
        let second = try animal(season: .winter, weather: .rain)
        XCTAssertEqual(differencePoints(first, second), 0, "装扮 / 雨伞渲染不许有任何抖动")
    }

    /// 睡眠时围巾与墨镜收起、绒帽照戴：睡着的小熊与「清醒 + 冬季」不同，
    /// 与「清醒 + 夏季」也不同（少了墨镜）—— 睡意判据真的接了。
    func testSleepingDropsScarfAndSunglassesButKeepsHat() throws {
        let awakeWinter = try animal(season: .winter)
        let asleepWinter = try makeHost(
            CuteAnimalView(kind: .bear, isSleeping: true, size: 96, bobbing: false,
                           season: .winter)
                .environment(\.appMotion, AppMotionDescriptor(reduceMotion: true, reduceTransparency: true))
                .frame(width: canvas.width, height: canvas.height),
            size: canvas
        )
        XCTAssertGreaterThan(differencePoints(awakeWinter, asleepWinter), 40,
                             "睡着的冬季小熊应与清醒时不同（围巾收起）")
    }
}
