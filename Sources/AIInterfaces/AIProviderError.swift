import Foundation

/// 统一 typed 错误（v2.0 §29）。禁止吞掉，禁止静默转空串。
public enum AIProviderError: Error, Sendable, LocalizedError, Equatable {
    case invalidConfiguration(String)
    case runtimeUnavailable(String)
    case modelUnavailable(String)
    case connectionFailed(String)
    case timeout(String)
    case cancelled
    case invalidRequest(String)
    case invalidResponse(String)
    case unsupportedCapability(String)
    case serverError(status: Int, message: String?)
    case notInitialized
    case loadFailed(String)
    case outOfMemory
    case runtimeCrash(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let m): "配置无效：\(m)"
        case .runtimeUnavailable(let m): "本地服务不可用：\(m)"
        case .modelUnavailable(let m): "模型不可用：\(m)"
        case .connectionFailed(let m): "连接失败：\(m)"
        case .timeout(let m): "请求超时：\(m)"
        case .cancelled: "已取消"
        case .invalidRequest(let m): "请求无效：\(m)"
        case .invalidResponse(let m): "响应解析失败：\(m)"
        case .unsupportedCapability(let m): "能力不支持：\(m)"
        case .serverError(let status, let m): "服务端错误 (\(status))：\(m ?? "无详细信息")"
        case .notInitialized: "Provider 尚未初始化"
        case .loadFailed(let m): "加载失败：\(m)"
        case .outOfMemory: "内存不足"
        case .runtimeCrash(let m): "运行时崩溃：\(m)"
        }
    }

    /// 是否值得重试。**非法请求 / 不支持的能力 / 配置错误一律不重试**。
    ///
    /// ⚠️ 两处容易写错的地方：
    /// 1. `serverError` 要看状态码 —— **4xx 是「你的请求不对」，重试再多次也是同一个结果**，
    ///    只有 5xx（服务端自己出问题）与 429（限流，等一会儿就好）才值得再来一次。
    ///    早先这里不区分状态码，401 也会被重试。
    /// 2. 「值得重试」≠「立刻重试」。`.timeout` 语义上值得重试，但**不该在同一处干等**
    ///    （用户已经等满一整轮超时了），是否真的再试由调用方按自己的耐心窗口决定，
    ///    见 `HTTPClient.RetryPolicy.shouldRetry(_:attempt:)`。
    public var isRetryable: Bool {
        switch self {
        case .connectionFailed, .timeout, .runtimeCrash: true
        case .serverError(let status, _): status >= 500 || status == 429
        default: false
        }
    }
}
