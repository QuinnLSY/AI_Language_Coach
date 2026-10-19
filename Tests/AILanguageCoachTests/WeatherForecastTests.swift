import AIDomain
import XCTest

/// 天气预报的**解码层**测试（#604）：两个服务商的响应字节 → 降水结论。
///
/// 这里的判据是一条都不能松的边界：**认不出来就返回 nil**，让调用方退回本地模拟。
/// 宁可少一层雨，也不能把一个来路不明的数字渲染成暴雪。
final class WeatherForecastTests: XCTestCase {

    // MARK: - WMO 天气代码

    /// 三个降水档各自的代表码都要落到对的位置。
    func testWMOCodesMapToTheRightPrecipitation() {
        for code in [0, 1, 2, 3, 45, 48] {
            XCTAssertEqual(WeatherForecast.precipitation(wmoCode: code), .none, "WMO \(code) 应是无降水")
        }
        for code in [51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82, 95, 96, 99] {
            XCTAssertEqual(WeatherForecast.precipitation(wmoCode: code), .rain, "WMO \(code) 应是雨")
        }
        for code in [71, 73, 75, 77, 85, 86] {
            XCTAssertEqual(WeatherForecast.precipitation(wmoCode: code), .snow, "WMO \(code) 应是雪")
        }
    }

    /// 认不出的码按「无降水」算。
    ///
    /// 这不是保守，是**必须**：Open-Meteo 将来加一档我们没见过的码，
    /// 猜成雨就是天天假下雨，猜成雪更离谱。
    func testUnknownWMOCodeIsTreatedAsNoPrecipitation() {
        XCTAssertEqual(WeatherForecast.precipitation(wmoCode: -1), .none)
        XCTAssertEqual(WeatherForecast.precipitation(wmoCode: 999), .none)
        XCTAssertEqual(WeatherForecast.precipitation(wmoCode: 4), .none)
    }

    /// 三个降水档都长得不一样 —— 少了这条，「全都判成晴」也能通过上面每一条测试。
    func testEveryPrecipitationCaseIsDistinct() {
        let all = WeatherForecast.Precipitation.allCases
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(Set(all.map(\.rawValue)).count, all.count)
        XCTAssertEqual(WeatherForecast.Precipitation.none.displayName, "晴")
        XCTAssertEqual(WeatherForecast.Precipitation.rain.displayName, "下雨")
        XCTAssertEqual(WeatherForecast.Precipitation.snow.displayName, "下雪")
    }

    // MARK: - Open-Meteo 响应

    func testDecodesTodaysWeatherCode() throws {
        let json = """
        {"latitude":39.9,"longitude":116.4,"daily":{"time":["2026-10-19"],"weather_code":[61]}}
        """
        let result = WeatherForecast.precipitation(openMeteoPayload: Data(json.utf8))
        XCTAssertEqual(result, .rain)
    }

    /// 只取**第一格**（今天）：服务端多给几天也不能跟着往后翻。
    func testOnlyTheFirstDayCounts() throws {
        let json = """
        {"daily":{"weather_code":[71,0,95]}}
        """
        XCTAssertEqual(WeatherForecast.precipitation(openMeteoPayload: Data(json.utf8)), .snow)
    }

    /// 空数组 / 不是 JSON / 缺 daily —— 一律 nil（解析层不猜）。
    func testUndecodableForecastPayloadsYieldNil() {
        let cases = [
            "",
            "not json",
            "{}",
            "{\"daily\":{\"weather_code\":[]}}",
            "{\"daily\":{\"time\":[]}}",
            "{\"error\":true,\"reason\":\"minute API request limit exceeded\"}"
        ]
        for payload in cases {
            XCTAssertNil(
                WeatherForecast.precipitation(openMeteoPayload: Data(payload.utf8)),
                "\(payload) 认不出来就该是 nil"
            )
        }
    }

    // MARK: - ipwho.is 响应

    func testDecodesCoordinates() {
        let json = """
        {"ip":"1.2.3.4","success":true,"latitude":39.9042,"longitude":116.4074,"city":"Beijing"}
        """
        let coordinates = WeatherForecast.coordinates(ipWhoIsPayload: Data(json.utf8))
        XCTAssertNotNil(coordinates)
        XCTAssertEqual(coordinates?.latitude ?? 0, 39.9042, accuracy: 0.0001)
        XCTAssertEqual(coordinates?.longitude ?? 0, 116.4074, accuracy: 0.0001)
    }

    /// `success: false`（限流 / 查不到）没有坐标字段 —— 必须按失败算，
    /// 否则会拿 0,0 去问「几内亚湾今天下不下雪」。
    func testFailurePayloadYieldsNil() {
        let json = """
        {"success":false,"message":"Rate limit reached"}
        """
        XCTAssertNil(WeatherForecast.coordinates(ipWhoIsPayload: Data(json.utf8)))
    }

    /// 坐标还要过一道范围钳制：越界值发去 Open-Meteo 只会拿到 400，
    /// 不如在这里就当成没定位到。
    func testOutOfRangeCoordinatesAreRejected() {
        for (lat, lon) in [(91.0, 0.0), (-91.0, 0.0), (0.0, 181.0), (0.0, -181.0)] {
            let json = """
            {"success":true,"latitude":\(lat),"longitude":\(lon)}
            """
            XCTAssertNil(
                WeatherForecast.coordinates(ipWhoIsPayload: Data(json.utf8)),
                "越界坐标 \(lat),\(lon) 不该被接受"
            )
        }
    }

    /// NaN / Infinity 也不是合法坐标（`isFinite` 那一道守卫）。
    func testNonFiniteCoordinatesAreRejected() {
        let json = """
        {"success":true,"latitude":1e999,"longitude":0}
        """
        XCTAssertNil(WeatherForecast.coordinates(ipWhoIsPayload: Data(json.utf8)))
    }

    // MARK: - 公共服务身份

    func testPublicServicesDescribeThemselves() {
        XCTAssertEqual(PublicService.allCases.count, 2)
        for service in PublicService.allCases {
            XCTAssertFalse(service.displayName.isEmpty)
            XCTAssertFalse(service.host.isEmpty)
            XCTAssertTrue(service.endpointPath.hasPrefix("/"), "\(service.rawValue) 的路径得是绝对路径")
        }
        XCTAssertEqual(PublicService.ipGeolocation.host, "ipwho.is")
        XCTAssertEqual(PublicService.weatherForecast.host, "api.open-meteo.com")
    }
}
