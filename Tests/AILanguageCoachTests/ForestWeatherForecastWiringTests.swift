import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import XCTest
@testable import AppUI

/// 真实天气预报接进应用的那几处**接线**（#604）。
///
/// 三层各管一段：
/// - `AppState.forestWeather(for:)`：应用层那句话 → 画面档位；
/// - `ForestThemeResolver`：预报有了用它、没有退本地模拟、开关关了用手动值；
/// - 源码哨兵：刷新点（启动 / 跨天 / 开关）真的接上了。
///
/// ⚠️ 网络一层在 `ForestWeatherServiceTests` 里测，这里不碰。
final class ForestWeatherForecastWiringTests: XCTestCase {

    // MARK: - 应用层答案 → 画面档位

    /// 「预报说晴天」=.clear，「没取到预报」= nil —— 这两件事不许混。
    ///
    /// 混了的表现是：断网时看到一片假晴天（拿不到预报却当成「无降水」画上去），
    /// 而正确行为是**退回本地按日期推算**。
    func testPrecipitationMapsToPictureWeather() {
        XCTAssertEqual(AppState.forestWeather(for: .none), .clear)
        XCTAssertEqual(AppState.forestWeather(for: .rain), .rain)
        XCTAssertEqual(AppState.forestWeather(for: .snow), .snow)
    }

    /// 「取不到」由调用方那两侧处理（`refreshTodayWeather`），函数内压根不可表达 ——
    /// 这是刻意的设计：入参一可选，`.none` 就会在传值那一瞬通解自然变成 nil。
    func testMissingForecastIsHandledByTheCallerNotTheMapping() throws {
        let appState = try source("AppUI/AppState.swift")
        XCTAssertTrue(
            appState.contains("guard let precipitation = await services.todayPrecipitation() else {\n            weatherForecast = nil\n            return\n        }"),
            "取不到预报时必须显式把它记成 nil，好让画面退回本地模拟"
        )
    }

    // MARK: - 解析器：预报 / 兜底 / 手动，三条路不许串

    private func resolve(followsWeather: Bool,
                         dayOfYear: Int = 180,
                         forecast: ForestWeather? = nil,
                         weatherOverride: ForestWeather? = nil) -> ForestTheme {
        ForestThemeResolver.resolve(mode: .day, systemIsDark: false,
                                    hour: 12, month: 6,
                                    followsClock: false, followsSeason: false,
                                    followsWeather: followsWeather, dayOfYear: dayOfYear,
                                    weatherOverride: weatherOverride,
                                    weatherForecast: forecast)
    }

    /// 跟随开着且有预报 → 预报说了算，本地推算不参与。
    ///
    /// 挑一个**本地推算会给出相反答案**的日子当反例：日序 180 本地是雨，
    /// 预报说晴 → 必须画晴。用同向的样本，这条测试撤掉实现也是绿的。
    func testForecastWinsOverLocalGuess() {
        XCTAssertEqual(ForestAtmosphere.weather(dayOfYear: 180), .rain, "前提：这一天本地推算是雨")
        XCTAssertEqual(resolve(followsWeather: true, dayOfYear: 180, forecast: .clear).weather, .clear)
        XCTAssertEqual(resolve(followsWeather: true, dayOfYear: 180, forecast: .snow).weather, .snow)
    }

    /// 跟随开着但**没取到**预报 → 退回本地日期推算（森林永远有天气）。
    func testMissingForecastFallsBackToLocalGuess() {
        // 日序 3 本地推算是雪（冬季判据），180 是雨 —— 两个不同的答案才能证明
        // 「兜底确实用的是按日序算出来的那份」。
        XCTAssertEqual(ForestAtmosphere.weather(dayOfYear: 3), .snow)
        XCTAssertEqual(resolve(followsWeather: true, dayOfYear: 3, forecast: nil).weather, .snow)
        XCTAssertEqual(resolve(followsWeather: true, dayOfYear: 180, forecast: nil).weather, .rain)
    }

    /// 跟随关着 → 预报缓存**完全不参与**：用户已经说了「我自己定」。
    func testForecastIsIgnoredWhenFollowIsOff() {
        XCTAssertNil(resolve(followsWeather: false, forecast: .snow).weather)
        XCTAssertEqual(resolve(followsWeather: false, forecast: .snow, weatherOverride: .rain).weather, .rain)
    }

    /// 关着又没手动 = 老样子（weather 为 nil，逐字等于 #418-A 之前）。
    func testNoWeatherWhenFollowIsOffAndNoManualPick() {
        XCTAssertNil(resolve(followsWeather: false, weatherOverride: nil).weather)
    }

    // MARK: - 源码哨兵

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: "Sources/\(relativePath)", encoding: .utf8)
    }

    /// theme 必须把预报缓存传进解析器 —— 漏了就是「天气取回来了，画面一动不动」。
    func testAppStateFeedsTheForecastIntoTheResolver() throws {
        let appState = try source("AppUI/AppState.swift")
        XCTAssertTrue(appState.contains("weatherForecast: weatherForecast"),
                      "theme 计算必须把预报缓存传给解析器")
    }

    /// 三个刷新点：启动一次、跨天一次、开关打开时一次。
    ///
    /// ⚠️ 钉的是**调用形态**（含上下文），不是函数名出现次数 ——
    /// `if false { … }` 那种写法一样能骗过计数。
    func testWeatherRefreshIsWiredToLaunchRolloverAndToggle() throws {
        let appState = try source("AppUI/AppState.swift")
        XCTAssertTrue(
            appState.contains("Task { [weak self] in await self?.refreshTodayWeather() }"),
            "启动必须后台取一次天气（且不能挡首屏）"
        )
        XCTAssertTrue(
            appState.contains("await self.refreshTodayWeather()"),
            "跨天必须重取 —— 昨天的预报今天就是错的"
        )
        XCTAssertTrue(
            appState.contains("product.forestFollowsWeather = on\n        await persistProduct()\n        await refreshTodayWeather()"),
            "开关打开就该立刻去取一次，否则开关看起来像没反应"
        )
    }

    /// 开关关着**不发请求**：那时 `theme` 根本用不到缓存，还去联网等于不把「我关了」当回事。
    func testRefreshDoesNothingWhenFollowIsOff() throws {
        let appState = try source("AppUI/AppState.swift")
        XCTAssertTrue(
            appState.contains("guard product.forestFollowsWeather else {\n            weatherForecast = nil\n            return\n        }"),
            "跟随天气关着时不许出门问天气"
        )
    }

    /// 预报必须**不上桌**：它是缓存，跨启动不恢复，落盘就是「昨天没下雨，今天偏在下」。
    func testForecastIsNeverPersisted() throws {
        let configuration = try source("AppCore/Configuration.swift")
        XCTAssertFalse(configuration.contains("weatherForecast"), "预报是缓存，不许进配置")
        XCTAssertFalse(configuration.contains("forestForecast"), "预报是缓存，不许进配置")
    }

    // MARK: - 披露

    /// 开了跟随天气才披露，关着一个字都不提 —— 这是它能不能被信任的底线。
    func testWeatherIsOnlyDisclosedWhenItIsActuallyUsed() throws {
        var configuration = try DefaultConfiguration.load()
        XCTAssertTrue(PrivacyPolicy.publicServiceFlows(for: configuration).isEmpty,
                      "默认关着：天气一次都不发，披露里就不该出现")

        configuration.product.forestFollowsWeather = true
        let flows = PrivacyPolicy.publicServiceFlows(for: configuration)
        XCTAssertEqual(flows.count, 2, "IP 定位 + 天气预报，两步都得说")
        XCTAssertEqual(flows.map(\.service), [.ipGeolocation, .weatherForecast])
        for flow in flows {
            XCTAssertFalse(flow.outboundNote.isEmpty, "\(flow.service.rawValue) 得说清送出去的是什么")
            XCTAssertFalse(flow.host.isEmpty)
        }
        XCTAssertFalse(PrivacyPolicy.disclosure(for: configuration).isLocalOnly,
                       "开着联网了就不再是纯本地")
    }

    /// 出厂默认必须是纯本地 —— 发布闸门 `privacy.noUnintendedNetwork` 看的就是这条。
    func testDefaultConfigurationRemainsLocalOnly() throws {
        let configuration = try DefaultConfiguration.load()
        let disclosure = PrivacyPolicy.disclosure(for: configuration)
        XCTAssertTrue(disclosure.isLocalOnly)
        XCTAssertTrue(disclosure.publicServiceFlows.isEmpty)
        XCTAssertEqual(disclosure.summary, "全部数据仅在本机处理")
    }
}
