import AIDomain
import AIInfrastructure
import AIServices
import Foundation
import XCTest

/// AI 自动课程的落盘仓库（③）：一条课一个 JSON、坏文件不删、同 id 覆盖、删除进废纸篓。
///
/// 与 `CustomScenarioStore` 同一条纪律，所以只钉**它自己的**那份契约。
final class CourseStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("course-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - 夹具

    private func course(_ id: String, lessons: Int = 2, createdAt: Date = Date()) -> CourseBlueprint {
        CourseBlueprint(
            id: id,
            title: "Ordering like a local",
            titleZh: "像本地人一样点单",
            focus: "盯住礼貌用语",
            targetLevel: .b1,
            rationale: "现在 B1",
            createdAt: createdAt,
            lessons: (1...lessons).map { index in
                CourseLesson(
                    id: "\(id)-l\(index)",
                    order: index,
                    title: "Lesson \(index)",
                    titleZh: "第\(index)节",
                    goal: "practice",
                    scenario: Scenario(
                        id: "\(id)-l\(index)",
                        title: "Lesson \(index)",
                        titleZh: "第\(index)节",
                        category: CourseBlueprintRule.category,
                        difficulty: 3,
                        level: "B1",
                        objective: "practice",
                        aiRole: "barista",
                        learnerRole: "customer",
                        opening: "Hi there!",
                        targetSentences: ["Could I get a latte?", "Does it cost extra?"],
                        origin: .course
                    )
                )
            }
        )
    }

    // MARK: - 用例

    func testRoundTripKeepsEveryLesson() async throws {
        let store = CourseStore(directory: directory)
        try await store.save(course("course-aaa", lessons: 3))

        let loaded = await store.all()
        XCTAssertEqual(loaded.map(\.id), ["course-aaa"])
        XCTAssertEqual(loaded.first?.lessonCount, 3, "一节课也不能少：它是这一条课的一格")
        XCTAssertEqual(loaded.first?.lessons.map(\.order), [1, 2, 3])
        XCTAssertEqual(loaded.first?.lessons.first?.scenario.origin, .course, "来源是数据，落盘往返后仍然读得出来")
    }

    func testSameIDOverwritesInsteadOfStacking() async throws {
        let store = CourseStore(directory: directory)
        try await store.save(course("course-aaa", lessons: 2))
        try await store.save(course("course-aaa", lessons: 4))

        let loaded = await store.all()
        XCTAssertEqual(loaded.count, 1, "同一份状态重排是覆盖，不是在面板上堆一串一模一样的课")
        XCTAssertEqual(loaded.first?.lessonCount, 4)
    }

    func testNewestCourseComesFirst() async throws {
        let store = CourseStore(directory: directory)
        let older = Date(timeIntervalSince1970: 1_000)
        try await store.save(course("course-old", createdAt: older))
        try await store.save(course("course-new", createdAt: older.addingTimeInterval(60)))

        let loaded = await store.all()
        XCTAssertEqual(loaded.map(\.id), ["course-new", "course-old"])
    }

    /// 坏文件**只跳过、不删**：一条课是拿学员的错题和水平换来的，删了没法再生。
    func testCorruptFileIsSkippedAndKeptOnDisk() async throws {
        let store = CourseStore(directory: directory)
        try await store.save(course("course-good"))
        let broken = directory.appendingPathComponent("course-broken.json")
        try "{ this is not json".write(to: broken, atomically: true, encoding: .utf8)

        let loaded = await store.all()
        XCTAssertEqual(loaded.map(\.id), ["course-good"], "坏的那份跳过，好的那份照常读出来")
        let corrupt = await store.corruptIDs
        XCTAssertEqual(corrupt, ["course-broken.json"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: broken.path), "坏文件必须留在盘上，不能悄悄清空目录")
    }

    func testDeleteRemovesItFromDiskAndFromTheList() async throws {
        let store = CourseStore(directory: directory)
        try await store.save(course("course-aaa"))
        let url = directory.appendingPathComponent("course-aaa.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        await store.delete(id: "course-aaa")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "删除要从目录里消失")
        let loaded = await store.all()
        XCTAssertTrue(loaded.isEmpty)
    }

    /// 传进来的 id 可能带着路径（手滑 / 恶意）：只取最后一段，不许写到目录外。
    func testDeleteStripsAnyPathFromTheID() async throws {
        let store = CourseStore(directory: directory)
        let outside = directory.deletingLastPathComponent()
            .appendingPathComponent("course-escape-\(UUID().uuidString).json")
        try "{}".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        await store.delete(id: "../\(outside.lastPathComponent)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path),
                      "路径穿越必须被挡住：目录外的文件不许被删")
        let inside = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(inside.isEmpty, "实际删的应该是目录里那个拼出来的名字：\(inside)")
    }

    /// 空目录不是错：没排过课就是空的（面板据此显示空态，而不是报错）。
    func testEmptyDirectoryYieldsEmptyListAndNoCorruption() async {
        let store = CourseStore(directory: directory.appendingPathComponent("not-created-yet", isDirectory: true))
        let loaded = await store.all()
        XCTAssertTrue(loaded.isEmpty)
        let corrupt = await store.corruptIDs
        XCTAssertTrue(corrupt.isEmpty, "目录不存在不算坏文件")
    }
}
