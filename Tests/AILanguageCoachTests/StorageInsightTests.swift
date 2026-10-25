import AIDomain
@testable import AIInfrastructure
import AIInterfaces
import AppCore
import Foundation
import XCTest

/// 存储面板看得见子目录（#673-A） + 素材按内容去重（#673-B）。
///
/// 两个真因：
/// - 面板只数平铺文件 → 数据目录报「1 MB」，而 `attachments/` + `corrupted/` 实际占十几 MB，
///   用户问「磁盘被谁吃了」拿到的是错答案；
/// - 附件存储名用随机 UUID → 同一张图发两次就落两份（实测 1.9 MB × 2）。
final class StorageInsightTests: XCTestCase {

    // MARK: - 夹具

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-storage-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func write(_ bytes: Int, into directory: URL, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    private func item(named name: String, in snapshot: CacheSnapshot) -> CacheItemInfo? {
        snapshot.items.first { $0.name == name }
    }

    // MARK: - A. 子目录必须被统计

    /// ⚠️ 回归测试：`snapshot()` 曾经不递归进子目录，
    /// 于是「聊天附件」这最大的一块占用完全不出现在面板上 —— 合计数字是假的。
    func testSubdirectoryIsRolledUpIntoOneRow() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(10, into: root.appendingPathComponent("attachments", isDirectory: true), name: "a.png")
        try write(20, into: root.appendingPathComponent("attachments", isDirectory: true), name: "b.png")

        let snapshot = CacheManager.snapshot(directory: root)
        let row = try XCTUnwrap(item(named: "聊天附件", in: snapshot))
        XCTAssertTrue(row.isDirectory, "子目录要汇总成一行，而不是铺开成上百个文件名")
        XCTAssertEqual(row.bytes, 30)
        XCTAssertEqual(row.fileCount, 2)
        XCTAssertEqual(row.kind, .attachments, "它是用户素材，属于不该被清理的那类资产")
    }

    func testNestedSubdirectoriesRollIntoTheTopLevelRow() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(7, into: root.appendingPathComponent("attachments/nested", isDirectory: true), name: "deep.png")

        let snapshot = CacheManager.snapshot(directory: root)
        let row = try XCTUnwrap(item(named: "聊天附件", in: snapshot))
        XCTAssertEqual(row.bytes, 7, "隔一层也要算进来")
        XCTAssertEqual(row.fileCount, 1)
    }

    /// ⚠️ 反证：平铺统计（只数顶层文件）得到的总数**必须**小于递归统计 ——
    /// 两者一样就说明递归没接上，而这条断言会一直绿。
    func testFlatOnlyTotalWouldUnderReport() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(5, into: root, name: "learning.db")
        try write(30, into: root.appendingPathComponent("attachments", isDirectory: true), name: "a.png")

        let recursive = CacheManager.snapshot(directory: root)
        XCTAssertEqual(recursive.totalBytes, 35)

        // 旧实现（只数顶层普通文件）会得到什么：
        let flat = (try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        XCTAssertEqual(flat, 5, "平铺统计确实会漏掉子目录 —— 这正是这条改动要修的事")
        XCTAssertLessThan(flat, recursive.totalBytes, "两种实现的结果必须相反，否则这条断言没在验东西")
    }

    func testCorruptedDirectoryIsFlaggedAsQuarantine() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(99, into: root.appendingPathComponent("corrupted", isDirectory: true),
                  name: "learning.db.corrupted-20261024-005010")

        let row = try XCTUnwrap(item(named: "坏库隔离", in: CacheManager.snapshot(directory: root)))
        XCTAssertEqual(row.kind, .quarantine)
        XCTAssertEqual(row.bytes, 99)
    }

    func testHiddenEntriesAreNotCounted() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(1234, into: root, name: ".cache-cleared")
        try write(1234, into: root.appendingPathComponent(".restore-pending", isDirectory: true), name: "learning.db")

        let snapshot = CacheManager.snapshot(directory: root)
        XCTAssertTrue(snapshot.items.isEmpty, "内部标记与暂存目录不是用户该关心的占用")
        XCTAssertEqual(snapshot.totalBytes, 0)
    }

    /// 老口径（`isLearningData` / `isCallLog`）必须还在 —— 面板靠它们打锁和对账标签。
    func testProtectedAndCallLogKindsStillRecognized() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(11, into: root, name: "learning.db")
        try write(22, into: root, name: "config.json")
        try write(33, into: root, name: "remote-calls.jsonl")

        let snapshot = CacheManager.snapshot(directory: root)
        let db = try XCTUnwrap(item(named: "学习数据库", in: snapshot))
        XCTAssertTrue(db.isLearningData)
        XCTAssertTrue(db.kind.badge?.isEmpty == false)
        let log = try XCTUnwrap(snapshot.items.first { $0.isCallLog })
        XCTAssertEqual(log.name, "对外调用留痕")
        XCTAssertEqual(log.kind, .callLog)
    }

    // MARK: - B. 素材按内容去重

    /// ⚠️ 反证：随机 UUID 命名会让同一份内容落两份；内容寻址只落一份。
    /// 两种命名策略**结果相反**（2 个文件 vs 1 个文件），所以这条断言真在验东西。
    func testIdenticalContentIsStoredOnce() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentStore(directory: root)

        let first = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-src-a-\(UUID().uuidString).png")
        let second = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-src-b-\(UUID().uuidString).png")
        let payload = Data(repeating: 0x7f, count: 2048)
        try payload.write(to: first)
        try payload.write(to: second)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let one = try await store.importFile(at: first)
        let two = try await store.importFile(at: second)
        XCTAssertEqual(one.storedPath, two.storedPath, "同一份内容必须落到同一个文件上")

        // 旧实现（UUID 命名）的对照：两份内容一样，文件却是两个。
        let naive = makeRoot()
        defer { try? FileManager.default.removeItem(at: naive) }
        try payload.write(to: naive.appendingPathComponent("\(UUID().uuidString).png"))
        try payload.write(to: naive.appendingPathComponent("\(UUID().uuidString).png"))

        let deduped = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.count ?? 0
        let duplicated = (try? FileManager.default.contentsOfDirectory(atPath: naive.path))?.count ?? 0
        XCTAssertEqual(deduped, 1)
        XCTAssertEqual(duplicated, 2, "两种命名策略的结果必须相反，否则这条断言没在验东西")
    }

    func testDifferentContentGetsDifferentNames() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentStore(directory: root)

        let a = FileManager.default.temporaryDirectory.appendingPathComponent("alc-src-\(UUID().uuidString).png")
        let b = FileManager.default.temporaryDirectory.appendingPathComponent("alc-src-\(UUID().uuidString).png")
        try Data(repeating: 1, count: 512).write(to: a)
        try Data(repeating: 2, count: 512).write(to: b)
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }

        let one = try await store.importFile(at: a)
        let two = try await store.importFile(at: b)
        XCTAssertNotEqual(one.storedPath, two.storedPath, "内容不同绝不能共用同一个文件")
    }

    /// 去重让两条记录共用一份文件：删掉其中一条，**另一条还得能打开**。
    func testRemovingOneOfTwoSharedAttachmentsKeepsTheFile() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentStore(directory: root)

        let source = FileManager.default.temporaryDirectory.appendingPathComponent("alc-src-\(UUID().uuidString).png")
        try Data(repeating: 9, count: 1024).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let one = try await store.importFile(at: source)
        let two = try await store.importFile(at: source)
        await store.remove(one)

        let stillThere = await store.fileURL(for: two)
        XCTAssertNotNil(stillThere, "还有一条记录在用这个文件，就不能清")
        let data = await store.data(for: two)
        XCTAssertEqual(data?.count, 1024, "留下来的那条必须还能读出完整内容")
    }

    /// 本次启动亲手复制进来、且没人共用的那份，删了就真删（否则待发区会越攒越多垃圾）。
    func testSelfCopiedAttachmentIsTrashedWhenNothingElseHoldsIt() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentStore(directory: root)

        let source = FileManager.default.temporaryDirectory.appendingPathComponent("alc-src-\(UUID().uuidString).png")
        try Data(repeating: 8, count: 512).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let one = try await store.importFile(at: source)
        await store.remove(one)
        let gone = await store.fileURL(for: one)
        XCTAssertNil(gone, "没人再用它时应当清掉")
    }

    /// 来历不明的那份（上一次启动留下的）保守不清：它可能正被历史消息引用着。
    func testAttachmentFromAnEarlierProcessIsNotTrashed() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("alc-src-\(UUID().uuidString).png")
        try Data(repeating: 7, count: 512).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let first = AttachmentStore(directory: root)
        let attachment = try await first.importFile(at: source)

        // 换一个仓库实例 = 换一次启动：它不知道这份文件是谁复制的。
        let restarted = AttachmentStore(directory: root)
        await restarted.remove(attachment)
        let kept = await restarted.fileURL(for: attachment)
        XCTAssertNotNil(kept, "跨进程无从核实引用关系，宁可留着也不清")
    }
}
