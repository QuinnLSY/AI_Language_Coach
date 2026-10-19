import AIInfrastructure
import AIInterfaces
import AIServices
import XCTest

/// 传输层失败原因的诊断文案（#616）。
///
/// 缺口本体：`URLError.localizedDescription` 随系统语言变，而且**中英两版都不含
/// 任何已收录的诊断关键词** ——
/// - 中文：「未能完成操作。（NSURLErrorDomain错误-1009。）」
/// - 英文："The operation couldn't be completed. (NSURLErrorDomain error -1009.)"
///
/// 于是 `ModelDiagnostics.hint(for:)` 配不出「请确认该模型的服务已启动」，
/// 用户在任何语言下都只能盯着一句 NSURLErrorDomain 发呆。
///
/// 修法两层：传输层改按错误码产稳定文案（`TransportFailure.reason`），
/// 诊断层再加「认码」兜底（数字码是 localizedDescription 里唯一不变的部分）。
/// 本文件两条路各钉一层，避免任一层被撤掉后悄悄回退。
final class TransportFailureDiagnosticTests: XCTestCase {

    // MARK: - 稳定原因文案（纯函数）

    /// 五种「连不上」各有各的说法，且都带数字错误码（下游匹配靠它）。
    func testReasonIsStableAndCarriesTheCode() {
        XCTAssertEqual(
            TransportFailure.reason(URLError(.notConnectedToInternet)),
            "网络未连接（错误码 -1009）"
        )
        XCTAssertEqual(
            TransportFailure.reason(URLError(.cannotConnectToHost)),
            "连不上服务器（错误码 -1004）"
        )
        XCTAssertEqual(
            TransportFailure.reason(URLError(.cannotFindHost)),
            "找不到服务器地址（错误码 -1003）"
        )
        XCTAssertEqual(
            TransportFailure.reason(URLError(.networkConnectionLost)),
            "网络连接中断（错误码 -1005）"
        )
        XCTAssertEqual(
            TransportFailure.reason(URLError(.timedOut)),
            "请求超时（错误码 -1001）"
        )
    }

    /// 兜底档不许谎称「连不上」（走到 default 的可能是响应类错误 -1011 之流）。
    func testFallbackReasonDoesNotClaimConnectivity() {
        let text = TransportFailure.reason(URLError(.badServerResponse))
        XCTAssertTrue(text.hasPrefix("网络错误"), text)
        XCTAssertTrue(text.contains("-1011"), "兜底也要带错误码：\(text)")
        XCTAssertFalse(text.contains("连不上"), "不该把「响应不对」说成「连不上」：\(text)")
    }

    /// 文案里不许再出现 `NSURLErrorDomain` 这类只有工程师才懂的字样。
    func testReasonIsHumanReadable() {
        let text = TransportFailure.reason(URLError(.notConnectedToInternet))
        XCTAssertFalse(text.contains("NSURLErrorDomain"), text)
        XCTAssertFalse(text.contains("The operation"), text)
        XCTAssertFalse(text.contains("未能完成操作"), text)
    }

    // MARK: - 真实链路：URLSession 真的连不上时

    /// 端到端：打一个**回环上的死端口**（端口 1 需要 root 才听得起，本机必然无人监听），
    /// 走的是真实 `URLSession` + `mapURLError` 那条路，不发任何外网请求。
    func testRealConnectionRefusalProducesActionableAdvice() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:1/v1/models")!)
        request.httpMethod = "GET"
        let client = HTTPClient(
            useSystemProxy: false,
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: 0)
        )

        let caught: AIProviderError
        do {
            _ = try await client.perform(request, timeout: 5)
            XCTFail("端口 1 不该有人监听")
            return
        } catch let error as AIProviderError {
            caught = error
        } catch {
            XCTFail("传输层必须统一成 AIProviderError 上浮：\(error)")
            return
        }

        guard case .connectionFailed(let reason) = caught else {
            XCTFail("连不上必须落在 connectionFailed 这一档：\(caught)")
            return
        }
        XCTAssertEqual(reason, "连不上服务器（错误码 -1004）", "原因文案必须是稳定的那句：\(reason)")

        let text = ModelDiagnostics.describe(
            providerName: "本地模型", model: "qwen3:8b", error: caught
        )
        XCTAssertTrue(text.contains("连接失败"), text)
        XCTAssertTrue(
            text.contains("请确认该模型的服务已启动"),
            "连不上必须给出可操作建议（#616 的本体）：\(text)"
        )
    }

    // MARK: - 原始 localizedDescription 也要能配出建议（认码兜底）

    /// 中文系统的原文案（硬编码，不依赖测试进程的语言）：认码这一层必须救得回来。
    func testChineseLocalizedDescriptionStillGetsAdvice() {
        let text = ModelDiagnostics.describe(
            providerName: "本地模型", model: "qwen3:8b",
            error: AIProviderError.connectionFailed("未能完成操作。（NSURLErrorDomain错误-1009。）")
        )
        XCTAssertTrue(
            text.contains("请确认该模型的服务已启动"),
            "中文 Locale 的 URLError 描述曾配不出任何建议（#616）：\(text)"
        )
    }

    /// 英文系统的原文案：同样不含关键词，靠错误码救回 —— 这不是「中文专属」缺口。
    func testEnglishLocalizedDescriptionStillGetsAdvice() {
        let text = ModelDiagnostics.describe(
            providerName: "本地模型", model: "qwen3:8b",
            error: AIProviderError.connectionFailed(
                "The operation couldn’t be completed. (NSURLErrorDomain error -1009.)"
            )
        )
        XCTAssertTrue(
            text.contains("请确认该模型的服务已启动"),
            "英文的那一句里没有 connection / network / host，也曾配不出建议：\(text)"
        )
    }

    // MARK: - 别把别的失败说成「去启动服务」

    /// 404 是「模型名写错了」，不是「服务没起」—— 认码那层不许乱抢。
    func testNotFoundStillPointsAtTheModelName() {
        let text = ModelDiagnostics.describe(
            providerName: "DeepSeek", model: "gpt-9",
            error: AIProviderError.connectionFailed("HTTP 404 not found")
        )
        XCTAssertTrue(text.contains("模型名"), text)
        XCTAssertFalse(text.contains("服务已启动"), "404 不该叫人去启动服务：\(text)")
    }

    /// 401 是密钥问题。
    func testUnauthorizedStillPointsAtTheKey() {
        let text = ModelDiagnostics.describe(
            providerName: "DeepSeek", model: "deepseek-chat",
            error: AIProviderError.connectionFailed("401 unauthorized")
        )
        XCTAssertTrue(text.contains("API Key"), text)
        XCTAssertFalse(text.contains("服务已启动"), "401 不该叫人去启动服务：\(text)")
    }
}
