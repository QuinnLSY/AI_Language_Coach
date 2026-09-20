import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import AIInterfaces
@testable import AppUI
import XCTest

/// 「确认配置 / 启动」的**认证闸门**与「弹窗说真话」回归（2026-09-14 反馈系列）。
///
/// 反馈的三个现象，这里逐一钉死：
/// 1. Key 认证失败后点「确认配置」，**不该**仍然启用成功、改写模型卡片；
///    失败的配置必须维持之前的模型调用。
/// 2. 卡片右上角（健康状态）与左下角（成功文案）必须同源：成功文案由
///    真实健康状态推导，不再写死「已启用云端模型」。
/// 3. 点「启动」的弹窗必须与真实连通性一致：云端/无后台服务的能力启动前
///    先做真实健康探测，失败就红色弹窗 + 原因，不再提前弹绿。
///
/// 全部走本机桩服务，**不触外网、不花钱**（费用护栏）。
@MainActor
final class ExternalModelApplyGateTests: XCTestCase {

    /// `nonisolated`：`setUp` / `tearDown` 重写的是 XCTest 里**非隔离**的方法，
    /// 从那里读主 actor 静态属性会被判越界。它本身只是个路径常量，跟隔离状态无关。
    private nonisolated static let isolatedLog = FileManager.default.temporaryDirectory
        .appendingPathComponent("alc-apply-gate-remote-calls.jsonl")

    override func setUp() {
        super.setUp()
        setenv("ALC_REMOTE_CALL_LOG", Self.isolatedLog.path, 1)
        try? FileManager.default.removeItem(at: Self.isolatedLog)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: Self.isolatedLog)
        super.tearDown()
    }

    // MARK: - 桩服务（可配置 200 / 401）

    private final class StubServer {
        let directory: URL
        private let process = Process()
        private let portFile: URL

        private init(directory: URL) {
            self.directory = directory
            self.portFile = directory.appendingPathComponent("port")
        }

        /// `authorized = true` → /v1/models 返回 200 + 模型清单；否则一律 401。
        static func start(authorized: Bool) throws -> StubServer {
            let python = "/usr/bin/python3"
            guard FileManager.default.isExecutableFile(atPath: python) else {
                throw XCTSkip("本机没有 python3，跳过桩服务测试")
            }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("alc-apply-gate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let server = StubServer(directory: directory)
            let script = directory.appendingPathComponent("stub.py")
            try Self.script(authorized: authorized).write(to: script, atomically: true, encoding: .utf8)
            server.process.executableURL = URL(fileURLWithPath: python)
            server.process.arguments = [script.path, server.portFile.path]
            server.process.standardOutput = FileHandle.nullDevice
            server.process.standardError = FileHandle.nullDevice
            try server.process.run()
            return server
        }

        func waitForPort() throws -> Int {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if let text = try? String(contentsOf: portFile, encoding: .utf8),
                   let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    return port
                }
                usleep(50_000)
            }
            throw XCTSkip("桩服务未能启动（端口未就绪）")
        }

        func cleanUp() {
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: directory)
        }

        private static func script(authorized: Bool) -> String {
            let status = authorized ? "200" : "401"
            let body = authorized
                ? "{\"data\":[{\"id\":\"stub-model\",\"object\":\"model\"}]}"
                : "{\"error\":{\"message\":\"Invalid token\",\"type\":\"AgnesAI_error\"}}"
            let bodyB64 = Data(body.utf8).base64EncodedString()
            return """
            import base64, sys
            from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

            port_file = sys.argv[1]
            STATUS = \(status)
            BODY = base64.b64decode("\(bodyB64)")

            class Handler(BaseHTTPRequestHandler):
                def do_GET(self):
                    self.send_response(STATUS)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(BODY)))
                    self.end_headers()
                    self.wfile.write(BODY)

                def log_message(self, *args):
                    pass

            server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            with open(port_file, "w") as handle:
                handle.write(str(server.server_address[1]))
            server.serve_forever()
            """
        }
    }

    // MARK: - 环境

    private func makeState(port: Int) async throws -> (AppState, ConfigStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-apply-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        try await store.updateProvider(
            ProviderConfig(
                id: "stub.llm", kind: .llm, enabled: false, runtime: .remoteAPI,
                endpoint: "http://127.0.0.1:\(port)/v1",
                candidateModels: ["stub-model"]
            )
        )
        let services = CoachServices(config: store, databasePath: ":memory:")
        return (AppState(services: services), store)
    }

    // MARK: - ① 认证失败 → 一路失败，卡片不动

    /// Key 被服务端拒绝时，「确认配置」必须整路失败：不激活、不改卡片、不写成功文案。
    func testApplyWithRejectedKeyFailsAllTheWayAndKeepsCardUntouched() async throws {
        let server = try StubServer.start(authorized: false)
        defer { server.cleanUp() }
        let port = try server.waitForPort()
        let (state, _) = try await makeState(port: port)

        state.setKeyDraft("sk-test-key", providerID: "stub.llm", kind: .llm)
        await state.applyExternalModel(.llm, providerID: "stub.llm", model: "stub-model")

        let message = state.externalMessages["stub.llm"] ?? ""
        XCTAssertTrue(message.contains("Invalid token") || message.contains("拒绝"),
                      "失败原因要原样呈现给用户：\(message)")
        XCTAssertNil(state.externalVerifiedKeys["stub.llm"], "失败的 Key 绝不能进「已验证」记录")
        XCTAssertNotEqual(
            state.activeProviderIDs[.llm], "stub.llm",
            "认证失败的配置不得把这家标成当前生效"
        )
        XCTAssertFalse(
            (state.remoteMessage ?? "").contains("已启用云端模型"),
            "卡片左下角不允许出现成功文案：\(state.remoteMessage ?? "nil")"
        )
    }

    /// 面板里的「已应用到模型卡片」只允许在真正成功后出现。
    func testRejectedKeyDoesNotMarkPanelAsApplied() async throws {
        let server = try StubServer.start(authorized: false)
        defer { server.cleanUp() }
        let port = try server.waitForPort()
        let (state, _) = try await makeState(port: port)

        state.setKeyDraft("sk-test-key", providerID: "stub.llm", kind: .llm)
        await state.applyExternalModel(.llm, providerID: "stub.llm", model: "stub-model")

        XCTAssertFalse(
            (state.externalMessages["stub.llm"] ?? "").contains("已启用"),
            "失败消息不允许含「已启用」（会被面板当成绿色成功）：\(state.externalMessages["stub.llm"] ?? "")"
        )
    }

    // MARK: - ② 认证通过 → 启用成功，且成功文案与真实健康同源

    func testApplyWithVerifiedKeyActivatesAndReportsTruthfully() async throws {
        let server = try StubServer.start(authorized: true)
        defer { server.cleanUp() }
        let port = try server.waitForPort()
        let (state, _) = try await makeState(port: port)

        state.setKeyDraft("sk-test-key", providerID: "stub.llm", kind: .llm)
        // 先「验证并获取模型」：这一步通过后同一把 Key 免二次探测。
        await state.fetchExternalModels(kind: .llm, providerID: "stub.llm")
        XCTAssertEqual(state.externalVerifiedKeys["stub.llm"], "sk-test-key")
        await state.applyExternalModel(.llm, providerID: "stub.llm", model: "stub-model")

        XCTAssertEqual(state.externalMessages["stub.llm"], "已启用 stub-model")
        XCTAssertEqual(state.activeProviderIDs[.llm], "stub.llm", "认证通过的配置应当生效")
        XCTAssertEqual(
            state.remoteMessage, "已启用云端模型 stub-model",
            "成功文案必须与健康状态同源（桩服务 200 → 已就绪）"
        )
    }

    /// 改了输入框里的 Key，「已验证」记录必须立刻作废——否则「验证 A → 改成 B → 应用」
    /// 会拿 A 的认证记录放行 B。
    func testEditingKeyDraftInvalidatesVerification() async throws {
        let server = try StubServer.start(authorized: true)
        defer { server.cleanUp() }
        let port = try server.waitForPort()
        let (state, _) = try await makeState(port: port)

        state.setKeyDraft("sk-test-key", providerID: "stub.llm", kind: .llm)
        await state.fetchExternalModels(kind: .llm, providerID: "stub.llm")
        XCTAssertEqual(state.externalVerifiedKeys["stub.llm"], "sk-test-key")

        state.setKeyDraft("sk-another-key", providerID: "stub.llm", kind: .llm)
        XCTAssertNil(
            state.externalVerifiedKeys["stub.llm"],
            "Key 一变，旧认证记录必须作废，下一次「确认配置」必须重新真实认证"
        )
    }

    // MARK: - ③ 启动弹窗必须与真实连通性一致

    /// Key 失效时点「启动」：必须抛错（红色弹窗 + 服务端原话），并回滚到关闭态。
    func testStartWithRejectedKeyThrowsInsteadOfPretendingSuccess() async throws {
        let server = try StubServer.start(authorized: false)
        defer { server.cleanUp() }
        let port = try server.waitForPort()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-apply-gate-start-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        try await store.updateProvider(
            ProviderConfig(
                id: "stub.llm", kind: .llm, enabled: true, runtime: .remoteAPI,
                endpoint: "http://127.0.0.1:\(port)/v1", apiKey: "sk-bad",
                model: "stub-model", candidateModels: ["stub-model"]
            )
        )
        // 必须把 stub 激活成产品层的当前 Provider：否则 `resolvedProvider` 会选到
        // 默认配置里的本地模型（本机 Ollama 真的在跑），探出来的就是别的错误了。
        try await store.mutateProduct { product in
            product.activateProvider("stub.llm", for: .llm)
            product.selectModel("stub-model", for: .llm)
        }
        let services = CoachServices(config: store, databasePath: ":memory:")

        // 先显式关闭（真实流程里「启动」按钮只出现在关闭态），再尝试启动。
        _ = try await services.setModelRunning(.llm, running: false)
        do {
            _ = try await services.setModelRunning(.llm, running: true)
            XCTFail("Key 被拒时「启动」绝不能报成功")
        } catch let error as AIProviderError {
            guard case .invalidConfiguration(let reason) = error else {
                XCTFail("应抛 invalidConfiguration，实际：\(error)")
                return
            }
            XCTAssertTrue(reason.contains("Invalid token"), "原因要带服务端原话：\(reason)")
        }
        // 启动失败要回滚：状态不得停留在「已启动」。
        let running = await services.isModelRunning(.llm)
        XCTAssertFalse(running, "启动失败后模型应保持关闭态，弹窗与状态才不会互相矛盾")
        try? FileManager.default.removeItem(at: directory)
    }
}
