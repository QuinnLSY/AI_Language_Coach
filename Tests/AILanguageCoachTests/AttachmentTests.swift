import AIDomain
@testable import AIInfrastructure
import AIInterfaces
import AIProviders
import AppCore
import XCTest

/// 聊天附件（第 3 项需求）：类型判定 / 体积护栏 / 仓库定位 / 落库往返 / 多模态组装。
///
/// 这一组里**最要紧**的是定位规则：附件路径曾经有两处各自拼接
/// （仓库一处、ChatService 一处），表现是「图片预览显示得出来、发给模型却是空的」——
/// 两边都不报错。测试钉死「必须解析到同一个绝对路径」。
final class AttachmentTests: XCTestCase {

    // MARK: - 类型判定（纯函数）

    func testClassifierMapsExtensionsToKinds() {
        XCTAssertEqual(AttachmentClassifier.kind(forExtension: "PNG"), .image, "大小写不应影响判定")
        XCTAssertEqual(AttachmentClassifier.kind(forExtension: ".Jpg"), .image, "开头带点也要认")
        XCTAssertEqual(AttachmentClassifier.kind(forExtension: "heic"), .image)
        XCTAssertEqual(AttachmentClassifier.kind(forExtension: "mp4"), .video)
        XCTAssertEqual(AttachmentClassifier.kind(forExtension: "MOV"), .video)
        XCTAssertEqual(AttachmentClassifier.kind(forExtension: "pdf"), .file)
        XCTAssertEqual(AttachmentClassifier.kind(forExtension: ""), .file, "认不出就是普通文件")
        XCTAssertEqual(AttachmentClassifier.kind(forExtension: "xyz"), .file)
    }

    func testClassifierReadsFileNameNotFullPath() {
        // 目录名里带 .png 不代表文件是图片 —— 必须只看扩展名那一段。
        XCTAssertEqual(AttachmentClassifier.kind(forFileName: "my.png.folder/report.pdf"), .file)
        XCTAssertEqual(AttachmentClassifier.kind(forFileName: "截图 2026.PNG"), .image)
    }

    func testMimeTypeKnownAndFallback() {
        XCTAssertEqual(AttachmentClassifier.mimeType(forExtension: "png"), "image/png")
        XCTAssertEqual(AttachmentClassifier.mimeType(forExtension: "jpeg"), "image/jpeg")
        XCTAssertEqual(AttachmentClassifier.mimeType(forExtension: "unknown"), "application/octet-stream")
    }

    // MARK: - 体积 / 数量护栏

    func testPolicyAcceptsBoundaryAndRejectsOverflow() {
        XCTAssertTrue(AttachmentPolicy.accepts(byteCount: 1))
        XCTAssertTrue(AttachmentPolicy.accepts(byteCount: AttachmentPolicy.maxBytes), "正好等于上限应放行")
        XCTAssertFalse(AttachmentPolicy.accepts(byteCount: AttachmentPolicy.maxBytes + 1))
        XCTAssertFalse(AttachmentPolicy.accepts(byteCount: 0), "空文件不该放行")
    }

    func testPolicyRejectionReasonDistinguishesEmptyFromTooLarge() {
        let empty = AttachmentPolicy.rejectionReason(fileName: "a.txt", byteCount: 0)
        XCTAssertNotNil(empty)
        XCTAssertTrue(empty?.contains("空文件") == true, "空文件与超大文件的原因必须能区分开")

        let huge = AttachmentPolicy.rejectionReason(fileName: "movie.mov", byteCount: AttachmentPolicy.maxBytes + 1)
        XCTAssertTrue(huge?.contains("movie.mov") == true, "原因里要带上文件名，用户才知道是哪一个")
        XCTAssertTrue(huge?.contains("20 MB") == true)

        XCTAssertNil(AttachmentPolicy.rejectionReason(fileName: "ok.png", byteCount: 1024))
    }

    func testPolicyRemainingSlotsNeverNegative() {
        XCTAssertEqual(AttachmentPolicy.remainingSlots(current: 0), AttachmentPolicy.maxPerMessage)
        XCTAssertEqual(AttachmentPolicy.remainingSlots(current: AttachmentPolicy.maxPerMessage), 0)
        XCTAssertEqual(AttachmentPolicy.remainingSlots(current: 99), 0, "超出上限不该给出负数槽位")
    }

    func testPerMessageLimitIsTen() {
        // 产品口径：一条消息最多 10 个附件（本轮需求）。钉住这个数字 ——
        // 它是「托盘换行」之外的另一半事实（用户能一次带多少东西）。
        XCTAssertEqual(AttachmentPolicy.maxPerMessage, 10)
        XCTAssertEqual(AttachmentPolicy.remainingSlots(current: 9), 1)
        XCTAssertEqual(AttachmentPolicy.remainingSlots(current: 10), 0)
    }

    func testOnlyImagesAreInlined() {
        XCTAssertTrue(AttachmentPolicy.isInlined(kind: .image))
        // 视频不懂内联是**刻意的**：OpenAI 兼容的 /chat/completions 不收视频字节。
        // 放宽这一条会让用户以为视频真被模型看懂了，所以钉住。
        XCTAssertFalse(AttachmentPolicy.isInlined(kind: .video))
        XCTAssertFalse(AttachmentPolicy.isInlined(kind: .file))
    }

    // MARK: - 模型侧体积文案

    func testSizeTextUsesBinaryUnits() {
        func attachment(_ bytes: Int) -> ChatAttachment {
            ChatAttachment(kind: .file, fileName: "f", mimeType: "application/octet-stream",
                           byteCount: bytes, storedPath: "attachments/x")
        }
        XCTAssertEqual(attachment(0).sizeText, "0 B")
        XCTAssertEqual(attachment(1023).sizeText, "1023 B")
        XCTAssertEqual(attachment(1024).sizeText, "1.0 KB")
        XCTAssertEqual(attachment(3 * 1024 * 1024 / 2).sizeText, "1.5 MB")
        XCTAssertEqual(attachment(-5).sizeText, "0 B", "负数不该渲染成奇怪的文案")
    }

    // MARK: - 仓库：注入目录必须被真正使用

    /// ⚠️ 回归测试：`fileURL` 曾经无视注入目录、直接去查全局用户数据目录，
    /// 于是「测试里放进去的文件」永远找不到，而生产里换个目录就会整批失效。
    func testStoreResolvesInsideItsOwnInjectedDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-attach-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = AttachmentStore(directory: root)
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-src-\(UUID().uuidString).png")
        // 1×1 PNG 足够了：这里验的是搬运与定位，不是图像解码。
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01]).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let attachment = try await store.importFile(at: source)
        XCTAssertEqual(attachment.kind, .image)
        XCTAssertEqual(attachment.fileName, source.lastPathComponent)
        XCTAssertEqual(attachment.mimeType, "image/png")
        XCTAssertTrue(attachment.storedPath.hasPrefix("attachments/"), "落库路径应自解释")

        // `await` 不能写进 `XCTUnwrap` / `XCTAssert*` 的 autoclosure —— 先取到局部量。
        let resolved = await store.fileURL(for: attachment)
        let located = try XCTUnwrap(resolved)
        XCTAssertEqual(located.deletingLastPathComponent().standardizedFileURL,
                       root.standardizedFileURL,
                       "必须解析到**注入的那个目录**，而不是全局用户数据目录")
        XCTAssertTrue(FileManager.default.fileExists(atPath: located.path))
        let loaded = await store.data(for: attachment)
        XCTAssertEqual(loaded?.count, 10)
    }

    func testStoreReturnsNilWhenFileWasCleanedUp() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-attach-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentStore(directory: root)

        let orphan = ChatAttachment(kind: .image, fileName: "gone.png", mimeType: "image/png",
                                    byteCount: 10, storedPath: "attachments/gone.png")
        // 返回 nil（而不是抛错）是刻意的：UI 据此显示「本地文件已不可用」。
        let url = await store.fileURL(for: orphan)
        XCTAssertNil(url)
        let payload = await store.data(for: orphan)
        XCTAssertNil(payload)
    }

    func testStoreRejectsEmptyFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-attach-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentStore(directory: root)

        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-empty-\(UUID().uuidString).txt")
        try Data().write(to: empty)
        defer { try? FileManager.default.removeItem(at: empty) }

        do {
            _ = try await store.importFile(at: empty)
            XCTFail("空文件应当被拒绝")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("空"), "原因要说清是空文件")
        }
    }

    // MARK: - 定位规则（唯一口径）

    func testFileNameRuleIsTolerantOfBothPathShapes() {
        // 带前缀（当前落库形态）与裸文件名（将来的存储布局）都要认。
        XCTAssertEqual(AttachmentStore.fileName(of: "attachments/abc.png"), "abc.png")
        XCTAssertEqual(AttachmentStore.fileName(of: "abc.png"), "abc.png")
        XCTAssertEqual(AttachmentStore.fileName(of: "/tmp/x/attachments/abc.png"), "abc.png")
    }

    /// ⚠️ 回归测试：`orphanFiles` 的入参若不归一，
    /// 调用方传了带前缀的 `storedPath` 就会**把全部在用附件判成孤儿** —— 而清理不可逆。
    func testOrphanFilesAcceptsBothPathShapes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-attach-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentStore(directory: root)

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-src-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let attachment = try await store.importFile(at: source)

        let byPath = await store.orphanFiles(referenced: [attachment.storedPath])
        XCTAssertTrue(byPath.isEmpty, "传带前缀的 storedPath 时不应把在用附件判成孤儿")

        let bare = AttachmentStore.fileName(of: attachment.storedPath)
        let byName = await store.orphanFiles(referenced: [bare])
        XCTAssertTrue(byName.isEmpty, "传裸文件名同样应被认出来")

        let none = await store.orphanFiles(referenced: [])
        XCTAssertEqual(none.count, 1, "没人引用时它就是孤儿")
    }

    // MARK: - 落库往返（schema v8 的 attachments 列）

    func testMessageAttachmentsPersistAndReload() async throws {
        let db = try LearningDatabase.inMemory()
        let session = ChatSession(mode: .conversation)
        try await db.createSession(session)

        let photo = ChatAttachment(kind: .image, fileName: "cat.png", mimeType: "image/png",
                                   byteCount: 2048, storedPath: "attachments/one.png")
        let clip = ChatAttachment(kind: .video, fileName: "trip.mp4", mimeType: "video/mp4",
                                  byteCount: 5_000_000, storedPath: "attachments/two.mp4")
        let message = ChatMessage(role: .user, content: "look", attachments: [photo, clip])
        try await db.appendMessage(message, sessionID: session.id)

        let loaded = try await db.messages(sessionID: session.id)
        let first = try XCTUnwrap(loaded.first)
        XCTAssertEqual(first.attachments.count, 2)
        XCTAssertEqual(first.attachments[0].fileName, "cat.png")
        XCTAssertEqual(first.attachments[0].kind, .image)
        XCTAssertEqual(first.attachments[1].kind, .video)
        XCTAssertEqual(first.content, "look")
    }

    func testMessageWithoutAttachmentsStillRoundTrips() async throws {
        let db = try LearningDatabase.inMemory()
        let session = ChatSession(mode: .conversation)
        try await db.createSession(session)
        try await db.appendMessage(ChatMessage(role: .assistant, content: "hi"), sessionID: session.id)

        let loaded = try await db.messages(sessionID: session.id)
        XCTAssertEqual(loaded.first?.attachments, [], "没有附件应是空数组，不是 nil 崩")
    }

    /// 旧库 / 旧 JSON 里没有 `attachments` 字段 —— 解码必须当「没有附件」，
    /// 而不是让整段历史读不出来。
    func testLegacyMessageJSONDecodesWithoutAttachments() throws {
        let json = """
        {"id":"\(UUID().uuidString)","role":"user","content":"old","createdAt":0}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let message = try decoder.decode(ChatMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.content, "old")
        XCTAssertEqual(message.attachments, [])
    }

    func testCorruptAttachmentJSONDegradesToNoAttachments() {
        // 一条附件的字节坏掉，不该让整段历史消失。
        XCTAssertEqual(LearningDatabase.decodeAttachments(nil), [])
        XCTAssertEqual(LearningDatabase.decodeAttachments(""), [])
        XCTAssertEqual(LearningDatabase.decodeAttachments("{ not json"), [])
        XCTAssertEqual(LearningDatabase.decodeAttachments("[{\"broken\":true}]"), [])
    }

    /// v7 → v8 迁移：旧库的 messages 表根本没有 attachments 列。
    ///
    /// 不补这一列的话，读消息的 SELECT 会直接失败 —— 症状是「打开应用看不到任何历史」，
    /// 而错误信息只会说「no such column」，看不出跟附件有关。
    func testMigrationAddsAttachmentsColumnToLegacyDatabase() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-v7-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }

        // 造一个 v7 的库：messages 有列但**没有** attachments。
        let sessionID = UUID()
        let messageID = UUID()
        let legacy = try SQLiteDatabase(path: url.path)
        try legacy.run("""
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY, started_at REAL NOT NULL, ended_at REAL,
            mode TEXT NOT NULL, message_count INTEGER NOT NULL DEFAULT 0, scenario_id TEXT
        )
        """)
        try legacy.run("""
        CREATE TABLE messages (
            id TEXT PRIMARY KEY, session_id TEXT NOT NULL, role TEXT NOT NULL,
            content TEXT NOT NULL, created_at REAL NOT NULL, reasoning TEXT
        )
        """)
        try legacy.run(
            "INSERT INTO sessions (id, started_at, mode, message_count) VALUES ('\(sessionID.uuidString)', 1, 'conversation', 1)"
        )
        try legacy.run(
            "INSERT INTO messages (id, session_id, role, content, created_at) VALUES ('\(messageID.uuidString)', '\(sessionID.uuidString)', 'user', '老消息', 1)"
        )
        try legacy.setSchemaVersion(7)
        legacy.close()

        let db = try LearningDatabase(path: url.path)
        let version = try await db.schemaVersion()
        XCTAssertEqual(version, LearningDatabase.schemaVersion, "迁移后应停在最新版")

        // 关键：**老消息必须还能读出来**，且附件为空数组（而不是整段历史读不出来）。
        let loaded = try await db.messages(sessionID: sessionID)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.content, "老消息")
        XCTAssertEqual(loaded.first?.attachments, [], "旧行没有附件列，应降级成空数组")
    }

    /// 迁移后新附件要能正常写入并读回。
    func testAttachmentsWorkAfterMigration() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-v7b-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }

        let legacy = try SQLiteDatabase(path: url.path)
        try legacy.run("""
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY, started_at REAL NOT NULL, ended_at REAL,
            mode TEXT NOT NULL, message_count INTEGER NOT NULL DEFAULT 0, scenario_id TEXT
        )
        """)
        try legacy.run("""
        CREATE TABLE messages (
            id TEXT PRIMARY KEY, session_id TEXT NOT NULL, role TEXT NOT NULL,
            content TEXT NOT NULL, created_at REAL NOT NULL, reasoning TEXT
        )
        """)
        try legacy.setSchemaVersion(7)
        legacy.close()

        let db = try LearningDatabase(path: url.path)
        let session = ChatSession(mode: .conversation)
        try await db.createSession(session)
        let photo = ChatAttachment(kind: .image, fileName: "new.png", mimeType: "image/png",
                                   byteCount: 12, storedPath: "attachments/new.png")
        try await db.appendMessage(
            ChatMessage(role: .user, content: "带图", attachments: [photo]), sessionID: session.id
        )

        let loaded = try await db.messages(sessionID: session.id)
        XCTAssertEqual(loaded.first?.attachments.first?.fileName, "new.png")
    }

    // MARK: - 多模态请求组装

    private func message(text: String, images: [LLMInlineImage] = [], referenced: [String] = []) -> LLMMessage {
        LLMMessage(role: .user, content: text, images: images, referencedFileNames: referenced)
    }

    func testTextOnlyMessageStaysAPlainString() {
        let content = RemoteCommon.chatContent(
            for: message(text: "hello"), inlineImages: true
        )
        guard case .text(let value) = content else {
            return XCTFail("没有附件时 content 应当是纯字符串（不少网关接受不了单元素 parts）")
        }
        XCTAssertEqual(value, "hello")
    }

    func testNonInlinedAttachmentsBecomeAReadableNote() throws {
        // 模型不吃图 / 视频 / 普通文件：只用文件名告知，绝不让模型以为看过内容。
        let content = RemoteCommon.chatContent(
            for: message(text: "look at this", referenced: ["trip.mp4"]),
            inlineImages: false
        )
        guard case .text(let value) = content else { return XCTFail("应为纯字符串") }
        XCTAssertTrue(value.contains("look at this"))
        XCTAssertTrue(value.contains("trip.mp4"), "文件名要出现在说明里")
    }

    func testImagesAreInlinedAsDataURLWhenModelHasVision() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let content = RemoteCommon.chatContent(
            for: message(
                text: "what is this",
                images: [LLMInlineImage(mimeType: "image/png", data: png, fileName: "cat.png")]
            ),
            inlineImages: true
        )
        guard case .parts(let parts) = content else { return XCTFail("有内联图片时应为 parts") }
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].type, "text", "文本 part 必须在图片之前")
        XCTAssertEqual(parts[1].type, "image_url")

        // 序列化后的键名必须是 OpenAI 认的 image_url / data: 前缀 ——
        // 这两处写错都只会在线上表现为 400，本地看不出来。
        let encoded = try JSONEncoder().encode(content)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]]
        )
        let imagePart = try XCTUnwrap(json.last)
        XCTAssertNotNil(imagePart["image_url"], "键名必须是 image_url")
        let url = try XCTUnwrap((imagePart["image_url"] as? [String: Any])?["url"] as? String)
        XCTAssertTrue(url.hasPrefix("data:image/png;base64,"), "内联必须是 data URL")
    }

    func testImagesFallBackToNoteWhenModelHasNoVision() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let content = RemoteCommon.chatContent(
            for: message(
                text: "what is this",
                images: [LLMInlineImage(mimeType: "image/png", data: png, fileName: "cat.png")]
            ),
            inlineImages: false
        )
        guard case .text = content else {
            return XCTFail("模型没声明视觉能力时**绝不能**内联 image_url —— 那只会稳定 400")
        }
        let encoded = try JSONEncoder().encode(content)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains("cat.png"), "降级后必须仍告诉模型有这张图")
    }
}
