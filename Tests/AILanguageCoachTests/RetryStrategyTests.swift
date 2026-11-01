import AIInterfaces
import Foundation
import XCTest
@testable import AIInfrastructure

/// 重试 / 退避 / 幂等 / Retry-After（本批 ②）。
///
/// 这一组的经济含义很直接：**多一次请求 = 多一次扣费**，而账本上只记一条。
/// 所以每条判据都在回答同一个问题 —— 这一次重发到底该不该发生。
final class RetryStrategyTests: XCTestCase {

    // MARK: - 退避

    func testBackoffSequenceIsLinearWithoutJitter() {
        let policy = RetryPolicy(maxAttempts: 4, baseDelay: 0.35, jitterRatio: 0)
        // 一次算出整条再比对：不在 await 之间采样，就不会写成「测机器有多快」。
        // 浮点不能直接比 1.05（0.35 × 3 实际是 1.0499999999999998），逐项带容差。
        let sequence = policy.backoffSequence()
        XCTAssertEqual(sequence.count, 3)
        let expected = [0.35, 0.70, 1.05]
        for (index, value) in sequence.enumerated() {
            XCTAssertEqual(value, expected[index], accuracy: 1e-9, "第 \(index) 段退避")
        }
    }

    func testJitterStaysInsideTheBand() {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 1, jitterRatio: 0.25)
        // 注入的是「落在区间里的哪个值」，所以取边界就用 lowerBound / upperBound。
        XCTAssertEqual(policy.delay(forAttempt: 1, random: { $0.lowerBound }), 0.75)
        XCTAssertEqual(policy.delay(forAttempt: 1, random: { $0.upperBound }), 1.25)
        XCTAssertEqual(policy.delay(forAttempt: 1, random: { _ in 0 }), 1.0)
    }

    func testDisabledPolicyHasNoBackoffAtAll() {
        XCTAssertTrue(RetryPolicy.disabled.backoffSequence().isEmpty)
        XCTAssertEqual(RetryPolicy.disabled.maxAttempts, 1)
    }

    // MARK: - 状态码 × 幂等

    func testSafeRequestRetriesServerErrorAndRateLimit() {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0)
        XCTAssertTrue(policy.shouldRetry(status: 500, attempt: 1, idempotency: .safe))
        XCTAssertTrue(policy.shouldRetry(status: 429, attempt: 1, idempotency: .safe))
        XCTAssertFalse(policy.shouldRetry(status: 401, attempt: 1, idempotency: .safe), "4xx 是你的请求不对，重试还是同一个结果")
    }

    func testUnsafeRequestRefusesToRetryServerError() {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0)
        XCTAssertFalse(
            policy.shouldRetry(status: 500, attempt: 1, idempotency: .unsafe),
            "500 可能是「已经算完并计费、只是回包坏了」—— 重发就是第二次扣款"
        )
        XCTAssertFalse(policy.shouldRetry(status: 503, attempt: 1, idempotency: .unsafe))
    }

    func testUnsafeRequestStillRetriesRateLimit() {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0)
        XCTAssertTrue(
            policy.shouldRetry(status: 429, attempt: 1, idempotency: .unsafe),
            "429 = 请求被明确拒绝且未被处理，重发天然安全"
        )
    }

    func testAttemptBudgetIsRespected() {
        let policy = RetryPolicy(maxAttempts: 2, baseDelay: 0)
        XCTAssertTrue(policy.shouldRetry(status: 500, attempt: 1, idempotency: .safe))
        XCTAssertFalse(policy.shouldRetry(status: 500, attempt: 2, idempotency: .safe), "预算用完就得停")
    }

    // MARK: - 传输层分类

    func testRefusedConnectionIsNotRetried() {
        // 本机服务没起时就是这个码：重发还是同一个结果，只是把「立刻告诉用户」
        // 拖成「等两轮」—— 冷启动最痛的那几秒正是这么来的。
        XCTAssertFalse(TransportRetry.isRetryable(.cannotConnectToHost))
        XCTAssertFalse(TransportRetry.isRetryable(.cannotFindHost))
        XCTAssertFalse(TransportRetry.isRetryable(.dnsLookupFailed))
        XCTAssertFalse(TransportRetry.isRetryable(.notConnectedToInternet))
        XCTAssertFalse(TransportRetry.isRetryable(.timedOut))
    }

    func testDroppedConnectionIsRetried() {
        XCTAssertTrue(TransportRetry.isRetryable(.networkConnectionLost))
        XCTAssertTrue(TransportRetry.isRetryable(.badServerResponse))
    }

    func testURLErrorPathHonoursIdempotency() {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0)
        let dropped = URLError(.networkConnectionLost)
        XCTAssertTrue(policy.shouldRetry(dropped, attempt: 1, idempotency: .safe))
        XCTAssertFalse(
            policy.shouldRetry(dropped, attempt: 1, idempotency: .unsafe),
            "扣费请求连「中途断线」也不重发：不知道服务端处理到哪一步了"
        )
    }

    // MARK: - Retry-After

    func testRetryAfterAcceptsSeconds() {
        XCTAssertEqual(RetryAfter.seconds(from: "3"), 3)
        XCTAssertEqual(RetryAfter.seconds(from: " 0 "), 0)
    }

    func testRetryAfterRejectsUnreasonableValues() {
        XCTAssertNil(RetryAfter.seconds(from: "3600"), "照着等一小时会把界面冻住，早该失败告知了")
        XCTAssertNil(RetryAfter.seconds(from: "-5"))
        XCTAssertNil(RetryAfter.seconds(from: ""))
        XCTAssertNil(RetryAfter.seconds(from: nil))
        XCTAssertNil(RetryAfter.seconds(from: "not-a-number"))
    }

    func testRetryAfterAcceptsHTTPDate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let header = Self.httpDate(now.addingTimeInterval(4))
        let parsed = RetryAfter.seconds(from: header, now: now)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed ?? -1, 4, accuracy: 1.5, "HTTP-date 形式要给到秒级即可")

        let past = Self.httpDate(now.addingTimeInterval(-30))
        XCTAssertNil(RetryAfter.seconds(from: past, now: now), "过去的时刻没有意义")
    }

    // MARK: - 重试循环整合

    func testRetryAfterHeaderOverridesLocalBackoff() async throws {
        let recorder = RetryRecorder()
        let value = try await HTTPClient.retrying(
            policy: RetryPolicy(maxAttempts: 2, baseDelay: 0.35, jitterRatio: 0),
            idempotency: .safe,
            sleep: { recorder.recordSleep($0) },
            onRetry: { attempt, _ in recorder.recordAttempt(attempt) }
        ) { attempt in
            (value: attempt, status: attempt == 1 ? 429 : 200, retryAfter: attempt == 1 ? 2 : nil)
        }

        XCTAssertEqual(value, 2)
        XCTAssertEqual(recorder.sleeps, [2], "服务端已经说了等 2 秒，就别按本地 0.35 秒重打")
        XCTAssertEqual(recorder.attempts, [1])
    }

    func testUnsafeRequestIsSentExactlyOnce() async throws {
        let recorder = RetryRecorder()
        let value = try await HTTPClient.retrying(
            policy: RetryPolicy(maxAttempts: 3, baseDelay: 0, jitterRatio: 0),
            idempotency: .unsafe,
            sleep: { recorder.recordSleep($0) },
            onRetry: { attempt, _ in recorder.recordAttempt(attempt) }
        ) { attempt in
            (value: attempt, status: 500, retryAfter: nil)
        }

        XCTAssertEqual(value, 1, "扣费请求遇到 500 只发一次")
        XCTAssertTrue(recorder.sleeps.isEmpty)
        XCTAssertTrue(recorder.attempts.isEmpty)
    }

    func testSafeRequestUsesTheWholeBudget() async throws {
        let recorder = RetryRecorder()
        let value = try await HTTPClient.retrying(
            policy: RetryPolicy(maxAttempts: 3, baseDelay: 0, jitterRatio: 0),
            idempotency: .safe,
            sleep: { recorder.recordSleep($0) },
            onRetry: { attempt, _ in recorder.recordAttempt(attempt) }
        ) { attempt in
            (value: attempt, status: 500, retryAfter: nil)
        }

        XCTAssertEqual(value, 3, "安全请求用满预算（3 次尝试）")
        XCTAssertEqual(recorder.attempts, [1, 2])
    }

    // MARK: - 源码哨兵（回环短路从外部构造不出来）

    func testLoopbackEndpointsSkipRetrying() throws {
        let source = try Self.code("Sources/AIInfrastructure/HTTPClient.swift")
        XCTAssertTrue(
            source.contains("let policy = isLoopback ? RetryPolicy.disabled : retryPolicy"),
            "回环端点必须短路成不重试：本机服务没起时重发毫无意义"
        )
        XCTAssertTrue(
            source.contains("PrivacyRedactor.isLoopbackEndpoint"),
            "回环判定必须复用披露层那一个函数，不能另写一套 host 判断"
        )
    }

    func testPaidAdaptersDeclareThemselvesUnsafe() throws {
        let paid = [
            "Sources/AIProviders/RemoteLLMAdapter.swift",
            "Sources/AIProviders/RemoteTTSAdapter.swift",
            "Sources/AIProviders/RemoteASRAdapter.swift",
            "Sources/AIProviders/RemoteEmbeddingAdapter.swift",
            "Sources/AIProviders/RemotePronunciationAdapter.swift",
        ]
        for path in paid {
            let source = try Self.code(path)
            XCTAssertTrue(source.contains("idempotency: .unsafe"), "\(path) 是扣费请求，必须显式声明不可重发")
        }
    }

    func testContinuationRequestsDoNotOpenANewBillingRecord() throws {
        XCTAssertFalse(
            LLMRequest(messages: []).continuesBilledCall,
            "默认必须当成「新的一次调用」：漏标的代价是多记一笔账，而不是少记"
        )

        let adapter = try Self.code("Sources/AIProviders/RemoteLLMAdapter.swift")
        XCTAssertTrue(
            adapter.contains("let intent: RemoteCallPolicy.Intent? = request.continuesBilledCall"),
            "扣费入口必须读这个标记，否则能力位等于不存在"
        )
        XCTAssertTrue(
            adapter.contains("if let intent { await RemoteCommon.endBillableCall(intent, outcome: .ok"),
            "续作没有 Intent 时不能凭空 end 一笔不存在的账"
        )

        let chat = try Self.code("Sources/AIServices/ChatService.swift")
        XCTAssertTrue(
            chat.contains("plain.continuesBilledCall = true"),
            "流式兜底是同一次发言的续作，否则一次发言会记两次调用"
        )
    }

    // MARK: - 工具

    private nonisolated static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.string(from: date)
    }

    private nonisolated static func code(_ path: String) throws -> String {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}

/// 记录重试循环「要求睡多久、试到第几次」。
private final class RetryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _sleeps: [TimeInterval] = []
    private var _attempts: [Int] = []

    func recordSleep(_ value: TimeInterval) {
        lock.lock()
        _sleeps.append(value)
        lock.unlock()
    }

    func recordAttempt(_ attempt: Int) {
        lock.lock()
        _attempts.append(attempt)
        lock.unlock()
    }

    var sleeps: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return _sleeps
    }

    var attempts: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return _attempts
    }
}
