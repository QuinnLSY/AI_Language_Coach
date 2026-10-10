import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import XCTest

/// AI 自动课程的**接线**（③）：一次请求 → 一条有序的课 → 落盘 → 课内情景进目录 → 目标词进词汇本。
///
/// 做法与 `ScenarioDraftFlowTests` 同款：起一个只监听 `127.0.0.1` 的桩服务，把 LLM Provider
/// 指向它，然后走**用户真正走的那条路**（`CoachServices.generateCourse`）。
/// 断言的重点不是「模型说了什么」，而是这条链路上的四件事：
///
/// 1. 一次排课 = **一个**请求 —— 顺序正是这条课的价值，分次生成就丢了；
/// 2. 每一节都与内置情景同构，且能按 id 从统一目录里查回来（否则点不进去）；
/// 3. 目标词真的进了词汇本（`source: .scenario`）；
/// 4. 失败的排课**一个字节都不落盘**。
///
/// 全程不触外网、不花钱；审计留痕、配置、学习库、课程目录全部重定向到临时目录。
final class CourseBlueprintFlowTests: XCTestCase {

    /// 复用 `ScenarioDraftFlowTests` 的桩服务（跨 target/文件共用夹具的老写法）。
    private typealias StubLLM = ScenarioDraftFlowTests.StubLLM

    /// 审计留痕重定向：自动化测试绝不能写进用户自己的对账文件。
    private static let isolatedLog = FileManager.default.temporaryDirectory
        .appendingPathComponent("alc-course-remote-calls.jsonl")

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

    /// 样板模型输出（键 = `Prompts/course_blueprint.txt` 要求的那七个）。
    private let sampleOutput = """
    course: Ordering like a local | 像本地人一样点单
    focus: 盯住点单时的礼貌用语和 think 里的 th 音
    lesson: 1. 开口点单
    scene: barista | customer | order a drink and ask about the price | 3 | Hi there! What can I get for you?
    sentence: Could I get a latte with oat milk, please?
    sentence: Does it cost extra to swap the milk?
    vocabulary: oat milk | n. | 燕麦奶 | Could I have oat milk instead?
    quest: 点单成功并问清价格
    lesson: 2. 结账与离店
    scene: cashier | customer | pay and leave politely | 4 | That'll be five dollars, thanks.
    sentence: Can I pay by card?
    sentence: Keep the change, thanks.
    vocabulary: receipt | n. | 收据 | Here's your receipt.
    quest: 结账并道谢离店
    """

    /// 排课请求里**故意留一个 ASCII 词**：请求体是 JSON，中文可能被转义，
    /// 用 ASCII 做「这句话真的发给了模型」的判据才稳。
    private func request(topics: [String] = ["latte 店里点单"]) -> CourseRequest {
        CourseRequest(
            level: .b1,
            recurringErrors: ["I go to school yesterday -> I went to school yesterday"],
            weakPhonemes: ["θ"],
            topics: topics
        )
    }

    /// 起桩服务 + 装配一套「LLM 指向桩服务」的完整服务（学习库在内存里、课落临时目录）。
    private func makeServices(reply: String) async throws -> (services: CoachServices, courses: URL) {
        let stub = try StubLLM.start(reply: reply)
        server = stub
        let port = try stub.waitForPort()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("course-flow-\(UUID().uuidString)", isDirectory: true)
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

        let courses = directory.appendingPathComponent("courses", isDirectory: true)
        let services = CoachServices(
            config: store,
            databasePath: ":memory:",
            courseStore: CourseStore(directory: courses)
        )
        return (services, courses)
    }

    // MARK: - ① 学员状态 → 一个请求 → 一条能开练的课

    func testOneRequestProducesAnOrderedCourseThatLandsInTheCatalog() async throws {
        let (services, courses) = try await makeServices(reply: sampleOutput)
        let stub = try XCTUnwrap(server)

        let course = try await services.generateCourse(request())

        // ① 一次排课 = 一个请求（装配时的模型探测是 GET，不算生成）。
        let posts = try stub.records().filter { $0.method == "POST" }
        XCTAssertEqual(posts.count, 1, "一次排课只能发 1 个请求，实际 \(posts.count) 个 —— 顺序是这条课的价值")
        XCTAssertEqual(posts.first?.path, "/v1/chat/completions")
        XCTAssertTrue(posts.first?.body.contains("latte") == true, "请求体里必须带上学员的主题")
        XCTAssertTrue(posts.first?.body.contains("stub-model") == true, "请求要用用户选定的模型")
        XCTAssertFalse(
            posts.first?.body.contains("{level}") == true
                || posts.first?.body.contains("{min_lessons}") == true,
            "模板占位符必须全部替换掉，否则模型收到的是带花括号的残页"
        )

        // ② 有序的几节，每一节都与内置情景同构。
        XCTAssertEqual(course.displayTitle, "像本地人一样点单")
        XCTAssertEqual(course.lessonCount, 2)
        XCTAssertEqual(course.lessons.map(\.order), [1, 2])
        XCTAssertEqual(course.lessons.map(\.title), ["开口点单", "结账与离店"], "标题里不该留着模型自报的序号")
        XCTAssertEqual(course.targetLevel, .b1)
        XCTAssertTrue(course.rationale.contains("现在 B1"), "卡片上要能回答「照着什么排的」")
        XCTAssertTrue(course.focus.contains("th 音"), "模型写的 focus 要留下来")

        // 难度夹进学员档位（B1 → 3...4）；档位按**学员的档**判，不由难度反推。
        XCTAssertEqual(course.lessons.map(\.scenario.difficulty), [3, 4])
        XCTAssertEqual(course.lessons.map(\.scenario.level), ["B1", "B1"])
        for lesson in course.lessons {
            XCTAssertEqual(lesson.scenario.origin, .course)
            XCTAssertEqual(lesson.scenario.id, lesson.id)
            XCTAssertFalse(lesson.scenario.questPlan.steps.isEmpty, "每节排完就该有可判定的主线步骤")
        }

        // ③ 落盘 + 进统一目录（分组展示 / 关卡绑定 / 今日跟读都读它）。
        let stored = await services.availableCourses()
        XCTAssertEqual(stored.map(\.id), [course.id])
        let catalogued = await services.availableScenarios().filter { $0.origin == .course }
        XCTAssertEqual(catalogued.count, 2, "课内每一节都要进目录，否则面板里点不进去")
        let firstLesson = try XCTUnwrap(course.lessons.first)
        let byID = await services.scenario(id: firstLesson.id)
        XCTAssertEqual(byID?.titleZh, "开口点单", "进行中的会话靠 id 恢复")
        let files = try FileManager.default.contentsOfDirectory(atPath: courses.path)
        XCTAssertEqual(files, ["\(course.id).json"], "一条课一个文件")

        // ④ 目标词进词汇本（`source: .scenario`）—— 它们顺带成了每日推荐「生词档」的候选。
        let entries = await services.vocabulary.entries()
        let words = Dictionary(uniqueKeysWithValues: entries.map { ($0.word, $0) })
        XCTAssertEqual(words["oat milk"]?.source, .scenario)
        XCTAssertEqual(words["receipt"]?.meaning, "收据")
        XCTAssertEqual(words.count, 2)
    }

    /// 同一份状态再排一次 = **覆盖**（想换一套排法就改主题，那天然是另一条课）。
    func testSameStateTwiceOverwritesInsteadOfStacking() async throws {
        let (services, courses) = try await makeServices(reply: sampleOutput)
        let stub = try XCTUnwrap(server)

        let first = try await services.generateCourse(request())
        let second = try await services.generateCourse(request())

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.lessons.map(\.id), second.lessons.map(\.id),
                       "节 id 由「课 id + 序号 + 标题」推出 → 同一节课还是同一格，树上的进度接得上")
        let posts = try stub.records().filter { $0.method == "POST" }
        XCTAssertEqual(posts.count, 2, "两次排课就是两个请求（不缓存、不假装成功）")
        let files = try FileManager.default.contentsOfDirectory(atPath: courses.path)
        XCTAssertEqual(files.count, 1)
    }

    /// 换个主题 = 另一条课（用户想换排法时唯一的动作）。
    func testDifferentTopicIsADifferentCourse() async throws {
        let (services, _) = try await makeServices(reply: sampleOutput)

        let first = try await services.generateCourse(request(topics: ["latte 店里点单"]))
        let second = try await services.generateCourse(request(topics: ["job interview"]))

        XCTAssertNotEqual(first.id, second.id)
        let stored = await services.availableCourses()
        XCTAssertEqual(stored.count, 2, "两条课并存，不是互相覆盖")
    }

    // MARK: - ② 失败路径：该拦的拦、该留白的留白

    /// 一条信号都没有：连模型装配都不该发生 —— 一个请求都不发。
    func testNoSignalNeverReachesTheModel() async throws {
        let (services, courses) = try await makeServices(reply: sampleOutput)
        let stub = try XCTUnwrap(server)

        do {
            _ = try await services.generateCourse(CourseRequest())
            XCTFail("没有排课依据时必须报错")
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            XCTAssertTrue(reason.contains("依据"), "报错要说清原因：\(reason)")
        }
        let records = try stub.records()
        XCTAssertTrue(records.isEmpty, "输入不合法时一个请求都不该发，实际 \(records.count) 个")
        let stored = await services.availableCourses()
        XCTAssertTrue(stored.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: courses.path)
        XCTAssertTrue(files.isEmpty)
    }

    /// 模型答得不成形（自由发挥 / 只排了一节 / 键名写错）：**报错且不落盘**。
    ///
    /// 半成品会以「AI 排的课」的名义长期留在面板上、还占着树上的一格，比一次失败难收拾得多。
    func testMalformedModelOutputFailsWithoutWritingAnything() async throws {
        let oneLesson = """
        course: Ordering | 点单
        focus: 点单
        lesson: 1. 开口点单
        scene: barista | customer | 点单 | 3 | Hi there!
        sentence: Could I get a latte?
        sentence: Does it cost extra?
        """
        let replies = [
            "Sure! Here's a course for you.",
            oneLesson,
            // 键名写错 = 关键行缺失（模型偶尔会自作主张改键名）。
            sampleOutput.replacingOccurrences(of: "lesson:", with: "step:"),
        ]
        for reply in replies {
            let (services, courses) = try await makeServices(reply: reply)
            let stub = try XCTUnwrap(server)
            defer {
                stub.cleanUp()
                server = nil
            }
            do {
                _ = try await services.generateCourse(request())
                XCTFail("不成形的输出必须报错：\(reply.prefix(24))")
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                XCTAssertFalse(reason.isEmpty, "要给出可读的失败说明")
            }
            let posts = try stub.records().filter { $0.method == "POST" }
            XCTAssertEqual(posts.count, 1, "毕竟真的问了模型一次")
            let stored = await services.availableCourses()
            XCTAssertTrue(stored.isEmpty, "失败不许落盘")
            let files = try FileManager.default.contentsOfDirectory(atPath: courses.path)
            XCTAssertTrue(files.isEmpty, "目录里不该出现任何文件：\(files)")
        }
    }

    // MARK: - ③ 缓存一致性：课与课内情景必须一起换

    /// 排完课**不必**再手动刷新，课内情景就已经在目录里（两份缓存同一次换）。
    func testCourseLessonsAreInTheCatalogRightAfterGenerating() async throws {
        let (services, _) = try await makeServices(reply: sampleOutput)

        let beforeCatalog = await services.availableScenarios().filter { $0.origin == .course }
        XCTAssertTrue(beforeCatalog.isEmpty, "还没排课时目录里不该有课内情景")
        let course = try await services.generateCourse(request())
        let catalogued = await services.availableScenarios().filter { $0.origin == .course }
        XCTAssertEqual(catalogued.map(\.id), course.lessons.map(\.id),
                       "排完课就要能点进去 —— 少刷一次就是「看得见、点不动」")
    }

    /// 删课 = 课与它那几节一起消失（两份缓存必须一起换）。
    func testDeletingTheCourseRemovesItsLessonsFromTheCatalog() async throws {
        let (services, _) = try await makeServices(reply: sampleOutput)
        let course = try await services.generateCourse(request())

        await services.deleteCourse(id: course.id)

        let stored = await services.availableCourses()
        XCTAssertTrue(stored.isEmpty)
        let catalogued = await services.availableScenarios().filter { $0.origin == .course }
        XCTAssertTrue(catalogued.isEmpty, "删了课却还留着它的情景 = 面板里出现打不开的孤儿卡片")
        let byID = await services.course(id: course.id)
        XCTAssertNil(byID)
    }
}
