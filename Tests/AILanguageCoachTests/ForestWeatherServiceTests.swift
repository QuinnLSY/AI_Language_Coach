import AIDomain
import AIInfrastructure
import XCTest

/// 天气服务的**链路**测试（#604）。
///
/// 两条纪律在这里钉住：
/// ① **任一步失败就整链放弃**（返回 nil，让森林退回本地模拟），不许从半截链子里挤出结论；
/// ② 两次请求都留下可核对的痕迹 —— 这是它们能被写进隐私披露的前提。
///
/// ⚠️ 网络一律走 `HTTPClient` 的注入传输：跑不出本机，也就不存在「断网就失败」。
/// ⚠️ 每个用例用**自己的** `RemoteCallAudit`：单例的计数与频率预算在整条测试进程里共享，
///    共用一份会让「第 N 次才被拦」这类判据互相踩踏（实测过：预算被前一个用例吃光）。
/// ⚠️ `await` 不能进 `XCTAssert` 的 autoclosure —— 一律先落到局部变量再断言。
final class ForestWeatherServiceTests: XCTestCase {

    private var logURL: URL!
    private var audit: RemoteCallAudit!

    override func setUp() {
        super.setUp()
        logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-weather-\(UUID().uuidString).jsonl")
        audit = RemoteCallAudit(fileURL: logURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: logURL)
        super.tearDown()
    }

    // MARK: - 正常链路

    func testFullChainReturnsTodaysPrecipitation() async {
        let (service, box) = makeService(ipResponse: Self.beijing, forecastResponse: Self.snowDay)
        let result = await service.todayPrecipitation()
        XCTAssertEqual(result, .snow)
        // 两次请求，各打各的服务。
        let requests = box.requests
        XCTAssertEqual(requests.count, 2, "一次刷新 = 定位一次 + 预报一次")
        XCTAssertEqual(requests.first?.url?.host, "ipwho.is")
        XCTAssertEqual(requests.last?.url?.host, "api.open-meteo.com")
    }

    /// 只给出城市级精度：坐标保留两位小数（≈1km），够了就行 ——
    /// 精细坐标既没必要，也只会把用户的位置说得更具体。
    func testForecastURLCarriesRoughCoordinatesOnly() throws {
        let url = try XCTUnwrap(ForestWeatherService.forecastURL(latitude: 39.904_199, longitude: 116.407_396))
        let query = try XCTUnwrap(url.query)
        XCTAssertTrue(query.contains("latitude=39.90"), query)
        XCTAssertTrue(query.contains("longitude=116.41"), query)
        XCTAssertFalse(query.contains("39.904"), "不该把原始精度发出去：\(query)")
        // 只要今天那一格：多要几天既浪费也用不到。
        XCTAssertTrue(query.contains("forecast_days=1"), query)
        XCTAssertTrue(query.contains("daily=weather_code"), query)
        XCTAssertEqual(url.host, "api.open-meteo.com")
    }

    // MARK: - 失败就放弃（断网 / 被限流 / 形状变了）

    /// 定位这一步就被服务端拒绝 → 不再往下问天气，结论是 nil。
    func testLocationRejectedStopsTheChain() async {
        let (service, box) = makeService(ipStatus: 429, ipResponse: Data("rate limited".utf8),
                                         forecastResponse: Self.snowDay)
        let result = await service.todayPrecipitation()
        XCTAssertNil(result)
        XCTAssertEqual(box.count, 1, "定位没成功就不该再去烦天气服务")
    }

    /// 定位一步失败也要有留痕（== nil 不等于什么都没发生）。
    func testLocationRejectionIsTraced() async {
        let (service, _) = makeService(ipStatus: 429, ipResponse: Data("rate limited".utf8),
                                       forecastResponse: Self.snowDay)
        _ = await service.todayPrecipitation()
        let records = await audit.recent(limit: 20)
        XCTAssertEqual(records.count, 1, "只发了定位这一次")
        XCTAssertEqual(records.first?.service, .ipGeolocation)
        XCTAssertEqual(records.first?.outcome, .httpError)
        XCTAssertEqual(records.first?.detail, "HTTP 429")
    }

    func testUnreadableLocationStopsTheChain() async {
        let (service, box) = makeService(ipResponse: Data("{\"success\":false}".utf8),
                                         forecastResponse: Self.snowDay)
        let result = await service.todayPrecipitation()
        XCTAssertNil(result)
        XCTAssertEqual(box.count, 1)
    }

    func testForecastRejectedYieldsNil() async {
        let (service, _) = makeService(ipResponse: Self.beijing,
                                       forecastStatus: 503,
                                       forecastResponse: Data("upstream down".utf8))
        let result = await service.todayPrecipitation()
        XCTAssertNil(result, "预报没拿到就是没拿到，不许猜")
    }

    func testTransportFailureYieldsNilAndIsTraced() async {
        let (service, _) = makeService(ipResponse: Self.beijing, forecastResponse: Self.snowDay,
                                       failsTransportOn: 1)
        let result = await service.todayPrecipitation()
        XCTAssertNil(result)
        let records = await audit.recent(limit: 20)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first?.service, .weatherForecast)
        XCTAssertEqual(records.first?.outcome, .failed)
    }

    // MARK: - 留痕

    /// 两次外发都要在留痕文件里留下对账级的身份：
    /// 用户拿着这份文件能回答「应用联系了谁」，隐私披露才有凭据。
    func testBothRequestsAreTracedWithServiceIdentity() async throws {
        let (service, _) = makeService(ipResponse: Self.beijing, forecastResponse: Self.rainDay)
        let precipitation = await service.todayPrecipitation()
        XCTAssertEqual(precipitation, .rain)

        let text = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"service\":\"ip-geolocation\""), text)
        XCTAssertTrue(text.contains("\"service\":\"weather-forecast\""), text)
        XCTAssertTrue(text.contains("\"operation\":\"weather\""), text)
        XCTAssertTrue(text.contains("\"kind\":\"public-service\""), text)
        XCTAssertEqual(text.components(separatedBy: "\n").filter { !$0.isEmpty }.count, 2)
    }

    /// 公共服务**不计费**、也**不是模型列表探测**：它们在对账卡片上自成一档。
    func testPublicServiceCallsAreCountedOnTheirOwn() async {
        let (service, _) = makeService(ipResponse: Self.beijing, forecastResponse: Self.rainDay)
        _ = await service.todayPrecipitation()
        let summary = await audit.summary()
        XCTAssertEqual(summary.publicServiceTotal, 2)
        XCTAssertEqual(summary.billableTotal, 0, "天气一分钱都不能进计费统计")
        XCTAssertEqual(summary.discoveryTotal, 0, "天气也不是模型列表探测")
        XCTAssertTrue(summary.models.isEmpty)
        XCTAssertTrue(summary.headline.contains("公共服务 2 次"), summary.headline)
    }

    // MARK: - 频率护栏

    /// 护栏真的会掐断失控刷新（每次刷新 2 次请求，上限 10 次/分钟）。
    ///
    /// ⚠️ 没有这条，`Limits.perMinute` 里给 weather 写的那行就是一句空话 ——
    /// 护栏读的是 `stamps`，而它过去只给计费调用写。
    func testRunawayRefreshIsStoppedByTheGuardrail() async {
        let (service, box) = makeService(ipResponse: Self.beijing, forecastResponse: Self.rainDay)
        var successes = 0
        var refusals = 0
        for _ in 0..<8 {
            let result = await service.todayPrecipitation()
            if result == .rain { successes += 1 } else { refusals += 1 }
        }
        XCTAssertEqual(successes, 5, "每分钟最多放行 5 次刷新（10 次请求）")
        XCTAssertEqual(refusals, 3)
        XCTAssertEqual(box.count, 10, "第 11 次请求开始就被拦下")
    }

    // MARK: - 装配

    /// 装配一次带假传输的天气服务；`box` 用来数实际发出去的请求。
    private func makeService(
        ipStatus: Int = 200,
        ipResponse: Data,
        forecastStatus: Int = 200,
        forecastResponse: Data,
        failsTransportOn index: Int? = nil
    ) -> (ForestWeatherService, RequestBox) {
        let box = RequestBox()
        let transport: HTTPClient.Transport = { request, _ in
            let step = box.record(request)
            if step == index { throw URLError(.notConnectedToInternet) }
            let isLocation = request.url?.host == "ipwho.is"
            let data = isLocation ? ipResponse : forecastResponse
            let status = isLocation ? ipStatus : forecastStatus
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.invalid")!,
                statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (data, response)
        }
        let service = ForestWeatherService(client: HTTPClient(transport: transport), audit: audit)
        return (service, box)
    }

    /// 计数器。要被 `@Sendable` 闭包捕获，因此显式甩掉 Sendable 检查 ——
    /// 它一次只服务一个请求，加锁只是为了让形态正确。
    private final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URLRequest] = []

        /// 记一笔，返回这是第几次（从 0 起）。
        func record(_ request: URLRequest) -> Int {
            lock.lock()
            defer { lock.unlock() }
            stored.append(request)
            return stored.count - 1
        }

        var requests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return stored.count
        }
    }

    private static let beijing = Data(
        """
        {"ip":"1.2.3.4","success":true,"latitude":39.9042,"longitude":116.4074,"city":"Beijing"}
        """.utf8
    )
    private static let snowDay = Data("{\"daily\":{\"weather_code\":[71]}}".utf8)
    private static let rainDay = Data("{\"daily\":{\"weather_code\":[61]}}".utf8)
}
