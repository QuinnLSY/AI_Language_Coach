import AIDomain
import AppCore
import Foundation

/// 真实天气预报（#604）：出口 IP → 城市级坐标 → 今日 WMO 天气代码 → 降水结论。
///
/// **取不到一律 nil**，一个异常都不往外抛：
/// 调用方（AppState）拿到 nil 就退回本地日期模拟（`ForestAtmosphere.weather`）。
/// 天气只是森林的一层插画装饰——为了「今天下不下雨」去打扰用户、崩一次、
/// 或者重试到卡住，都不值。
///
/// 为什么这两次请求照旧要过**费用护栏与留痕**（虽然它们不计费）：
/// 它们确实是出网的第三方请求。虽然没有账单，但「这次外发到底联系了谁」
/// 必须能在 `remote-calls.jsonl` 里逐条查到——这是整份隐私披露能被验证的前提。
public struct ForestWeatherService: Sendable {

    /// 单次请求超时。
    ///
    /// 天气是**启动时后台差事**，用户并不知道它在跑（也不会等它）；
    /// 给 8 秒是让它有充分时间成功，又不至于让一个挂着的 Task 占着半天。
    public static let requestTimeout: TimeInterval = 8

    private let client: HTTPClient
    private let audit: RemoteCallAudit

    /// - Parameter audit: 审计闸门（生产走 `.shared`）。留成参数是为了让测试用**自己的**
    ///   实例 —— 单例的使用计数是全局的，测试之间会互相吃掉对方的频率预算。
    public init(client: HTTPClient = HTTPClient(useSystemProxy: true),
                audit: RemoteCallAudit = .shared) {
        self.client = client
        self.audit = audit
    }

    // MARK: - URL

    /// IP 定位请求（ipwho.is）：出口 IP → 城市级坐标。
    ///
    /// ⚠️ URL **只在这里拼**（服务自己给出了 host）；别在别处再抄一遍字面量，
    /// 否则留痕里的 host 与实际请求的 host 迟早分叉。
    public static func ipLocationURL() -> URL? {
        URL(string: "https://\(PublicService.ipGeolocation.host)/")
    }

    /// 天气预报请求（Open-Meteo）：只要**今天**那一格天气代码。
    ///
    /// 坐标只保留两位小数（≈ 1.1 km）：城市级精度对天气足够，
    /// 更精细的坐标既没必要也只会把用户的位置说得更具体。
    public static func forecastURL(latitude: Double, longitude: Double) -> URL? {
        let lat = String(format: "%.2f", latitude)
        let lon = String(format: "%.2f", longitude)
        let host = PublicService.weatherForecast.host
        let query = "latitude=\(lat)&longitude=\(lon)&daily=weather_code&timezone=auto&forecast_days=1"
        return URL(string: "https://\(host)\(PublicService.weatherForecast.endpointPath)?\(query)")
    }

    // MARK: - 取今日降水

    /// 今日降水结论。任一步失败 = nil（断网 / 被限流 / 响应形状变了都算）。
    public func todayPrecipitation() async -> WeatherForecast.Precipitation? {
        guard let locationURL = Self.ipLocationURL() else { return nil }
        guard let coordinates = await Self.step(
            service: .ipGeolocation, url: locationURL, client: client, audit: audit,
            decode: WeatherForecast.coordinates(ipWhoIsPayload:)
        ) else { return nil }

        guard let forecastURL = Self.forecastURL(latitude: coordinates.latitude,
                                                 longitude: coordinates.longitude) else { return nil }
        return await Self.step(
            service: .weatherForecast, url: forecastURL, client: client, audit: audit,
            decode: WeatherForecast.precipitation(openMeteoPayload:)
        )
    }

    /// 一次「过闸门 → 发请求 → 留痕 → 解码」。
    ///
    /// 抽成一个泛型是为了让两个服务的**纪律相同**（不可能只偏心其中一个）：
    /// ① 护栏没放行就根本不发；② 非 2xx 记一条 `httpError` 并返回 nil；
    /// ③ 传输异常记一条 `failed` 并返回 nil；④ 解码不出来也返回 nil。
    private static func step<T>(
        service: PublicService,
        url: URL,
        client: HTTPClient,
        audit: RemoteCallAudit,
        decode: @Sendable (Data) -> T?
    ) async -> T? {
        let intent = RemoteCallPolicy.Intent(service: service, operation: .weather)

        if case .denied(let reason) = await audit.authorize(intent) {
            AppLog.info("天气这一步被护栏拦下：\(reason)", category: "weather")
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        do {
            let (data, response) = try await client.perform(request, timeout: requestTimeout)
            guard (200..<300).contains(response.statusCode) else {
                await audit.record(intent, outcome: .httpError, httpStatus: response.statusCode)
                AppLog.info("天气服务返回 \(response.statusCode)，退回本地模拟", category: "weather")
                return nil
            }
            await audit.record(intent, outcome: .ok, httpStatus: response.statusCode)
            guard let value = decode(data) else {
                AppLog.info("天气响应认不出来（\(service.rawValue)），退回本地模拟", category: "weather")
                return nil
            }
            return value
        } catch {
            await audit.record(intent, outcome: .failed)
            AppLog.info("天气请求失败，退回本地模拟：\(error.localizedDescription)", category: "weather")
            return nil
        }
    }
}
