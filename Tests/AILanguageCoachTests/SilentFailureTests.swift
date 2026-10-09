import XCTest
@testable import AppCore
@testable import AIInfrastructure
@testable import AIServices

/// S1 静默失败批次的回归测试。
///
/// 这批改的是「失败了要让人知道」，多数行为无法用纯函数断言（要靠真实文件与
/// 注入的记账实例），因此测试分两类：**真实行为**用隔离目录实测，**接线**用源码哨兵
/// （判据限定声明体，不裸 `contains` 全文件 —— 同名语句会救活假绿）。
final class SilentFailureTests: XCTestCase {

    // MARK: - 工具

    private nonisolated static func code(_ path: String) throws -> String {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// 提取某个声明的**声明体**（brace 计数），避免同名调用点干扰。
    private nonisolated static func declBody(matching marker: String, in source: String) throws -> String {
        guard let signature = source.range(of: marker) else {
            throw NSError(domain: "sentinel", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "找不到声明 \(marker)"])
        }
        guard let open = source.range(of: "{", range: signature.upperBound..<source.endIndex) else {
            throw NSError(domain: "sentinel", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "找不到 \(marker) 的声明体开头"])
        }
        var depth = 0
        var index = open.lowerBound
        while index < source.endIndex {
            let character = source[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return String(source[open.lowerBound..<index]) }
            }
            index = source.index(after: index)
        }
        throw NSError(domain: "sentinel", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "\(marker) 的声明体没有闭合"])
    }

    private nonisolated static func occurrences(of needle: String, in source: String) -> Int {
        source.components(separatedBy: needle).count - 1
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-silent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - S1-1 配置文件读失败不能抹掉用户配置

    /// 坏 config.json：必须先把原文件另存一份，而不是「默默退成默认值」等着被写回覆盖。
    func testUnreadableConfigIsQuarantinedBeforeDefaultsTakeOver() async throws {
        let directory = try makeTempDirectory()
        let configURL = directory.appendingPathComponent("config.json")
        try Data("这不是 JSON".utf8).write(to: configURL)

        let store = ConfigStore(fileURL: configURL)
        // 读失败要说出来：设置页读的是 `loadFailureReason`。
        let reason = await store.loadFailureReason
        XCTAssertNotNil(reason, "用户层读取失败必须有出口（否则界面毫无迹象）")
        XCTAssertTrue(reason?.contains("另存为") == true,
                      "要说清原文件被另存到哪了：\(reason ?? "")")
        // 原文件必须还在（换了个名字），不能被丢掉也不能被覆盖。
        let survivors = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("config.corrupt-") }
        XCTAssertEqual(survivors.count, 1, "坏配置要被另存为 config.corrupt-<时间>.json：\(survivors)")
        // ⚠️ 绝不 `survivors[0]`：判据失效时越界会 fatal error 崩掉整个 xctest 进程，
        // 后面的用例全跑不了（等于把「失败」伪装成「没跑」）。用 XCTUnwrap 抛错跳过。
        let quarantined = directory.appendingPathComponent(
            try XCTUnwrap(survivors.first, "坏配置必须留下原文件（用户要靠它找回 Key）")
        )
        XCTAssertEqual(try Data(contentsOf: quarantined), Data("这不是 JSON".utf8),
                       "另存的必须是原文件原文（用户要靠它找回 Key）")
    }

    /// 正常配置不该被误伤：能读出来就没有失败提示、也不产生隔离文件。
    func testReadableConfigIsLeftAlone() async throws {
        let directory = try makeTempDirectory()
        let configURL = directory.appendingPathComponent("config.json")
        // 让 ConfigStore 自己落一份（手写 JSON 容易漏掉非可选字段，解码照样失败，
        // 那样测的是「坏配置」而不是「正常配置」）。
        try await ConfigStore(fileURL: configURL).mutateProduct { _ in }

        let store = ConfigStore(fileURL: configURL)
        let reason = await store.loadFailureReason
        XCTAssertNil(reason, "能读出来的配置不该报失败")
        let survivors = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("config.corrupt-") }
        XCTAssertTrue(survivors.isEmpty, "正常配置不该被隔离")
    }

    // MARK: - S1-2 落库失败记账

    func testRecorderAccumulatesFailuresWithActionNames() async {
        let recorder = PersistenceFailureRecorder()
        await recorder.record("保存这段对话", nil)
        let count = await recorder.count
        let last = await recorder.lastDescription
        XCTAssertEqual(count, 1)
        XCTAssertEqual(last, "保存这段对话：学习记录库不可用",
                       "库不可用时也要给出动作名，不能只记一个数字")
        await recorder.record("保存这次复盘", AppError.database("磁盘已满"))
        let second = await recorder.count
        XCTAssertEqual(second, 2)
    }

    /// CoachServices 的计数必须来自**同一个** recorder（子服务写失败也要进这份账）。
    func testCoachServicesReadsFailureCountFromTheSharedRecorder() async {
        let services = CoachServices(databasePath: ":memory:")
        let failures = services.persistenceFailures
        await failures.record("保存学习进度", AppError.database("磁盘已满"))
        let count = await services.persistenceFailureCount
        let last = await services.lastPersistenceFailure
        XCTAssertEqual(count, 1, "UI 读的必须是同一份账（原来各服务自己吞掉，横幅永远不亮）")
        XCTAssertEqual(last, "保存学习进度：磁盘已满")
    }

    // MARK: - 源码哨兵：接线

    /// 三个子服务的 `failures` 注入**不给默认值**（默认新实例 = 记在自己那份里，UI 看不到）。
    func testSubServicesRequireAnInjectedFailureRecorder() throws {
        let raw = try Self.code("Sources/AIServices/CoachServices.swift")
        for name in ["SessionReviewService(llm", "VocabularyService(llm", "ShadowingService(voice"] {
            XCTAssertTrue(raw.contains("\(name)") && raw.contains("failures: self.persistenceFailures"),
                          "\(name) 必须注入共享的 persistenceFailures")
        }
        for file in ["SessionReviewService", "VocabularyService", "ShadowingService"] {
            let source = try Self.code("Sources/AIServices/\(file).swift")
            XCTAssertFalse(source.contains("failures: PersistenceFailureRecorder = "),
                           "\(file) 的 failures 不许带默认值（带默认值 = 漏注入也编译得过）")
        }
    }

    /// 用户可见成果的写入不许再 `try?`：逐个函数体里钉死。
    func testVisibleOutcomeWritesAreNoLongerSilentlyOptional() throws {
        let raw = try Self.code("Sources/AIServices/CoachServices.swift")
        let guarded = [
            "public func saveProgress(",
            "public func saveQuestProgress(",
            "public func clearQuestProgress(",
            "public func recordWritingSubmission(",
            "public func saveReading(",
        ]
        for marker in guarded {
            let body = try Self.declBody(matching: marker, in: raw)
            XCTAssertFalse(body.contains("try? await learning"),
                           "\(marker) 里还有 try? —— 写失败用户看不到")
            XCTAssertTrue(body.contains("recordPersistenceFailure"),
                          "\(marker) 必须把失败记进那份共享的账")
        }
    }

    /// 坏库隔离不完整时，不许再说「文件保留在 corrupt 目录里、没有被删除」。
    func testRecoveryNoteIsHonestAboutIncompleteQuarantine() throws {
        let raw = try Self.code("Sources/AIServices/CoachServices.swift")
        let body = try Self.declBody(matching: "private static func recoveryNote(path: String, quarantined: Bool)", in: raw)
        XCTAssertTrue(body.contains("没能完整隔离"),
                      "隔离失败时要如实说找不回来了（原来那句「没有被删除」是假的）")
        XCTAssertTrue(body.contains("corrupt 目录里"), "隔离成功时才说文件在 corrupt 目录")
    }

    /// 备份恢复的两处「清不掉」必须中止，而不是带着残留继续。
    func testRestoreAbortsWhenCleanupFails() throws {
        let raw = try Self.code("Sources/AIInfrastructure/DataBackup.swift")
        XCTAssertEqual(Self.occurrences(of: "已中止本次恢复", in: raw), 1)
        XCTAssertEqual(Self.occurrences(of: "已中止恢复以免污染新库", in: raw), 1)
        XCTAssertEqual(Self.occurrences(of: "try? fm.removeItem", in: raw), 0,
                       "旧库伴生文件的删除不能再是 try?")
    }

    /// 配置落盘失败要有出口（原来是 try?，改完重启还原，用户毫无察觉）。
    func testPersistProductReportsFailures() throws {
        let raw = try Self.code("Sources/AppUI/AppState+Maintenance.swift")
        let body = try Self.declBody(matching: "func persistProduct() async", in: raw)
        XCTAssertFalse(body.contains("try? await services.updateProduct"),
                       "配置落盘不许再静默吞错")
        XCTAssertTrue(body.contains("catch"), "失败要走到提示分支")
    }
}
