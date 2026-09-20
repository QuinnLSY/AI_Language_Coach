import AIDomain
import AIInterfaces
import AIInfrastructure
import AIServices
import AppCore
@testable import AppUI
import XCTest

/// 「查单词取消输入 → 正在跑的那次查询要跟着终止」的回归（用户 09-18 报障）。
///
/// 用户口径：`查单词取消输入后，应该同步终止正在查的进程。`
/// 报障现场是「输入框已清空，卡片却照样顶上来」—— 因为旧实现对在途请求只做到
/// 「结果回来时丢掉」，请求本身仍在跑：白等一次模型、白烧一次额度，
/// 期间那个词还一直占着「正在查…」的转圈。
///
/// ⚠️ 用**可控的桩 Provider**，不碰真模型：真请求要么秒回（测不出「在途」），
/// 要么几十秒（用例跑不动）；而且默认配置会把 `llm` 解析到本机真在跑的 Ollama 上。
/// 桩可以「挂起不返回」，于是「有没有真取消」变成可断言的事实。
@MainActor
final class DictionaryLookupCancelTests: XCTestCase {

    // MARK: - 桩

    /// `reply` 为 nil → 一直挂着，直到被取消；设了值 → 立刻返回那段文本。
    private final class ControlledLLMProvider: LLMProvider, @unchecked Sendable {
        let providerID = "stub.llm"
        let kind: AIProviderKind = .llm

        private let lock = NSLock()
        private var reply: String?
        private var started = 0
        private var cancelled = 0

        /// 已经进来的 `generate` 次数。
        var generateCount: Int { lock.withLock { started } }
        /// 其中**被动取消**的次数。
        var cancelCount: Int { lock.withLock { cancelled } }

        func setReply(_ text: String?) { lock.withLock { reply = text } }

        func resetCounters() { lock.withLock { started = 0; cancelled = 0 } }

        func initialize(config: ProviderConfig) async throws {}
        func load() async throws {}
        func unload() async {}
        func healthCheck() async -> ProviderHealth { .connected(model: "mock-model") }
        func capabilities() -> ProviderCapabilities {
            ProviderCapabilities(streaming: false, structuredOutput: true, multilingual: true)
        }
        func metadata() -> ProviderMetadata {
            ProviderMetadata(id: providerID, displayName: "可控桩", runtime: .mock, version: "1.0")
        }
        func llmCapabilities() -> LLMCapabilities {
            LLMCapabilities(streaming: false, structuredOutput: true, multilingual: true)
        }
        func discoverModels() async throws -> [DiscoveredModel] { [] }

        func generate(_ request: LLMRequest) async throws -> LLMResponse {
            let immediate: String? = lock.withLock { started += 1; return reply }
            if let immediate {
                return LLMResponse(text: immediate, model: request.model, finishReason: "stop")
            }
            do {
                // 长到用例绝不会等它自然结束；被取消时 `Task.sleep` 立刻抛 `CancellationError`。
                // ⚠️ 取 15s 而不是更长：修复生效时这条路径**根本不等待**（取消立刻返回），
                //    只有修复被改坏、用例开始失败时才会真的耗掉这段时间。
                try await Task.sleep(nanoseconds: 15 * 1_000_000_000)
            } catch {
                lock.withLock { cancelled += 1 }
                throw error
            }
            return LLMResponse(text: "", model: request.model, finishReason: "stop")
        }

        func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMChunk, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    /// 一份能解析出词条的最小模型回话（格式见 `dictionary_lookup.txt` 的模板）。
    private static let nominalReply = """
        word: nominal
        phonetic_us: /ˈnɑːmɪnl/
        sense: adj. | 名义上的；有名无实的
        example: They charged a nominal fee. | 他们收取了象征性的费用。
        """

    // MARK: - 造台子

    private func makeState() async throws -> (AppState, ControlledLLMProvider, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-dict-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        try await store.updateProvider(
            ProviderConfig(
                id: "stub.llm", kind: .llm, enabled: true, runtime: .mock, model: "mock-model",
                candidateModels: ["mock-model"]
            )
        )
        try await store.mutateProduct { product in
            product.activateProvider("stub.llm", for: .llm)
            product.selectModel("mock-model", for: .llm)
        }
        // ⚠️ 词典库一律换成临时仓库：默认的 `.shared` 读写的是用户真实的
        // `dictionaries.json`，用例不该动它。
        let books = directory.appendingPathComponent("dict-store", isDirectory: true)
        let dictionaryStore = DictionaryBookStore(
            fileURL: books.appendingPathComponent("dictionaries.json"),
            booksDirectory: books.appendingPathComponent("books", isDirectory: true)
        )
        let services = CoachServices(
            config: store, databasePath: ":memory:", dictionaryStore: dictionaryStore
        )
        try await services.bootstrapLLM()
        let provider = ControlledLLMProvider()
        await services.llm.register(provider)
        return (AppState(services: services), provider, directory)
    }

    /// 等到「请求真的发出去、还挂着」为止（而不是靠固定 sleep 猜）。
    private func waitUntilInFlight(
        _ state: AppState, provider: ControlledLLMProvider, timeout: TimeInterval = 5
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if provider.generateCount > 0, state.dictionaryLoadingWord != nil { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - ① 清空输入 → 在途请求要真被取消

    func testClearingTheQueryCancelsTheInFlightLookup() async throws {
        let (state, provider, directory) = try await makeState()
        defer { try? FileManager.default.removeItem(at: directory) }
        await state.openDictionary()
        provider.resetCounters()

        // 这个词不在任何词库里 → 一定走模型 → 必然挂在桩里。
        let lookup = Task { await state.lookUpDictionaryWord("zqxwv-nonexistent", pushing: false) }
        await waitUntilInFlight(state, provider: provider)
        XCTAssertEqual(provider.generateCount, 1, "这次查词应当真的发出了一次模型请求")
        XCTAssertEqual(
            state.dictionaryLoadingWord, "zqxwv-nonexistent",
            "请求在途时页面上应当显示「正在查…」，否则这个用例的前提不成立"
        )

        // 用户清空输入框：`TextField.onChange` 走的就是这一步。
        state.dictionaryQuery = ""
        await state.dictionaryQueryChanged()

        await lookup.value   // 让被取消的那次调用收尾，用例结束时不留后台任务

        XCTAssertEqual(
            provider.cancelCount, 1,
            "清空输入后，正在跑的这次请求必须被**真取消**（不是只把结果丢掉）"
        )
        XCTAssertNil(state.dictionaryLoadingWord, "请求不会再回来了，「正在查…」必须收掉，否则永远转着")
        XCTAssertNil(
            state.dictionaryLookup.currentWord,
            "还没拿到结果的当前页要撤掉（回到空态），不能把一个查不完的词留在展示位上"
        )
    }

    // MARK: - ② 已经查到的词不许被误伤

    /// 反方向也要成立：查询**已经成功**之后再清空输入，那张卡片要留着。
    ///
    /// 用户清空输入要终止的是「正在查的进程」，不是「已经查到的结果」——
    /// 顺手把卡片抹掉会让用户觉得「我什么都没干，内容自己没了」。
    func testClearingTheQueryKeepsAnAlreadyLoadedCard() async throws {
        let (state, provider, directory) = try await makeState()
        defer { try? FileManager.default.removeItem(at: directory) }
        await state.openDictionary()
        provider.setReply(Self.nominalReply)
        provider.resetCounters()

        await state.lookUpDictionaryWord("nominal", pushing: false)
        XCTAssertEqual(state.dictionaryLookup.currentWord, "nominal", "这次查询应当成功落成一页")
        XCTAssertNotNil(state.dictionaryLookup.current, "详情应当已经缓存进查词会话")

        // 清空输入。
        state.dictionaryQuery = ""
        await state.dictionaryQueryChanged()

        XCTAssertEqual(provider.cancelCount, 0, "已经没有在途请求了，不该凭空取消什么")
        XCTAssertEqual(
            state.dictionaryLookup.currentWord, "nominal",
            "已经查到的词不该因为清空输入被撤掉"
        )
        XCTAssertNotNil(state.dictionaryLookup.current, "已加载的详情要留着")
    }
}
