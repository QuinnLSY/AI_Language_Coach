import AIInterfaces
import Foundation

// MARK: - 重试策略

/// 瞬时故障重试策略。
///
/// 存在的理由：`AIProviderError.isRetryable` 把「哪些错误值得重试」写得很完整，
/// 但真正决定「要不要再发一次」的还得是这里 —— 因为「值得重试」和「重试是安全的」
/// 是两个正交的维度：
///
/// - **值得**：5xx / 429 / 断线，等一会儿可能就好（`isRetryable`）。
/// - **安全**：重发一次不会让用户多付一次钱、多生成一份内容（`Idempotency`）。
///
/// 两条护栏写死在契约里：
/// - **只重试「上一次根本没拿到可用响应」的情况**（`perform` 是非流式路径）。
///   流式请求（`streamSSE`）绝不重试：那会把同一份 Prompt 再发一遍 = 重复计费。
/// - **超时不重试**：用户已经等满一整轮超时，再等一轮等于把「卡住」变成「卡死」。
public struct RetryPolicy: Sendable {

    /// 这次请求**重复发送**是否安全。
    public enum Idempotency: Sendable, Equatable {
        /// GET 类发现、探活、纯查询：发几次与发一次等价。
        case safe
        /// 扣费 / 有副作用（chat / TTS / 转写 / 评测）：服务端可能已经处理并计费，
        /// 此时重发就是第二次扣款 —— 而本地账本与 `remote-calls.jsonl` 只记 1 条，
        /// 账、实、留痕三者对不上，事后无从核对。
        ///
        /// ⚠️ 只有 **429** 是例外：它表示请求被明确拒绝、**没有被处理**，
        /// 重发天然安全（而且服务端通常会顺手给一个 `Retry-After`）。
        /// 5xx 不行 —— 那可能是「已经算完了但回包失败」。
        case unsafe
    }

    /// 默认：最多 2 次尝试（= 允许 1 次重试），退避 0.35s，带 ±25% 抖动。
    public static let `default` = RetryPolicy(maxAttempts: 2, baseDelay: 0.35)

    /// 一次都不再试。用于回环端点（失败 = 服务没起，重发还是同一个结果）。
    public static let disabled = RetryPolicy(maxAttempts: 1, baseDelay: 0)

    /// 默认抖动幅度。
    ///
    /// 抖动不是「加点随机更自然」，是必须的：同一批请求（批量附件、并发翻译、
    /// 一眼扫多个生词）失败时间几乎重合，不抖动就会在同一毫秒一起重打 ——
    /// 把「偶发限流」变成「必然限流」。
    public static let defaultJitterRatio = 0.25

    /// 总尝试次数（1 = 不重试）。
    public let maxAttempts: Int
    /// 第 n 次重试前的**基准**退避（线性：`baseDelay × n`）。
    public let baseDelay: TimeInterval
    /// 抖动幅度（占基准退避的比例）。0 = 无抖动。
    public let jitterRatio: Double

    public init(maxAttempts: Int, baseDelay: TimeInterval, jitterRatio: Double = RetryPolicy.defaultJitterRatio) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = max(0, baseDelay)
        self.jitterRatio = min(max(0, jitterRatio), 1)
    }

    // MARK: 判定

    /// 该不该再试一次（传输层错误）。
    func shouldRetry(_ error: Error, attempt: Int, idempotency: Idempotency) -> Bool {
        guard attempt < maxAttempts else { return false }
        // 有副作用的请求：连"要不要重试"的门槛都过不了，除非底层明确说是可重放的传输故障。
        // 这里保守取「不重试」—— 少发一次总能靠用户手点重试补回来，多发一次的钱要不回来。
        guard idempotency == .safe else { return false }
        guard let providerError = error as? AIProviderError else { return false }
        // 用户主动取消：立刻停，不许偷偷再发一次。
        if case .cancelled = providerError { return false }
        if case .timeout = providerError { return false }
        return providerError.isRetryable
    }

    /// 该不该再试一次（传输层 `URLError`）。
    ///
    /// 与上面那条分开，是因为 `URLError.code` 里藏着「重发注定没用」的确定信息：
    /// 连不上 / 找不到主机 / DNS 失败 / 无网络 —— 这些是**环境问题**，不是瞬时抖动。
    func shouldRetry(_ error: URLError, attempt: Int, idempotency: Idempotency) -> Bool {
        guard attempt < maxAttempts else { return false }
        guard TransportRetry.isRetryable(error.code) else { return false }
        guard idempotency == .safe else { return false }
        return true
    }

    /// 该不该再试一次（服务端状态码）。
    ///
    /// 判定口径**复用** `AIProviderError.isRetryable`，不在这里另写一份 ——
    /// 「哪些错值得重试」只能有一个答案，两份口径迟早分叉。
    func shouldRetry(status: Int, attempt: Int, idempotency: Idempotency) -> Bool {
        guard attempt < maxAttempts else { return false }
        switch idempotency {
        case .unsafe:
            // 429 = 明确被拒、未被处理 → 重发安全。
            return status == 429
        case .safe:
            return AIProviderError.serverError(status: status, message: nil).isRetryable
        }
    }

    // MARK: 退避

    /// 第 `attempt` 次重试前该睡多久。
    ///
    /// `random` 可注入，是为了让整条序列能被**精确断言**而不靠抽样碰运气。
    func delay(
        forAttempt attempt: Int,
        random: (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
    ) -> TimeInterval {
        let base = baseDelay * Double(max(1, attempt))
        guard jitterRatio > 0, base > 0 else { return base }
        let factor = 1 + random(-jitterRatio...jitterRatio)
        return max(0, base * factor)
    }

    /// 整条退避序列（`maxAttempts - 1` 个元素）。
    ///
    /// 一次算出整条而不是逐个取，测试就能直接比对数组 ——
    /// 不用在 `await` 之间采样，也就不会写出「测出来的是机器此刻有多快」那种判据。
    public func backoffSequence(
        random: (ClosedRange<Double>) -> Double = { Double.random(in: $0) }
    ) -> [TimeInterval] {
        guard maxAttempts > 1 else { return [] }
        return (1..<maxAttempts).map { delay(forAttempt: $0, random: random) }
    }
}

// MARK: - Retry-After

/// `Retry-After` 响应头的解析（RFC 7231 的两种形式）。
///
/// 过去这个头**全仓零读取**：429 一律按本地退避 0.35s 重打，于是必然再被拒一次 ——
/// 服务端明明已经把「等 30 秒」写在回包里了。
public enum RetryAfter {

    /// 愿意照办的上限。
    ///
    /// ⚠️ 必须夹住：端点完全可能回 `Retry-After: 3600`，照着等会把界面冻住一小时，
    /// 而这件事早就该以失败告知用户了。超上限就返回 nil，交回本地退避序列。
    public static let ceiling: TimeInterval = 10

    /// 解析成秒数。nil = 没有 / 读不懂 / 超过上限。
    public static func seconds(from header: String?, now: Date = Date()) -> TimeInterval? {
        guard let raw = header?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let value = TimeInterval(raw) {
            guard value >= 0, value <= ceiling else { return nil }
            return value
        }
        guard let date = httpDateFormatter.date(from: raw) else { return nil }
        let interval = date.timeIntervalSince(now)
        guard interval > 0, interval <= ceiling else { return nil }
        return min(interval, ceiling)
    }

    /// `DateFormatter` 从 iOS 7 / macOS 10.9 起是线程安全的（可重入读取），
    /// 而且它本身已经是 `Sendable`，不需要 `nonisolated(unsafe)` 之类的绕行。
    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}

// MARK: - 传输层是否值得重发

/// `URLError.code` → 「重发有没有意义」。
///
/// 与 `TransportFailure.reason`（文案渲染）分开：那个负责「怎么说」，
/// 这个负责「要不要再来一次」。混在一起会让人不敢改文案。
public enum TransportRetry {

    public static func isRetryable(_ code: URLError.Code) -> Bool {
        switch code {
        // 环境问题，不是瞬时抖动：再发一次还是同一个结果，只是把「立刻告诉他」
        // 拖成「等两轮」。本机服务没起（-1004）走的就是这条。
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet:
            return false
        // 超时不重试：用户已经等满一整轮了（项目既有纪律）。
        case .timedOut:
            return false
        // 连接在传输中途断掉 / 响应不可用：确实可能是瞬时抖动。
        case .networkConnectionLost, .badServerResponse, .dataNotAllowed:
            return true
        default:
            return false
        }
    }
}
