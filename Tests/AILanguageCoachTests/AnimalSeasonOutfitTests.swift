import AppCore
import XCTest
@testable import AppUI

/// 小动物四季装扮与降水行为（#605）单测。
///
/// 覆盖三件事：
/// 1. 季节 → 装扮的映射是纯函数（春 / 夏 / 秋 / 冬各一件，钉死不怕换实现）；
/// 2. 天气 → 降水行为的映射（下雨打伞、下雪哆嗦、晴与无天气都没行为）；
/// 3. 装配哨兵：地面带必须把 theme 的 season / weather 透传给每只居民。
final class AnimalSeasonOutfitTests: XCTestCase {

    // MARK: - 季节装扮映射

    /// 四季各一件，且互不相同（两季共用一件 = 那一件白画了）。
    func testSeasonOutfitMapping() {
        XCTAssertEqual(AnimalSeasonOutfit.forSeason(.spring), .flower, "春 = 小花")
        XCTAssertEqual(AnimalSeasonOutfit.forSeason(.summer), .sunglasses, "夏 = 墨镜")
        XCTAssertEqual(AnimalSeasonOutfit.forSeason(.autumn), .scarf, "秋 = 围巾")
        XCTAssertEqual(AnimalSeasonOutfit.forSeason(.winter), .woolHat, "冬 = 绒帽")
        let outfits = ForestSeason.allCases.map(AnimalSeasonOutfit.forSeason)
        XCTAssertEqual(Set(outfits).count, 4, "四季装扮必须两两不同")
    }

    // MARK: - 降水行为映射

    /// 下雨打伞、下雪哆嗦；晴与「没有天气」都没行为 ——
    /// 「晴」不配道具，天好着打把伞才是怪的（用户 2026-10 拍板「继续在场」）。
    func testWeatherBehaviorMapping() {
        XCTAssertEqual(AnimalWeatherBehavior.forWeather(.rain), .umbrella)
        XCTAssertEqual(AnimalWeatherBehavior.forWeather(.snow), .shiver)
        XCTAssertNil(AnimalWeatherBehavior.forWeather(.clear), "晴天没有降水行为")
        XCTAssertNil(AnimalWeatherBehavior.forWeather(nil), "不跟随天气 = 没有降水行为")
    }

    // MARK: - 装配哨兵

    /// ⚠️ 被扫的字符串不能出现在源码注释里；反证必须真删。
    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: "Sources/\(relativePath)", encoding: .utf8)
    }

    /// 地面带必须把季节与天气透传进 `LivelyAnimal`（漏一个 = 那一路装扮静默失效）。
    func testTreeCanvasWiresSeasonAndWeatherIntoResidents() throws {
        let canvas = try TreeCanvasSentinel.joined()
        XCTAssertTrue(canvas.contains("season: theme.season"),
                      "resident() 必须把 theme 的季节传给每只居民")
        XCTAssertTrue(canvas.contains("weather: theme.weather"),
                      "resident() 必须把 theme 的天气传给每只居民")
    }

    /// `LivelyAnimal` 必须把两个值继续透传给 `CuteAnimalView`。
    func testLivelyAnimalPassesThroughToCuteAnimal() throws {
        let lively = try source("AppUI/Components/LivelyAnimal.swift")
        XCTAssertTrue(lively.contains("season: season, weather: weather"),
                      "LivelyAnimal 必须把季节与天气透传给 CuteAnimalView")
    }

    /// 伞必须同时过**两道**闸门：行为是打伞、且天气确实是下雨（源码哨兵）。
    ///
    /// 为什么用源码哨兵而不是渲染断言（2026-10-21 反证实测的结果）：把第二道闸门
    /// 拆掉（`if behavior == .umbrella {`）之后，全部渲染用例依然全绿 —— 因为
    /// `forWeather(.snow)` 返回 `.shiver`，这条路径**运行时不可达**，任何画面都照不出区别。
    /// 用户当年在雪天看到帽子底下一排深橘红小点（伞面画坏了在冒充装饰），根因是
    /// AppState 切天气时 theme 没同步；这道闸门是防「将来有人把 weather 表改错」的保险，
    /// 而保险只能靠源码形态钉住。
    ///
    /// ⚠️ 钉的是**挂载那一行的整串形态**，不是出现次数：只数次数会被注释里的字符串骗过去。
    func testUmbrellaIsGatedOnRainTwice() throws {
        let animals = try source("AppUI/Theme/Animals.swift")
        XCTAssertTrue(animals.contains("if behavior == .umbrella, weather == .rain {"),
                      "伞必须同时过 behavior 与 weather 两道闸门（两者缺一就可能在雪天冒出来）")
    }
}
