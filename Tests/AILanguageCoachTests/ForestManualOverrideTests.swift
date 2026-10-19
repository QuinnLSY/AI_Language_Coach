import AppCore
import XCTest
@testable import AppUI

/// 季节 / 天气的**手动选择**（#602）单测。
///
/// 口径（与设置页两个开关下的 segmented 一一对应）：
/// - 跟随开着 = 自动派生说了算（手动值存着但不参与）；
/// - 跟随关着 = 用手动值；手动值也没有 = nil（老样子）；
/// - 手动天气只有下雨 / 下雪两档，「晴」不是手动档；
/// - 手动季节不影响日夜档位（picker 在「森林时刻」卡里，档位归上面那排管）。
final class ForestManualOverrideTests: XCTestCase {

    private func resolve(followsSeason: Bool = false, followsWeather: Bool = false,
                         season: ForestSeason? = nil, weather: ForestWeather? = nil,
                         mode: ThemeMode = .day, month: Int = 6,
                         dayOfYear: Int = 180) -> ForestTheme {
        ForestThemeResolver.resolve(mode: mode, systemIsDark: false,
                                    hour: 12, month: month,
                                    followsClock: false, followsSeason: followsSeason,
                                    followsWeather: followsWeather, dayOfYear: dayOfYear,
                                    seasonOverride: season,
                                    weatherOverride: weather)
    }

    // MARK: - 季节手动档

    /// 关跟随后手动挑一季：叶色按挑好的走，日夜档位不受影响。
    func testManualSeasonAppliesWhenFollowIsOff() {
        let theme = resolve(followsSeason: false, season: .autumn)
        XCTAssertEqual(theme.season, .autumn)
        XCTAssertEqual(theme.palette, .day, "手动季节不许动日夜档位")
    }

    /// 跟随时手动值被忽略：6 月自动派生夏天，哪怕手动存着秋天。
    func testAutoSeasonWinsWhenFollowIsOn() {
        let theme = resolve(followsSeason: true, season: .autumn, month: 6)
        XCTAssertEqual(theme.season, .summer, "跟随开着 = 月份说了算，手动值只是存着")
        let winter = resolve(followsSeason: true, season: .autumn, month: 1)
        XCTAssertEqual(winter.season, .winter)
    }

    /// 跟随着关又没挑过：season 为 nil（与老行为逐字相同的那条路）。
    func testNoSeasonWhenNeitherAutoNorManual() {
        XCTAssertNil(resolve(followsSeason: false, season: nil).season)
    }

    /// 手动季节与「跟随时间」并存：时刻照走、叶色按手动的来（两条线互不干扰）。
    func testManualSeasonCoexistsWithFollowClock() {
        let theme = ForestThemeResolver.resolve(
            mode: .day, systemIsDark: false, hour: 22, month: 6,
            followsClock: true, followsSeason: false,
            seasonOverride: .winter
        )
        XCTAssertEqual(theme.season, .winter, "夜里也按手动季节换叶色口径")
        XCTAssertEqual(theme.palette, .night, "22 点跟时间走 → 夜景")
        XCTAssertEqual(theme.moment, .night)
    }

    // MARK: - 天气手动档

    /// 关跟随后手动挑降水：下雨 / 下雪都落字段。
    func testManualWeatherAppliesWhenFollowIsOff() {
        XCTAssertEqual(resolve(followsWeather: false, weather: .rain).weather, .rain)
        XCTAssertEqual(resolve(followsWeather: false, weather: .snow).weather, .snow)
    }

    /// 跟随时手动值被忽略：dayOfYear=180（6 月底）自动判雨，哪怕手动存着雪。
    func testAutoWeatherWinsWhenFollowIsOn() {
        let theme = resolve(followsWeather: true, weather: .snow, dayOfYear: 180)
        XCTAssertEqual(theme.weather, .rain, "跟随开着 = 日序说了算，手动值只是存着")
    }

    /// 跟随着关又没挑过：weather 为 nil。
    func testNoWeatherWhenNeitherAutoNorManual() {
        XCTAssertNil(resolve(followsWeather: false, weather: nil).weather)
    }

    /// 手动天气不影响季节与时刻：它只叠自己的层。
    func testManualWeatherDoesNotTouchSeasonOrMoment() {
        let theme = resolve(followsSeason: false, season: .summer, weather: .snow)
        XCTAssertEqual(theme.season, .summer)
        XCTAssertEqual(theme.weather, .snow)
        XCTAssertEqual(theme.palette, .day)
    }

    /// 夜间手动天气照样生效（夜雪换亮一档颜色，但不拒绝下雪）。
    func testManualWeatherAtNight() {
        let theme = resolve(followsWeather: false, weather: .snow, mode: .night)
        XCTAssertEqual(theme.weather, .snow)
        XCTAssertTrue(theme.isNight)
    }

    // MARK: - 装配哨兵

    /// ⚠️ 被扫的字符串不能出现在源码注释里；反证必须真删。
    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: "Sources/\(relativePath)", encoding: .utf8)
    }

    /// theme 计算必须把两个手动值传给解析器（漏一个 = 那一路手动挑选静默失效）。
    func testAppStateWiresBothOverridesIntoTheResolver() throws {
        let appState = try source("AppUI/AppState.swift")
        XCTAssertTrue(appState.contains("seasonOverride: forestSeasonOverride"),
                      "theme 计算必须把手动季节传给解析器")
        XCTAssertTrue(appState.contains("weatherOverride: forestWeatherOverride"),
                      "theme 计算必须把手动天气传给解析器")
    }

    /// 两个 setter 必须真的写配置（存 rawValue，AppCore 不认识 AppUI 的枚举）。
    func testAppStateSettersWriteTheConfig() throws {
        let appState = try source("AppUI/AppState.swift")
        XCTAssertTrue(appState.contains("product.forestSeasonOverride = season?.rawValue"),
                      "季节 setter 必须写配置")
        XCTAssertTrue(appState.contains("product.forestWeatherOverride = weather?.rawValue"),
                      "天气 setter 必须写配置")
    }

    /// 设置页两个 segmented 必须接上 AppState 的 setter。
    func testSettingsViewHasBothManualPickers() throws {
        let settings = try source("AppUI/Views/SettingsView.swift")
        XCTAssertTrue(settings.contains("state.setForestSeasonOverride(season)"),
                      "设置页必须把手动季节写回 AppState")
        XCTAssertTrue(settings.contains("state.setForestWeatherOverride(weather)"),
                      "设置页必须把手动天气写回 AppState")
        XCTAssertTrue(settings.contains("state.forestSeasonOverride"),
                      "设置页必须读到手动手季节的当前值")
        XCTAssertTrue(settings.contains("state.forestWeatherOverride"),
                      "设置页必须读到手动手天气的当前值")
    }
}
