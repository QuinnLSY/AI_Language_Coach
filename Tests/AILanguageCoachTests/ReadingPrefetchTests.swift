import AIDomain
import AIInfrastructure
import AIInterfaces
import AIServices
import AppCore
@testable import AppUI
import XCTest

/// 桩 LLM 复用 `ScenarioDraftFlowTests` 那一只（跨文件共用，免得同款 python 脚本抄两遍）。
private typealias StubLLM = ScenarioDraftFlowTests.StubLLM

/// 开屏后台预生成今天的短文阅读（#330）的**接线**回归。
///
/// 做的事：起一个桩 LLM（`ScenarioDraftFlowTests.StubLLM` 复用），把 Provider 指向它，
/// 然后走**用户真正走的那条路**：
///   ① `prefetchTodaysReading()`（开屏后台那次）→ 今天那篇是不是**只落库、不上屏**；
///   ② `openReading()`（用户点开阅读）→ 能不能**直接用**刚才预生成的那篇（不再发请求）；
///   ③ 今天已经有一篇时，预生成**绝不再出第二篇**（阅读是「一天一篇」的量）。
///
/// ⚠️ 断言的重点不是「模型写了什么」，而是「**发了几个请求**」与「界面状态有没有被偷改」。
/// ⚠️ 全程不触外网、不花钱；留痕与环境全部重定向到临时目录。
/// ⚠️ 不用 `setUp/tearDown`（那是非隔离上下文，碰主 actor 属性会刷屏警告）——
/// 每个用例自己 `defer` 收尾。
@MainActor
final class ReadingPrefetchTests: XCTestCase {

    /// 审计留痕重定向：自动化测试绝不能写进用户自己的对账文件。
    private static let isolatedLog = FileManager.default.temporaryDirectory
        .appendingPathComponent("alc-reading-prefetch-remote-calls.jsonl")

    /// 样板模型输出（键 = `Prompts/reading_generation.txt` 要求的那几个）。
    /// 两道题就够 —— 解析器只要有文章 + 至少一道题就不算空。
    private static let sampleReading = """
    title: The Lighthouse Cat
    passage: Mimo lived in a lighthouse. Every morning she chased the gulls.
    q: Where did Mimo live?
    opt: In a school. || In a lighthouse. || On a farm. || In a boat.
    answer: 1
    quote: Mimo lived in a lighthouse.
    explain: 第一段第一句直接说了住处。
    trap: 其余选项都不在原文里。
    q: What did Mimo chase?
    opt: mice || gulls || dogs || fish
    answer: 1
    quote: Every morning she chased the gulls.
    explain: chase 后面接追逐对象。
    trap: 顺序易混。
    """

    // MARK: - 夹具

    private func makeState(
        firstPostDelayMilliseconds: Int = 0
    ) async throws -> (state: AppState, stub: StubLLM, directory: URL) {
        setenv("ALC_REMOTE_CALL_LOG", Self.isolatedLog.path, 1)
        try? FileManager.default.removeItem(at: Self.isolatedLog)

        let stub = try StubLLM.start(reply: Self.sampleReading, firstPostDelayMilliseconds: firstPostDelayMilliseconds)
        let port = try stub.waitForPort()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("reading-prefetch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let store = ConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        // ⚠️ `runtime: .ollama`：本地 runtime 的适配器**明确绕开系统代理** ——
        // 云端适配器默认沿用系统代理，本机 `HTTP_PROXY` 会劫持回环请求（桩服务被打成 502）。
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
        let services = CoachServices(
            config: store, databasePath: directory.appendingPathComponent("learning.db").path
        )
        return (AppState(services: services), stub, directory)
    }

    private static func todayKey() -> Int { WritingTopicPicker.dayKey(for: Date()) }

    /// 收尾（每例自己 defer）。
    private func cleanUp(_ stub: StubLLM, _ directory: URL) {
        stub.cleanUp()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: Self.isolatedLog)
    }

    private func posts(_ stub: StubLLM) throws -> Int {
        try stub.records().filter { $0.method == "POST" }.count
    }

    /// 轮询到桩服务收到第 `count` 个 POST（用来定位「请求已经在途」的那一刻）。
    private func waitForPosts(_ stub: StubLLM, count: Int, timeout: TimeInterval = 6) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try posts(stub) >= count { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("桩服务迟迟没有收到第 \(count) 个请求（当前 \(try posts(stub)) 个）—— 夹具坏了，不是断言坏了")
    }

    // MARK: - ① 预生成 = 落库 + 不上屏

    func testPrefetchStoresTodaysReadingWithoutTouchingTheScreen() async throws {
        let (state, stub, directory) = try await makeState()
        defer { cleanUp(stub, directory) }

        await state.prefetchTodaysReading()

        XCTAssertEqual(try posts(stub), 1, "预生成就是**一次**请求")
        let stored = await state.services.todaysReadings(dayKey: Self.todayKey())
        XCTAssertEqual(stored.count, 1, "预生成必须把今天那篇落进库里，否则用户点开时还得现等")
        XCTAssertEqual(stored.first?.passage.title, "The Lighthouse Cat")

        // ⚠️ 「不上屏」是这一条的重点：用户还没进阅读页，界面状态一个字都不许动 ——
        // 替他决定「今天看第几篇」会让页面一进去就停在一篇他没点过的文章上。
        XCTAssertTrue(state.readingEntries.isEmpty, "预生成不许往页面上塞东西")
        XCTAssertEqual(state.readingEntryIndex, 0)
        XCTAssertFalse(state.isReadingReviewed, "预生成不许把页面标成「已交卷」")
        XCTAssertTrue(state.readingChoices.isEmpty, "预生成不许替用户答题")
        XCTAssertFalse(state.isReadingLoading, "预生成跑完要把加载态收干净")
        XCTAssertTrue(state.readingNotice.isEmpty, "后台活儿不该在页面上留一句提示")
    }

    // MARK: - ② 用户点开阅读：直接用预生成那篇，不再发请求

    func testOpenReadingReusesWhatWasPrefetchedWithoutASecondRequest() async throws {
        let (state, stub, directory) = try await makeState()
        defer { cleanUp(stub, directory) }

        await state.prefetchTodaysReading()
        XCTAssertEqual(try posts(stub), 1)

        await state.openReading()

        XCTAssertEqual(try posts(stub), 1, "预生成过了就该秒开 —— 再发一次请求就是白花钱")
        XCTAssertEqual(state.readingEntries.count, 1)
        XCTAssertEqual(state.readingEntries.first?.passage.title, "The Lighthouse Cat")
        XCTAssertEqual(state.readingPassage?.title, "The Lighthouse Cat", "页面要落在预生成的那一篇上")
    }

    // MARK: - ③ 今天已经有了：一次请求都不该再发

    func testPrefetchIsANoOpWhenTodayAlreadyHasOne() async throws {
        let (state, stub, directory) = try await makeState()
        defer { cleanUp(stub, directory) }

        await state.prefetchTodaysReading()
        XCTAssertEqual(try posts(stub), 1)
        // 第二次（比如用户当天又重启了一次应用）。
        await state.prefetchTodaysReading()

        XCTAssertEqual(try posts(stub), 1, "阅读是「一天一篇」的量：今天有了就绝不再出")
        let stored = await state.services.todaysReadings(dayKey: Self.todayKey())
        XCTAssertEqual(stored.count, 1, "库里也不许攒出第二篇")
    }

    /// 用户开着应用自己在页面上出了一篇（`loadReading`）之后，预生成也不许再补一刀。
    func testPrefetchYieldsWhenTheLearnerAlreadyGeneratedOnThePage() async throws {
        let (state, stub, directory) = try await makeState()
        defer { cleanUp(stub, directory) }

        await state.openReading()
        XCTAssertEqual(try posts(stub), 1, "页面上先出的一篇就是一次请求")

        await state.prefetchTodaysReading()

        XCTAssertEqual(try posts(stub), 1, "预生成不许在用户自己出的那篇之后再补一篇")
        let stored = await state.services.todaysReadings(dayKey: Self.todayKey())
        XCTAssertEqual(stored.count, 1)
    }

    // MARK: - ④ 两个请求同时在途：后到的那个要**等**，不是另起一篇

    /// 用户的动作可能和开屏那次预生成**撞在一起**（他手比模型快）。
    /// `openReading` 必须等那次在途的预生成，而不是自己再出今天第二篇。
    ///
    /// ⚠️ 这条必须靠桩服务卡住响应才测得出来：不卡的话「在途」那一刻根本抓不住，
    /// 用例要么常年绿（假绿）、要么看机器忙不忙。做法是等桩服务**已经收到**那个请求
    /// （说明预生成正卡在等响应），这时才点阅读。
    func testOpenReadingWaitsForAnInflightPrefetchInsteadOfGeneratingASecondOne() async throws {
        let (state, stub, directory) = try await makeState(firstPostDelayMilliseconds: 700)
        defer { cleanUp(stub, directory) }

        state.readingPrefetchTask = Task { [weak state] in await state?.prefetchTodaysReading() }
        try await waitForPosts(stub, count: 1)

        await state.openReading()

        XCTAssertEqual(
            try posts(stub), 1,
            "预生成还在途时点开阅读，应当等它 —— 另起一篇会白花一次请求，"
                + "用户还会在「1 / 2」的编号里看到内容跳变"
        )
        XCTAssertEqual(state.readingEntries.count, 1, "页面落在预生成那一篇上，不该多出第二篇")
        let stored = await state.services.todaysReadings(dayKey: Self.todayKey())
        XCTAssertEqual(stored.count, 1, "库里也不许出现今天第二篇")
    }

    // MARK: - ④-b 页面上「换一篇」撞上在途的预生成：收尾时不许再补一篇

    /// 还有一条路能在预生成在途时又发一次生成：用户已经在阅读页上，点了「换一篇」
    /// （`loadReading` 的语义就是「**再出一篇**」，它不该、也不会去看今天有没有）。
    /// 两次生成同时在途时，**预生成那一路要认输** —— 否则今天会攒出两篇。
    func testPrefetchYieldsToAPageGenerationThatOverlapsIt() async throws {
        let (state, stub, directory) = try await makeState(firstPostDelayMilliseconds: 700)
        defer { cleanUp(stub, directory) }

        state.readingPrefetchTask = Task { [weak state] in await state?.prefetchTodaysReading() }
        try await waitForPosts(stub, count: 1)

        await state.loadReading()
        XCTAssertEqual(try posts(stub), 2, "「换一篇」本来就要发一次请求（两次同时在途正是要造的场面）")

        await state.readingPrefetchTask?.value
        let stored = await state.services.todaysReadings(dayKey: Self.todayKey())
        XCTAssertEqual(
            stored.count, 1,
            "预生成收尾时发现用户已经自己出了一篇，就该**丢掉自己那一份** ——"
                + "落下去就是今天第二篇（白花一次请求，还会让用户看到内容跳变）"
        )
    }

    // MARK: - ④-c 侧栏连点两下：第二下也要等，不许自己再出一篇

    /// 两次「进阅读页」挤在一起时，也只能有**一次**生成。
    ///
    /// ⚠️ 这条钉的是 `openReading` 里那个等待块**整体**在不在（撤掉它 → 两条并发用例各报 2 个请求）；
    /// 它**不能**区分「等完是否把任务清空」—— 清空发生在等待之后，并发进来的第二个照样看得到它
    /// （实测：把清空加回去这条仍然绿）。别把它当成那个的守卫。
    func testASecondEntryWhilePrefetchIsInflightAlsoWaits() async throws {
        let (state, stub, directory) = try await makeState(firstPostDelayMilliseconds: 700)
        defer { cleanUp(stub, directory) }

        state.readingPrefetchTask = Task { [weak state] in await state?.prefetchTodaysReading() }
        try await waitForPosts(stub, count: 1)

        async let first: Void = state.openReading()
        async let second: Void = state.openReading()
        _ = await (first, second)

        XCTAssertEqual(
            try posts(stub), 1,
            "两次进入阅读页都该等那一次在途预生成；第二下自己另起一篇就是白花钱"
        )
        XCTAssertEqual(state.readingEntries.count, 1)
    }

    // MARK: - ⑤ 模型被用户关掉：预生成不许把它偷偷拉起来
    func testPrefetchNeverResurrectsAModelTheLearnerSwitchedOff() async throws {
        let (state, stub, directory) = try await makeState()
        defer { cleanUp(stub, directory) }

        // ⚠️ `try?`：桩服务对「卸载模型」那条 `POST /api/generate` 回的是 OpenAI 形状的体，
        // 适配器解不出来就会抛。但**状态是在调控制器之前就落下的**
        // （`CoachServices.setModelRunning` 先 `stoppedKinds.insert`），所以这里只管状态。
        try? await state.services.setModelRunning(.llm, running: false)
        // ⚠️ 断言钉子问的是**服务层真源**：`AppState.modelRunStates` 是界面快照，
        // 它这里仍然是 true（本次没有 `syncModelRunStates`）——
        // 而预生成要挡的正是「快照过期」那种情形，问快照就等于没挡。
        let modelRunning = await state.services.isModelRunning(.llm)
        XCTAssertFalse(modelRunning, "夹具没把模型关掉，后面的断言就全是空的")
        // 关模型自己会打一次桩服务（那是卸载请求，不是生成请求）——先量好基线，
        // 断言的是「预生成**没有再添**请求」，而不是「一个请求都没有」。
        let afterSwitchingOff = try posts(stub)

        await state.prefetchTodaysReading()

        XCTAssertEqual(
            try posts(stub), afterSwitchingOff,
            "用户关掉的模型不该被开屏的后台任务悄悄叫起来"
        )
        let stored = await state.services.todaysReadings(dayKey: Self.todayKey())
        XCTAssertTrue(stored.isEmpty, "没生成出来就不该有落库")
        XCTAssertTrue(state.readingNotice.isEmpty, "后台活儿失败要静默：用户没点过任何东西")
        XCTAssertFalse(state.isReadingLoading, "也不该在界面上留一个转圈")
    }
}
