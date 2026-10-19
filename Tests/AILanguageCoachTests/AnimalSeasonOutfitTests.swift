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
        let canvas = try source("AppUI/Components/TreeCanvas.swift")
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
}
