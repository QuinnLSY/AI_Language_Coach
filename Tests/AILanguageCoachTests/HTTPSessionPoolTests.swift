import XCTest

@testable import AIInfrastructure

/// #666：HTTP 会话池的判据。
///
/// 改前 `HTTPClient.performOnce` / `streamSSE` **每次请求新建 `URLSession`，用完立刻
/// `invalidateAndCancel()`** —— 连接池是挂在会话上的，会话一销毁连接就散了，下一次
/// 请求只能重走 TCP + TLS。本地回环几乎无感，云端每次调用都要再付一次握手。
///
/// 这类改动**编译照过、单测照绿**：复用悄悄退化成「每次新建」没有任何人会报错，
/// 只有「数会话被建了几次」能抓住它 —— 所以判据全部落在 `createdCount` 上。
final class HTTPSessionPoolTests: XCTestCase {

    /// 连不上的回环端口（1 号端口没人监听，立即 refused）：只碰本机，不碰外网。
    private func refusedRequest() -> URLRequest {
        URLRequest(url: URL(string: "http://127.0.0.1:1/ping")!)
    }

    /// 一个只发一次的客户端：重试会毁掉「建了几次会话」这个判据的可读性。
    private func client(pool: HTTPSessionPool, systemProxy: Bool) -> HTTPClient {
        HTTPClient(
            useSystemProxy: systemProxy,
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: 0),
            sessionPool: pool
        )
    }

    // MARK: - 判据 1：同键复用

    /// 同口径的请求必须拿到同一个会话；口径一变就不能共用。
    func testSameKeyReusesTheSession() {
        let pool = HTTPSessionPool()

        let first = pool.session(proxy: true, timeout: 15)
        let second = pool.session(proxy: true, timeout: 15)
        XCTAssertTrue(first === second, "同一口径的两次取会话应返回同一个实例")
        XCTAssertEqual(pool.createdCount, 1, "第二次不该再建会话")

        // 代理口径不同 → 不能共用：共用了就等于把本机服务的请求交给代理转发（#S2-8）。
        let noProxy = pool.session(proxy: false, timeout: 15)
        XCTAssertTrue(first !== noProxy, "绕代理与走代理绝不能共用会话")
        XCTAssertEqual(pool.createdCount, 2)

        // 超时不同 → 也不能共用：`URLSessionConfiguration` 在建会话时就被拷走，
        // 借别人的会话 = 借别人的超时（流式请求被 15s 掐断那种最难查的问题）。
        let otherTimeout = pool.session(proxy: true, timeout: 30)
        XCTAssertTrue(first !== otherTimeout, "超时不同不能共用会话")
        XCTAssertEqual(pool.createdCount, 3)

        // 回头再取旧的口径，仍然是原来那个，不该又新建一个。
        XCTAssertTrue(pool.session(proxy: true, timeout: 15) === first)
        XCTAssertEqual(pool.createdCount, 3)
    }

    // MARK: - 判据 2：请求之间真的复用

    /// 连发两次请求只建一次会话 —— 这是「连接池复用」这件事本身。
    func testRequestsShareOneSession() async throws {
        let pool = HTTPSessionPool()
        let client = self.client(pool: pool, systemProxy: true)

        _ = try? await client.perform(refusedRequest(), timeout: 5)
        XCTAssertEqual(pool.createdCount, 1, "第一次请求建了会话")
        _ = try? await client.perform(refusedRequest(), timeout: 5)
        XCTAssertEqual(
            pool.createdCount, 1,
            "第二次请求复用了会话（每次新建 = 每次握手，云端延迟全花在这上面）"
        )
    }

    // MARK: - 判据 3：回环请求复用「绕代理」那个会话

    /// 回环端点一律绕代理（#S2-8）。判据不去看代理字典（那要真建连接后才看得到），
    /// 而是看**它借走了哪一个会话**：借走「绕代理」那个 = 判定生效；自己另建一个
    /// = 判定没生效，本机服务的数据被代理接了出去。
    func testLoopbackRequestBorrowsTheNoProxySession() async throws {
        let pool = HTTPSessionPool()
        let client = self.client(pool: pool, systemProxy: true)

        // 先把「绕代理」那个会话建出来并记住它。
        let noProxy = pool.session(proxy: false, timeout: 5)
        XCTAssertEqual(pool.createdCount, 1)

        _ = try? await client.perform(refusedRequest(), timeout: 5)
        XCTAssertEqual(
            pool.createdCount, 1,
            "回环请求必须落在『绕代理』那个会话上 —— 多建一个就说明它走了系统代理"
        )
        XCTAssertTrue(
            pool.session(proxy: false, timeout: 5) === noProxy,
            "回环请求用的会话应与『绕代理』口径的会话是同一个"
        )
    }

    // MARK: - 判据 5：不许把池里的会话再 invalidate 掉

    /// `createdCount` 抓不到这种退化：**留着池、却在每次请求后 `invalidateAndCancel()`**
    /// —— 会话还是同一个（计数不变），可连接池早被销毁了，复用名存实亡。
    /// 这条只能扫源码（剥掉注释，注释里为了说明反例写了这个调用名）。
    ///
    /// 配套一条正向断言：整个池化被删掉时，负面断言会因为「压根没有那行」而恒绿。
    func testNoInvalidateAndCancelLeftInTheClient() throws {
        let raw = try String(contentsOfFile: "Sources/AIInfrastructure/HTTPClient.swift", encoding: .utf8)
        let code = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertTrue(
            code.contains("sessionPool.session(proxy:"),
            "HTTPClient 应继续从会话池取会话（整块池化被删也会让判据 5 恒绿）"
        )
        XCTAssertFalse(
            code.contains("invalidateAndCancel"),
            "请求结束不许 invalidate 会话 —— 连接池随之销毁，复用名存实亡"
        )
    }

    // MARK: - 判据 4：超时不同就换会话

    /// 超时是缓存键的一部分：不同超时各有一个会话，谁也不会借到别人的超时。
    func testDifferentTimeoutsGetDifferentSessions() async throws {
        let pool = HTTPSessionPool()
        let client = self.client(pool: pool, systemProxy: false)

        _ = try? await client.perform(refusedRequest(), timeout: 5)
        _ = try? await client.perform(refusedRequest(), timeout: 30)
        XCTAssertEqual(
            pool.createdCount, 2,
            "超时不同的请求各用一个会话（`timeoutIntervalForResource` 没有逐任务覆盖口）"
        )
    }
}
