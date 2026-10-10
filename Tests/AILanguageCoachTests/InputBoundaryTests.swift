import AIDomain
@testable import AIInfrastructure
@testable import AIProviders
import AIServices
@testable import AppUI
import AppCore
import XCTest

/// S5 · 输入边界与潜藏崩溃（12 条）。
///
/// 共同症状是**外部输入把程序推到它没设想过的状态** —— 素材 JSON 绕开钳制、
/// 端点吐永不换行的字节、上千个占位符越限、一个 4 GB 的文件写满数据目录。
/// 多数要等将来（导入 / 云同步 / 恶意端点）才成真崩溃，但代价都是「应用直接倒下」。
///
/// 本文件两类判据（与 S4 同一套纪律）：
/// - **纯函数 / 行为**：能直接驱动的走这条（能真撤反证）；
/// - **源码哨兵**：判据落在 private 函数里、造不出真实链路时才用，
///   且**每种失效方式各配一条断言**（一条包打天下 = 没测）。
///
/// ⚠️ 哨兵别钉整串调用实参、别钉恒等式；判据跟着签名走。
@MainActor
final class InputBoundaryTests: XCTestCase {

    // MARK: - 工具

    private func makeStore() -> ConfigStore {
        ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("s5-config-\(UUID().uuidString).json")
        )
    }

    private func makeState() -> AppState {
        AppState(services: CoachServices(config: makeStore(), databasePath: ":memory:"))
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: "Sources/\(relativePath)", encoding: .utf8)
    }

    /// 取出函数体：从 `needle` 起到下一个成员声明为止。
    private func body(of needle: String, in source: String) -> String {
        guard let range = source.range(of: needle) else { return "" }
        let rest = source[range.lowerBound...]
        let tail = rest.dropFirst(needle.count)
        let terminators = ["\n    public func ", "\n    private func ", "\n    func ",
                           "\n    static func ", "\n    private static func ",
                           "\n    public static func ", "\n    public var ", "\n    private var ",
                           "\n    var ", "\n    let ", "\n    // MARK:"]
        let ends = terminators.compactMap { tail.range(of: $0)?.lowerBound }
        if let end = ends.min() { return String(rest[..<end]) }
        return String(rest)
    }

    /// 造一个指定字节数的临时文件（内容无关紧要，只用来推体积判据）。
    private func makeTempFile(bytes: Int, name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-s5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    // MARK: - S5-1 素材 JSON 绕不开钳制

    /// 合成的 `Decodable` 逐属性直赋，`timeLimitSeconds: 0` 曾能原样进来 →
    /// 每题一开表就超时、全被跳过却照样出成绩单（假成功）。
    ///
    /// 反证：删掉 `ExamStage.init(from:)` 里对 init 的委托（改回逐属性直赋）→ 本条红。
    func testDecodedExamStageStillHonoursClamps() throws {
        let json = """
        {"id": "s1", "title": "t", "instructions": "i", "prompts": ["q"],
         "timeLimitSeconds": 0, "minimumWords": 0}
        """
        let stage = try JSONDecoder().decode(ExamStage.self, from: Data(json.utf8))
        XCTAssertEqual(stage.timeLimitSeconds, 10, "限时下限必须穿过 JSON 解码这道门")
        XCTAssertEqual(stage.minimumWords, 5, "期望词数下限同样")
    }

    /// 负数同样要夹住（钳制的上下限是一体的，只挡 0 不算挡）。
    func testDecodedExamStageClampsNegativeValues() throws {
        let json = """
        {"id": "s1", "title": "t", "instructions": "i", "prompts": ["q"],
         "timeLimitSeconds": -99, "minimumWords": -99}
        """
        let stage = try JSONDecoder().decode(ExamStage.self, from: Data(json.utf8))
        XCTAssertEqual(stage.timeLimitSeconds, 10)
        XCTAssertEqual(stage.minimumWords, 5)
    }

    /// 走完整链路（考卷 → 环节）也要夹住：`ExamBlueprint` 合成解码会转发到 `ExamStage`。
    func testDecodedBlueprintClampsItsStages() throws {
        let json = """
        {"id": "b1", "format": "ieltsSpeaking", "title": "T", "summary": "",
         "stages": [{"id": "s", "title": "t", "instructions": "i", "prompts": ["q"],
                     "timeLimitSeconds": 0, "minimumWords": 0}]}
        """
        let blueprint = try JSONDecoder().decode(ExamBlueprint.self, from: Data(json.utf8))
        XCTAssertEqual(blueprint.stages.first?.timeLimitSeconds, 10)
        XCTAssertEqual(blueprint.stages.first?.minimumWords, 5)
        XCTAssertEqual(blueprint.totalTimeLimitSeconds, 10, "整场限时是各环节之和，也要跟着夹住")
    }

    // MARK: - S5-2 题号越界

    /// `remaining <= stage.prompts.count` 对 `remaining = 0` 恒真 → 曾直接取 `prompts[-1]`。
    ///
    /// 反证：删掉 `prompt(forQuestion:)` 开头那句 `guard number >= 1` → 本条整进程崩。
    func testPromptLookupRejectsNonPositiveNumber() {
        let session = ExamSession(blueprint: ExamBlueprint(
            id: "b", format: .ieltsSpeaking, title: "T", summary: "",
            stages: [ExamStage(id: "s", title: "t", instructions: "i", prompts: ["q1", "q2"],
                               timeLimitSeconds: 30, minimumWords: 10)]
        ))
        XCTAssertNil(session.prompt(forQuestion: 0), "题号 0 必须是「找不到」，不是崩")
        XCTAssertNil(session.prompt(forQuestion: -1))
        XCTAssertEqual(session.prompt(forQuestion: 1), "q1", "合法题号的行为不能被守卫改掉")
        XCTAssertEqual(session.prompt(forQuestion: 2), "q2")
        XCTAssertNil(session.prompt(forQuestion: 3))
    }

    // MARK: - S5-3 词汇同款绕钳制 + 取址兜底

    /// 与 S5-1 同款式：`mastery` 曾能解码成负数 → `intervalDays[-3]` 越界。
    func testDecodedVocabularyEntryHonoursClamps() throws {
        let json = """
        {"id": "\(UUID().uuidString)", "word": "cat", "meaning": "", "example": "",
         "difficulty": 99, "mastery": -3, "reviewCount": -5, "ease": 99.0,
         "source": "manual", "createdAt": 0}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let entry = try decoder.decode(VocabularyEntry.self, from: Data(json.utf8))
        XCTAssertEqual(entry.mastery, 0, "掌握度下限")
        XCTAssertEqual(entry.difficulty, 5, "难度上限")
        XCTAssertEqual(entry.reviewCount, 0, "复习次数不为负")
        XCTAssertEqual(entry.ease, ReviewScheduler.maxEase, "难度系数夹到上限")
    }

    /// 取址处还要再兜一道：万一有别的构造路径把 `mastery` 弄成负数（这里是直接改属性模拟），
    /// 也不能崩在数组下标上。
    ///
    /// 反证：把 `reviewIntervalDays` 里的 `max(0, min(...))` 改回 `min(...)` → 本条崩溃。
    func testReviewIntervalSurvivesNegativeMastery() {
        var entry = VocabularyEntry(word: "cat")
        entry.mastery = -3
        let days = ReviewScheduler.reviewIntervalDays(for: entry)
        XCTAssertEqual(days, 0, "负数掌握度按第 0 档算（当天到期），不该崩")
    }

    // MARK: - S5-4 SSE 行缓冲

    func testSSELineBufferEmitsOnlyOnNewline() {
        var buffer = SSELineBuffer(maxLineBytes: 64)
        for byte in Data("data: he".utf8) {
            // ⚠️ 先把 mutating 调用的结果取出来再断言：不能让它待在 XCTAssert 的 autoclosure 里。
            let outcome = buffer.append(byte)
            XCTAssertEqual(outcome, .incomplete)
        }
        var last: SSELineBuffer.Outcome = .incomplete
        for byte in Data("llo\n".utf8) { last = buffer.append(byte) }
        XCTAssertEqual(last, .line("data: hello"), "整行要在遇到换行那一刻交出来")
    }

    /// 单行超限必须**中止**，而不是继续攒（原来没有任何上限）。
    ///
    /// 反证：把 `guard buffer.count <= maxLineBytes` 删掉 → 本条红。
    func testSSELineBufferStopsAtTheLineLimit() {
        var buffer = SSELineBuffer(maxLineBytes: 8)
        for _ in 0..<8 {
            let outcome = buffer.append(UInt8(ascii: "x"))
            XCTAssertEqual(outcome, .incomplete, "上限之内都是「还没成行」")
        }
        let overflow = buffer.append(UInt8(ascii: "x"))
        XCTAssertEqual(overflow, .oversized, "第 9 个字节越限，必须报超限")
    }

    /// 越限之后立刻换行也不许「补回」成一行：上限是中止条件，不是「攒够就丢」。
    func testSSELineBufferStaysOversizedUntilReset() {
        var buffer = SSELineBuffer(maxLineBytes: 4)
        for byte in Data("abcde".utf8) {
            let outcome = buffer.append(byte)
            XCTAssertNotEqual(outcome, .line("abcde"), "越限的那一行不许被当成正常行交出去")
        }
        let newline = buffer.append(UInt8(ascii: "\n"))
        XCTAssertEqual(newline, .oversized)
    }

    func testSSELineBufferClearsOnEmptyLine() {
        var buffer = SSELineBuffer(maxLineBytes: 64)
        for byte in Data("\n".utf8) {
            let outcome = buffer.append(byte)
            XCTAssertEqual(outcome, .incomplete, "空行不产出")
        }
        // 空行必须把缓冲清干净，否则下一行会带着上一个换行一起交出来。
        var last: SSELineBuffer.Outcome = .incomplete
        for byte in Data("data: a\n".utf8) { last = buffer.append(byte) }
        XCTAssertEqual(last, .line("data: a"))
    }

    /// 装配器抽出来了，还得确认**流式那条路真的在用它**（否则上面几条全是自说自话）。
    ///
    /// 反证：把 `streamSSE` 的 switch 换回原来的裸 `buffer.append(byte)` → 本条红。
    func testStreamingPathGoesThroughTheLineBuffer() throws {
        let text = try source("AIInfrastructure/HTTPClient.swift")
        let streaming = body(of: "public func streamSSE", in: text)
        XCTAssertTrue(streaming.contains("lineBuffer.append(byte)"), "流式循环必须走装配器")
        XCTAssertFalse(streaming.contains("var buffer = Data()"), "旧的无上限缓冲不许再出现")
    }

    // MARK: - S5-5 multipart 注入

    /// 字段值里的 `\r\n--边界` 能把请求体结构改写掉（自己造出后续字段）。
    ///
    /// 判据是**结构性的**：multipart 的分隔符必须由 CRLF 引出，所以抹掉 CR/LF 之后，
    /// 注入的 `--B` 只能退化成值里的普通字符（它当然还在字符串里，但不再是分隔符）。
    ///
    /// 反证：把 `multipartField` 里的 `strippedOfNewlines(value)` 换回裸 `value` → 本条红。
    func testMultipartFieldNeutralisesNewlineInjection() throws {
        let hostile = "model-x\r\n--B\r\nContent-Disposition: form-data; name=\"evil\"\r\n\r\ninjected"
        let field = RemoteCommon.multipartField(name: "model", value: hostile, boundary: "B")
        let text = try XCTUnwrap(String(data: field, encoding: .utf8))

        let injectedDelimiters = text.components(separatedBy: "\r\n--B").count - 1
        XCTAssertEqual(injectedDelimiters, 0, "字段体里不许出现被 CRLF 引出的边界")
        XCTAssertFalse(
            text.contains("\r\nContent-Disposition: form-data; name=\"evil\""),
            "注入的头部不许落到结构位置上"
        )
        XCTAssertTrue(text.contains("model-x--B"), "值本身要留着（只是失去了分隔符身份）")
    }

    /// 引号内的令牌（字段名 / 文件名）还要中和 `"`，否则 quoted-string 会提前闭合。
    func testMultipartFileFieldNeutralisesHeaderTokens() throws {
        let field = RemoteCommon.multipartFileField(
            name: "fi\"le", filename: "a\"b\r\nZ.wav", mimeType: "audio/wav",
            data: Data([0x52]), boundary: "B"
        )
        let text = try XCTUnwrap(String(data: field, encoding: .utf8))
        XCTAssertTrue(text.contains("filename=\"a_bZ.wav\""), "换行与引号都要在文件名里被中和：\(text)")
        XCTAssertTrue(text.contains("name=\"fi_le\""))
    }

    /// 边界不能是编译期常量（常量 = 端点事先知道边界，注入就更容易成形）。
    ///
    /// 反证：把 `RemoteASRAdapter` 的 boundary 改回 `private static let` → 本条红。
    func testMultipartBoundaryIsPerRequest() throws {
        XCTAssertNotEqual(RemoteCommon.makeMultipartBoundary(), RemoteCommon.makeMultipartBoundary())
        let adapter = try source("AIProviders/RemoteASRAdapter.swift")
        XCTAssertFalse(adapter.contains("static let boundary"), "边界不许是编译期常量")
        XCTAssertTrue(adapter.contains("makeMultipartBoundary()"), "边界要走统一入口")
    }

    /// 本地那份 multipart 私有副本必须已经收编（两份实现分叉 = 只护住一半上传路径）。
    func testWhisperAdapterHasNoPrivateMultipartCopy() throws {
        let text = try source("AIProviders/WhisperASRAdapter.swift")
        XCTAssertFalse(text.contains("private static func multipartField"), "私有副本要收编到 RemoteCommon")
        XCTAssertTrue(text.contains("RemoteCommon.multipartFileField"))
    }

    // MARK: - S5-6 查询参数编码

    /// `language` 是手填的，直拼字符串能让它改写整个 query。
    ///
    /// 反证：把 `assessmentPath` 改回字符串拼接 → 本条红（会 split 出第三个参数）。
    func testAssessmentPathKeepsQueryShapeForHostileLocale() throws {
        let hostile = "en-US&format=simple&x=1"
        let path = try XCTUnwrap(RemotePronunciationAdapter.assessmentPath(locale: hostile))
        let components = try XCTUnwrap(URLComponents(string: path))
        let items = try XCTUnwrap(components.queryItems)
        XCTAssertEqual(items.count, 2, "注入的 & 不许 split 出额外参数")
        XCTAssertEqual(items.first { $0.name == "language" }?.value, hostile, "整个语言串要原样待在一个参数里")
        XCTAssertEqual(items.first { $0.name == "format" }?.value, "detailed")
        XCTAssertEqual(components.path, "/speech/recognition/conversation/cognitiveservices/v1")
    }

    /// 带空格的写法原来会让 `URL(string:)` 静默变 nil，用户只看到「地址无法拼接」。
    func testAssessmentPathEncodesSpaceInLocale() throws {
        let path = try XCTUnwrap(RemotePronunciationAdapter.assessmentPath(locale: "en US"))
        XCTAssertFalse(path.contains(" "))
        XCTAssertTrue(path.contains("en%20US"))
        XCTAssertNotNil(URL(string: "https://example.com" + path), "编码之后必须能拼成合法 URL")
    }

    // MARK: - S5-7 绑定变量上限

    /// 长会话点「重新生成」会一次传上千个 id，越过上限时整条事务回滚 →
    /// 界面上消息没了、库里一条没删，下次启动整批复活。
    ///
    /// 反证：把 `deleteMessages` 里的 `for batch in ids.batched(...)` 换回单条语句 → 本条抛错（红）。
    func testDeleteMessagesPagesPastTheBindingLimit() async throws {
        let db = try LearningDatabase.inMemory()
        let session = ChatSession(mode: .conversation)
        try await db.createSession(session)

        let total = SQLiteDatabase.maxBoundVariables + 1
        var ids: [UUID] = []
        for index in 0..<total {
            let message = ChatMessage(role: .user, content: "m\(index)")
            ids.append(message.id)
            try await db.appendMessage(message, sessionID: session.id)
        }
        let inserted = try await db.messageCount(sessionID: session.id)
        XCTAssertEqual(inserted, total)

        let deleted = try await db.deleteMessages(ids: ids, sessionID: session.id)
        XCTAssertEqual(deleted, total, "跨过上限也要整批删掉，不能「删了一半还报成功」")
        let remaining = try await db.messageCount(sessionID: session.id)
        XCTAssertEqual(remaining, 0)
    }

    /// 第二个 `IN (...)` 调用点同样要分页。
    func testLatestShadowingAttemptsPagesPastTheBindingLimit() async throws {
        let db = try LearningDatabase.inMemory()
        let total = SQLiteDatabase.maxBoundVariables + 1
        let ids = (0..<total).map { "d\($0)" }
        for (index, id) in ids.enumerated() {
            try await db.appendShadowingAttempt(ShadowingAttempt(
                drillID: id, referenceText: "ref", recognizedText: "rec",
                accuracy: 0.8, createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            ))
        }
        let latest = try await db.latestShadowingAttempts(drillIDs: ids)
        XCTAssertEqual(latest.count, total, "跨批也要每句都取到")
        XCTAssertNotNil(latest[ids.last ?? ""], "第二批的那句不能丢")
    }

    /// 分页重写不能改掉「每句留最新一条」的口径。
    func testLatestShadowingAttemptsKeepsTheNewestPerDrill() async throws {
        let db = try LearningDatabase.inMemory()
        try await db.appendShadowingAttempt(ShadowingAttempt(
            drillID: "d1", referenceText: "r", recognizedText: "old",
            accuracy: 0.3, createdAt: Date(timeIntervalSince1970: 100)
        ))
        try await db.appendShadowingAttempt(ShadowingAttempt(
            drillID: "d1", referenceText: "r", recognizedText: "new",
            accuracy: 0.9, createdAt: Date(timeIntervalSince1970: 200)
        ))
        let latest = try await db.latestShadowingAttempts(drillIDs: ["d1"])
        XCTAssertEqual(latest["d1"]?.recognizedText, "new", "同一句有多次记录时留最新的那条")
    }

    // MARK: - S5-8 体积护栏

    func testImportLimitPolicyRejectsMaterialAboveTheCap() {
        XCTAssertNil(ImportLimitPolicy.materialRejectionReason(
            fileName: "ok.txt", byteCount: ImportLimitPolicy.maxMaterialBytes
        ), "刚好到上限放行")
        let reason = ImportLimitPolicy.materialRejectionReason(
            fileName: "big.txt", byteCount: ImportLimitPolicy.maxMaterialBytes + 1
        )
        XCTAssertNotNil(reason, "多一个字节就要拒")
        XCTAssertTrue(reason?.contains("big.txt") == true, "理由要点名是哪个文件")
    }

    func testImportLimitPolicyRejectsVoiceReferenceAboveTheCap() {
        XCTAssertNil(ImportLimitPolicy.voiceReferenceRejectionReason(
            fileName: "ref.wav", byteCount: ImportLimitPolicy.maxVoiceReferenceBytes
        ))
        XCTAssertNotNil(ImportLimitPolicy.voiceReferenceRejectionReason(
            fileName: "ref.wav", byteCount: ImportLimitPolicy.maxVoiceReferenceBytes + 1
        ))
    }

    /// 空文件也要给话：以前是「读不出来」，现在能说清是空的。
    func testImportLimitPolicyExplainsEmptyFile() throws {
        let empty = try makeTempFile(bytes: 0, name: "empty.txt")
        let size = try XCTUnwrap(ImportLimitPolicy.byteCount(ofFileAt: empty))
        let reason = ImportLimitPolicy.materialRejectionReason(fileName: "empty.txt", byteCount: size)
        XCTAssertTrue(reason?.contains("空文件") == true, "空文件要有专门的理由：\(String(describing: reason))")
    }

    /// 读不到体积时返回 nil —— 不许兜成 0 假造一句「空文件」把真实原因盖掉。
    func testImportLimitPolicyReportsUnknownSizeAsNil() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-s5-missing-\(UUID().uuidString).txt")
        XCTAssertNil(ImportLimitPolicy.byteCount(ofFileAt: missing))
    }

    /// 材料导入必须在**读之前**就挡下（`String(contentsOfFile:)` 是整份读进内存）。
    ///
    /// 反证：删掉 `importMaterialFile` 里的体积判断 → 本条红（超限文件会被整个读进来）。
    func testMaterialImportRejectsOversizedFileBeforeReading() throws {
        let state = makeState()
        let big = try makeTempFile(bytes: ImportLimitPolicy.maxMaterialBytes + 1, name: "big.txt")
        state.importMaterialFile(at: big.path)
        XCTAssertTrue(
            state.materialResult?.contains("超过") == true,
            "超限材料要给出可读理由，实际：\(String(describing: state.materialResult))"
        )
        XCTAssertTrue(state.materialDraft.isEmpty, "被拒时不该留下半份草稿")
    }

    /// 正常大小要照常放行（守则不能把功能一起关掉）。
    func testMaterialImportAcceptsSmallFile() throws {
        let state = makeState()
        let small = try makeTempFile(bytes: 64, name: "small.txt")
        state.importMaterialFile(at: small.path)
        XCTAssertNil(state.materialResult, "正常文件不该报错：\(String(describing: state.materialResult))")
        XCTAssertFalse(state.materialDraft.isEmpty)
    }

    /// 音色参考音频原来「连扩展名以外什么都不查」就 copy，4 GB 文件能写满数据目录。
    ///
    /// 仓库指向临时目录：**即使这道守卫被撤掉、真的走到 copy，也不会写进开发机的数据目录**
    /// （`VoiceProfileStore` 的 `fileURL` 是可注入的，音频目录由它派生）。
    ///
    /// 反证：删掉 `importVoiceReference` 里的体积判断 → 本条红（文件会被真复制进数据目录）。
    func testVoiceReferenceImportRejectsOversizedFile() async throws {
        let isolated = VoiceProfileStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("alc-s5-voice-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("voice-profiles.json")
        )
        let services = CoachServices(
            config: makeStore(), databasePath: ":memory:", voiceProfileStore: isolated
        )
        let big = try makeTempFile(bytes: ImportLimitPolicy.maxVoiceReferenceBytes + 1, name: "ref.wav")
        do {
            _ = try await services.importVoiceReference(from: big)
            XCTFail("超限音频必须被拒，而不是写进数据目录")
        } catch let error as AppError {
            guard case let .configuration(message) = error else {
                return XCTFail("应当是配置类错误：\(error)")
            }
            XCTAssertTrue(message.contains("参考音频"), "理由要说到点上：\(message)")
        }
    }

    // MARK: - S5-9 备份校验不整读大文件

    /// 校验发生在**用户确认导入之前**，整读一份几百 MB 的 JSON 就在那儿撑爆内存。
    ///
    /// 反证：把 `readCapped` 里的 `data.count <= limit` 改回恒 true → 本条红。
    func testBackupConfigReadIsCapped() throws {
        let url = try makeTempFile(bytes: 4096, name: "config.json")
        let withinCap = try DataBackup.readCapped(url, limit: 4096)
        XCTAssertNotNil(withinCap, "刚好等于上限要放行")
        XCTAssertEqual(withinCap?.count, 4096)

        let overCap = try DataBackup.readCapped(url, limit: 4095)
        XCTAssertNil(overCap, "超过上限要判为 nil（由调用方拒绝导入）")
    }

    /// 上面那条只证明函数对；还要钉住**校验路径真的用了它**。
    ///
    /// 反证：把 `validatePayload` 换回 `Data(contentsOf: config)` → 本条红。
    func testPayloadValidationUsesTheCappedRead() throws {
        let text = try source("AIInfrastructure/DataBackup.swift")
        let validation = body(of: "private static func validatePayload", in: text)
        XCTAssertFalse(validation.isEmpty, "找不到 validatePayload（签名变了就回来改）")
        XCTAssertTrue(validation.contains("readCapped(config"), "校验必须走上限读取")
        XCTAssertFalse(validation.contains("Data(contentsOf: config)"), "不许再整读配置文件")
    }

    // MARK: - S5-10 空环节的考卷

    /// 判据是「**每个**环节都有题」，不是「总题数 > 0」。
    ///
    /// 反证：把 `isRunnable` 改成 `questionCount > 0` → 本条红。
    func testBlueprintWithAnEmptyStageIsNotRunnable() {
        let broken = ExamBlueprint(id: "b", format: .ieltsSpeaking, title: "T", summary: "", stages: [
            ExamStage(id: "a", title: "A", instructions: "i", prompts: ["q1"],
                      timeLimitSeconds: 30, minimumWords: 10),
            ExamStage(id: "b", title: "B", instructions: "i", prompts: [],
                      timeLimitSeconds: 30, minimumWords: 10),
        ])
        XCTAssertGreaterThan(broken.questionCount, 0, "它的总题数确实大于 0 —— 这正是老判据漏掉它的原因")
        XCTAssertFalse(broken.isRunnable, "有环节没题目 = 不能考")
        XCTAssertFalse(ExamBlueprint(id: "e", format: .ieltsSpeaking, title: "T", summary: "",
                                     stages: []).isRunnable, "一个环节都没有同样不能考")
    }

    /// 坏卷子要在**进考场之前**就被丢掉（否则只能等超时逐题爬过去，且没有任何提示）。
    ///
    /// 反证：删掉 `ExamCatalog.load` 里的 `guard blueprint.isRunnable` → 本条红。
    func testCatalogSkipsBlueprintWithAnEmptyStage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-s5-exams-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let good = """
        {"id": "good", "format": "ieltsSpeaking", "title": "可以考", "summary": "",
         "stages": [{"id": "a", "title": "A", "instructions": "i", "prompts": ["q1"],
                     "timeLimitSeconds": 30, "minimumWords": 10}]}
        """
        let broken = """
        {"id": "broken", "format": "ieltsSpeaking", "title": "中间有个空环节", "summary": "",
         "stages": [{"id": "a", "title": "A", "instructions": "i", "prompts": ["q1"],
                     "timeLimitSeconds": 30, "minimumWords": 10},
                    {"id": "b", "title": "B", "instructions": "i", "prompts": [],
                     "timeLimitSeconds": 30, "minimumWords": 10}]}
        """
        try good.write(to: directory.appendingPathComponent("good.json"), atomically: true, encoding: .utf8)
        try broken.write(to: directory.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)

        let loaded = ExamCatalog.load(from: directory)
        XCTAssertEqual(loaded.map(\.id), ["good"], "坏卷子要被跳过，好卷子照常加载")
    }

    // MARK: - S5-11 唯一一处插值 SQL

    /// PRAGMA 不接受绑定参数，所以只能插值；插的是 `Int` 无注入面，
    /// 但要有一道 guard 把这个前提钉住，免得后人照抄成字符串插值。
    ///
    /// 反证：删掉 `setSchemaVersion` 里的 `guard version >= 0` → 本条红。
    func testSchemaVersionRejectsNegativeValue() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-s5-schema-\(UUID().uuidString).db")
        let db = try SQLiteDatabase(path: url.path)
        try db.setSchemaVersion(7)
        XCTAssertEqual(try db.schemaVersion(), 7, "合法值照写")

        XCTAssertThrowsError(try db.setSchemaVersion(-1)) { error in
            guard case AppError.database = error else {
                return XCTFail("应当是数据库类错误：\(error)")
            }
        }
        XCTAssertEqual(try db.schemaVersion(), 7, "被拒之后版本不该被动过")
    }

    // MARK: - S5-12 会话消息取数

    /// 开屏恢复要能加上限、导出**绝不能**截断。
    ///
    /// 反证：把 `messages(sessionID:limit:)` 的 limit 分支删掉（永远全量）→ 本条红。
    func testMessagesLimitKeepsTheMostRecentOnes() async throws {
        let db = try LearningDatabase.inMemory()
        let session = ChatSession(mode: .conversation)
        try await db.createSession(session)
        for index in 0..<5 {
            try await db.appendMessage(
                ChatMessage(role: .user, content: "m\(index)"), sessionID: session.id
            )
        }

        let all = try await db.messages(sessionID: session.id)
        XCTAssertEqual(all.map(\.content), ["m0", "m1", "m2", "m3", "m4"], "不传 limit = 全量（导出路径靠它）")

        let latest = try await db.messages(sessionID: session.id, limit: 2)
        XCTAssertEqual(latest.map(\.content), ["m3", "m4"], "超限时留最近的两条，且仍按时间正序返回")

        let none = try await db.messages(sessionID: session.id, limit: 0)
        XCTAssertTrue(none.isEmpty, "limit 0 就是「不要」，不能退化成「不限」")
    }

    /// 功能对还不够：**开屏恢复那条路**得真的把上限传下去。
    ///
    /// 反证：把 `latestSession` 里的 `limit: Self.maxRestoredMessages` 删掉 → 本条红。
    func testStartupRestorePassesTheMessageCap() throws {
        let text = try source("AIInfrastructure/LearningDatabase.swift")
        let latest = body(of: "public func latestSession", in: text)
        XCTAssertFalse(latest.isEmpty, "找不到 latestSession（签名变了就回来改）")
        XCTAssertTrue(latest.contains("limit: Self.maxRestoredMessages"), "恢复要走带上限的那条路")
    }

    /// 导出路径反过来**不许**带上限（截断 = 悄悄少给用户几条学习记录）。
    func testExportPathDoesNotCapMessages() throws {
        let text = try source("AIServices/CoachServices.swift")
        let export = body(of: "public func exportLearningRecords", in: text)
        XCTAssertFalse(export.isEmpty, "找不到 exportLearningRecords（签名变了就回来改）")
        XCTAssertTrue(export.contains("messages(sessionID:"), "导出仍要取消息")
        XCTAssertFalse(export.contains("limit: LearningDatabase.maxRestoredMessages"),
                       "导出不许套用恢复的上限")
    }
}
