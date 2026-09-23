import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import XCTest

/// 一句话生成情景的**接线**（⑦）：一次请求 → 一个情景 → 落盘 → 进目录 → 目标词进词汇本。
///
/// 做法与 `RemoteCallE2ETests` 同款：起一个只监听 `127.0.0.1` 的桩服务，把 LLM Provider
/// 指向它，然后走**用户真正走的那条路**（`CoachServices.generateScenarioDraft`）。
/// 断言的重点不是「模型说了什么」，而是这条链路上的四件事：
///
/// 1. 一次生成 = **一个**请求（「一次操作 = 一个模型请求」的纪律）；
/// 2. 生成结果必须与内置情景同构，并且能按 id 从目录里查回来；
/// 3. 目标词真的进了词汇本（`source: .scenario`）—— 否则「自动出题」只做了一半；
/// 4. 失败的生成**一个字节都不落盘**。
///
/// 全程不触外网、不花钱；审计留痕与环境全部重定向到临时目录。
final class ScenarioDraftFlowTests: XCTestCase {

    /// 审计留痕重定向：自动化测试绝不能写进用户自己的对账文件。
    private static let isolatedLog = FileManager.default.temporaryDirectory
        .appendingPathComponent("alc-scenario-remote-calls.jsonl")

    private var server: StubLLM?
    private var workDirectory: URL?

    override func setUp() {
        super.setUp()
        setenv("ALC_REMOTE_CALL_LOG", Self.isolatedLog.path, 1)
        try? FileManager.default.removeItem(at: Self.isolatedLog)
    }

    override func tearDown() {
        server?.cleanUp()
        server = nil
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
        workDirectory = nil
        try? FileManager.default.removeItem(at: Self.isolatedLog)
        super.tearDown()
    }

    // MARK: - 夹具

    /// 样板模型输出（键 = `Prompts/scenario_draft.txt` 要求的那五个）。
    private let sampleOutput = """
    title: Ordering an oat milk latte | 咖啡店换燕麦奶
    scene: barista | customer | order a latte and ask to swap the milk | 2 | Hi! What can I get for you today?
    sentence: Could I get a latte with oat milk instead?
    sentence: Does it cost extra to swap the milk?
    vocabulary: oat milk | n. | 燕麦奶 | Could I have oat milk instead?
    vocabulary: swap | v. | 换掉 | Can I swap the milk?
    quest: Order your drink and change one thing about it
    """

    /// 一句描述里**故意留一个 ASCII 词**：请求体是 JSON，中文可能被转义，
    /// 用 ASCII 做「这句话真的发给了模型」的判据才稳。
    private let prompt = "在咖啡店点一杯 latte，想换成 oat milk"

    /// 起桩服务 + 装配一套「LLM 指向桩服务」的完整服务（学习库在内存里、情景落临时目录）。
    private func makeServices(reply: String) async throws -> (services: CoachServices, drafts: URL) {
        let stub = try StubLLM.start(reply: reply)
        server = stub
        let port = try stub.waitForPort()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scenario-flow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        workDirectory = directory

        let store = ConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        // ⚠️ 用 `runtime: .ollama`：本地 runtime 的适配器**明确绕开系统代理**
        // （云端适配器默认沿用系统代理，本机 `HTTP_PROXY` 会劫持回环请求 —— 桩服务会被打成 502）。
        try await store.updateProvider(
            ProviderConfig(
                id: "stub.llm", kind: .llm, enabled: true, runtime: .ollama,
                endpoint: "http://127.0.0.1:\(port)",
                model: "stub-model", candidateModels: ["stub-model"]
            )
        )
        try await store.mutateProduct { product in
            product.activateProvider("stub.llm", for: .llm)
            product.selectModel("stub-model", for: .llm)
        }

        let drafts = directory.appendingPathComponent("scenarios", isDirectory: true)
        let services = CoachServices(
            config: store,
            databasePath: ":memory:",
            customScenarioStore: CustomScenarioStore(directory: drafts)
        )
        return (services, drafts)
    }

    // MARK: - ① 一句话 → 一个请求 → 一个能开练的情景

    func testOnePromptBecomesOneRequestOneScenarioAndOneVocabularyBatch() async throws {
        let (services, drafts) = try await makeServices(reply: sampleOutput)
        let stub = try XCTUnwrap(server)

        let draft = try await services.generateScenarioDraft(from: prompt)

        // ① 一次生成 = 一个请求（装配时的模型探测是 GET，不算生成）。
        let posts = try stub.records().filter { $0.method == "POST" }
        XCTAssertEqual(posts.count, 1, "一次生成只能发 1 个请求，实际 \(posts.count) 个")
        XCTAssertEqual(posts.first?.path, "/v1/chat/completions")
        XCTAssertTrue(posts.first?.body.contains("latte") == true, "请求体里必须有用户那句话")
        XCTAssertTrue(posts.first?.body.contains("stub-model") == true, "请求要用用户选定的模型")
        XCTAssertFalse(
            posts.first?.body.contains("{prompt}") == true
                || posts.first?.body.contains("{learning_language}") == true,
            "模板占位符必须全部替换掉，否则模型收到的是带花括号的残页"
        )

        // ② 生成结果与内置情景同构，且能按 id 查回来。
        XCTAssertEqual(draft.scenario.titleZh, "咖啡店换燕麦奶")
        XCTAssertEqual(draft.scenario.origin, .custom)
        XCTAssertEqual(draft.scenario.id, ScenarioDraftRule.stableID(prompt: prompt))
        XCTAssertEqual(draft.scenario.targetSentences.count, 2)
        XCTAssertFalse(draft.scenario.questPlan.steps.isEmpty, "生成完就该有可判定的主线步骤")

        let storedDrafts = await services.availableScenarioDrafts()
        XCTAssertEqual(storedDrafts.map(\.id), [draft.id], "生成成功必须落盘")
        let catalogued = await services.availableScenarios().first { $0.id == draft.id }
        XCTAssertNotNil(catalogued, "自建情景要进统一目录：分组展示 / 关卡绑定 / 今日跟读都读它")
        XCTAssertEqual(catalogued?.origin, .custom)
        let byID = await services.scenario(id: draft.id)
        XCTAssertEqual(byID?.titleZh, "咖啡店换燕麦奶", "进行中的会话靠 id 恢复")

        // ③ 目标词进词汇本（`source: .scenario`）—— 它们也顺带成了每日推荐「生词档」的候选。
        let entries = await services.vocabulary.entries()
        let words = Dictionary(uniqueKeysWithValues: entries.map { ($0.word, $0) })
        XCTAssertEqual(words["oat milk"]?.source, .scenario)
        XCTAssertEqual(words["swap"]?.meaning, "换掉")
        XCTAssertEqual(words.count, 2, "只收了这一批目标词")

        // ④ 落盘的就是这一份（文件名 = id）。
        let files = try FileManager.default.contentsOfDirectory(atPath: drafts.path)
        XCTAssertEqual(files, ["\(draft.id).json"])
    }

    /// 同一句话再生成一次 = **覆盖**（改说法才是新情景）：
    /// 否则用户反复点「生成」，列表里会堆出一串一模一样的情景。
    func testSamePromptTwiceOverwritesInsteadOfStacking() async throws {
        let (services, drafts) = try await makeServices(reply: sampleOutput)
        let stub = try XCTUnwrap(server)

        let first = try await services.generateScenarioDraft(from: prompt)
        let second = try await services.generateScenarioDraft(from: " \(prompt)\n")

        XCTAssertEqual(first.id, second.id, "只差空白算同一句话")
        let posts = try stub.records().filter { $0.method == "POST" }
        XCTAssertEqual(posts.count, 2, "两次生成就是两个请求（不缓存、不假装成功）")
        let storedDrafts = await services.availableScenarioDrafts()
        XCTAssertEqual(storedDrafts.count, 1, "仍旧只有一份")
        let files = try FileManager.default.contentsOfDirectory(atPath: drafts.path)
        XCTAssertEqual(files.count, 1)
    }

    // MARK: - ② 失败路径：该拦的拦、该留白的留白

    /// 描述太短：连模型装配都不该发生 —— 一个请求都不发。
    func testTooShortPromptNeverReachesTheModel() async throws {
        let (services, _) = try await makeServices(reply: sampleOutput)
        let stub = try XCTUnwrap(server)

        do {
            _ = try await services.generateScenarioDraft(from: "练口语")
            XCTFail("太短的描述必须报错")
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            XCTAssertTrue(reason.contains("太短"), "报错要说清原因：\(reason)")
        }
        let records = try stub.records()
        XCTAssertTrue(records.isEmpty, "输入不合法时一个请求都不该发，实际 \(records.count) 个")
        let storedDrafts = await services.availableScenarioDrafts()
        XCTAssertTrue(storedDrafts.isEmpty)
    }

    /// 模型答得不成形（缺标题 / 缺开场白 / 目标句不够）：**报错且不落盘**。
    ///
    /// 半成品会以「我的情景」的名义长期留在列表里，比一次失败难收拾得多。
    func testMalformedModelOutputFailsWithoutWritingAnything() async throws {
        let replies = [
            "Sure! Here's a scenario for you.",
            // 键名写错 = 关键行缺失（模型偶尔会自作主张改键名）。
            sampleOutput.replacingOccurrences(of: "title:", with: "topic:"),
        ]
        for reply in replies {
            let (services, drafts) = try await makeServices(reply: reply)
            let stub = try XCTUnwrap(server)
            // 每个回复各起一个桩服务：这一轮用完立刻收掉（`server` 马上会被下一轮覆盖）。
            defer {
                stub.cleanUp()
                server = nil
            }
            do {
                _ = try await services.generateScenarioDraft(from: prompt)
                XCTFail("不成形的输出必须报错：\(reply.prefix(24))")
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                XCTAssertFalse(reason.isEmpty, "要给出可读的失败说明")
            }
            let posts = try stub.records().filter { $0.method == "POST" }
            XCTAssertEqual(posts.count, 1, "毕竟真的问了模型一次")
            let storedDrafts = await services.availableScenarioDrafts()
            XCTAssertTrue(storedDrafts.isEmpty, "失败不许落盘")
            let files = try FileManager.default.contentsOfDirectory(atPath: drafts.path)
            XCTAssertTrue(files.isEmpty, "目录里不该出现任何文件：\(files)")
        }
    }

    // MARK: - 桩服务

    /// 一个只监听 `127.0.0.1` 的 OpenAI 兼容桩服务：`GET /v1/models` 回模型清单、
    /// `POST /v1/chat/completions` 回一份写死的 key-value 文本，并记录每一次请求。
    private final class StubLLM {

        struct Record {
            let method: String
            let path: String
            let body: String
        }

        private let directory: URL
        private let process = Process()
        private let portFile: URL
        private let logFile: URL
        private let replyFile: URL

        private init(directory: URL) {
            self.directory = directory
            self.portFile = directory.appendingPathComponent("port")
            self.logFile = directory.appendingPathComponent("requests.jsonl")
            self.replyFile = directory.appendingPathComponent("reply.txt")
        }

        /// python3 不可用时抛 skip（与 `RemoteCallE2ETests` 同款）。
        static func start(reply: String) throws -> StubLLM {
            let python = "/usr/bin/python3"
            guard FileManager.default.isExecutableFile(atPath: python) else {
                throw XCTSkip("本机没有 python3，跳过桩服务端到端测试")
            }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("alc-scenario-stub-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let stub = StubLLM(directory: directory)
            try reply.write(to: stub.replyFile, atomically: true, encoding: .utf8)
            let script = directory.appendingPathComponent("stub.py")
            try Self.script.write(to: script, atomically: true, encoding: .utf8)

            stub.process.executableURL = URL(fileURLWithPath: python)
            stub.process.arguments = [script.path, stub.portFile.path, stub.logFile.path, stub.replyFile.path]
            stub.process.standardOutput = FileHandle.nullDevice
            stub.process.standardError = FileHandle.nullDevice
            try stub.process.run()
            return stub
        }

        /// 轮询端口文件，最多等 10 秒。
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

        func cleanUp() {
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: directory)
        }

        private static let script = #"""
        import json, sys
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

        port_file, log_file, reply_file = sys.argv[1], sys.argv[2], sys.argv[3]

        class Handler(BaseHTTPRequestHandler):
            def _reply(self, payload):
                body = json.dumps(payload).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                self._log("GET", "")
                self._reply({"object": "list", "data": [{"id": "stub-model", "object": "model"}]})

            def do_POST(self):
                length = int(self.headers.get("Content-Length") or 0)
                raw = self.rfile.read(length).decode("utf-8", "replace")
                self._log("POST", raw)
                try:
                    with open(reply_file) as handle:
                        content = handle.read()
                except OSError:
                    content = ""
                self._reply({"model": "stub-model", "choices": [
                    {"message": {"role": "assistant", "content": content}, "finish_reason": "stop"}]})

            def _log(self, method, body):
                with open(log_file, "a") as handle:
                    handle.write(json.dumps({"method": method, "path": self.path, "body": body}) + "\n")

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        with open(port_file, "w") as handle:
            handle.write(str(server.server_address[1]))
        server.serve_forever()
        """#
    }
}
