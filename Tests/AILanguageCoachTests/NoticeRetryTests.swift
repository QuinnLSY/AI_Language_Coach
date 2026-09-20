import AIDomain
import AIInterfaces
import AIInfrastructure
import AIServices
import AppCore
@testable import AppUI
import XCTest

/// 「报错要带重试」（#283）的回归。
///
/// 两条钉住的事实：
/// 1. **失败的那条提示必须自带重试** —— 只给一句「失败了」，用户得自己回忆
///    刚才点的是哪个按钮、再点一遍，尤其复习卡上那个按钮还被折叠在卡片里；
/// 2. **重试跑的是刚才那一步**，不能是「再来一次」但其实是别的事；
///    同理，**没法重试**的提示（词已经被删了）就不该挂按钮 —— 挂了只会让人白点。
@MainActor
final class NoticeRetryTests: XCTestCase {

    /// 一个必定失败的 LLM：让「释义失败」不依赖本机有没有真模型在跑。
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

    private func makeState() async throws -> AppState {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notice-retry-\(UUID().uuidString)", isDirectory: true)
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
        return AppState(services: services)
    }

    // MARK: - 查词失败 → 重试

    func testFailedDictionaryLookupOffersRetry() async throws {
        let state = try await makeState()

        await state.lookUpDictionaryWord("zqxwv-not-a-word", pushing: false)

        let notice = try XCTUnwrap(state.dictionaryNotice, "查词失败必须给一条提示")
        let action = try XCTUnwrap(notice.action, "失败提示必须自带「重试」，否则用户得自己再点一遍原按钮")
        XCTAssertEqual(action.title, "重试")

        // 重试必须**真的再查一次**：把提示清掉，按下重试，它应当重新发请求并以失败收场。
        // （只断言「提示还在」是不行的 —— 什么都没做时它也还在。）
        state.dictionaryNotice = nil
        action.run()
        await waitUntil { state.dictionaryNotice != nil }
        XCTAssertNotNil(state.dictionaryNotice, "按下「重试」要真的再查一次同一个词")
    }

    // MARK: - 释义失败 → 重试

    func testFailedDefinitionOffersRetry() async throws {
        let state = try await makeState()
        let id = try await addWord(state, "zqxwv")

        await state.defineVocabulary(id: id)

        let notice = try XCTUnwrap(state.vocabularyNotice, "释义失败必须给一条提示")
        XCTAssertNotNil(notice.action, "释义失败这条要能重试（模型没开时尤其如此）")
    }

    /// 反方向：词已经不在词表里 → 重试没意义，不该挂按钮。
    func testUnretryableNoticeHasNoAction() async throws {
        let state = try await makeState()
        let id = try await addWord(state, "zqxwv")
        // 让这次请求走「词不在词表里」那一支。
        state.vocabularyEntries = []

        await state.defineVocabulary(id: id)

        let notice = try XCTUnwrap(state.vocabularyNotice)
        XCTAssertNil(notice.action, "词都没了还挂「重试」，点下去只会得到同一句话")
    }

    // MARK: - 复习卡：读失败 → 重试

    /// 复习卡上「没听清 / 没拿到录音」这类提示要能直接再读一遍。
    func testReviewNoticeCarriesItsRetryAction() async throws {
        let state = try await makeState()
        _ = try await addWord(state, "zqxwv")
        await state.startVocabularyReview()
        XCTAssertNotNil(state.vocabularyReview?.current, "前提：复习会话要真的开起来")

        // 一次都没录就收尾 → 一定落在「没有听清…」那一支（这是复习时最常见的失败）。
        await state.finishVocabularyReviewRecording()

        let notice = try XCTUnwrap(state.vocabularyReviewNotice, "读不了必须说一声")
        XCTAssertNotNil(
            notice.action,
            "读失败这条要自带重试：用户不用退出复习、不用去找原来那颗按钮"
        )
    }

    // MARK: - 辅助

    /// 往词汇本里加一个词，返回它的 id。
    private func addWord(_ state: AppState, _ word: String) async throws -> UUID {
        // ⚠️ 先 `await` 拿到值再 `XCTUnwrap`：`XCTUnwrap` 的入参是 autoclosure，
        // 塞 `await` 进去编译不过（`VocabularyService` 是 actor）。
        let entry = await state.services.vocabulary.add(word: word)
        await state.reloadVocabulary()
        return try XCTUnwrap(entry, "前提：这个词要能加进词汇本").id
    }

    /// 等到条件成立（最多 2 秒），不靠固定 sleep 猜。
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
