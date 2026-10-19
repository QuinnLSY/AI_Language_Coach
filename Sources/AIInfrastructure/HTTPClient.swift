import AIDomain
import AIInterfaces
import AppCore
import Foundation

// MARK: - 重试策略

/// 瞬时故障重试策略。
///
/// 存在的理由：`AIProviderError.isRetryable` 把「哪些错误值得重试」写得很完整，
/// 但**没有任何调用方读它** —— 也就是说不存在重试。断线、服务端 5xx 这类
/// 一秒钟后自愈的问题，用户看到的是直接失败。
///
/// 两条护栏写死在契约里：
/// - **只重试「上一次根本没拿到响应」的情况**（`perform` 是非流式路径）。
///   流式请求（`streamSSE`）绝不重试：那会把同一份 Prompt 再发一遍 = 重复计费。
/// - **超时不重试**：用户已经等满一整轮超时，再等一轮等于把「卡住」变成「卡死」。
public struct RetryPolicy: Sendable {

    /// 默认：最多 2 次尝试（= 允许 1 次重试），退避 0.35s。
    public static let `default` = RetryPolicy(maxAttempts: 2, baseDelay: 0.35)

    /// 总尝试次数（1 = 不重试）。
    public let maxAttempts: Int
    /// 第 n 次重试前的退避（线性：`baseDelay × n`）。
    public let baseDelay: TimeInterval

    public init(maxAttempts: Int, baseDelay: TimeInterval) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = max(0, baseDelay)
    }

    /// 该不该再试一次（传输层错误）。
    func shouldRetry(_ error: Error, attempt: Int) -> Bool {
        guard attempt < maxAttempts else { return false }
        guard let providerError = error as? AIProviderError else { return false }
        // 用户主动取消：立刻停，不许偷偷再发一次。
        if case .cancelled = providerError { return false }
        if case .timeout = providerError { return false }
        return providerError.isRetryable
    }

    /// 该不该再试一次（服务端状态码）。
    ///
    /// 判定口径**复用** `AIProviderError.isRetryable`，不在这里另写一份 ——
    /// 「哪些错值得重试」只能有一个答案，两份口径迟早分叉。
    func shouldRetry(status: Int, attempt: Int) -> Bool {
        guard attempt < maxAttempts else { return false }
        return AIProviderError.serverError(status: status, message: nil).isRetryable
    }

    func delay(forAttempt attempt: Int) -> TimeInterval { baseDelay * Double(attempt) }
}

/// SSE 行装配器：把逐字节的流切成「一整行」，并给单行长度设上限。
///
/// 单独抽出来是因为它**必须能被单测**：`streamSSE` 整条路要真起 HTTP 连接才跑得起来，
/// 而这里两条最要紧的纪律（只有遇 `\n` 才成行、单行超限立即中止）恰恰只能在无网络时钉住。
struct SSELineBuffer {

    enum Outcome: Equatable {
        /// 还没等到换行，继续攒。
        case incomplete
        /// 收到一整行（已 trim；空行 / 非 `data:` 行由调用方忽略）。
        case line(String)
        /// 单行超过上限仍未换行 —— 被劫持 / 自建端点的典型症状，必须中止。
        case oversized
    }

    /// 单行长度上限的默认值（1 MiB）。
    ///
    /// ⚠️ 缓冲必须有上限：SSE 只在遇 `\n` 时清空，接上一个**持续吐字节却永不换行**的端点，
    /// 内存会单调增长到进程被杀（错误路径反而有 512 上限，正常路径原本没有）。
    /// 1 MiB 对正常 SSE 极宽松 —— 流式补全是逐 token 成行的，单行很少超过几十 KB。
    static let defaultMaxLineBytes = 1 * 1024 * 1024

    /// 本实例实际采用的上限。
    ///
    /// 留成参数是为了让单测能把边界压到个位数、**精确**钉住「第几字节越限」；
    /// 否则要真喂满 1 MiB 才碰得到，判据既慢又只能测个大概。
    let maxLineBytes: Int

    private var buffer = Data()

    init(maxLineBytes: Int = SSELineBuffer.defaultMaxLineBytes) {
        self.maxLineBytes = max(1, maxLineBytes)
    }

    /// 喂一个字节，返回这一步的结果。
    mutating func append(_ byte: UInt8) -> Outcome {
        buffer.append(byte)
        guard buffer.count <= maxLineBytes else { return .oversized }
        // 只有换行才算收到一整行；顺带清空（空行 / 非 UTF-8 也清，与改前一致）。
        guard byte == UInt8(ascii: "\n") else { return .incomplete }
        defer { buffer.removeAll(keepingCapacity: true) }
        guard let text = String(data: buffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty else {
            return .incomplete
        }
        return .line(text)
    }
}

/// 本地 runtime 专用 HTTP 客户端。
///
/// 关键约束（AGENTS.md §0.1）：本机存在系统代理 `HTTP_PROXY=http://127.0.0.1:59067`，
/// 会劫持 `localhost` 请求并返回 502。所有本地 runtime 会话**必须**清空代理字典。
public struct HTTPClient: Sendable {

    /// 是否沿用系统代理设置。**本地 runtime 必须绕开代理**（防 502 劫持），
    /// 云端 API（DeepSeek / OpenRouter）通常需要系统代理才能出网。
    private let useSystemProxy: Bool
    /// 测试注入点：给出后 `perform` 直接走它，**不发起真实网络**。
    /// 生产代码永远不传（nil = 真实 URLSession）。
    private let transport: Transport?
    /// 瞬时故障重试策略（见 `RetryPolicy`）。
    private let retryPolicy: RetryPolicy

    /// 传输抽象：测试用它把适配器完整跑一遍（请求形状 / 响应解析 / 错误映射），
    /// 无需真的起一个 runtime。
    public typealias Transport = @Sendable (_ request: URLRequest, _ timeout: TimeInterval) async throws -> (Data, HTTPURLResponse)

    public init(
        useSystemProxy: Bool = false,
        transport: Transport? = nil,
        retryPolicy: RetryPolicy = .default
    ) {
        self.useSystemProxy = useSystemProxy
        self.transport = transport
        self.retryPolicy = retryPolicy
    }

    /// 建一次性的会话。
    ///
    /// ⚠️ `target` 用来判「这个请求是不是发往回环端点」，因为**披露口径与传输层必须
    /// 判同一件事**（#S2-8）：`PrivacyPolicy` 把回环端点判为「数据不出这台机器」，
    /// 披露里因此不算外发、也不触发发布闸门；而五个 RemoteAdapter 默认
    /// `useSystemProxy: true`（云端 API 常需要系统代理才能出网）—— 于是默认 TTS
    /// （`127.0.0.1:8856`）这个**本机服务**的请求被系统代理接手转发出去，
    /// 界面说着「仅在本机处理」，数据其实出了机器。
    ///
    /// 修法不是改披露（回环确实不出机器），而是让**回环一律绕代理**：判据复用同一个
    /// `PrivacyRedactor.isLoopbackEndpoint`，别一处判 runtime 一处判 host。
    private func makeSession(timeout: TimeInterval, target: URL? = nil) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        let isLoopback = target.map { PrivacyRedactor.isLoopbackEndpoint($0.absoluteString) } ?? false
        // 绕开系统代理：本地 runtime 要防 502 劫持；回环端点要防「以为不出机器、却被代理转发出去」。
        if !useSystemProxy || isLoopback {
            configuration.connectionProxyDictionary = [:]
        }
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = max(timeout * 4, 60)
        configuration.httpAdditionalHeaders = ["Accept": "application/json"]
        return URLSession(configuration: configuration)
    }

    /// 发起请求并返回原始数据与响应，便于 Adapter 自行做状态码与错误体映射。
    ///
    /// 瞬时故障（连不上 / 5xx / 限流）按 `retryPolicy` 自动重试一次 —— 重试只可能发生在
    /// **上一次没有拿到任何可用响应**时，因此不会出现「一次操作被计两次费」。
    public func perform(_ request: URLRequest, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        // 测试注入：走假传输，不碰真实网络，也不重试（测试要的是确定的单次行为）。
        if let transport {
            return try await transport(request, timeout)
        }
        return try await Self.retrying(
            policy: retryPolicy,
            sleep: { delay in
                guard delay > 0 else { return }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            },
            onRetry: { attempt, reason in
                AppLog.debug(
                    "请求失败（\(reason)），\(String(format: "%.2f", retryPolicy.delay(forAttempt: attempt)))s 后重试第 \(attempt + 1)/\(retryPolicy.maxAttempts) 次",
                    category: "transport"
                )
            },
            { _ in
                let (data, http) = try await performOnce(request, timeout: timeout)
                return ((data, http), http.statusCode)
            }
        )
    }

    /// 重试循环本体。
    ///
    /// 抽成独立函数是为了**能测**：真实 `URLSession` 造不出可控的 5xx，
    /// 而这段逻辑恰恰最该有测试 —— 多发一次请求就是「一次操作被计两次费」。
    ///
    /// `attemptBody` 返回 `(值, HTTP 状态码)`；状态码非 nil 时按策略决定要不要再来一次。
    static func retrying<T>(
        policy: RetryPolicy,
        sleep: (TimeInterval) async -> Void,
        onRetry: (Int, String) -> Void,
        _ attemptBody: (Int) async throws -> (T, Int?)
    ) async throws -> T {
        var attempt = 1
        while true {
            do {
                let (value, status) = try await attemptBody(attempt)
                // 5xx / 429 交给适配器之前先生效一次重试：适配器的错误映射一个字都不动，
                // 最后一轮仍会把原始 response 交回去让它报「服务端错误 (500)」。
                guard let status,
                      !Task.isCancelled,
                      policy.shouldRetry(status: status, attempt: attempt) else { return value }
                onRetry(attempt, "HTTP \(status)")
                await sleep(policy.delay(forAttempt: attempt))
                attempt += 1
            } catch {
                // `shouldRetry` 内部已经把「用户取消」排除掉了，这里只补任务级别的取消。
                guard !Task.isCancelled, policy.shouldRetry(error, attempt: attempt) else { throw error }
                onRetry(attempt, error.localizedDescription)
                await sleep(policy.delay(forAttempt: attempt))
                attempt += 1
            }
        }
    }

    private func performOnce(_ request: URLRequest, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        let session = makeSession(timeout: timeout, target: request.url)
        defer { session.invalidateAndCancel() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw mapURLError(error)
        } catch {
            if error is CancellationError { throw AIProviderError.cancelled }
            throw AIProviderError.connectionFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AIProviderError.invalidResponse("响应不是 HTTP 响应")
        }
        return (data, http)
    }

    /// SSE 流：逐条产出 `data:` 之后的有效载荷（已去除 `[DONE]`）。
    public func streamSSE(_ request: URLRequest, timeout: TimeInterval) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let session = makeSession(timeout: timeout)
                defer { session.invalidateAndCancel() }
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        continuation.finish(throwing: AIProviderError.invalidResponse("流式响应不是 HTTP 响应"))
                        return
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        let body = await collectBody(bytes)
                        continuation.finish(throwing: AIProviderError.serverError(status: http.statusCode, message: body))
                        return
                    }
                    var lineBuffer = SSELineBuffer()
                    for try await byte in bytes {
                        if Task.isCancelled {
                            continuation.finish(throwing: AIProviderError.cancelled)
                            return
                        }
                        switch lineBuffer.append(byte) {
                        case .incomplete:
                            continue
                        case .oversized:
                            // 不静默截断：这条流已经不可信了（多半不是我们要的端点），
                            // 报出来让用户看到「流式响应异常」，而不是等着内存涨爆。
                            continuation.finish(throwing: AIProviderError.invalidResponse(
                                "流式响应单行超过 \(lineBuffer.maxLineBytes) 字节仍未换行，已中止"
                            ))
                            return
                        case .line(let line):
                            guard line.hasPrefix("data:") else { continue }
                            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            if payload == "[DONE]" {
                                continuation.finish()
                                return
                            }
                            continuation.yield(String(payload))
                        }
                    }
                    continuation.finish()
                } catch let error as URLError {
                    continuation.finish(throwing: mapURLError(error))
                } catch {
                    if error is CancellationError {
                        continuation.finish(throwing: AIProviderError.cancelled)
                    } else {
                        continuation.finish(throwing: AIProviderError.connectionFailed(error.localizedDescription))
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func collectBody(_ bytes: URLSession.AsyncBytes) async -> String? {
        var text = ""
        do {
            for try await byte in bytes {
                text.append(Character(UnicodeScalar(byte)))
                if text.count > 512 { break }
            }
        } catch {
            return text.isEmpty ? nil : text
        }
        return text.isEmpty ? nil : text
    }

    /// ⚠️ 原因一律走 `TransportFailure.reason`（由错误码推导），**不用**
    /// `error.localizedDescription`：后者随系统语言变，且中英两版都不含任何
    /// 已收录的诊断关键词 → 用户拿不到「服务没启动」那句可操作建议（#616）。
    private func mapURLError(_ error: URLError) -> AIProviderError {
        switch error.code {
        case .cancelled: .cancelled
        case .timedOut: .timeout(TransportFailure.reason(error))
        default: .connectionFailed(TransportFailure.reason(error))
        }
    }
}
