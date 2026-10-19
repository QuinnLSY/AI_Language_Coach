import Foundation

/// 非模型的**公共服务**身份（#604 天气预报）。
///
/// 为什么不让天气复用 `AIProviderKind`：那个枚举的每个 case 都对应一套
/// 「Provider + 模型 + 端点」的配置装配——`ConfigurationTests` 里
/// 「默认配置覆盖全部能力」钉着「每个 kind 都有 Provider」，
/// `ModelRegistry.inconsistencies` 也会对没有 Provider 的 kind 报
/// 「没有任何×× Provider」。天气是**两个固定的免密钥公共服务**：
/// 没有 Provider、没有模型、不计费。硬塞一个 case 进去，就要为它
/// 在这些不变量上处处破例 —— 那是拿假态换代码量。
///
/// 于是留痕（`remote-calls.jsonl`）与隐私披露各认这个身份：
/// 记录的 `kind` 为 nil、`service` 为这里的值。
public enum PublicService: String, Sendable, CaseIterable, Identifiable {

    /// IP 定位（ipwho.is）：出口 IP → 城市级坐标。
    case ipGeolocation = "ip-geolocation"

    /// 天气预报（Open-Meteo）：坐标 → 今日 WMO 天气代码。
    case weatherForecast = "weather-forecast"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ipGeolocation: "IP 定位"
        case .weatherForecast: "天气预报"
        }
    }

    /// 服务主机（披露与留痕用：**不含路径**，路径属于服务商的计费细节）。
    public var host: String {
        switch self {
        case .ipGeolocation: "ipwho.is"
        case .weatherForecast: "api.open-meteo.com"
        }
    }

    /// 请求路径（留痕用，与实际请求一致；Open-Meteo 的查询串不进来）。
    public var endpointPath: String {
        switch self {
        case .ipGeolocation: "/"
        case .weatherForecast: "/v1/forecast"
        }
    }

    /// 留痕 jsonl 里 `kind` 字段对公共服务的取值。
    ///
    /// 字面量只写这一处：`remote-calls.jsonl` 是用户拿去 diff 账单的文稿，
    /// 「这行是谁」必须一眼认得出，不能随着实现的改动忽而 `tts`、忽而别的写法。
    public static let jsonlKind = "public-service"
}
