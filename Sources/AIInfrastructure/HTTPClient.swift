import AIDomain
import AIInterfaces
import AppCore
import Foundation

// 重试策略见 `RetryStrategy.swift`（`RetryPolicy` / `RetryAfter` / `TransportRetry`）。

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

/// HTTP 会话池：按「走不走系统代理 × 超时」缓存**长生命周期**的 `URLSession`。
///
/// 为什么必须复用（#666）：改前 `performOnce` / `streamSSE` **每次请求都新建 session，
/// 用完立刻 `invalidateAndCancel()`** —— 连接池是挂在会话上的，会话一销毁连接就散了，
/// 下一次请求只能重走一遍 TCP + TLS 握手。本地回环（8856 / 8858 / 11434）几乎无感；
/// 云端 API 每次调用都要再付一次握手（一次对话里 LLM / 翻译 / TTS 各一次，攒下来几百毫秒）。
///
/// 缓存键为什么要带**超时**：`URLSessionConfiguration` 在建会话的那一刻被拷走，之后改不动
/// （只有 `URLRequest.timeoutInterval` 能覆盖 `timeoutIntervalForRequest`，
/// `timeoutIntervalForResource` 根本没有逐任务的覆盖口）。键里不带超时，就会出现
/// 「借了别人的会话 = 借了别人的超时」—— 流式请求被一个 15s 的会话超时掐断，
/// 这种问题最难查。带上超时之后，同键的请求拿到的超时与改前逐字一致。
///
/// 缓存键为什么要带**代理口径**：回环端点一律绕代理（#S2-8），与走系统代理的云端请求
/// 绝不能共用同一个会话 —— 共用了就等于把「本机服务」的请求交给代理转发出去，
/// 界面说着「仅在本机处理」，数据其实出了机器。
///
/// 会话**永不 invalidate**：它们是按键缓存的，键的数量有界（代理 2 档 × 少数几档超时）。
public final class HTTPSessionPool: @unchecked Sendable {

    public static let shared = HTTPSessionPool()

    private struct Key: Hashable {
        let proxy: Bool
        let timeout: TimeInterval
    }

    private let lock = NSLock()
    private var sessions: [Key: URLSession] = [:]
    /// 实际新建过的会话数。**测试用它钉「第二次请求没有再建会话」**（否则连接池复用
    /// 悄悄退化成「每次新建」也无人知晓 —— 编译照过、单测照绿）。
    private(set) var createdCount = 0

    public init() {}

    /// 取（或首次创建）该口径下的会话。同键必定返回同一个实例。
    func session(proxy: Bool, timeout: TimeInterval) -> URLSession {
        let key = Key(proxy: proxy, timeout: timeout)
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[key] { return existing }
        let created = makeSession(proxy: proxy, timeout: timeout)
        sessions[key] = created
        createdCount += 1
        return created
    }

    private func makeSession(proxy: Bool, timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        // 绕开系统代理：本地 runtime 要防 502 劫持；回环端点要防「以为不出机器、却被代理转发出去」。
        if !proxy {
            configuration.connectionProxyDictionary = [:]
        }
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = max(timeout * 4, 60)
        configuration.httpAdditionalHeaders = ["Accept": "application/json"]
        return URLSession(configuration: configuration)
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
    /// 会话池（#666）：默认是进程内共享的那一个；测试可注入自己的池来数「建了几次会话」。
    private let sessionPool: HTTPSessionPool

    /// 传输抽象：测试用它把适配器完整跑一遍（请求形状 / 响应解析 / 错误映射），
    /// 无需真的起一个 runtime。
    public typealias Transport = @Sendable (_ request: URLRequest, _ timeout: TimeInterval) async throws -> (Data, HTTPURLResponse)

    public init(
        useSystemProxy: Bool = false,
        transport: Transport? = nil,
        retryPolicy: RetryPolicy = .default,
        sessionPool: HTTPSessionPool = .shared
    ) {
        self.useSystemProxy = useSystemProxy
        self.transport = transport
        self.retryPolicy = retryPolicy
        self.sessionPool = sessionPool
    }

    /// 取这次请求该用的会话（**复用，不新建**）。
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
    /// （#666 顺带补上：改前 `streamSSE` 建会话时**没传 target**，于是流式请求拿不到
    /// 这份回环判定 —— 本机 TTS / Ollama 的流式请求照旧被代理接走。）
    private func session(for target: URL?, timeout: TimeInterval) -> URLSession {
        let isLoopback = target.map { PrivacyRedactor.isLoopbackEndpoint($0.absoluteString) } ?? false
        return sessionPool.session(proxy: useSystemProxy && !isLoopback, timeout: timeout)
    }

    /// 发起请求并返回原始数据与响应，便于 Adapter 自行做状态码与错误体映射。
    ///
    /// 瞬时故障（断线 / 5xx / 限流）按 `retryPolicy` 自动重试 —— 但**只在 `idempotency`
    /// 允许时**。扣费请求（chat / TTS / 转写 / 评测）必须传 `.unsafe`：
    /// 服务端可能已经算完并计了费，只是回包失败，重发就是第二次扣款。
    public func perform(
        _ request: URLRequest,
        timeout: TimeInterval,
        idempotency: RetryPolicy.Idempotency = .safe
    ) async throws -> (Data, HTTPURLResponse) {
        // 测试注入：走假传输，不碰真实网络，也不重试（测试要的是确定的单次行为）。
        if let transport {
            return try await transport(request, timeout)
        }
        // 回环端点（本机语音 / Ollama）失败几乎只有一个原因：服务没起。
        // 对它重试，只是在「立刻告诉用户」前面插两段等待 —— 冷启动最痛的那几秒就是这么来的。
        let isLoopback = request.url.map { PrivacyRedactor.isLoopbackEndpoint($0.absoluteString) } ?? false
        let policy = isLoopback ? RetryPolicy.disabled : retryPolicy

        return try await Self.retrying(
            policy: policy,
            idempotency: idempotency,
            sleep: { delay in
                guard delay > 0 else { return }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            },
            onRetry: { attempt, reason in
                AppLog.debug(
                    "请求失败（\(reason)），即将重试第 \(attempt + 1)/\(policy.maxAttempts) 次",
                    category: "transport"
                )
            },
            { _ in
                let (data, http) = try await performOnce(request, timeout: timeout)
                return (value: (data, http), status: http.statusCode, retryAfter: Self.retryAfterSeconds(http))
            }
        )
    }

    /// 服务端建议的等待时长（只有 429 / 503 才谈得上）。
    private static func retryAfterSeconds(_ response: HTTPURLResponse) -> TimeInterval? {
        guard response.statusCode == 429 || response.statusCode == 503 else { return nil }
        return RetryAfter.seconds(from: response.value(forHTTPHeaderField: "Retry-After"))
    }

    /// 重试循环本体。
    ///
    /// 抽成独立函数是为了**能测**：真实 `URLSession` 造不出可控的 5xx，
    /// 而这段逻辑恰恰最该有测试 —— 多发一次请求就是「一次操作被计两次费」。
    ///
    /// `attemptBody` 返回 `(值, HTTP 状态码, 服务端建议的等待时长)`；
    /// 状态码非 nil 时按策略决定要不要再来一次。
    static func retrying<T>(
        policy: RetryPolicy,
        idempotency: RetryPolicy.Idempotency,
        sleep: (TimeInterval) async -> Void,
        onRetry: (Int, String) -> Void,
        _ attemptBody: (Int) async throws -> (value: T, status: Int?, retryAfter: TimeInterval?)
    ) async throws -> T {
        var attempt = 1
        while true {
            do {
                let outcome = try await attemptBody(attempt)
                // 5xx / 429 交给适配器之前先生效一次重试：适配器的错误映射一个字都不动，
                // 最后一轮仍会把原始 response 交回去让它报「服务端错误 (500)」。
                guard let status = outcome.status,
                      !Task.isCancelled,
                      policy.shouldRetry(status: status, attempt: attempt, idempotency: idempotency)
                else { return outcome.value }
                onRetry(attempt, "HTTP \(status)")
                // 服务端给了 `Retry-After` 就照办（已夹过上限），否则用本地退避。
                await sleep(outcome.retryAfter ?? policy.delay(forAttempt: attempt))
                attempt += 1
            } catch let urlError as URLError {
                // ⚠️ 就地判定：只有这一层看得见 `URLError.code`。
                // 翻成 `AIProviderError` 之后「连不上」和「传输中途断了」就分不出来了，
                // 而这两者对「要不要重发」的答案正好相反。
                guard !Task.isCancelled,
                      policy.shouldRetry(urlError, attempt: attempt, idempotency: idempotency)
                else { throw Self.mapURLError(urlError) }
                onRetry(attempt, TransportFailure.reason(urlError))
                await sleep(policy.delay(forAttempt: attempt))
                attempt += 1
            } catch {
                // `shouldRetry` 内部已经把「用户取消」排除掉了，这里只补任务级别的取消。
                guard !Task.isCancelled,
                      policy.shouldRetry(error, attempt: attempt, idempotency: idempotency)
                else { throw error }
                onRetry(attempt, error.localizedDescription)
                await sleep(policy.delay(forAttempt: attempt))
                attempt += 1
            }
        }
    }

    private func performOnce(_ request: URLRequest, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        // #666：会话从池里取，**不再每次新建 + 用完就 invalidate** ——
        // 那样连接池跟着会话一起散，每次请求都要重新握手。
        let session = self.session(for: request.url, timeout: timeout)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            // 原样抛出：重试判定需要 `URLError.code`（连不上 vs 传输中途断了），
            // 翻成 `AIProviderError` 之后这条信息就没了。翻译在 `retrying` 的出口做。
            throw error
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
                // #666：同 `performOnce`，走池；顺带把 target 传进去（改前漏传 →
                // 流式请求拿不到回环判定，本机服务被代理接走）。
                let session = self.session(for: request.url, timeout: timeout)
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
                    continuation.finish(throwing: Self.mapURLError(error))
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
    private static func mapURLError(_ error: URLError) -> AIProviderError {
        switch error.code {
        case .cancelled: .cancelled
        case .timedOut: .timeout(TransportFailure.reason(error))
        default: .connectionFailed(TransportFailure.reason(error))
        }
    }
}
