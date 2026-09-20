import AIDomain
import AIInterfaces
import AIInfrastructure
import AIServices
import AppCore
@testable import AppUI
import XCTest

/// 词典「最近查过」（#282）的回归。
///
/// 三条容易坏在这里的事：
/// 1. **查失败的词也记进来** —— 列表里躺着一个点进去必定再失败的按钮，比没有这个列表更糟；
/// 2. 同名词叠成一排（`Nominal` / `nominal` 各占一颗）—— 那就是「列表里混进了重复项」；
/// 3. 只增不截 —— 攒到几十个以后这一行从「回查」变成「找词」。
@MainActor
final class DictionaryRecentWordsTests: XCTestCase {

    /// 一份临时目录里的 AppState：绝不碰真实配置、真实数据库与真实词典库。
    private func makeState() -> AppState {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dict-recent-\(UUID().uuidString)", isDirectory: true)
        let books = directory.appendingPathComponent("dict-store", isDirectory: true)
        let state = AppState(services: CoachServices(
            config: ConfigStore(fileURL: directory.appendingPathComponent("config.json")),
            databasePath: ":memory:",
            dictionaryStore: DictionaryBookStore(
                fileURL: books.appendingPathComponent("dictionaries.json"),
                booksDirectory: books.appendingPathComponent("books", isDirectory: true)
            )
        ))
        // 「最近查过」存 `UserDefaults.standard`，进程内共享：每个用例都从空表起步。
        state.clearRecentDictionaryWords()
        return state
    }

    // MARK: - 记账规则（纯逻辑）

    /// 最新的排在最前。
    func testMostRecentComesFirst() {
        let state = makeState()
        state.recordRecentDictionaryWord("alpha")
        state.recordRecentDictionaryWord("beta")
        XCTAssertEqual(state.recentDictionaryWords, ["beta", "alpha"])
    }

    /// 同名词（大小写不同也算同一个）只留最新位置，不叠成一排。
    func testSameWordIsDeduplicatedCaseInsensitively() {
        let state = makeState()
        state.recordRecentDictionaryWord("alpha")
        state.recordRecentDictionaryWord("beta")
        state.recordRecentDictionaryWord("ALPHA")
        XCTAssertEqual(state.recentDictionaryWords, ["ALPHA", "beta"])
    }

    /// 有上限：超出的从尾巴上掉下去。
    func testListIsCapped() {
        let state = makeState()
        for index in 0..<(AppState.recentDictionaryWordsLimit + 5) {
            state.recordRecentDictionaryWord("word\(index)")
        }
        XCTAssertEqual(state.recentDictionaryWords.count, AppState.recentDictionaryWordsLimit)
        // 掉下去的是最早的那一批（word0…word4）。
        XCTAssertEqual(state.recentDictionaryWords.last, "word5")
    }

    /// 清空只清这一排。
    func testClearEmptiesTheRow() {
        let state = makeState()
        state.recordRecentDictionaryWord("alpha")
        state.clearRecentDictionaryWords()
        XCTAssertTrue(state.recentDictionaryWords.isEmpty)
    }

    // MARK: - 只记「真的查到了」的

    /// 命中缓存（走模型的那一支之外的成功路径）→ 记一笔。
    func testSuccessfulLookupIsRecorded() async {
        let state = makeState()
        // 先把详情摆进会话：这条路径就是「已经查过、不用再发请求」那一支。
        state.dictionaryLookup.cache(DictionaryDetail(word: "alpha"))

        await state.lookUpDictionaryWord("alpha", pushing: false)

        XCTAssertEqual(state.recentDictionaryWords, ["alpha"])
    }

    /// 查失败 → 不记。
    ///
    /// ⚠️ 必须用**桩**把失败钉死：这一支若落到本机真在跑的模型上，查询会成功
    /// （实测等了 21 秒还成功了），用例的前提当场塌掉。桩让失败变成确定的事实。
    func testFailedLookupIsNotRecorded() async throws {
        let (state, directory) = try await makeStateWithFailingModel()
        defer { try? FileManager.default.removeItem(at: directory) }

        await state.lookUpDictionaryWord("zqxwv-not-a-word", pushing: false)

        XCTAssertNotNil(state.dictionaryNotice, "前提：这次查询确实失败了")
        XCTAssertTrue(
            state.recentDictionaryWords.isEmpty,
            "查失败的词不该进「最近查过」—— 点进去必定再失败一次"
        )
    }

    // MARK: - 桩

    /// 一个**必定失败**的 LLM：让「查词失败」这件事不依赖本机有没有真模型在跑。
    private final class FailingLLMProvider: LLMProvider, @unchecked Sendable {
        let providerID = "stub.failing.llm"
        let kind: AIProviderKind = .llm

        func initialize(config: ProviderConfig) async throws {}
        func load() async throws {}
        func unload() async {}
        func healthCheck() async -> ProviderHealth { .connected(model: "mock-model") }
        func capabilities() -> ProviderCapabilities {
            ProviderCapabilities(streaming: false, structuredOutput: true, multilingual: true)
        }
        func metadata() -> ProviderMetadata {
            ProviderMetadata(id: providerID, displayName: "失败桩", runtime: .mock, version: "1.0")
        }
        func llmCapabilities() -> LLMCapabilities {
            LLMCapabilities(streaming: false, structuredOutput: true, multilingual: true)
        }
        func discoverModels() async throws -> [DiscoveredModel] { [] }

        func generate(_ request: LLMRequest) async throws -> LLMResponse {
            throw URLError(.notConnectedToInternet)
        }

        func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMChunk, Error> {
            AsyncThrowingStream { $0.finish(throwing: URLError(.notConnectedToInternet)) }
        }
    }

    /// 把「查词要问模型」这条路指到必定失败的桩上（与 `DictionaryLookupCancelTests` 同一套造法）。
    private func makeStateWithFailingModel() async throws -> (AppState, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dict-recent-fail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        try await store.updateProvider(
            ProviderConfig(
                id: "stub.failing.llm", kind: .llm, enabled: true, runtime: .mock, model: "mock-model",
                candidateModels: ["mock-model"]
            )
        )
        try await store.mutateProduct { product in
            product.activateProvider("stub.failing.llm", for: .llm)
            product.selectModel("mock-model", for: .llm)
        }
        let services = CoachServices(
            config: store, databasePath: ":memory:",
            dictionaryStore: DictionaryBookStore(
                fileURL: directory.appendingPathComponent("dictionaries.json"),
                booksDirectory: directory.appendingPathComponent("books", isDirectory: true)
            )
        )
        try await services.bootstrapLLM()
        await services.llm.register(FailingLLMProvider())
        let state = AppState(services: services)
        state.clearRecentDictionaryWords()
        return (state, directory)
    }
}
