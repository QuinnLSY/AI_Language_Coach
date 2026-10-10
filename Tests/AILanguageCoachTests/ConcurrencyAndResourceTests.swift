import AIDomain
import AIInterfaces
@testable import AIServices
import AppCore
import Darwin
import Foundation
@testable import AIInfrastructure
import XCTest

/// S3 并发与资源。
///
/// 批次一（Process 与音频资源）四个条目都属于「不会报错、只会卡住 / 留垃圾」那一类：
/// - #S3-1 播放等待没有取消钩子 + `play()` 的返回值被丢 → 永久转圈；
/// - #S3-2 管道不排空 → 输出超过 64KB 的命令永远卡在 write 上，被误判成超时；
/// - #S3-4 报告称「局部 `Process` 出作用域即弃会留下 `<defunct>`」；
/// - #S3-12 变速播放的抛错路径不清理临时文件。
///
/// 批次二（备份 / 留痕 / 心跳）：
/// - #S3-3 `waitUntilExit()` 跑在 actor 的执行器上 → 堵住并发线程池；
/// - #S3-5 留痕磁盘无上限 + 打不开时 `.atomic` 覆写会把历史截断成一行；
/// - #S3-9 资源巡检任务没有任何人能停它。
///
/// 所以判据尽量落在**可观测的后果**上（耗时、还能不能被 `kill` 到、证据还在不在），
/// 而不是「代码里有没有那句话」—— 后者只作为哨兵兜底。
final class ConcurrencyAndResourceTests: XCTestCase {

    // MARK: - 工具

    /// 读出源码并去掉整行注释（哨兵只看代码，不看说明文字）。
    private nonisolated static func source(_ path: String) throws -> String {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// 取某个声明的大括号体（第一处匹配）。
    private nonisolated static func body(of marker: String, in source: String) throws -> String {
        guard let signature = source.range(of: marker) else {
            throw NSError(domain: "sentinel", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "找不到声明 \(marker)"])
        }
        guard let open = source.range(of: "{", range: signature.upperBound..<source.endIndex) else {
            throw NSError(domain: "sentinel", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "找不到 \(marker) 的声明体"])
        }
        var depth = 0
        var index = open.lowerBound
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { return String(source[open.lowerBound..<index]) }
            }
            index = source.index(after: index)
        }
        throw NSError(domain: "sentinel", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "\(marker) 的声明体没有闭合"])
    }

    /// 起一个**没人 wait** 的子进程（判据对照组用），返回 pid。
    private nonisolated static func spawnWithoutWaiting(_ script: String) -> Int32 {
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [
            strdup("/bin/sh"), strdup("-c"), strdup(script), nil
        ]
        defer { for argument in argv where argument != nil { free(argument) } }
        guard posix_spawn(&pid, "/bin/sh", nil, nil, &argv, environ) == 0 else { return -1 }
        return pid
    }

    /// 这个 pid 还在进程表里吗？（僵尸也算「在」—— 这正是判据的着力点）
    private nonisolated static func isStillInProcessTable(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    /// 同上，但把 `errno` 一起带回来（`kill` 返回 0 时 errno 是陈旧值，只有失败时才有意义）。
    private nonisolated static func probeProcessTable(_ pid: Int32) -> (isInTable: Bool, failure: Int32) {
        let result = kill(pid, 0)
        return (result == 0, result == 0 ? 0 : errno)
    }

    override func setUp() {
        super.setUp()
        ShellCommandApproval.revokeAll()
    }

    override func tearDown() {
        ShellCommandApproval.revokeAll()
        super.tearDown()
    }

    // MARK: - #S3-2 管道必须边跑边排空

    /// 输出超过管道缓冲区（64KB）的命令：不排空就会在 write 上阻塞、永不退出，
    /// 表现是「一秒钟就该干完的命令，等满 20 秒后报超时」。这里同时钉住**结果**与**耗时**。
    func testLargeOutputDoesNotTurnIntoAFalseTimeout() async throws {
        let command = "yes abcdefgh | head -c 200000"
        ShellCommandApproval.approve(command)

        let started = Date()
        let result = try await LocalServiceRunner.run(command, timeout: 10)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(result.code, 0, "200000 字节输出远没到超时，退出码应为 0")
        XCTAssertTrue(result.output.contains("abcdefgh"), "尾部输出必须真的读到了：\(result.output.prefix(80))")
        XCTAssertLessThanOrEqual(
            result.output.utf8.count, ProcessRunner.outputLimit,
            "输出要按上限截断，别让一条刷屏的命令把内存吃干"
        )
        XCTAssertLessThan(elapsed, 5, "本该一秒内结束；超过 5 秒说明管道没被排空，卡在 64KB 缓冲区上了")
    }

    /// 取消要立刻收摊：不能等满超时（原来 `try? await Task.sleep` 会把取消吞掉，一直空转到进程自己退出）。
    func testCancellingTheWaitTerminatesTheCommandPromptly() async throws {
        let command = "sleep 10"
        ShellCommandApproval.approve(command)

        let started = Date()
        let task = Task { () -> (code: Int32, output: String) in
            try await LocalServiceRunner.run(command, timeout: 30)
        }
        try await Task.sleep(nanoseconds: 300_000_000)   // 让它先真的跑起来
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("被取消的等待不该正常返回")
        } catch let failure as LocalServiceRunner.Failure {
            guard case .cancelled = failure else {
                return XCTFail("应是取消错误，实际：\(failure)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "取消后要立刻终止子进程并返回")
    }

    /// 收集器的纯逻辑：留末尾、超限丢最老的，且**超限后照样接受新数据**（继续读才不会写阻塞）。
    func testCollectorKeepsTheTailAndKeepsTakingDataPastTheLimit() {
        let collector = ProcessRunner.OutputCollector(limit: 10)
        XCTAssertFalse(collector.isDrained, "还没读到 EOF")
        collector.append(Data("0123456789".utf8))
        collector.append(Data("ABCDE".utf8))
        XCTAssertEqual(collector.text(), "56789ABCDE", "超限要丢最老的、留末尾（失败原因总在最后）")

        let once = ProcessRunner.OutputCollector(limit: 4)
        once.append(Data("abcdefgh".utf8))
        XCTAssertEqual(once.text(), "efgh", "一次就超过上限时也只留末尾")

        once.markDrained()
        XCTAssertTrue(once.isDrained)
    }

    /// 截断点可能把一个多字节字符切成两半 —— 容错解码，别把整段输出丢成空字符串。
    func testCollectorSurvivesTruncationInTheMiddleOfACharacter() {
        let collector = ProcessRunner.OutputCollector(limit: 3)
        collector.append(Data("语林".utf8))          // 每个汉字 3 字节
        XCTAssertFalse(collector.text().isEmpty, "切在多字节字符中间也要给出能看的内容")
        XCTAssertEqual(collector.text(), "林")
    }

    // MARK: - #S3-4 拉起子进程不留僵尸（报告的说法需要更正）

    /// 报告认为「局部 `Process` 出作用域即弃 → 留下 `<defunct>`」。实测**不成立**：
    /// Foundation 的 `Process` 有独立于对象的回收机制。用两个进程对照着钉：
    /// 裸 `posix_spawn` 无人 wait 的子进程**是**僵尸（说明判据有效），
    /// 而 `launch()` 拉起的那个不是。
    func testLaunchedChildIsReapedWithoutAZombie() async throws {
        // 对照组：判据本身要能认出僵尸，否则下面那句断言是空转的。
        let control = Self.spawnWithoutWaiting("sleep 0.2")
        XCTAssertGreaterThan(control, 0)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertTrue(Self.isStillInProcessTable(control),
                      "对照组的裸 posix_spawn 子进程没人收尸，应当仍留在进程表里")
        var controlStatus: Int32 = 0
        XCTAssertEqual(waitpid(control, &controlStatus, WNOHANG), control, "对照组应当是未被回收的僵尸")

        // 正主：`launch()` 只管拉起，`Process` 对象随后立刻出作用域。
        // 让命令把自己的 pid 写出来（`$$` 就是被 launch 的那个 sh）。
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-zombie-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let command = "echo $$ > \(pidFile.path); sleep 0.2"
        ShellCommandApproval.approve(command)
        try LocalServiceRunner.launch(command)

        try await Task.sleep(nanoseconds: 1_200_000_000)
        let text = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(text), "没读到子进程 pid：\(text)")

        XCTAssertFalse(Self.isStillInProcessTable(pid),
                       "launch() 拉起的子进程退出后应已被回收；还在进程表里 = 留了僵尸")
        let probe = Self.probeProcessTable(pid)
        XCTAssertTrue(probe.isInTable == false && probe.failure == ESRCH,
                      "kill 应当以「没有这个进程」失败，实际 errno=\(probe.failure)")
    }

    // MARK: - 源码哨兵（兜住「机制没被改回去」）

    /// 两条等待路径都要有取消钩子，且起播被拒必须上抛；原来只有裸 `park` + 丢掉返回值的 `play()`。
    func testPlaybackWiresCancellationAndSurfacesAStartFailure() throws {
        let raw = try Self.source("Sources/AIInfrastructure/AudioPlayback.swift")
        let occurrences = raw.components(separatedBy: "withTaskCancellationHandler").count - 1
        XCTAssertEqual(occurrences, 2, "等比与变速两条等待路径都补取消钩子，缺一条就会永久卡住那条流水线")

        let playAndWait = try Self.body(of: "public func playAndWait(wavData: Data, rate: Float = 1.0) async throws", in: raw)
        XCTAssertTrue(playAndWait.contains("parkAndPlay(continuation, player: player)"),
                      "登记等待者与起播要在同一个临界区里完成")
        XCTAssertTrue(playAndWait.contains("AudioPlaybackError.playerRefusedStart"),
                      "起播被拒时不会再有回调，必须上抛")
        XCTAssertTrue(raw.contains("case playerRefusedStart"), "错误类型要有这一档")

        let parkAndPlay = try Self.body(of: "private func parkAndPlay(_ continuation: CheckedContinuation<PlaybackEnd, Never>,", in: raw)
        XCTAssertTrue(parkAndPlay.contains("resume(returning: .notStarted)"),
                      "被拒的等待者要自己唤醒（否则永久转圈）")
        XCTAssertTrue(parkAndPlay.contains("Task.isCancelled"),
                      "进临界区前就已取消的任务不会被 onCancel 叫醒，得自查一次")
    }

    /// #S3-12：变速播放落盘之后，每条抛错路径都要删掉临时文件（原来只有一处清理）。
    func testEnginePlaybackCleansItsTempFileOnEveryThrowPath() throws {
        let raw = try Self.source("Sources/AIInfrastructure/AudioPlayback.swift")
        let body = try Self.body(of: "private func playWithEngine(wavData: Data, rate: Float) async throws", in: raw)
        XCTAssertTrue(body.contains("defer { try? FileManager.default.removeItem(at: url) }"),
                      "落盘之后要统一挂一个 defer 兜住所有抛错路径")
        XCTAssertTrue(body.contains("withTaskCancellationHandler"), "变速路径同样是长等待，也要能被打断")
    }

    /// #S3-2 / #S3-3：跑子进程的唯一实现必须边跑边读，而且**不许阻塞等待**。
    func testProcessRunnerDrainsThePipeAndNeverBlocks() throws {
        let raw = try Self.source("Sources/AIInfrastructure/ProcessRunner.swift")
        let body = try Self.body(of: "static func run(executable: String,", in: raw)
        XCTAssertTrue(body.contains("readabilityHandler = {"), "要边跑边排空，不能等进程结束后再读")
        XCTAssertTrue(body.contains("availableData"), "挂上去的处理块得真的在读管道")
        XCTAssertFalse(body.contains("readDataToEndOfFile"),
                       "进程结束再读 = 读到的是「已经写满、已经卡死」的那条管道")
        XCTAssertTrue(body.contains("Task.isCancelled"), "轮询里要检查取消")
        XCTAssertFalse(body.contains("waitUntilExit"),
                       "waitUntilExit() 是阻塞调用：跑在 actor 的执行器上就堵住一条并发线程")
    }

    /// 服务启停命令走共享 runner，并把失败翻成本模块自己的错误档（UI 只认这套文案）。
    func testServiceRunUsesTheSharedRunnerAndKeepsItsErrorTiers() throws {
        let raw = try Self.source("Sources/AIInfrastructure/LocalServiceRunner.swift")
        let body = try Self.body(of: "public static func run(_ command: String, timeout: TimeInterval = 20) async throws", in: raw)
        XCTAssertTrue(body.contains("ProcessRunner.run("), "别再就地写第二份子进程逻辑")
        XCTAssertTrue(body.contains("Failure.cancelled"))
        // 超时不再伪装成「退出码 -1」——进程根本没退出过，那个退出码是编的。
        XCTAssertTrue(body.contains("Failure.timedOut"))
        XCTAssertTrue(raw.contains("case timedOut(seconds: Int, output: String)"))
    }

    /// #S3-3：备份与恢复同样走共享 runner；`DataBackup` 里不许再有阻塞等待。
    func testBackupRunsDittoWithoutBlockingTheActor() throws {
        let raw = try Self.source("Sources/AIInfrastructure/DataBackup.swift")
        XCTAssertTrue(raw.contains("ProcessRunner.run("), "打包 / 解包要走共享实现")
        XCTAssertFalse(raw.contains("waitUntilExit"),
                       "DataBackup 是 actor：就地 waitUntilExit() 会堵住它的执行器（并发线程池的一条）")
        XCTAssertFalse(raw.contains("readDataToEndOfFile"), "读取交给 ProcessRunner 边跑边读")
        XCTAssertTrue(raw.contains("private static func zip(payload: URL, to destination: URL) async throws"),
                      "打包已是 async：等待期间不占线程")
    }

    /// #S3-3 的**要害**：等待子进程不能占用协作线程池的线程。
    ///
    /// 池子只有内核数量级条线程。同时起 2×内核数 条「等子进程」的任务：
    /// 若等待是阻塞式的，线程会被占光，下面那条纯计算任务就排不上队（要等子进程结束）。
    func testProcessWaitsDoNotOccupyCooperativeThreads() async {
        let width = ProcessInfo.processInfo.activeProcessorCount
        let waits = (0..<(width * 2)).map { _ in
            Task { try? await ProcessRunner.run(executable: "/bin/sleep", arguments: ["1"], timeout: 30) }
        }
        try? await Task.sleep(nanoseconds: 300_000_000)   // 让它们都进到等待里

        let probe = Task { () -> Int in
            var sum = 0
            for value in 0..<200_000 { sum &+= value }
            return sum
        }
        let started = Date()
        _ = await probe.value
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 0.5,
                          "协作线程池被阻塞的等待占住了：\(width * 2) 条等待下，一条普通计算任务都排不上队")

        for wait in waits { _ = await wait.value }
    }

    // MARK: - #S3-5 留痕轮转与「只许追加」

    /// 轮转规则本身：封顶、定宽可排序、认得出历史份。
    func testRotationRulesKeepTheLogBoundedAndSortable() {
        let rules = RemoteCallAudit.Rotation.self
        XCTAssertFalse(rules.shouldRotate(currentBytes: 0, incomingBytes: 10_000, maxBytes: 100),
                       "空文件不轮转，否则第一条就把刚建的文件换名")
        XCTAssertFalse(rules.shouldRotate(currentBytes: 90, incomingBytes: 10, maxBytes: 100), "刚好到顶不轮转")
        XCTAssertTrue(rules.shouldRotate(currentBytes: 91, incomingBytes: 10, maxBytes: 100))

        let early = rules.rotatedName(for: "remote-calls.jsonl", at: Date(timeIntervalSince1970: 0))
        let later = rules.rotatedName(for: "remote-calls.jsonl", at: Date(timeIntervalSince1970: 3_600))
        XCTAssertTrue(early.hasPrefix("remote-calls-") && early.hasSuffix(".jsonl"), early)
        XCTAssertLessThan(early, later, "时间戳定宽 → 按名字排序就是按时间排序")

        XCTAssertTrue(rules.isRotated(early, of: "remote-calls.jsonl"))
        XCTAssertTrue(rules.isRotated(rules.rotatedName(for: "remote-calls.jsonl", at: Date(), round: 3),
                                      of: "remote-calls.jsonl"), "同刻去重后缀也算历史份")
        XCTAssertFalse(rules.isRotated("remote-calls.jsonl", of: "remote-calls.jsonl"), "当前那份不是历史份")
        XCTAssertFalse(rules.isRotated("remote-calls-20261010-161530123.txt", of: "remote-calls.jsonl"))
        XCTAssertFalse(rules.isRotated("learning.db", of: "remote-calls.jsonl"))

        let names = ["remote-calls-20260101-000000000.jsonl",
                     "remote-calls-20260201-000000000.jsonl",
                     "remote-calls-20260301-000000000.jsonl",
                     "remote-calls-20260401-000000000.jsonl"]
        XCTAssertEqual(rules.namesToPrune(names, keeping: 2),
                       ["remote-calls-20260101-000000000.jsonl", "remote-calls-20260201-000000000.jsonl"],
                       "封顶只留最新的几份")
        XCTAssertTrue(rules.namesToPrune(names, keeping: 9).isEmpty)
    }

    /// 留痕文件名识别：清理入口靠它把「当前那份 + 历史份」一起算上。
    func testCallLogFileNamesAreRecognised() {
        XCTAssertTrue(RemoteCallAudit.isCallLogFile("remote-calls.jsonl"))
        XCTAssertTrue(RemoteCallAudit.isCallLogFile("remote-calls-20261010-161530123.jsonl"))
        XCTAssertFalse(RemoteCallAudit.isCallLogFile("remote-calls.txt"))
        XCTAssertFalse(RemoteCallAudit.isCallLogFile("learning.db"))
        XCTAssertFalse(RemoteCallAudit.isCallLogFile("config.json"))
    }

    /// 超过上限就轮转：换个名字留档，历史份数有封顶，**内容不许丢**。
    func testAuditLogRotatesInsteadOfGrowingForever() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 上限压到 2KB：几十条记录就能撑爆它，不必真写满 1MB。
        let audit = RemoteCallAudit(fileURL: directory.appendingPathComponent(RemoteCallAudit.fileName),
                                    rotationMaxBytes: 2 * 1024)
        for _ in 0..<120 { await audit.record(Self.remoteIntent(), outcome: .ok) }

        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let rotated = names.filter { RemoteCallAudit.Rotation.isRotated($0, of: RemoteCallAudit.fileName) }
        XCTAssertFalse(rotated.isEmpty, "超过上限必须轮转，不能一直往同一个文件里塞")
        XCTAssertLessThanOrEqual(rotated.count, RemoteCallAudit.Rotation.maxFiles, "历史份数要有封顶")

        let oldest = try XCTUnwrap(rotated.sorted().first)
        let size = try FileManager.default
            .attributesOfItem(atPath: directory.appendingPathComponent(oldest).path)[.size] as? Int
        XCTAssertGreaterThan(size ?? 0, 0, "轮转是换名字留档，不是把内容截掉")
    }

    /// ⚠️ 回归：留痕已存在但打不开时，**绝不能**退到 `.atomic` 覆写 ——
    /// 那会把用户拿来对账的历史整份截断成一行（`.atomic` 靠 rename，绕过文件权限，照样写得进去）。
    func testUnwritableExistingCallLogIsLeftAloneInsteadOfTruncated() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent(RemoteCallAudit.fileName)
        try Data("历史记录：上一次对账用的那一行\n".utf8).write(to: log)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: log.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: log.path) }

        let audit = RemoteCallAudit(fileURL: log)
        await audit.record(Self.remoteIntent(), outcome: .ok)

        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        XCTAssertTrue(text.contains("历史记录"), "已有留痕只能追加：打不开也绝不能把历史覆写成一行，实际：\(text)")
    }

    /// 清理入口必须把留痕算进去，而且走**废纸篓**（对账证据，点错一次不该永久消失）。
    func testCacheClearingCoversTheCallLogThroughTheTrash() throws {
        let raw = try Self.source("Sources/AIInfrastructure/CacheManager.swift")
        let clear = try Self.body(of: "public static func clearCaches(database: LearningDatabase?) async", in: raw)
        XCTAssertTrue(clear.contains("clearCallLogs()"), "留痕要进清理入口（#S3-5）")

        let clearLogs = try Self.body(of: "private static func clearCallLogs()", in: raw)
        XCTAssertTrue(clearLogs.contains("RemoteCallAudit.isCallLogFile"), "当前那份与历史份都要算上")
        XCTAssertTrue(clearLogs.contains("TrashItem.delete"), "留痕是对账证据：进废纸篓，别直接删")
        XCTAssertFalse(clearLogs.contains("removeItem"), "别绕过废纸篓")
    }

    // MARK: - #S3-9 心跳任务要能收工

    /// 拥有者（`CoachServices`）没了以后，巡检要**明确收工**：
    /// 原来这种情况下 `runOnce()` 只是「什么都不做、照常返回一个间隔」，
    /// 循环照转 —— 加上 `stop()` 在生产代码里零调用，没有任何人能停它。
    func testLifecycleTickReportsDoneWhenItsOwnerIsGone() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-lifecycle-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        var owner: CoachServices? = CoachServices(
            config: ConfigStore(fileURL: fileURL), databasePath: ":memory:"
        )
        let manager = ModelLifecycleManager(services: try XCTUnwrap(owner), monitor: FakePressureMonitor())

        let first = await manager.runOnce()
        XCTAssertNotNil(first, "拥有者还在：照常巡检并给出下次间隔（nil 只表示该收工）")

        owner = nil
        let after = await manager.runOnce()
        XCTAssertNil(after, "拥有者没了 → nil：巡检任务据此收工，不再每 60 秒空醒一次")
    }

    /// 两条心跳都不许强引用拥有者 —— 否则谁也放不掉它，任务也不会随主人一起消失。
    func testHeartbeatsDoNotKeepTheirOwnerAlive() throws {
        let lifecycle = try Self.source("Sources/AIServices/ModelLifecycleManager.swift")
        XCTAssertTrue(lifecycle.contains("private weak var services"),
                      "巡检管理器不许强引用 CoachServices")
        let start = try Self.body(of: "public func start()", in: lifecycle)
        XCTAssertTrue(start.contains("[weak self]"), "巡检任务不许强引用管理器")
        XCTAssertTrue(start.contains("else { return }"), "runOnce 返回 nil 时任务要收工")

        let appState = try Self.source("Sources/AppUI/AppState.swift")
        let watch = try Self.body(of: "func startDayRolloverWatch()", in: appState)
        XCTAssertTrue(watch.contains("[weak self]"), "跨天监察不许强引用 AppState")
        XCTAssertTrue(watch.contains("guard let self"), "AppState 没了要自然退出循环")
    }

    // MARK: - #S3-6 有界缓存（键是用户输入的那三处）

    /// 跳转历史的明细缓存：到顶要倒掉，但**不能倒掉导航栈里那几条** ——
    /// `current` 靠它取正文，倒空了页面会一直停在「正在查…」（那次请求早就回来了）。
    func testDetailCacheIsCappedWithoutBlankingTheCurrentPage() {
        var session = DictionaryLookupSession.empty
        session.begin("alpha")
        session.remember(DictionaryDetail(word: "alpha"))
        session.push("beta")
        session.remember(DictionaryDetail(word: "beta"))
        XCTAssertNotNil(session.current)

        for index in 0..<(DictionaryLookupSession.detailLimit * 2) {
            session.cache(DictionaryDetail(word: "filler\(index)"))
        }

        XCTAssertLessThanOrEqual(session.details.count, DictionaryLookupSession.detailLimit,
                                 "明细缓存到顶要倒掉，不能只涨不落")
        XCTAssertNotNil(session.current, "倒缓存不能把用户正看着的那一条也倒掉")
        XCTAssertEqual(session.history, ["alpha", "beta"], "历史是导航栈，不该被缓存清理牵动")
    }

    /// 三处「以用户输入为键」的缓存都要有上限 —— 这类容器不会报错，只会一直涨。
    func testUserKeyedCachesAreBounded() throws {
        let service = try Self.source("Sources/AIServices/DictionaryService.swift")
        let lookUp = try Self.body(of: "public func lookUp(", in: service)
        XCTAssertTrue(lookUp.contains("cache.count >= cacheLimit"),
                      "查词缓存到顶要先倒掉（与 parseCache 同一口径）")
        XCTAssertTrue(service.contains("private let cacheLimit"), "上限得是个真的数字，不是注释里的愿望")

        let domain = try Self.source("Sources/AIDomain/Dictionary.swift")
        let store = try Self.body(of: "private mutating func storeDetail(_ detail: DictionaryDetail, key: String)", in: domain)
        XCTAssertTrue(store.contains("DictionaryLookupSession.detailLimit") || store.contains("Self.detailLimit"),
                      "封顶只在这一个落笔处做，新增写入点绕不过它")

        let appState = try Self.source("Sources/AppUI/AppState.swift")
        XCTAssertTrue(appState.contains("static let wordLookupAttemptLimit"), "划词闸门要封顶")
        let selection = try Self.source("Sources/AppUI/AppState+WordSelection.swift")
        XCTAssertTrue(selection.contains("wordLookupAttemptLimit"),
                      "上限必须真的被执行到，不能只声明不用")
    }

    // MARK: - #S3-7 同键在途合成只跑一趟

    /// 同一句并发合成两次 → **只发一次请求**。原来命中判断与写入之间夹着
    /// `await tts.synthesize`（一个挂起点），第二次调用会重新走「没命中」的分支。
    func testConcurrentSynthesisOfTheSameLineOnlyHitsTheProviderOnce() async throws {
        let provider = CountingTTSProvider(delay: 0.15)
        let tts = TTSManager()
        await tts.register(provider)
        let voice = VoiceService(tts: tts)
        let selection = SpeechVoiceSelection.builtin("v1")

        async let first = voice.synthesizeCached("Hello there, friend.", voice: selection, language: "en")
        async let second = voice.synthesizeCached("Hello there, friend.", voice: selection, language: "en")
        let pair = try await (first, second)

        XCTAssertEqual(pair.0, pair.1, "合流的两个调用方拿到同一份音频")
        let calls = provider.callCount
        XCTAssertEqual(calls, 1, "同一句在途时第二次调用要合流，不能重复烧一次请求")
    }

    /// 同一句顺序合成两次（第二次是缓存命中）以及 FIFO 淘汰仍要正常：
    /// 键重复入队会让淘汰账目错位，这里钉住「最新的那条一定还在」。
    func testSynthesisCacheStillEvictsTheOldest() async throws {
        let provider = CountingTTSProvider()
        let tts = TTSManager()
        await tts.register(provider)
        let voice = VoiceService(tts: tts)
        let selection = SpeechVoiceSelection.builtin("v1")

        // 缓存上限 48：写满 + 溢出一条。
        for index in 0..<49 {
            _ = try await voice.synthesizeCached("line \(index)", voice: selection, language: "en")
        }
        let afterFill = provider.callCount
        XCTAssertEqual(afterFill, 49)

        _ = try await voice.synthesizeCached("line 48", voice: selection, language: "en")
        XCTAssertEqual(provider.callCount, afterFill, "最新那条必须还在缓存里（刚写进去就被挤掉 = 淘汰账目错了）")

        _ = try await voice.synthesizeCached("line 0", voice: selection, language: "en")
        XCTAssertEqual(provider.callCount, afterFill + 1, "最老那条应当已被淘汰，重查要真的再发一次")
    }

    /// 缓存队列天然不许出现重复的键（重复只可能来自「两次都判成没命中」）。
    func testSynthesisCacheQueueNeverHoldsTheSameKeyTwice() throws {
        let raw = try Self.source("Sources/AIServices/VoiceService.swift")
        let remember = try Self.body(of: "private func remember(key: String, wav: Data)", in: raw)
        XCTAssertTrue(remember.contains("firstIndex(of: key)"),
                      "先查重再淘汰：合流的后来者会再走一遍写入，键已经在队里")
        XCTAssertTrue(remember.contains("audioCache[oldest] = nil"), "淘汰要同时清掉字典与队列两侧")

        let synth = try Self.body(of: "func synthesizeCached(_ text: String, voice: SpeechVoiceSelection, language: String)", in: raw)
        XCTAssertTrue(synth.contains("synthInflight[key]"), "同键在途要合流")
        XCTAssertTrue(synth.contains("running.value"), "后来者等那一趟，而不是自己再发一次")
    }

    // MARK: - #S3-8 写库必须按提交顺序

    /// 排队的意义：**发起顺序 = 执行顺序**。故意让后提交的工作更快完成 ——
    /// 没有串行化的话，先提交的反而后落库（「删掉的又回来了」就是这一类）。
    func testSerialQueueRunsItsWorkInSubmissionOrder() async {
        let queue = SerialTaskQueue()
        let recorder = OrderRecorder()
        let total = 12
        for index in 0..<total {
            // 越是后提交的、睡的时间越短：不串行的话顺序一定被打乱。
            let delay = Double(total - index) * 0.01
            queue.enqueue { await recorder.record(index, delay: delay) }
        }
        await queue.drain()

        let order = await recorder.snapshot()
        XCTAssertEqual(order, Array(0..<total), "串行队列被绕过了：执行顺序乱了")
    }

    /// 插入与删除必须排进**同一条**队；各自起 `Task` 就等于把顺序交回调度器。
    func testChatPersistenceGoesThroughOneOrderedQueue() throws {
        let raw = try Self.source("Sources/AIServices/ChatService.swift")
        let insert = try Self.body(of: "private func persist(_ message: ChatMessage)", in: raw)
        XCTAssertTrue(insert.contains("persistenceQueue.enqueue"), "插入要排队")
        XCTAssertFalse(insert.contains("Task {"), "插入不许自己起 Task")

        let delete = try Self.body(of: "private func persistDeletion(of ids: [UUID])", in: raw)
        XCTAssertTrue(delete.contains("persistenceQueue.enqueue"), "删除要排进同一条队")
        XCTAssertFalse(delete.contains("Task {"), "删除不许自己起 Task")
    }

    // MARK: - #S3-10 录音生命周期闸门

    /// 并发进同一扇门只能有一个 owner —— 多一个就会多留一套引擎与 tap（麦克风常开）。
    func testOnlyOneConcurrentRecorderStartWinsTheGate() {
        for _ in 0..<40 {
            let gate = RecordingGate()
            let winners = AtomicCounter()
            DispatchQueue.concurrentPerform(iterations: 16) { _ in
                if gate.beginStarting() { winners.increment() }
            }
            XCTAssertEqual(winners.value, 1,
                           "并发 start 里有 \(winners.value) 个以为自己是 owner：多出来的那套引擎没人停")
        }
    }

    /// 「启动中」也算占用：这正是原来缺的那一格（check 与 set 之间隔着整段不加锁的代码）。
    func testRecorderGateKeepsTheSlotWhileStarting() {
        let gate = RecordingGate()
        XCTAssertFalse(gate.isRecording)
        XCTAssertTrue(gate.beginStarting())
        XCTAssertFalse(gate.beginStarting(), "启动中也是占用：再点一次必须被挡回去")
        XCTAssertFalse(gate.isRecording, "还没真正在录（否则 `stop` 会在一个半成品上动手）")

        gate.markRecording()
        XCTAssertTrue(gate.isRecording)
        XCTAssertFalse(gate.beginStarting(), "在录的时候更不能重入")

        gate.release()
        XCTAssertFalse(gate.isRecording)
        XCTAssertTrue(gate.beginStarting(), "停下来之后要能重新开始")
    }

    /// 构建中途失败必须把坑让出来，否则麦克风一次失败就再也起不来了。
    func testRecorderStartReleasesTheGateOnEveryFailurePath() throws {
        let raw = try Self.source("Sources/AIInfrastructure/MicrophoneRecorder.swift")
        let start = try Self.body(of: "public func start() throws", in: raw)
        let throwsCount = start.components(separatedBy: "throw AppError.audio").count - 1
        let releases = start.components(separatedBy: "gate.release()").count - 1
        XCTAssertGreaterThanOrEqual(throwsCount, 3)
        XCTAssertEqual(releases, throwsCount, "每条抛错路径都要先放闸门（\(throwsCount) 条 throw / \(releases) 次 release）")
        XCTAssertTrue(start.contains("gate.beginStarting()"), "先占坑再干活")
        XCTAssertTrue(start.contains("gate.markRecording()"), "构建成功才进入录音中")
    }

    // MARK: - #S3-11 庆祝演出的代际令牌

    /// `celebrate()` 一次要起几十个错峰 Task（三波欢跳 × 在场只数 + 台词 + 收尾）。
    /// 它们不持有、也没法取消，所以**每个 Task 动手前都要对一次代际令牌**。
    func testCelebrationTasksRevalidateTheirGenerationToken() throws {
        let raw = try Self.source("Sources/AppUI/Components/TreeCanvas.swift")
        let celebrate = try Self.body(of: "private func celebrate()", in: raw)
        let spawns = celebrate.components(separatedBy: "Task { @MainActor in").count - 1
        XCTAssertGreaterThanOrEqual(spawns, 3, "三处派发点：欢跳 / 台词 / 收尾")
        let checks = celebrate.components(separatedBy: "celebrationToken == token").count - 1
        XCTAssertEqual(checks, spawns, "有 \(spawns) 个 Task 创建点，却只有 \(checks) 处对账")

        let home = try Self.body(of: "private func sendEveryoneHome()", in: raw)
        XCTAssertTrue(home.contains("celebrationToken += 1"),
                      "「回家」要把在飞的演出作废，否则它还会把刚站好的队伍拽走一只")
    }

    // MARK: - 工具（批次三）

    /// 线程安全的计数（并发闸门用例用）。
    private final class AtomicCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() {
            lock.lock(); count += 1; lock.unlock()
        }
        var value: Int {
            lock.lock(); defer { lock.unlock() }
            return count
        }
    }

    /// 记录执行顺序（串行队列用例用）。`delay` 故意随下标递减，好把「没串行」暴露出来。
    private actor OrderRecorder {
        private var order: [Int] = []
        func record(_ value: Int, delay: Double) async {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            order.append(value)
        }
        func snapshot() -> [Int] { order }
    }

    /// 计次 TTS Provider：合流没生效的话它会数到 2。
    private final class CountingTTSProvider: TTSProvider, @unchecked Sendable {
        let providerID = "counting.tts"
        let kind: AIProviderKind = .tts
        private let lock = NSLock()
        private var calls = 0
        private let delay: TimeInterval

        init(delay: TimeInterval = 0) { self.delay = delay }

        func initialize(config: ProviderConfig) async throws {}
        func load() async throws {}
        func unload() async {}
        func healthCheck() async -> ProviderHealth { .connected(model: nil) }
        func capabilities() -> ProviderCapabilities { ProviderCapabilities() }
        func metadata() -> ProviderMetadata {
            ProviderMetadata(id: providerID, displayName: "Counting TTS", runtime: .ollama)
        }

        var callCount: Int {
            lock.lock(); defer { lock.unlock() }
            return calls
        }

        func synthesize(_ request: TTSRequest) async throws -> TTSResult {
            noteCall()
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            return TTSResult(audioSamples: [], sampleRate: 16_000, audioData: Data([0x00]))
        }

        /// 同步记账：`NSLock.lock()` 在 async 上下文里不可用（`noasync`）。
        private func noteCall() {
            lock.lock(); calls += 1; lock.unlock()
        }
    }

    // MARK: - 工具（批次二）

    /// 一个只属于本用例的临时目录。
    private nonisolated static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-s3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 一次云端调用的审计意图（只落元数据，不含任何用户文本）。
    private nonisolated static func remoteIntent() -> RemoteCallPolicy.Intent {
        RemoteCallPolicy.Intent(
            kind: .llm, providerID: "remote.test", model: "test-model",
            host: "example.invalid", operation: .chat
        )
    }

    /// 内存压力假实现：系统不告知 → 按「不紧张」保守处理（与 `ResourcePolicyTests` 同口径）。
    private struct FakePressureMonitor: MemoryPressureMonitoring {
        func availableMemoryBytes() -> UInt64? { nil }
    }
}
