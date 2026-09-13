import AIDomain
import AIInfrastructure
import AIInterfaces
import AIProviders
import AppCore
import Foundation
import XCTest

/// 「点一次朗读 = 一个模型 + 一次请求」的端到端证明（**不触外网、不花钱**）。
///
/// 起一个本机桩服务，把教师语音 Provider 指向它，然后走朗读真正走的那条路
/// （`RemoteTTSAdapter.synthesize`）。断言：
///
/// 1. 桩服务**只**收到 1 个请求；
/// 2. 请求体里的 `model` **就是**用户选定的那个，而不是候选列表里的其它模型；
/// 3. 审计里多出 1 条计费记录，模型名一致。
///
/// 之所以强调「不花钱」：事故之后用户明确要求不要再靠真实调用去试错。
/// 这条测试把「朗读只打一次、只打一个模型」钉死在 CI 里。
final class RemoteCallE2ETests: XCTestCase {

    /// 把审计留痕重定向到临时目录：自动化测试绝不能写进用户自己的对账文件。
    private static let isolatedLog = FileManager.default.temporaryDirectory
        .appendingPathComponent("alc-e2e-remote-calls.jsonl")

    override func setUp() {
        super.setUp()
        setenv("ALC_REMOTE_CALL_LOG", Self.isolatedLog.path, 1)
        try? FileManager.default.removeItem(at: Self.isolatedLog)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: Self.isolatedLog)
        super.tearDown()
    }

    // MARK: - 桩服务

    private final class StubServer {
        let directory: URL
        private let process = Process()
        private let portFile: URL
        private let logFile: URL

        private init(directory: URL) {
            self.directory = directory
            self.portFile = directory.appendingPathComponent("port")
            self.logFile = directory.appendingPathComponent("requests.jsonl")
        }

        /// 起一个只监听 127.0.0.1 的桩服务；python3 不可用时抛 skip。
        static func start() throws -> StubServer {
            let python = "/usr/bin/python3"
            guard FileManager.default.isExecutableFile(atPath: python) else {
                throw XCTSkip("本机没有 python3，跳过桩服务端到端测试")
            }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("alc-stub-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let server = StubServer(directory: directory)
            let script = directory.appendingPathComponent("stub.py")
            try Self.script.write(to: script, atomically: true, encoding: .utf8)

            server.process.executableURL = URL(fileURLWithPath: python)
            server.process.arguments = [script.path, server.portFile.path, server.logFile.path]
            server.process.standardOutput = FileHandle.nullDevice
            server.process.standardError = FileHandle.nullDevice
            try server.process.run()
            return server
        }

        var port: Int? {
            guard let text = try? String(contentsOf: portFile, encoding: .utf8) else { return nil }
            return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        /// 轮询端口文件，最多等 10 秒。
        func waitForPort() throws -> Int {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if let port { return port }
                usleep(50_000)
            }
            throw XCTSkip("桩服务未能启动（端口未就绪）")
        }

        struct Record {
            let method: String
            let path: String
            let body: String
        }

        func records() throws -> [Record] {
            guard let text = try? String(contentsOf: logFile, encoding: .utf8) else { return [] }
            return try text.split(separator: "\n").map { line in
                let object = try XCTUnwrap(
                    try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                )
                return Record(
                    method: object["method"] as? String ?? "",
                    path: object["path"] as? String ?? "",
                    body: object["body"] as? String ?? ""
                )
            }
        }

        func stop() {
            if process.isRunning { process.terminate() }
        }

        func cleanUp() {
            stop()
            try? FileManager.default.removeItem(at: directory)
        }

        /// 桩服务：记录每一次请求（方法 / 路径 / 请求体），并回一个最小合法响应。
        private static let script = #"""
        import json, sys
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

        port_file, log_file = sys.argv[1], sys.argv[2]

        class Handler(BaseHTTPRequestHandler):
            def _reply(self, payload, content_type):
                body = payload if isinstance(payload, (bytes, bytearray)) else json.dumps(payload).encode()
                self.send_response(200)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                with open(log_file, "a") as handle:
                    handle.write(json.dumps({"method": "GET", "path": self.path, "body": ""}) + "\n")
                self._reply({"data": []}, "application/json")

            def do_POST(self):
                length = int(self.headers.get("Content-Length") or 0)
                raw = self.rfile.read(length).decode("utf-8", "replace")
                with open(log_file, "a") as handle:
                    handle.write(json.dumps({"method": "POST", "path": self.path, "body": raw}) + "\n")
                self._reply(b"RIFF\x00\x00\x00\x00WAVE", "audio/wav")

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        with open(port_file, "w") as handle:
            handle.write(str(server.server_address[1]))
        server.serve_forever()
        """#
    }

    // MARK: - 用例

    func testOneSpeakCallIssuesExactlyOneRequestWithTheSelectedModel() async throws {
        let server = try StubServer.start()
        defer { server.cleanUp() }
        let port = try server.waitForPort()

        let selectedModel = "fnlp/MOSS-TTSD-v0.5"
        let config = ProviderConfig(
            id: "test.tts",
            kind: .tts,
            enabled: true,
            runtime: .remoteAPI,
            endpoint: "http://127.0.0.1:\(port)/v1",
            apiKey: "sk-test-only",
            model: selectedModel,
            // 候选列表里故意放别的模型：用来证明它们不会被误用。
            candidateModels: ["some/other-model", "another/model"],
            voices: ["FunAudioLLM/CosyVoice2-0.5B:bella"]
        )
        let adapter = RemoteTTSAdapter(providerID: "test.tts", client: HTTPClient(useSystemProxy: false))
        try await adapter.initialize(config: config)

        let before = await RemoteCallAudit.shared.summary().billableTotal
        _ = try await adapter.synthesize(
            TTSRequest(text: "Nice to meet you!", voice: "FunAudioLLM/CosyVoice2-0.5B:bella")
        )
        let after = await RemoteCallAudit.shared.summary()

        let records = try server.records()
        // ① 一次朗读 = 一个请求
        XCTAssertEqual(records.count, 1, "一次朗读只能产生 1 个云端请求，实际 \(records.count) 个")
        XCTAssertEqual(records[0].method, "POST")
        XCTAssertEqual(records[0].path, "/v1/audio/speech")

        // ② 请求体里的模型就是用户选定的那个
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(records[0].body.utf8)) as? [String: Any]
        )
        XCTAssertEqual(json["model"] as? String, selectedModel)
        XCTAssertFalse(records[0].body.contains("other-model"), "绝不能调用候选列表里的其它模型")

        // ③ 审计如实记账（用户可据此与账单逐条对账）
        XCTAssertEqual(after.billableTotal, before + 1)
        XCTAssertTrue(after.models.contains(selectedModel), "涉及模型：\(after.models)")
        XCTAssertEqual(after.blockedTotal, 0)
    }

    /// 连着点两次朗读 = 两个请求、两个模型名都不变（不会因为「重复」而扩散）。
    func testRepeatedSpeakCallsStayOnTheSameModel() async throws {
        let server = try StubServer.start()
        defer { server.cleanUp() }
        let port = try server.waitForPort()

        let selectedModel = "fnlp/MOSS-TTSD-v0.5"
        let config = ProviderConfig(
            id: "test.tts", kind: .tts, enabled: true, runtime: .remoteAPI,
            endpoint: "http://127.0.0.1:\(port)/v1", apiKey: "sk-test-only",
            model: selectedModel, candidateModels: ["some/other-model"]
        )
        let adapter = RemoteTTSAdapter(providerID: "test.tts", client: HTTPClient(useSystemProxy: false))
        try await adapter.initialize(config: config)

        for text in ["Hello!", "Nice to meet you!"] {
            _ = try await adapter.synthesize(TTSRequest(text: text))
        }

        let records = try server.records()
        XCTAssertEqual(records.count, 2)
        for record in records {
            XCTAssertTrue(record.body.contains("MOSS-TTSD-v0.5"))
        }
        let uniqueModels = try records.map { record -> String in
            let json = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(record.body.utf8)) as? [String: Any]
            )
            return try XCTUnwrap(json["model"] as? String)
        }
        XCTAssertEqual(Set(uniqueModels), [selectedModel], "两次朗读用的必须是同一个模型")
    }

    /// 回归（29 步事故最后一处隐患）：Provider 只探测出候选清单、**自己没配模型**、
    /// 产品层也没选时，朗读必须**拒绝发请求**——桩服务收到 0 个请求，
    /// 而不是拿 `candidateModels.first` 去打一个用户没选的模型。
    func testSpeakWithoutSelectedModelRefusesInsteadOfGuessing() async throws {
        let server = try StubServer.start()
        defer { server.cleanUp() }
        let port = try server.waitForPort()

        let config = ProviderConfig(
            id: "test.tts", kind: .tts, enabled: true, runtime: .remoteAPI,
            endpoint: "http://127.0.0.1:\(port)/v1", apiKey: "sk-test-only",
            model: nil,                                              // 没配默认模型
            candidateModels: ["some/other-model", "another/model"]    // 只有探测来的候选清单
        )
        let adapter = RemoteTTSAdapter(providerID: "test.tts", client: HTTPClient(useSystemProxy: false))
        try await adapter.initialize(config: config)

        do {
            _ = try await adapter.synthesize(TTSRequest(text: "Hello!"))
            XCTFail("没选模型时必须拒绝，而不是替用户挑一个候选模型去计费")
        } catch let error as AIProviderError {
            guard case .invalidConfiguration(let reason) = error else {
                return XCTFail("应当是配置类错误，实际：\(error)")
            }
            XCTAssertTrue(reason.contains("未选择"), "错误要说清原因，方便用户去设置里选：\(reason)")
        }

        XCTAssertEqual(try server.records().count, 0, "被拒绝时一个请求都不该发出去")
    }
}
