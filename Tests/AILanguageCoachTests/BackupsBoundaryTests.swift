import XCTest
@testable import AIDomain
@testable import AIInfrastructure

/// S2 备份 / 凭据 / 边界的回归测试。
///
/// 这批改的都是「用户数据可不可逆、可不可信」的边界，尽量用**真实行为**断言：
/// 隔离目录 + 真文件，不靠读源码猜。源码哨兵只用在「嵌套函数体里的分支」
/// （`applyPendingRestoreIfNeeded` 里的 `finish` 是局部函数，行为上没法单独构造）。
final class BackupsBoundaryTests: XCTestCase {

    // MARK: - 工具

    private nonisolated static func code(_ path: String) throws -> String {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// 限定函数体（brace 计数），避免同名调用点把判据救活。
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

    private func makeTempDirectory(function: String = #function) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// 解包现场的结构：专属容器 + 里面的 `contents/`（与 `unpackBackup` 保持一致）。
    private func makeStaging(function: String = #function) throws -> URL {
        let container = try makeTempDirectory(function: function)
        let staging = container.appendingPathComponent("contents", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    /// 一份最小的、能通过校验的学习库（只验文件头 16 字节）。
    private func writeFakeDatabase(at url: URL) throws {
        var header = Data("SQLite format 3\u{0}".utf8)
        header.append(Data(repeating: 0, count: 64))
        try header.write(to: url)
    }

    // MARK: - S2-11 保留策略不被「无时间戳文件名」绕过

    /// 外部拷进来的包（文件名没有时间戳 → 新鲜度只能退回文件属性 = 拷进来那一刻）
    /// 永远排在最前，清理又从最旧开始砍 → 被砍掉的本该是本应用自己的旧包。
    func testPruneOnlyRemovesSelfProducedBackups() async throws {
        let data = try makeTempDirectory()
        let backups = try makeTempDirectory()
        for index in 0..<14 {
            let name = "AI_Language_Coach_备份_\(Self.stamp(2026, 1, 1, 0, index / 60, index % 60)).zip"
            try Data("x".utf8).write(to: backups.appendingPathComponent(name))
        }
        // 三个「用户自己拷进来」的外来包：文件系统时间就是现在 = 最新
        for index in 0..<3 {
            try Data("y".utf8).write(to: backups.appendingPathComponent("我的旧备份-\(index).zip"))
        }
        let backup = DataBackup(dataDirectory: data, backupDirectory: backups)
        let removed = try await backup.prune(keeping: 12)
        let left = try FileManager.default.contentsOfDirectory(atPath: backups.path).sorted()

        XCTAssertEqual(removed, 2, "自家包 14 份、留 12 → 只清最旧的 2 份")
        XCTAssertEqual(left.filter { $0.contains("我的旧备份") }.count, 3,
                       "用户自己留下的包不该被自动回收：\(left)")
        XCTAssertEqual(left.filter { $0.contains("AI_Language_Coach_备份") }.count, 12)
        // 被清掉的必须是**最旧**的两份（时刻最小）
        XCTAssertFalse(left.contains("AI_Language_Coach_备份_\(Self.stamp(2026, 1, 1, 0, 0, 0)).zip"),
                       "最旧那份（00:00）该被清掉")
        // 14 份留 12 → 留住的正好是 index 2...13（index 0/1 是最旧的两份）
        XCTAssertTrue(left.contains("AI_Language_Coach_备份_\(Self.stamp(2026, 1, 1, 0, 0, 2)).zip"),
                      "第 3 旧的一份要留着")
        XCTAssertFalse(left.contains("AI_Language_Coach_备份_\(Self.stamp(2026, 1, 1, 0, 0, 1)).zip"),
                       "第 2 旧的一份该被清掉")
    }

    // MARK: - S2-3 解包准入

    /// 符号链接指向暂存目录之外 → 拒绝恢复（Zip Slip 的现成形态）。
    func testUnpackAuditRejectsEscapingSymlink() throws {
        let staging = try makeStaging(function: "testUnpackAudit")
        let outside = try makeTempDirectory(function: "outside")
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(
            at: staging.appendingPathComponent("escape"),
            withDestinationURL: outside.appendingPathComponent("secret.txt")
        )
        XCTAssertThrowsError(try DataBackup.auditUnpackedTree(at: staging),
                             "逃出暂存目录的条目必须被拒")
    }

    /// Zip Slip 的现成形态：zip 里的 `../evil` 落到解包目录**的同级**。
    ///
    /// ⚠️ 这条判据不能靠「枚举解包目录里的条目路径」来判 —— 逃出去的文件不在解包目录里，
    /// 枚举它永远看不到，删掉那条检查测试照样绿（已实测）。真能抓它的是「专属空容器 +
    /// 事后核对容器里有没有多出东西」。
    func testUnpackAuditRejectsEscapeBesideTheStagingDirectory() throws {
        let staging = try makeStaging(function: "testUnpackAuditEscape")
        try Data("payload".utf8).write(to: staging.appendingPathComponent("learning.db"))
        // 模拟 `../evil.txt` 被解到了容器的另一侧
        try Data("evil".utf8).write(to: staging.deletingLastPathComponent().appendingPathComponent("evil.txt"))
        XCTAssertThrowsError(try DataBackup.auditUnpackedTree(at: staging),
                             "写到解包目录之外的内容必须被拒")
    }

    /// 条目数超上限 → 拒绝（一个构造过的 zip 能塞几十万条目把目录撑爆）。
    func testUnpackAuditRejectsTooManyEntries() throws {
        let staging = try makeStaging(function: "testUnpackAuditMany")
        for index in 0...DataBackup.maxUnpackedEntries {
            try Data().write(to: staging.appendingPathComponent("f\(index)"))
        }
        XCTAssertThrowsError(try DataBackup.auditUnpackedTree(at: staging))
    }

    /// 正常备份树必须放行（别把自审写成什么都拒）。
    func testUnpackAuditAcceptsOrdinaryBackupTree() throws {
        let staging = try makeStaging(function: "testUnpackAuditOK")
        let nested = staging.appendingPathComponent("AI_Language_Coach_备份", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try writeFakeDatabase(at: nested.appendingPathComponent("learning.db"))
        try Data("{\"a\":1}".utf8).write(to: nested.appendingPathComponent("config.json"))
        XCTAssertNoThrow(try DataBackup.auditUnpackedTree(at: staging))
    }

    /// 解包必须真的调用自审 —— 只靠 `ditto` 的内部行为等于没有边界。
    func testUnpackActuallyAuditsTheTree() throws {
        let raw = try Self.code("Sources/AIInfrastructure/DataBackup.swift")
        let body = try Self.declBody(matching: "private static func unpackBackup(at url: URL) async throws -> URL", in: raw)
        XCTAssertTrue(body.contains("try auditUnpackedTree(at: staging)"), "解包后必须自审")
        let audit = try Self.declBody(matching: "static func auditUnpackedTree(at staging: URL) throws", in: raw)
        for needle in ["maxUnpackedEntries", "maxUnpackedBytes", "isSymbolicLinkKey",
                       "contentsOfDirectory(atPath: container.path)"] {
            XCTAssertTrue(audit.contains(needle), "自审里必须有 \(needle)")
        }
    }

    // MARK: - S2-4 恢复不永久删除旧数据

    /// 恢复成功后数据目录里不该留下改名留存的残骸。
    func testSuccessfulRestoreLeavesNoDisplacedFiles() async throws {
        let data = try makeTempDirectory()
        let pending = DataBackup.pendingRestoreDirectory(dataDirectory: data)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        try writeFakeDatabase(at: pending.appendingPathComponent("learning.db"))
        try Data("{\"new\":1}".utf8).write(to: pending.appendingPathComponent("config.json"))
        // 旧数据：必须先被让开，恢复完再消失
        try Data("old-db".utf8).write(to: data.appendingPathComponent("learning.db"))
        try Data("{\"old\":1}".utf8).write(to: data.appendingPathComponent("config.json"))
        try Data("old-wal".utf8).write(to: data.appendingPathComponent("learning.db-wal"))

        let note = DataBackup.applyPendingRestoreIfNeeded(dataDirectory: data)
        let entries = try FileManager.default.contentsOfDirectory(atPath: data.path)
        XCTAssertNotNil(note)
        XCTAssertFalse(entries.contains { $0.hasPrefix(".replaced-") },
                       "恢复成功不留存：\(entries)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path), "暂存目录应清掉")
        XCTAssertEqual(try Data(contentsOf: data.appendingPathComponent("config.json")), Data("{\"new\":1}".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.appendingPathComponent("learning.db-wal").path),
                       "旧库伴生文件必须被清掉（不同库的 WAL 是毒药）")
    }

    /// 留存文件名要躲开 SQLite 的视线：那两个伴生文件名必须腾空。
    func testDisplacedNamesHideFromSQLite() {
        let wal = DataBackup.displacedName(for: URL(fileURLWithPath: "/tmp/data/learning.db-wal"), stamp: "20260101-000000")
        XCTAssertNotEqual(wal.lastPathComponent, "learning.db-wal")
        XCTAssertFalse(wal.lastPathComponent.hasPrefix("learning.db"), "SQLite 按名字找伴生文件：\(wal.lastPathComponent)")
        XCTAssertTrue(wal.deletingLastPathComponent().path.contains("/tmp/data"), "留在原目录，才捞得回来")
    }

    /// 失败路径必须把「旧文件留着了」说出来 —— 局部函数没法行为构造，用哨兵钉。
    func testRestoreFailureTellsWhereTheOldFilesWent() throws {
        let raw = try Self.code("Sources/AIInfrastructure/DataBackup.swift")
        let body = try Self.declBody(
            matching: "public static func applyPendingRestoreIfNeeded(", in: raw
        )
        XCTAssertTrue(body.contains("try displace(target)"), "旧文件走改名留存")
        XCTAssertEqual(Self.occurrences(of: "try fm.removeItem(at: displaced", in: raw), 0,
                       "别把留存清成永久删除")
        let finishBody = try XCTUnwrap(body.components(separatedBy: "func finish(")[1]
            .components(separatedBy: "\n        }").first)
        XCTAssertTrue(finishBody.contains("替换下来的旧文件我留着了"),
                      "恢复失败要告诉用户旧文件在哪")
        // ⚠️ 排除断言：只钉「有这句话」不够 —— 把它挂在成功路径上同样能过。
        XCTAssertTrue(finishBody.contains("if removePending {") && finishBody.contains("} else {"),
                      "留存提示只在失败分支")
    }

    // MARK: - S2-2 备份包里的明文密钥必须明示

    /// 产品口径是「保守：不剥离、只明示」，那这句话就必须钉住。
    func testManifestWarnsAboutPlaintextKeys() {
        let withConfig = DataBackup.manifestText(files: ["learning.db", "config.json"], createdAt: Date())
        XCTAssertTrue(withConfig.contains("明文"), "包内清单必须说明 API Key 是明文")
        XCTAssertTrue(withConfig.contains("API Key"))
        XCTAssertTrue(withConfig.contains("不要发给他人"))
        // 没有 config.json 的包就别吓唬人
        let withoutConfig = DataBackup.manifestText(files: ["learning.db"], createdAt: Date())
        XCTAssertFalse(withoutConfig.contains("API Key"), "不含配置的包不必提密钥")
    }

    // MARK: - S2-10 401 文案不替用户泄密

    /// 服务端会**回显我们发过去的凭据片段**，这段文案直接显示在 UI 上。
    func testServerMessageGetsItsCredentialsRedacted() {
        let text = RemoteAuthDiagnostics.unauthorized(
            address: "api.example.com/v1/chat",
            keyDescription: "51 位，末尾 ••••2f9a",
            serverMessage: "Invalid token sk-live-AbCdEf0123456789XYZ for user 100861"
        )
        XCTAssertFalse(text.contains("AbCdEf0123456789XYZ"), "回显的 Key 片段必须打码：\(text)")
        XCTAssertTrue(text.contains("********"), text)
        // 排查真正用得上的短数字要留着
        XCTAssertTrue(text.contains("100861"), "用户编号这类短数字留着才有排查价值：\(text)")
    }

    /// 打码不得吃掉「已截断」的提示，也不得把整句英文变成星号。
    func testRedactionKeepsPunctuationAndShortText() {
        let long = String(repeating: "x", count: 500)
        let truncated = RemoteAuthDiagnostics.unauthorized(
            address: "h/p", keyDescription: "空", serverMessage: long
        )
        XCTAssertTrue(truncated.contains("…"), "截断提示要留着")
        let sentence = RemoteAuthDiagnostics.unauthorized(
            address: "h/p", keyDescription: "空",
            serverMessage: "The Authorization header is malformed, missing Bearer prefix"
        )
        XCTAssertTrue(sentence.contains("Authorization"), "普通英文句子不该被整体打码：\(sentence)")
        XCTAssertTrue(sentence.contains("malformed"))
    }

    // MARK: - S2-5 配置文件落盘权限

    /// 配置文件里明文躺着全部 API Key → 落盘必须是 0600，不能跟随 umask 变 0644。
    func testWrittenConfigIsOwnerOnly() async throws {
        let directory = try makeTempDirectory(function: "testConfigPerm")
        let url = directory.appendingPathComponent("config.json")
        try await ConfigStore(fileURL: url).mutateProduct { _ in }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.int16Value, 0o600, "配置文件必须只给本人读")
    }

    // MARK: - S2-12 留痕路径不许被环境变量指向任意位置

    /// 测试用的临时目录路径必须放行（否则单测会污染用户自己的对账文件）。
    func testCallLogOverrideAcceptsTempJSONL() {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-audit-\(UUID().uuidString).jsonl")
        withEnvironment("ALC_REMOTE_CALL_LOG", target.path) {
            XCTAssertEqual(RemoteCallAudit.logURL().standardizedFileURL, target.standardizedFileURL)
        }
    }

    /// 指向别处的值一律不认（否则「重定向 + 覆写」= 抹别的文件、抹对账证据）。
    func testCallLogOverrideRejectsPathsOutsideTemp() {
        let fallback = AppPaths.userDataDirectory().appendingPathComponent("remote-calls.jsonl")
        for bad in [
            NSHomeDirectory() + "/Desktop/alc-evil.jsonl",
            NSHomeDirectory() + "/.ssh/authorized_keys.jsonl",
            "/tmp/alc-notes.txt",
        ] {
            withEnvironment("ALC_REMOTE_CALL_LOG", bad) {
                XCTAssertEqual(
                    RemoteCallAudit.logURL().standardizedFileURL, fallback.standardizedFileURL,
                    "\(bad) 不该被采纳为留痕位置"
                )
            }
        }
    }

    /// ⚠️ 改环境变量会**同进程后续用例**都看得见 → 必须还原。
    private func withEnvironment(_ key: String, _ value: String, _ body: () -> Void) {
        let previous = ProcessInfo.processInfo.environment[key]
        setenv(key, value, 1)
        defer {
            if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
        }
        body()
    }

    // MARK: - 工具

    private nonisolated static func stamp(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, _ s: Int) -> String {
        String(format: "%04d%02d%02d-%02d%02d%02d", y, m, d, h, min, s)
    }
}