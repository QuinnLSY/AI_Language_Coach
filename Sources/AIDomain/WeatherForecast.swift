import Foundation

/// 天气预报的**纯函数**解码（#604）。
///
/// 这里不碰 I/O、不认识 UI：把两个服务商的响应字节翻成「今天有没有降水、
/// 是雨还是雪」的结论。翻不出来一律 nil —— 调用方（`ForestWeatherService`）
/// 拿到 nil 就退回本地日期模拟，绝不在解析层猜。
public enum WeatherForecast {

    /// 降水结论。森林插画层只分「无降水 / 雨 / 雪」三档（#603 收窄后的口径）。
    public enum Precipitation: String, Sendable, Equatable, CaseIterable {
        /// 无降水（晴 / 多云 / 雾）。
        case none
        case rain
        case snow

        public var displayName: String {
            switch self {
            case .none: "晴"
            case .rain: "下雨"
            case .snow: "下雪"
            }
        }
    }

    // MARK: - WMO 代码 → 降水

    /// WMO 天气代码 → 降水结论。
    ///
    /// 只认 Open-Meteo 实际会返回的那些码；认不出的按「无降水」算 ——
    /// 宁可少一层雨，也不把一个来路不明的码渲染成暴雪。
    ///
    /// 归类口径（与服务商文档一致）：
    /// - 无降水：0–3（晴到阴）、45/48（雾）；
    /// - 雨：51–57（毛毛雨 / 冻毛毛雨）、61–67（雨 / 冻雨）、80–82（阵雨）、
    ///   95–99（雷阵雨 —— 森林层没有「雷」这一档，并进雨）；
    /// - 雪：71–77（雪 / 雪粒）、85–86（阵雪）。
    public static func precipitation(wmoCode: Int) -> Precipitation {
        switch wmoCode {
        case 0, 1, 2, 3, 45, 48:
            return .none
        case 51, 53, 55, 56, 57,
             61, 63, 65, 66, 67,
             80, 81, 82,
             95, 96, 99:
            return .rain
        case 71, 73, 75, 77, 85, 86:
            return .snow
        default:
            return .none
        }
    }

    // MARK: - Open-Meteo 响应

    /// Open-Meteo `daily.weather_code` 的**今天**那一格 → 降水结论。
    ///
    /// 解析失败（不是 JSON / 缺 `daily` / 代码数组为空）= nil。
    public static func precipitation(openMeteoPayload data: Data) -> Precipitation? {
        guard let payload = try? JSONDecoder().decode(OpenMeteoPayload.self, from: data),
              let code = payload.daily.weatherCode.first else { return nil }
        return precipitation(wmoCode: code)
    }

    /// Open-Meteo 只取 `daily=weather_code&forecast_days=1`，响应形状：
    /// `{"daily": {"time": ["2026-10-18"], "weather_code": [3]}}`。
    private struct OpenMeteoPayload: Decodable {
        let daily: Daily
        struct Daily: Decodable {
            let weatherCode: [Int]
            // 键名就是服务商的 snake_case 字面量，显式映射 —— 不走
            // `convertFromSnakeCase`（`prosodyStyle` 被静默翻错的教训）。
            private enum CodingKeys: String, CodingKey {
                case weatherCode = "weather_code"
            }
        }
    }

    // MARK: - ipwho.is 响应

    /// ipwho.is 响应 → 坐标。
    ///
    /// 失败形状（限流 / 查不到）是 `{"success": false, "message": "..."}`：
    /// 没有坐标字段，按解析失败算（nil）。坐标还要过一道范围钳制 ——
    /// 越界值发去 Open-Meteo 只会拿到 400，不如在这里就当成没定位到。
    public static func coordinates(ipWhoIsPayload data: Data) -> (latitude: Double, longitude: Double)? {
        guard let payload = try? JSONDecoder().decode(IPWhoIsPayload.self, from: data),
              payload.success,
              let latitude = payload.latitude, let longitude = payload.longitude,
              latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        return (latitude, longitude)
    }

    private struct IPWhoIsPayload: Decodable {
        let success: Bool
        let latitude: Double?
        let longitude: Double?
    }
}
