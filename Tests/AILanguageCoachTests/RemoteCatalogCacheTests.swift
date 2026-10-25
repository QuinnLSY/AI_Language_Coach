import XCTest
import AIInterfaces
import AIProviders
import AppCore

// MARK: - 测试夹具（文件内全局，避免 @Sendable 闭包捕获不可发送的 XCTestCase）

private func sampleModels(_ ids: [String]) -> [DiscoveredModel] {
    ids.map { DiscoveredModel(id: $0, name: $0) }
}

private func catalogKey(_ secret: String = "sk-secret-abcdef") -> String {
    RemoteCatalogCache.key(
        base: URL(string: "https://api.example.com/v1")!,
        apiKey: secret,
        kind: .llm
    )
}

/// 云端模型目录缓存的行为单测（#671）。
///
/// 它守的是一条**很贵**的性质：开屏问了三遍「这家供应商有哪些模型」，
/// 而这三遍其实是同一个问题 —— 少缓存一次，用户就多等一趟跨网往返。
/// 每一条性质都配了「同一条路上不缓存会怎样」的对照（键不同 / 过期 / 失败），
/// 否则「缓存压根没生效、断言照样绿」这种假闸是看不见的。
final class RemoteCatalogCacheTests: XCTestCase {

    private actor Counter {
        private var value = 0
        func bump() { value += 1 }
        var current: Int { value }
    }

    // MARK: - 命中

    /// TTL 内的第二次调用**不发请求**。
    func testSecondCallInsideTTLDoesNotFetchAgain() async throws {
        let cache = RemoteCatalogCache()
        let counter = Counter()
        let k = catalogKey()

        let first = try await cache.models(key: k) { await counter.bump(); return sampleModels(["a", "b"]) }
        let second = try await cache.models(key: k) { await counter.bump(); return sampleModels(["z"]) }

        XCTAssertEqual(first.map(\.id), ["a", "b"])
        // 第二次闭包给的 "z" 不该被采用：命中缓存时闭包根本没跑。
        XCTAssertEqual(second.map(\.id), ["a", "b"], "命中缓存必须返回第一次的结果")
        let calls = await counter.current
        XCTAssertEqual(calls, 1, "TTL 内两次取目录只应发一次请求")
    }

    /// TTL 一过就重新取：模型列表会变（供应商上架新模型），缓存不能是永久的。
    func testExpiredEntryIsRefetched() async throws {
        let cache = RemoteCatalogCache()
        let counter = Counter()
        let k = catalogKey()

        _ = try await cache.models(key: k) { sampleModels(["old"]) }
        let later = Date().addingTimeInterval(RemoteCatalogCache.ttl + 60)
        let after = try await cache.models(key: k, now: later) {
            await counter.bump()
            return sampleModels(["new"])
        }

        XCTAssertEqual(after.map(\.id), ["new"], "过期后必须重新发请求")
        let calls = await counter.current
        XCTAssertEqual(calls, 1, "过期这一次就是重新发的那一次")
    }

    // MARK: - 合流

    /// 并发的同一个键只发一趟（开屏两处几乎同时问）。
    func testConcurrentCallsCoalesceIntoOneFetch() async throws {
        let cache = RemoteCatalogCache()
        let counter = Counter()
        let k = catalogKey()

        async let left = cache.models(key: k) {
            await counter.bump()
            try? await Task.sleep(nanoseconds: 80_000_000)
            return sampleModels(["a"])
        }
        async let right = cache.models(key: k) {
            await counter.bump()
            try? await Task.sleep(nanoseconds: 80_000_000)
            return sampleModels(["a"])
        }
        let (l, r) = try await (left, right)

        XCTAssertEqual(l.map(\.id), r.map(\.id))
        let calls = await counter.current
        XCTAssertEqual(calls, 1, "并发同键必须合流成一趟请求")
    }

    // MARK: - 失败不入缓存

    /// 一次超时不许让后面 30 秒都报「连不上」：失败**不写**缓存。
    func testFailureIsNotCached() async throws {
        let cache = RemoteCatalogCache()
        let counter = Counter()
        let k = catalogKey()

        _ = try? await cache.models(key: k) {
            await counter.bump()
            throw AIProviderError.timeout("慢")
        }
        _ = try? await cache.models(key: k) {
            await counter.bump()
            return sampleModels(["ok"])
        }

        let calls = await counter.current
        XCTAssertEqual(calls, 2, "失败之后的下一次必须重新发请求（失败没被写进缓存）")
    }

    // MARK: - 键

    /// 键要能区分「换了供应商 / 换了 Key」，且**不许**把密钥原文留在键里。
    func testKeySeparatesCredentialsAndHidesTheSecret() {
        let secret = "sk-live-1234567890"
        let k = catalogKey(secret)

        XCTAssertFalse(k.contains(secret), "缓存键里不许出现密钥原文（键名会被日志 / 调试器看到）")
        XCTAssertFalse(k.contains("1234567890"), "密钥的任一截段都不该进键名")

        XCTAssertNotEqual(k, catalogKey("sk-live-0987654321"),
                          "换了 Key 必须是另一个键，否则会拿上家的模型列表充当这一家的")
        XCTAssertNotEqual(
            k,
            RemoteCatalogCache.key(
                base: URL(string: "https://other.example.com/v1")!, apiKey: secret, kind: .llm
            ),
            "换了端点必须是另一个键"
        )
    }

    // MARK: - 接线

    /// 健康探测与模型发现必须**共用**同一个缓存入口。
    ///
    /// 它们打的是同一个 URL —— 只要哪天有人给其中一处新写一个 `client.perform`，
    /// 开屏就会悄悄多出一趟跨网往返，而这种退化在功能上完全看不出来（只是变慢）。
    func testHealthCheckAndDiscoveryShareOneCatalogFetch() throws {
        let path = "Sources/AIProviders/RemoteLLMAdapter.swift"
        let text = try String(contentsOfFile: path, encoding: .utf8)

        // 正向断言：缓存类型真的被用上了（只断言「没有裸请求」会恒绿）。
        XCTAssertTrue(text.contains("RemoteCatalogCache.shared.models"),
                      "\(path) 应当走共享缓存取模型目录")
        XCTAssertTrue(text.contains("private func fetchCatalog("),
                      "\(path) 应当有一个共用的取目录入口")

        let callers = text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .filter { !String($0.element).trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .filter { String($0.element).contains("fetchCatalog(") }
        XCTAssertEqual(callers.count, 3,
                       "声明 + 健康探测 + 模型发现，共 3 处引用（实际 \(callers.count) 处）—— 少一处就是有人绕开了缓存")
    }

    // MARK: - 真撤反证

    /// 反证：**换一个键**走同一条缓存路径，请求次数必须是 2。
    ///
    /// 光断言「同键两次 = 1 趟」是假闸 —— 计数器写错（永远返回 1）时它照样绿。
    /// 这条把「去重生效」与「去重不生效」摆在同一个测试里：一边 1 趟、一边 2 趟，
    /// 少哪一半都能立刻看出来（记忆里的「两种实现结果相反」）。
    func testDifferentKeysAreNotDeduped() async throws {
        let cache = RemoteCatalogCache()
        let counter = Counter()

        _ = try await cache.models(key: catalogKey("sk-one")) {
            await counter.bump()
            return sampleModels(["a"])
        }
        _ = try await cache.models(key: catalogKey("sk-two")) {
            await counter.bump()
            return sampleModels(["a"])
        }

        let calls = await counter.current
        XCTAssertEqual(calls, 2, "不同键不该互相命中 —— 这一条同时证明计数器真的在数")
    }
}
