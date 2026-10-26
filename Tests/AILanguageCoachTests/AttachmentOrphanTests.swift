import AIDomain
@testable import AIInfrastructure
import AIInterfaces
import AppCore
import Foundation
import XCTest

/// 孤儿附件回收（#676）。
///
/// 真因：清缓存删的是**会话流水**，而被引用的图片早在发送时就复制进了 `attachments/`
/// —— 引用没了，文件还躺着。`AttachmentStore.orphanFiles` 早写好了却没有任何调用方，
/// 于是半年攒出 6 个孤儿文件 9.5 MB，其中两张是同一张图（后来发现 Greatest Hits：
/// 内容寻址只对新导入生效，老的那批没人管）。
///
/// 这一组判据盯三件事：
/// - 引用不明 → 一个都不许删（这是最容易翻车的方向：`Set<String>()` 的空字典语义）；
/// - 在途 / 新鲜的留下（崩一次不该清掉还没落库的素材）；
/// - 真孤儿确实会被带走（不然这条机制等于没接）。
final class AttachmentOrphanTests: XCTestCase {

    // 有初值（而不是 IUO）：避免「隐式解包可选值被当成 Any」那类警告。
    private var now: Date = Date()
    private var old: Date = Date()

    override func setUp() {
        super.setUp()
        // 基准只取一次（#669 的教训：判据里两次取当前时刻 = 在测机器有多快）。
        now = Date()
        old = now.addingTimeInterval(-3 * 24 * 60 * 60)
    }

    // MARK: - 夹具

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-orphan-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func write(_ bytes: Int, into directory: URL, name: String, modifiedAt: Date) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        return url
    }

    private func candidate(_ name: String, _ modifiedAt: Date, _ bytes: Int) -> AttachmentOrphanCandidate {
        AttachmentOrphanCandidate(name: name, modifiedAt: modifiedAt, bytes: Int64(bytes))
    }

    // MARK: - A. 引用不明 = 零删除（fail-closed）

    /// ⚠️ 这是整份保护的核心：把「读库失败」翻译成空集合是最顺手的写法，
    /// 而它的后果是**所有在用素材被判成孤儿**（空集合的字面意思就是「没人引用」）。
    func testUnknownReferencesBlockEverything() {
        let plan = AttachmentOrphanPolicy.plan(
            candidates: [
                candidate("a.png", old, 100),
                candidate("b.png", old, 200),
            ],
            references: .unavailable(reason: "读学习库失败：database is locked"),
            now: now
        )
        XCTAssertTrue(plan.removable.isEmpty, "引用不明时不许动任何一个文件")
        XCTAssertNotNil(plan.blockReason, "必须给出为什么没清 —— 静默不干活同样查不出问题")
        XCTAssertEqual(plan.freedBytes, 0)
        XCTAssertNil(AttachmentReferenceIndex.unavailable(reason: "x").count, "不知道 ≠ 0")
    }

    /// ⚠️ 反证：假设有人把接口「简化」成 `.verified([])`（空集合），
    /// 两种实现的结果必须相反 —— 否则上一条断言就是假的。
    func testEmptyVerifiedSetWouldWipeEverything() {
        let files = [candidate("a.png", old, 100), candidate("b.png", old, 200)]
        let guarded = AttachmentOrphanPolicy.plan(
            candidates: files, references: .unavailable(reason: "x"), now: now
        )
        let naive = AttachmentOrphanPolicy.plan(
            candidates: files, references: .verified([]), now: now
        )
        XCTAssertTrue(guarded.removable.isEmpty)
        XCTAssertEqual(naive.removable.count, 2, "空集合语义 = 全部可清：这正是要拦下来的写法")
    }

    // MARK: - B. 谁必须留下

    func testReferencedFilesAreKeptEvenWhenAncient() {
        let plan = AttachmentOrphanPolicy.plan(
            candidates: [candidate("stored.png", old, 4096)],
            references: .verified(["stored.png"]),
            now: now
        )
        XCTAssertTrue(plan.removable.isEmpty)
        XCTAssertEqual(plan.keptReferenced, 1)
    }

    /// 引用表混着带前缀的写法（`attachments/x.png`）也能对上 —— 不归一就全判成孤儿。
    func testReferencePrefixIsNormalized() {
        let plan = AttachmentOrphanPolicy.plan(
            candidates: [candidate("stored.png", old, 4096)],
            references: .verified(["attachments/stored.png"]),
            now: now
        )
        XCTAssertTrue(plan.removable.isEmpty, "带 `attachments/` 前缀的形态必须认得出来")
        XCTAssertEqual(plan.keptReferenced, 1)
    }

    /// 刚进来还没落库的那一张：崩一次再起来不该把它扫掉。
    func testFreshFilesAreProtectedByGraceWindow() {
        let fresh = now.addingTimeInterval(-AttachmentOrphanPolicy.graceInterval / 2)
        let plan = AttachmentOrphanPolicy.plan(
            candidates: [candidate("brand-new.png", fresh, 1024)],
            references: .verified([]),
            now: now
        )
        XCTAssertTrue(plan.removable.isEmpty)
        XCTAssertEqual(plan.keptRecent, 1)
    }

    func testInFlightImportsAreProtectedEvenWhenOld() {
        let plan = AttachmentOrphanPolicy.plan(
            candidates: [candidate("importing.png", old, 1024)],
            references: .verified([]),
            inFlight: ["importing.png"],
            now: now
        )
        XCTAssertTrue(plan.removable.isEmpty, "本进程刚复制进来的，消息可能还没落库")
        XCTAssertEqual(plan.keptInFlight, 1)
    }

    // MARK: - C. 真孤儿会被带走

    func testAncientOrphanIsRemovedAndCountedAsFreed() {
        let plan = AttachmentOrphanPolicy.plan(
            candidates: [
                candidate("referenced.png", old, 10),
                candidate("fresh.png", now.addingTimeInterval(-60), 20),
                candidate("orphan.png", old, 30),
            ],
            references: .verified(["referenced.png"]),
            now: now
        )
        XCTAssertEqual(plan.removable, ["orphan.png"])
        XCTAssertEqual(plan.freedBytes, 30, "只算真的被删掉的那几个")
        XCTAssertEqual(plan.keptReferenced, 1)
        XCTAssertEqual(plan.keptRecent, 1)
    }

    /// 内容重复的两个孤儿（本机实况：同一张 1.87 MB 的图存了两遍）—— 两个都被判孤儿，
    /// 于是两个都会被清：清完之后确实一条引用都没有，留哪一个都没有意义。
    func testDuplicateOrphansAreBothRemoved() {
        let plan = AttachmentOrphanPolicy.plan(
            candidates: [
                candidate("E879FCB7.jpeg", old, 1_879_079),
                candidate("EB5D44EF.jpeg", old, 1_879_079),
            ],
            references: .verified([]),
            now: now
        )
        XCTAssertEqual(plan.removable.count, 2)
        XCTAssertEqual(plan.freedBytes, 3_758_158)
    }

    // MARK: - D. 仓库 IO

    /// ⚠️ 端到端：目录里三类文件，扫完之后只有「老孤儿」真的从磁盘上消失。
    func testPruneOrphansRemovesOnlyUnreferencedAncientFiles() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(100, into: root, name: "referenced.png", modifiedAt: old)
        try write(200, into: root, name: "fresh.png", modifiedAt: now.addingTimeInterval(-60))
        try write(300, into: root, name: "orphan.png", modifiedAt: old)

        let store = AttachmentStore(directory: root)
        let summary = await store.pruneOrphans(references: .verified(["referenced.png"]), now: now)

        XCTAssertEqual(summary.removed, 1)
        XCTAssertEqual(summary.freedBytes, 300)
        XCTAssertEqual(summary.keptReferenced, 1)
        XCTAssertEqual(summary.keptRecent, 1)
        let remaining = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        )
        XCTAssertFalse(remaining.contains("orphan.png"), "没人要的老文件应该被带走")
        XCTAssertTrue(remaining.contains("referenced.png"), "还在用的必须原封不动")
        XCTAssertTrue(remaining.contains("fresh.png"), "新鲜的那一批要留到下一轮")
    }

    func testPruneOrphansSkipsWhenReferencesUnknown() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(100, into: root, name: "orphan.png", modifiedAt: old)

        let store = AttachmentStore(directory: root)
        let summary = await store.pruneOrphans(references: .unavailable(reason: "读库失败"), now: now)

        XCTAssertEqual(summary.removed, 0)
        XCTAssertNotNil(summary.skippedReason)
        XCTAssertTrue(
            (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.contains("orphan.png") == true,
            "引用不明时一个文件都不许动"
        )
    }

    /// 本进程刚复制进来、还没来得及被任何消息引用的那张图不能被自己这轮清扫扫掉。
    func testPruneOrphansSparesWhatThisProcessJustImported() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-src-\(UUID().uuidString).png")
        try Data(repeating: 6, count: 256).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let store = AttachmentStore(directory: root)
        let attachment = try await store.importFile(at: source)
        // 刻意在清扫前把它「伪装」成很老的文件：新鲜窗口救不了它，能在途名册才行。
        let stored = root.appendingPathComponent(AttachmentStore.fileName(of: attachment.storedPath))
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: stored.path)

        let summary = await store.pruneOrphans(references: .verified([]), now: now)
        XCTAssertEqual(summary.removed, 0, "刚复制进来、还没引用的素材不能自己把自己清了")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.path))
    }

    /// ⚠️ 闸门：测试宿主拿不到用户废纸篓，`TrashItem` 会回落到**永久删除**。
    /// 因此「真实数据目录」这条路径在测试进程里必须直接收手 ——
    /// 宁可白跑一轮，也不可赌将来没有哪个用例不小心走过 `clearCaches()`。
    func testPruneOrphansRefusesRealDirectoryUnderTestProcess() async throws {
        XCTAssertTrue(ProcessIdentity.isRunningTests, "这条断言只在测试宿主里成立，它验的就是那个分支")
        let store = AttachmentStore()
        let directory = await store.storageDirectory
        XCTAssertTrue(
            directory.standardizedFileURL == AttachmentStore.defaultDirectory.standardizedFileURL,
            "没注入目录 = 指向用户的真实数据目录"
        )
        let summary = await store.pruneOrphans(references: .verified([]))
        XCTAssertEqual(summary.removed, 0)
        XCTAssertNotNil(summary.skippedReason, "拒绝就得说出为什么，别静默什么都不干")
    }

    /// 注入了临时目录就可以真删：否则这条机制的端到端根本没法测。
    func testPruneOrphansStillWorksOnInjectedDirectoryUnderTestProcess() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(128, into: root, name: "orphan.png", modifiedAt: old)
        let store = AttachmentStore(directory: root)
        let summary = await store.pruneOrphans(references: .verified([]), now: now)
        XCTAssertEqual(summary.removed, 1, "注入的沙盘不受闸门影响，机制还得能转")
    }

    /// 隐藏文件不是用户素材，不该出现在清理范围里。
    func testHiddenFilesAreIgnored() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(50, into: root, name: ".DS_Store", modifiedAt: old)

        let store = AttachmentStore(directory: root)
        let summary = await store.pruneOrphans(references: .verified([]), now: now)
        XCTAssertEqual(summary.removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".DS_Store").path))
    }

    // MARK: - E. 引用表的真相源

    /// 落过库的消息里带了附件 → 它必须在引用表里。
    func testReferencedAttachmentPathsReadsStoredMessages() async throws {
        let db = try LearningDatabase.inMemory()
        let sessionID = UUID()
        try await db.createSessionIfAbsent(ChatSession(id: sessionID))
        try await db.appendMessage(
            ChatMessage(
                role: .user,
                content: "看看这张",
                attachments: [
                    ChatAttachment(kind: .image, fileName: "a.png", mimeType: "image/png",
                                   byteCount: 10, storedPath: "attachments/a.png")
                ]
            ),
            sessionID: sessionID
        )

        let referenced = try await db.referencedAttachmentPaths()
        XCTAssertEqual(referenced, ["a.png"], "存储名要归一成裸文件名再交给策略层")
    }

    /// 消息被删干净后，同一个文件名从引用表里消失 → 它就该被判成孤儿。
    /// 这正是「清缓存留下附件」那条因果链的两端。
    func testReferencedAttachmentPathsEmptyAfterMessagesGone() async throws {
        let db = try LearningDatabase.inMemory()
        let sessionID = UUID()
        try await db.createSessionIfAbsent(ChatSession(id: sessionID))
        let message = ChatMessage(
            role: .user,
            content: "看看这张",
            attachments: [
                ChatAttachment(kind: .image, fileName: "a.png", mimeType: "image/png",
                               byteCount: 10, storedPath: "attachments/a.png")
            ]
        )
        try await db.appendMessage(message, sessionID: sessionID)
        let before = try await db.referencedAttachmentPaths()
        XCTAssertEqual(before.count, 1)

        _ = try await db.deleteMessages(ids: [message.id], sessionID: sessionID)
        let stillReferenced = try await db.referencedAttachmentPaths()
        XCTAssertTrue(stillReferenced.isEmpty, "引用没了，文件就该在下一轮被清掉")
    }

    /// 一条消息带多个附件：一个都不能漏（漏一个 = 那个文件被误清）。
    func testEveryAttachmentOfAMessageIsCollected() async throws {
        let db = try LearningDatabase.inMemory()
        let sessionID = UUID()
        try await db.createSessionIfAbsent(ChatSession(id: sessionID))
        try await db.appendMessage(
            ChatMessage(
                role: .user,
                content: "两张一起看",
                attachments: [
                    ChatAttachment(kind: .image, fileName: "one.png", mimeType: "image/png",
                                   byteCount: 1, storedPath: "attachments/one.png"),
                    ChatAttachment(kind: .file, fileName: "notes.txt", mimeType: "text/plain",
                                   byteCount: 1, storedPath: "attachments/notes.txt"),
                ]
            ),
            sessionID: sessionID
        )
        let referenced = try await db.referencedAttachmentPaths()
        XCTAssertEqual(referenced, ["one.png", "notes.txt"])
    }

    // MARK: - F. 接线哨兵

    /// 三个落点必须都在：开屏后台、清缓存之后、引用采集失败时要翻译成 `.unavailable`。
    /// 少一处这条机制就等于没接 —— 而它没有任何东西稳态 nagging，只能靠哨兵。
    func testWiringIsInPlace() throws {
        let app = stripComments(
            try String(contentsOfFile: project("Sources/AppUI/AppState.swift"), encoding: .utf8)
        )
        XCTAssertTrue(
            app.contains("Task { [weak self] in _ = await self?.services.pruneAttachmentOrphans() }"),
            "孤儿清扫必须挂在开屏后台 Task 上（要遍历目录 + 可能动废纸篓，不能挡首屏）"
        )

        let maintenance = try String(contentsOfFile: project("Sources/AIServices/CoachServices+Maintenance.swift"), encoding: .utf8)
        XCTAssertTrue(
            maintenance.contains("await pruneAttachmentOrphans()"),
            "「清缓存」删掉会话后必须顺手带走刚变成孤儿的那些文件"
        )
        XCTAssertTrue(
            maintenance.contains("do {\n            references = .verified(try await learning.referencedAttachmentPaths())\n        } catch {\n            references = .unavailable(reason:"),
            "读库失败必须翻译成 `.unavailable`，绝不能留成「等价于空集合」的路径"
        )

        let db = try String(contentsOfFile: project("Sources/AIInfrastructure/LearningDatabase.swift"), encoding: .utf8)
        XCTAssertTrue(
            db.contains("public func referencedAttachmentPaths() throws -> Set<String>"),
            "引用采集必须是会抛错的真相源，而不是返回空集合的 helper"
        )
    }

    /// 剥掉整行注释。
    ///
    /// ⚠️ 不剥的话，「把调用注释掉」这种最自然的反证手法**不会**让哨兵变红
    /// （字符串还在文件里），判据就成了假绿 —— 这条是反证时实测出来的。
    private func stripComments(_ source: String) -> String {
        source.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// 从 `Tests/AILanguageCoachTests/<本文件>` 上溯三层到包根目录。
    private func project(_ relative: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
            .path
    }
}
