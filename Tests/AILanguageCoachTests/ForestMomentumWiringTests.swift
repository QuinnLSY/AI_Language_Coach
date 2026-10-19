import AIDomain
import AppCore
import AppUI
import XCTest

/// #600 接线：学习节奏从 `ProgressSnapshot` 派生、进 Resolver、落进 `ForestTheme`。
final class ForestMomentumWiringTests: XCTestCase {

    private func resolve(momentum: ForestMomentum?,
                         followsSeason: Bool = true,
                         followsWeather: Bool = false,
                         dayOfYear: Int = 60,
                         hour: Int = 12,
                         weatherForecast: ForestWeather? = nil) -> ForestTheme {
        ForestThemeResolver.resolve(
            mode: .day, systemIsDark: false,
            hour: hour, month: 3,
            followsClock: true, followsSeason: followsSeason,
            followsWeather: followsWeather, dayOfYear: dayOfYear,
            weatherForecast: weatherForecast,
            momentum: momentum
        )
    }

    // MARK: - Resolver 集成

    func testResolverCarriesMomentumIntoTheme() {
        XCTAssertEqual(resolve(momentum: .flourishing).momentum, .flourishing)
        XCTAssertEqual(resolve(momentum: .growing).momentum, .growing)
        XCTAssertNil(resolve(momentum: nil).momentum, "不跟随学习节奏 → 老样子")
    }

    func testMomentumNilKeepsThemeUnchanged() {
        // 全关 + momentum nil：与加这个参数之前逐字相等（Equatable 钉得住）。
        let plain = ForestThemeResolver.resolve(mode: .day, systemIsDark: false,
                                                hour: 12, month: 3,
                                                followsClock: false, followsSeason: false)
        XCTAssertNil(plain.moment)
        XCTAssertNil(plain.season)
        XCTAssertNil(plain.weather)
        XCTAssertNil(plain.momentum)
    }

    func testFlourishingFoliageDiffersFromResting() {
        // 丰季叶色走盛档（白天；春天原色 0x6CC476 → lush 0x52C65F）。
        let resting = resolve(momentum: nil)
        let flourishing = resolve(momentum: .flourishing)
        XCTAssertNotEqual(resting.foliage, flourishing.foliage, "丰季必须让叶色变盛")
        XCTAssertNotEqual(resting.foliageDeep, flourishing.foliageDeep)
        XCTAssertNotEqual(resting.hillMid, flourishing.hillMid)
        // 成长 / 休憩不掺和（非惩罚性：停滞也不会让叶色变衰）。
        XCTAssertEqual(resolve(momentum: .growing).foliage, resting.foliage)
        XCTAssertEqual(resolve(momentum: .resting).foliage, resting.foliage)
    }

    func testFlourishingDoesNotTouchNightFoliage() {
        // 夜里看不出叶色（既有约定）：丰季也不许把夜景改坏。
        let night = ForestThemeResolver.resolve(
            mode: .night, systemIsDark: true,
            hour: 23, month: 3,
            followsClock: true, followsSeason: true,
            momentum: .flourishing
        )
        let nightResting = ForestThemeResolver.resolve(
            mode: .night, systemIsDark: true,
            hour: 23, month: 3,
            followsClock: true, followsSeason: true
        )
        XCTAssertEqual(night.foliage, nightResting.foliage, "夜档叶色不随节奏变")
    }

    func testFlourishingBiasesFallbackWeatherOnly() {
        // day 60 常态是雨；丰季 + 取不到预报 → 兜底模拟偏晴。
        let flourishing = resolve(momentum: .flourishing, followsWeather: true, dayOfYear: 60)
        XCTAssertEqual(flourishing.weather, .clear, "丰季偏晴只发生在本地兜底模拟里")
        let resting = resolve(momentum: nil, followsWeather: true, dayOfYear: 60)
        XCTAssertEqual(resting.weather, .rain)
    }

    func testRealForecastWinsOverMomentum() {
        // ⚠️ 真天气预报拿到了就以它为准 —— 学业节奏是氛围奖励，
        // 不是给用户播报假天气的许可（今天真实下雨就不能因为达标而放晴）。
        let rainy = resolve(momentum: .flourishing, followsWeather: true,
                            dayOfYear: 60, weatherForecast: .rain)
        XCTAssertEqual(rainy.weather, .rain, "真实预报不许被节奏覆盖")
        let snowy = resolve(momentum: .flourishing, followsWeather: true,
                            dayOfYear: 8, weatherForecast: .snow)
        XCTAssertEqual(snowy.weather, .snow)
        // 预报说晴也照用（clear 是可信结论，不是「没取到」）。
        let clear = resolve(momentum: .growing, followsWeather: true,
                            dayOfYear: 60, weatherForecast: .clear)
        XCTAssertEqual(clear.weather, .clear)
    }

    func testMomentumDoesNotNeedFollowsSeason() {
        // 只开节奏（不开季节跟随）时 theme 也要带上 momentum：
        // 盛档判据在 ForestTheme.seasonal 里，没季节时它不显色，但字段必须在。
        let theme = resolve(momentum: .flourishing, followsSeason: false)
        XCTAssertEqual(theme.momentum, .flourishing)
        XCTAssertNil(theme.season, "没开季节跟随 → 不分季节")
    }

    // MARK: - 源码哨兵（接线断了要红在这里）

    /// ⚠️ 被扫的字符串不能出现在源码注释里；反证必须真删。
    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: "Sources/\(relativePath)", encoding: .utf8)
    }

    /// theme 计算必须把当前学习节奏传给解析器（漏传 = 开关开了也没反应）。
    func testAppStateWiresMomentumIntoTheResolver() throws {
        let appState = try source("AppUI/AppState.swift")
        XCTAssertTrue(appState.contains("momentum: forestMomentum"),
                      "theme 计算必须把学习节奏传给解析器")
    }

    /// setter 必须真的写配置并持久化。
    func testAppStateSetterWritesTheConfig() throws {
        let appState = try source("AppUI/AppState.swift")
        XCTAssertTrue(appState.contains("product.forestFollowsMomentum = on"),
                      "节奏开关 setter 必须写配置")
    }

    /// 设置页开关必须接上 AppState 的读写。
    func testSettingsViewHasMomentumToggle() throws {
        let settings = try source("AppUI/Views/SettingsView.swift")
        XCTAssertTrue(settings.contains("state.setForestFollowsMomentum(on)"),
                      "设置页必须把开关写回 AppState")
        XCTAssertTrue(settings.contains("state.forestFollowsMomentum"),
                      "设置页必须读到开关的当前值")
        XCTAssertTrue(settings.contains("state.forestMomentum"),
                      "设置页 hint 必须显示当前节奏")
    }
}
