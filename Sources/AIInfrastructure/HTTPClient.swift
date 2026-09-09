import AIInterfaces
import Foundation

/// 本地 runtime 专用 HTTP 客户端。
///
/// 关键约束（AGENTS.md §0.1）：本机存在系统代理 `HTTP_PROXY=http://127.0.0.1:59067`，
/// 会劫持 `localhost` 请求并返回 502。所有本地 runtime 会话**必须**清空代理字典。
public struct HTTPClient: Sendable {

    /// 是否沿用系统代理设置。**本地 runtime 必须绕开代理**（防 502 劫持），
    /// 云端 API（DeepSeek / OpenRouter）通常需要系统代理才能出网。
    private let useSystemProxy: Bool

    public init(useSystemProxy: Bool = false) {
        self.useSystemProxy = useSystemProxy
    }

    private func makeSession(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        // 绕开系统代理，否则 localhost 请求会被代理拦截。
        if !useSystemProxy {
            configuration.connectionProxyDictionary = [:]
        }
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = max(timeout * 4, 60)
        configuration.httpAdditionalHeaders = ["Accept": "application/json"]
        return URLSession(configuration: configuration)
    }

    /// 发起请求并返回原始数据与响应，便于 Adapter 自行做状态码与错误体映射。
    public func perform(_ request: URLRequest, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        let session = makeSession(timeout: timeout)
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
                    var buffer = Data()
                    for try await byte in bytes {
                        if Task.isCancelled {
                            continuation.finish(throwing: AIProviderError.cancelled)
                            return
                        }
                        buffer.append(byte)
                        // SSE 以空行分隔事件
                        guard byte == UInt8(ascii: "\n"),
                              let line = String(data: buffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !line.isEmpty else {
                            if byte == UInt8(ascii: "\n") { buffer.removeAll(keepingCapacity: true) }
                            continue
                        }
                        buffer.removeAll(keepingCapacity: true)
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" {
                            continuation.finish()
                            return
                        }
                        continuation.yield(String(payload))
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

    private func mapURLError(_ error: URLError) -> AIProviderError {
        switch error.code {
        case .cancelled: .cancelled
        case .timedOut: .timeout(error.localizedDescription)
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
            .connectionFailed(error.localizedDescription)
        default: .connectionFailed(error.localizedDescription)
        }
    }
}
