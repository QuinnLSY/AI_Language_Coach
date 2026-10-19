import Foundation

/// 传输层失败的**稳定原因文案**（#616）。
///
/// 存在的理由：`URLError.localizedDescription` 随系统语言变 ——
/// 中文系统上是「未能完成操作。（NSURLErrorDomain错误-1009。）」，
/// 英文系统上是 "The operation couldn't be completed. (NSURLErrorDomain error -1009.)"。
/// 把它原样塞进 `AIProviderError.connectionFailed(reason)` 有两个后果：
///
/// 1. 用户看到的是一句既无信息量又不像人话的文案（还带着 `NSURLErrorDomain`）；
/// 2. 下游 `ModelDiagnostics.hint(for:)` 靠关键词给建议，而**两种语言的那句话里
///    碰巧都不含任何已收录的关键词**（英文那句里没有 connection / network / host），
///    于是「请确认该模型的服务已启动」这句最有用的建议在**任何语言下都不出现** ——
///    原本以为是「中文 Locale 缺口」，实测中英文都缺。
///
/// 修法：原因由 `URLError.code`（与语言无关）推导，且**保留数字错误码** ——
/// 数字码是 `localizedDescription` 里唯一不随语言变的部分，即使别处仍透传原始文案，
/// 下游也能靠它认出「这是连不上」。
public enum TransportFailure {

    /// 把 URLError 翻成一句稳定的中文原因（带数字错误码）。
    ///
    /// ⚠️ 文案必须含错误码：这是给下游做稳定匹配的钩子，不是给用户看的装饰。
    /// ⚠️ 不写 `.timedOut` 之外的英文，也不写 `NSURLErrorDomain`。
    public static func reason(_ error: URLError) -> String {
        let code = error.errorCode
        switch error.code {
        case .notConnectedToInternet:
            return "网络未连接（错误码 \(code)）"
        case .cannotConnectToHost:
            return "连不上服务器（错误码 \(code)）"
        case .cannotFindHost:
            return "找不到服务器地址（错误码 \(code)）"
        case .networkConnectionLost:
            return "网络连接中断（错误码 \(code)）"
        case .dnsLookupFailed:
            return "域名解析失败（错误码 \(code)）"
        case .timedOut:
            return "请求超时（错误码 \(code)）"
        default:
            // 兜底保持中性（不谎称「连不上」）：走到这里的可能是响应类错误（-1011 等）。
            return "网络错误（错误码 \(code)）"
        }
    }
}
