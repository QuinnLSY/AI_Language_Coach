import AppCore
import XCTest
@testable import AppUI

/// 森林天气（#418-A）单测。
///
/// 覆盖四件事：
/// 1. 天气判据是**日期**的确定性纯函数（同一天永远同一种天气，一天内不变卦）；
/// 2. 整个 100 天散列周期恰好五五分成（50 晴 / 30 多云 / 20 雨）——分布是有意设计的，不是玄学；
/// 3. 天气**只改插画层**：开关关着时主题与旧版逐字相等，开着时天空渐变本色不变；
/// 4. 装配哨兵：配置字段、设置开关、AppState 接线一处都不能少。
final class ForestWeatherTests: XCTestCase {

    // MARK: - ① 判据

    func testSameDayAlwaysGetsTheSameWeather() {
        // 确定性：同一天问一百遍，答案必须一样。
        for day in [1, 2, 3, 100, 180, 366] {
            let first = ForestAtmosphere.weather(dayOfYear: day)
            for _ in 0..<100 {
                XCTAssertEqual(ForestAtmosphere.weather(dayOfYear: day), first)
            }
        }
    }

    /// ⚠️ 别写 `allCases.contains(...)` 这种断言：返回值是非空的 `ForestWeather`，
    /// `allCases` 覆盖全部三档 —— 对任何实现都成立，撤掉实现也不会变红。
    /// 真正有效的是下面两条**等值**断言（越界必须钳到边界那一天）。
    func testOutOfRangeDaysAreClampedNotFatal() {
        XCTAssertEqual(ForestAtmosphere.weather(dayOfYear: 0),
                       ForestAtmosphere.weather(dayOfYear: 1))
        XCTAssertEqual(ForestAtmosphere.weather(dayOfYear: -5),
                       ForestAtmosphere.weather(dayOfYear: 1))
        XCTAssertEqual(ForestAtmosphere.weather(dayOfYear: 999),
                       ForestAtmosphere.weather(dayOfYear: 366))
        XCTAssertEqual(ForestAtmosphere.weather(dayOfYear: 367),
                       ForestAtmosphere.weather(dayOfYear: 366))
    }

    /// 判据里不许出现「当下时刻」：一天之内问多少次都必须同答（这是「不变卦」的真判据）。
    func testWeatherNeverReadsTheClock() throws {
        let raw = try String(contentsOfFile: "Sources/AppUI/Theme/ForestAtmosphere.swift",
                             encoding: .utf8)
        let body = raw.split(separator: "\n")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertFalse(body.contains("Date()"), "天气判据不能读当前时刻（一天之内会变卦）")
        XCTAssertFalse(body.contains(".random"), "天气判据不能用随机数（同一天必须同答）")
    }

    /// 全年（不只是前 100 天）都要有定义，且分布大致守住五/三/二。
    func testWholeYearStaysWithinDesignedMix() {
        var counts = [ForestWeather: Int]()
        for day in 1...366 {
            counts[ForestAtmosphere.weather(dayOfYear: day), default: 0] += 1
        }
        let total = counts.values.reduce(0, +)
        XCTAssertEqual(total, 366, "闰年 366 天每一天都要有天气")
        XCTAssertEqual(counts[.clear] ?? 0, 183)
        XCTAssertEqual(counts[.cloudy] ?? 0, 110)
        XCTAssertEqual(counts[.rain] ?? 0, 73)
    }

    func testOneFullCycleSplitsFiftyThirtyTwenty() {
        // 61 与 100 互质 → 前 100 天恰好铺满全部散列值：50 晴 / 30 多云 / 20 雨。
        var counts = [ForestWeather: Int]()
        for day in 1...100 {
            counts[ForestAtmosphere.weather(dayOfYear: day), default: 0] += 1
        }
        XCTAssertEqual(counts[.clear], 50)
        XCTAssertEqual(counts[.cloudy], 30)
        XCTAssertEqual(counts[.rain], 20)
    }

    // MARK: - ② 主题只改插画层

    /// 开关关着：主题与旧版**逐字相等**（weather 为 nil）——升级不改老用户看到的样子。
    func testResolverWithoutWeatherSwitchMatchesLegacyTheme() {
        let legacy = ForestThemeResolver.resolve(mode: .day, systemIsDark: false,
                                                 hour: 12, month: 6,
                                                 followsClock: false, followsSeason: false)
        let withSwitch = ForestThemeResolver.resolve(mode: .day, systemIsDark: false,
                                                     hour: 12, month: 6,
                                                     followsClock: false, followsSeason: false,
                                                     followsWeather: false, dayOfYear: 83)
        XCTAssertEqual(withSwitch, legacy, "跟随天气关着时，主题必须与旧版逐字相等")
        XCTAssertNil(legacy.weather)
    }

    /// 开关开着：weather 落字段，但**天空渐变本色不变**（雨是叠上去的一层，不是换一片天）。
    func testWeatherDoesNotTouchTheSkyGradient() {
        let clear = ForestThemeResolver.resolve(mode: .day, systemIsDark: false,
                                                hour: 12, month: 6,
                                                followsClock: false, followsSeason: false,
                                                followsWeather: false)
        let raining = ForestThemeResolver.resolve(mode: .day, systemIsDark: false,
                                                  hour: 12, month: 6,
                                                  followsClock: false, followsSeason: false,
                                                  followsWeather: true, dayOfYear: 3)
        XCTAssertEqual(raining.weather, .rain, "dayOfYear=3 应判为雨")
        XCTAssertEqual(raining.sky, clear.sky, "雨天的天空渐变必须与晴天同色（插画层叠加，不改本色）")
        // 夜里也照样落字段（夜雨换暗一档的颜色，但不拒绝下雨）。
        let night = ForestThemeResolver.resolve(mode: .night, systemIsDark: false,
                                                hour: 12, month: 6,
                                                followsClock: false, followsSeason: false,
                                                followsWeather: true, dayOfYear: 3)
        XCTAssertEqual(night.weather, .rain)
        XCTAssertTrue(night.isNight)
    }

    // MARK: - ③ 装配哨兵

    /// ⚠️ 被扫的字符串不能出现在源码注释里；反证必须真删。
    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: "Sources/\(relativePath)", encoding: .utf8)
    }

    func testAppStateWiresTheWeatherSwitch() throws {
        let appState = try source("AppUI/AppState.swift")
        XCTAssertTrue(appState.contains("followsWeather: product.forestFollowsWeather"),
                      "theme 计算必须把天气开关传给解析器")
        XCTAssertTrue(appState.contains("dayOfYear: clockDayOfYear"),
                      "theme 计算必须把年内日序传给解析器")
        XCTAssertTrue(appState.contains("product.forestFollowsWeather = on"),
                      "开关 setter 必须真的写配置")
    }

    func testSettingsViewHasTheWeatherToggle() throws {
        let settings = try source("AppUI/Views/SettingsView.swift")
        XCTAssertTrue(settings.contains("state.forestFollowsWeather"),
                      "设置页必须读到天气开关")
        XCTAssertTrue(settings.contains("state.setForestFollowsWeather(on)"),
                      "设置页必须把开关写回 AppState")
    }
}
