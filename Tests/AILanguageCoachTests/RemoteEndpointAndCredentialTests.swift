import AIDomain
import XCTest

/// 云端外部模型接入的两个回归点（都来自 2026-09-14 用户实测）：
///
/// 1. **端点已带 `/v1` 时不能再拼一遍**。AgnesAI 国内/国际站的端点是
///    `https://apihub.agnes-ai.cn/v1`，适配器里写死 `appendingPathComponent("v1/…")`
///    就拼成了 `/v1/v1/chat/completions`，服务端回 `Invalid URL` ——
///    用户看到的是「模型不存在 / 密钥无效」这类**指错方向**的提示，
///    于是把 key 删了重建反复试，怎么都不通。
/// 2. **粘贴进来的 Key 需要清洗**。控制台复制出来的 `"sk-…"` / `Bearer sk-…` /
///    带换行的 Key 会让服务端回「Invalid token」，而用户看不出自己贴的哪里不对。
final class RemoteEndpointAndCredentialTests: XCTestCase {

    // MARK: - 端点拼接（重复 v1 回归）

    private func modelsURL(_ endpoint: String) throws -> String {
        let base = try XCTUnwrap(RemoteEndpoint.base(endpoint))
        return RemoteEndpoint.modelsURL(base: base).absoluteString
    }

    private func chatURL(_ endpoint: String) throws -> String {
        let base = try XCTUnwrap(RemoteEndpoint.base(endpoint))
        return RemoteEndpoint.chatURL(base: base).absoluteString
    }

    func testModelsURLNeverDoublesVersionPrefix() throws {
        // 端点自带 /v1 —— 就是踩过的那一类（AgnesAI 国内/国际站、OpenAI）。
        XCTAssertEqual(try modelsURL("https://apihub.agnes-ai.cn/v1"), "https://apihub.agnes-ai.cn/v1/models")
        XCTAssertEqual(try modelsURL("https://apihub.agnes-ai.com/v1"), "https://apihub.agnes-ai.com/v1/models")
        XCTAssertEqual(try modelsURL("https://api.openai.com/v1"), "https://api.openai.com/v1/models")
        XCTAssertEqual(try modelsURL("https://api.siliconflow.cn/v1"), "https://api.siliconflow.cn/v1/models")
    }

    func testModelsURLKeepsWorkingForEndpointsWithoutVersionPrefix() throws {
        // 端点不带 /v1 —— 另一类厂商（DeepSeek 是裸域名；OpenRouter 是 /api）。
        XCTAssertEqual(try modelsURL("https://api.deepseek.com"), "https://api.deepseek.com/v1/models")
        XCTAssertEqual(try modelsURL("https://openrouter.ai/api"), "https://openrouter.ai/api/v1/models")
        // 结尾多余的斜杠不该造成任何差别。
        XCTAssertEqual(try modelsURL("https://apihub.agnes-ai.cn/v1/"), "https://apihub.agnes-ai.cn/v1/models")
    }

    func testChatURLNeverDoublesVersionPrefix() throws {
        XCTAssertEqual(
            try chatURL("https://apihub.agnes-ai.cn/v1"),
            "https://apihub.agnes-ai.cn/v1/chat/completions"
        )
        XCTAssertEqual(
            try chatURL("https://api.deepseek.com"),
            "https://api.deepseek.com/v1/chat/completions"
        )
    }

    func testURLRuleDoesNotDisturbNonVersionPaths() throws {
        // 语音网关类端点（`tts.kina.ink` + 路径 `tts`）不能被规则改道。
        let base = try XCTUnwrap(RemoteEndpoint.base("https://tts.kina.ink"))
        XCTAssertEqual(RemoteEndpoint.url(base: base, path: "tts").absoluteString, "https://tts.kina.ink/tts")
        // 首段不同名时只做普通拼接。
        let api = try XCTUnwrap(RemoteEndpoint.base("https://openrouter.ai/api"))
        XCTAssertEqual(
            RemoteEndpoint.url(base: api, path: "v1/models").absoluteString,
            "https://openrouter.ai/api/v1/models"
        )
    }

    // MARK: - Key 粘贴清洗

    func testPlainKeyIsUntouched() {
        XCTAssertEqual(CredentialText.normalizedKey("sk-abc123DEF"), "sk-abc123DEF")
        XCTAssertFalse(CredentialText.needsCleaning("sk-abc123DEF"))
    }

    func testWrappingQuotesAreRemoved() {
        XCTAssertEqual(CredentialText.normalizedKey("\"sk-abc123\""), "sk-abc123")
        XCTAssertEqual(CredentialText.normalizedKey("'sk-abc123'"), "sk-abc123")
        XCTAssertEqual(CredentialText.normalizedKey("“sk-abc123”"), "sk-abc123")
        XCTAssertTrue(CredentialText.needsCleaning("\"sk-abc123\""))
    }

    func testAuthorizationPrefixIsRemoved() {
        XCTAssertEqual(CredentialText.normalizedKey("Bearer sk-abc123"), "sk-abc123")
        XCTAssertEqual(CredentialText.normalizedKey("bearer sk-abc123"), "sk-abc123")
        XCTAssertEqual(CredentialText.normalizedKey("Bearer: sk-abc123"), "sk-abc123")
        // 前缀 + 引号混在一起（`Bearer "sk-x"`）也要能剥干净。
        XCTAssertEqual(CredentialText.normalizedKey("Bearer \"sk-abc123\""), "sk-abc123")
    }

    func testInteriorWhitespaceAndNewlinesAreRemoved() {
        XCTAssertEqual(CredentialText.normalizedKey("  sk-abc-123 \n"), "sk-abc-123")
        XCTAssertEqual(CredentialText.normalizedKey("sk-abc\n123"), "sk-abc123")
        XCTAssertEqual(CredentialText.normalizedKey("sk-abc 123"), "sk-abc123")
    }

    func testEmptyStaysEmpty() {
        XCTAssertEqual(CredentialText.normalizedKey(""), "")
        XCTAssertEqual(CredentialText.normalizedKey("   \n "), "")
        XCTAssertEqual(CredentialText.normalizedKey("\"\""), "")
        XCTAssertFalse(CredentialText.needsCleaning(""))
    }

    func testKeyCaseAndBodyAreNeverAltered() {
        // 清洗只删「几乎不可能是 Key 一部分」的东西，不改大小写、不截断。
        let key = "sk-AbC-123_XYZ.789"
        XCTAssertEqual(CredentialText.normalizedKey("\(key)\n"), key)
    }

    func testSafeDescriptionNeverLeaksTheKey() {
        let key = "sk-abcdefghijklmnop"
        let described = CredentialText.safeDescription(key)
        XCTAssertEqual(described, "19 位，末尾 ••••mnop")
        XCTAssertFalse(described.contains("abcdefg"), "说明里不能出现 Key 中段")
        XCTAssertEqual(CredentialText.safeDescription(""), "空")
        XCTAssertTrue(CredentialText.safeDescription("ab").contains("过短"))
    }

    // MARK: - 401 说明

    func testUnauthorizedExplainsMissingKey() {
        let text = RemoteAuthDiagnostics.unauthorized(
            address: "apihub.agnes-ai.cn/v1/models",
            keyDescription: "空",
            serverMessage: "Token not provided"
        )
        XCTAssertTrue(text.contains("没有携带 API Key"), text)
        XCTAssertTrue(text.contains("Token not provided"), text)
        XCTAssertTrue(text.contains("apihub.agnes-ai.cn/v1/models"), text)
    }

    func testUnauthorizedExplainsRejectedKey() {
        let text = RemoteAuthDiagnostics.unauthorized(
            address: "apihub.agnes-ai.cn/v1/models",
            keyDescription: "51 位，末尾 ••••2f9a",
            serverMessage: "Invalid token"
        )
        XCTAssertTrue(text.contains("服务端拒绝了这个 Key"), text)
        XCTAssertTrue(text.contains("51 位，末尾 ••••2f9a"), text)
        // 必须给出「粘贴可能带引号/前缀」这条可操作线索，否则用户只能干重建 Key。
        XCTAssertTrue(text.contains("Bearer"), text)
    }

    func testUnauthorizedHandlesMissingAndHugeServerMessage() {
        let missing = RemoteAuthDiagnostics.unauthorized(
            address: "h/p", keyDescription: "空", serverMessage: nil
        )
        XCTAssertTrue(missing.contains("服务端未给出说明"), missing)

        let huge = String(repeating: "x", count: 500)
        let truncated = RemoteAuthDiagnostics.unauthorized(
            address: "h/p", keyDescription: "空", serverMessage: huge
        )
        XCTAssertTrue(truncated.contains("…"), "超长服务端原文要截断，避免把报错框撑爆")
        XCTAssertLessThan(truncated.count, 400)
    }
}
