import AIDomain
import AIInfrastructure
import AIServices
import AppCore
@testable import AppUI
import XCTest

/// 自停（退出收尾）+ 自启可见性（#546）的回归。
///
/// 覆盖四件事：
/// 1. 退出**只停本应用亲手拉起**的服务（登记簿语义，用户自己拉的不碰）；
/// 2. 未授权 / 超时 / 无停止命令三种「停不掉」都有界、不挂死、不谎报；
/// 3. 退出路径（⌘Q / 菜单栏 / Dock 兜底）都先收尾再真退出；
/// 4. 开屏自启没起来时，提示条挂得出来、点得动（未授权直接弹 #S2-6 确认框）。
@MainActor
final class AppServiceShutdownTests: XCTestCase {

    // MARK: - 工具

    private nonisolated static func code(_ path: String) throws -> String {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

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

    /// 授权落在 UserDefaults 上 → 每个用例前后清干净，别串到同进程后续用例。
    override func setUp() {
        super.setUp()
        ShellCommandApproval.revokeAll()
    }

    override func tearDown() {
        ShellCommandApproval.revokeAll()
        super.tearDown()
    }

    /// 每个用例自建临时目录 + 配置库 + 服务装配，调用方用 `defer` 清目录。
    ///
    /// ⚠️ 刻意**不做成存储属性**：`setUp/tearDown` 是非隔离的，在 `@MainActor`
    /// 测试类里碰主 actor 隔离的属性会刷一屏隔离警告（实测 14 条）。
    private func makeServices() -> (services: CoachServices, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-shutdown-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        return (CoachServices(config: store, databasePath: ":memory:"), directory)
    }

    /// 登记簿是**进程全局**的：每个用例体首行先清，再摆自己的场景。
    /// ⚠️ 不能放 setUp/tearDown：那是同步上下文，`await` 不了 actor。
    private func resetRegistry() async {
        await LaunchedLocalServices.shared.resetForTesting()
    }

    // MARK: - 登记簿语义：只停自己拉起的

    /// 反证用例：**不在册的服务绝不允许被停** —— 用户自己拉起的 Edge 代理 / whisper
    /// 退出时要原样活着，否则用户会以为「应用把我的服务杀了」。
    func testStopOnlyTouchesServicesTheAppStarted() async throws {
        await resetRegistry()
        let (services, directory) = makeServices()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mine = directory.appendingPathComponent("mine-stopped.txt")
        let theirs = directory.appendingPathComponent("theirs-stopped.txt")

        let started = ProviderConfig(
            id: "test.mine", kind: .tts, runtime: .externalLocalRuntime,
            serviceStartCommand: "true",
            serviceStopCommand: "echo stopped > \(mine.path)"
        )
        let userStarted = ProviderConfig(
            id: "test.theirs", kind: .tts, runtime: .externalLocalRuntime,
            serviceStopCommand: "echo stopped > \(theirs.path)"
        )
        ShellCommandApproval.approve(started.serviceStopCommand ?? "")
        ShellCommandApproval.approve(userStarted.serviceStopCommand ?? "")

        // 只登记 started（= 本应用拉起）；userStarted 故意不登记（= 用户自己拉的）。
        await LaunchedLocalServices.shared.record(started)

        let leftovers = await services.stopServicesStartedByApp()

        XCTAssertTrue(leftovers.isEmpty, leftovers.joined(separator: "；"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mine.path),
                      "本应用拉起的服务，退出时必须停掉")
        XCTAssertFalse(FileManager.default.fileExists(atPath: theirs.path),
                       "用户自己拉起的服务不在册，退出时不许碰")
    }

    /// 启动成功即登记、停止成功即注销（登记簿的两个写入点）。
    func testRegistryRecordsOnStartAndRemovesOnStop() async throws {
        await resetRegistry()
        let config = ProviderConfig(
            id: "test.registry", kind: .tts, runtime: .externalLocalRuntime,
            serviceStartCommand: "true", serviceStopCommand: "true"
        )
        ShellCommandApproval.approve("true")

        try await LocalServiceControl.start(config: config)
        let recorded = await LaunchedLocalServices.shared.snapshot().map(\.id)
        XCTAssertEqual(recorded, ["test.registry"],
                       "启动成功必须登记（自停的台账）")

        try await LocalServiceControl.stop(config: config)
        let afterStop = await LaunchedLocalServices.shared.snapshot().isEmpty
        XCTAssertTrue(afterStop,
                      "停止成功必须注销，否则下次退出会重复停")
    }

    /// Ollama 的形态：有启动命令、**没有**停止命令（停它等于杀掉用户的常驻应用）。
    /// 这种服务不报错、不执行任何命令，也不假装停过。
    func testProvidersWithoutStopCommandAreLeftAlone() async throws {
        await resetRegistry()
        let (services, directory) = makeServices()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ProviderConfig(
            id: "test.ollama-like", kind: .llm, runtime: .externalLocalRuntime,
            serviceStartCommand: "true"
        )
        await LaunchedLocalServices.shared.record(config)

        let leftovers = await services.stopServicesStartedByApp()
        XCTAssertTrue(leftovers.isEmpty, "没有停止命令不是失败：\(leftovers)")
    }

    // MARK: - 停不掉的三条路都有界

    /// 未授权的停止命令：不执行、进摘要、**留在册上**（下次退出重试）。
    func testUnapprovedStopCommandIsSkippedAndKeptForRetry() async throws {
        await resetRegistry()
        let (services, directory) = makeServices()
        defer { try? FileManager.default.removeItem(at: directory) }
        let forbidden = directory.appendingPathComponent("must-not-exist.txt")
        let config = ProviderConfig(
            id: "test.unapproved", kind: .tts, runtime: .externalLocalRuntime,
            serviceStopCommand: "echo nope > \(forbidden.path)"
        )
        // 故意不授权（#S2-6）：退出路径没有交互机会，只能跳过。
        await LaunchedLocalServices.shared.record(config)

        let leftovers = await services.stopServicesStartedByApp()

        XCTAssertEqual(leftovers.count, 1)
        XCTAssertTrue(leftovers[0].contains("test.unapproved"), leftovers[0])
        XCTAssertTrue(leftovers[0].contains("确认"), leftovers[0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: forbidden.path),
                       "未授权的命令一条都不许执行")
        let kept = await LaunchedLocalServices.shared.snapshot().map(\.id)
        XCTAssertEqual(kept, ["test.unapproved"],
                       "没停掉的服务要留在册上，下次退出才重试")
        await resetRegistry()
    }

    /// 停止命令卡住（sleep 5）时必须有界返回：退出永远不能被挂死。
    func testStopTimeoutIsBounded() async throws {
        await resetRegistry()
        let (services, directory) = makeServices()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = ProviderConfig(
            id: "test.slow", kind: .tts, runtime: .externalLocalRuntime,
            serviceStopCommand: "sleep 5"
        )
        ShellCommandApproval.approve("sleep 5")
        await LaunchedLocalServices.shared.record(config)

        let clock = ContinuousClock()
        let startedAt = clock.now
        let leftovers = await services.stopServicesStartedByApp(stopTimeout: 1)
        let elapsed = startedAt.duration(to: clock.now)

        XCTAssertLessThan(elapsed, .seconds(3), "停止命令超时必须有界，实测 \(String(describing: elapsed))")
        XCTAssertFalse(leftovers.isEmpty, "超时未停掉的服务要进摘要，不能装作停过了")
        await resetRegistry()
    }

    /// 退出收尾端到端：真的执行、且**幂等**（第二遍在册为空，直接返回）。
    func testAppServiceShutdownRunsBoundedAndIsIdempotent() async throws {
        await resetRegistry()
        let (services, directory) = makeServices()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ran = directory.appendingPathComponent("shutdown-ran.txt")
        let config = ProviderConfig(
            id: "test.shutdown", kind: .tts, runtime: .externalLocalRuntime,
            serviceStopCommand: "echo ran > \(ran.path)"
        )
        ShellCommandApproval.approve(config.serviceStopCommand ?? "")
        await LaunchedLocalServices.shared.record(config)

        AppServiceShutdown.run(services: services, timeout: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ran.path),
                      "退出收尾必须真的把停止命令执行掉")

        // 再跑一遍（terminate 与 applicationWillTerminate 会各跑一次）：不许重复停。
        try? FileManager.default.removeItem(at: ran)
        AppServiceShutdown.run(services: services, timeout: 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ran.path),
                       "幂等：在册为空时第二次收尾不该再执行任何命令")
    }

    // MARK: - 接线哨兵：三条退出路径都先收尾

    /// ⌘Q / 菜单栏退出：收尾必须排在 `NSApp.terminate` **之前** —— 排在后面等于没跑
    /// （进程当场就退了，detached 任务没有机会执行）。
    func testTerminateRunsShutdownBeforeQuitting() throws {
        let host = try Self.code("Sources/AppUI/AppKitHost.swift")

        let body = try Self.declBody(matching: "public static func terminate(services: CoachServices? = nil)", in: host)
        guard let shutdown = body.range(of: "AppServiceShutdown.run(services: services)"),
              let quit = body.range(of: "NSApp?.terminate(nil)") else {
            return XCTFail("terminate(services:) 要同时含收尾与真退出两步")
        }
        XCTAssertLessThan(shutdown.lowerBound, quit.lowerBound,
                          "收尾必须排在 NSApp.terminate 之前，否则 detached 任务没机会跑")

        // Dock 右键退出 / 系统关机不经过菜单项：委派里必须兜底。
        let fallback = try Self.declBody(
            matching: "public func applicationWillTerminate(_ notification: Notification)", in: host)
        XCTAssertTrue(fallback.contains("AppServiceShutdown.run"),
                      "applicationWillTerminate 必须兜底跑退出收尾")
    }

    /// ⌘Q 自接管（`CommandGroup(replacing: .appTermination)`）+ 菜单栏那颗退出。
    func testQuitEntryPointsCarryServices() throws {
        let main = try Self.code("Sources/AppMain/AppMain.swift")
        guard let group = main.range(of: "CommandGroup(replacing: .appTermination)") else {
            return XCTFail("⌘Q 必须自接管，否则走系统默认项直接退出、不收尾")
        }
        let windowEnd = main.index(group.upperBound, offsetBy: 260, limitedBy: main.endIndex) ?? main.endIndex
        let window = main[group.upperBound..<windowEnd]
        XCTAssertTrue(window.contains("AppKitHost.terminate(services: state.services)"),
                      "退出菜单项必须带上 services，收尾才停得掉本应用拉起的服务")
        XCTAssertTrue(window.contains(".keyboardShortcut(\"q\")"), "⌘Q 等价键要显式挂上")

        let menu = try Self.code("Sources/AppUI/MenuBarController.swift")
        XCTAssertTrue(menu.contains("AppKitHost.terminate(services: state.services)"),
                      "菜单栏面板的「退出」同样要带 services")
    }

    /// 确认框（#S2-6）**全局唯一挂点在 MainView 根上**：开屏提示条在对话区也要能弹它，
    /// 挂在设置页里的话用户不在设置页时框永远不出现；同时不许两处各挂一份。
    func testShellApprovalAlertHasASingleGlobalMount() throws {
        let main = try Self.code("Sources/AppUI/Views/MainView.swift")
        XCTAssertTrue(main.contains("pendingShellApproval"), "确认框要挂在 MainView 根上")
        XCTAssertTrue(main.contains("state.approvePendingShellCommand()"), "确认按钮要能放行")
        XCTAssertTrue(main.contains("state.declinePendingShellCommand()"), "也要能拒绝")

        let settings = try Self.code("Sources/AppUI/Views/SettingsView.swift")
        XCTAssertFalse(settings.contains(".alert(item:"),
                       "确认框只挂一处：设置页再挂一份会双弹")
    }

    // MARK: - 自启可见性（#546）

    /// 开屏结果 → 提示条：没起来且用户能动手的两档才挂；正常的档不亮。
    func testLaunchOutcomeBecomesAnActionableNotice() async throws {
        await resetRegistry()
        let (services, directory) = makeServices()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(services: services)

        state.applyLocalServiceLaunchNotice(.needsApproval(command: "nohup start-edge.sh"), kind: .tts)
        let notice = try XCTUnwrap(state.serviceLaunchNotices[.tts])
        XCTAssertTrue(notice.text.contains("教师语音"), notice.text)
        XCTAssertTrue(notice.text.contains("确认"), notice.text)
        XCTAssertEqual(notice.action?.title, "去确认")

        // 点动作：命令原文必须原样进确认框（Edge 代理没有服务控制器，
        // 指望 setModelRunning 弹框是弹不出来的）。
        notice.action?.run()
        XCTAssertNil(state.serviceLaunchNotices[.tts], "点动作即清提示")
        let request = try XCTUnwrap(state.pendingShellApproval)
        XCTAssertEqual(request.command, "nohup start-edge.sh")
        XCTAssertEqual(request.kind, .tts)
        XCTAssertTrue(request.running)
        state.pendingShellApproval = nil

        // 一切正常的三档不挂提示（提示条是稀缺注意力）。
        state.applyLocalServiceLaunchNotice(.started, kind: .tts)
        state.applyLocalServiceLaunchNotice(.alreadyRunning, kind: .asr)
        state.applyLocalServiceLaunchNotice(.notConfigured, kind: .asr)
        XCTAssertTrue(state.serviceLaunchNotices.isEmpty, "正常结果不该亮提示条")

        // 失败挂「重试」，文案要点明能力和原因。
        state.applyLocalServiceLaunchNotice(.failed("服务启动后仍不可达：http://127.0.0.1:8856"), kind: .asr)
        let failed = try XCTUnwrap(state.serviceLaunchNotices[.asr])
        XCTAssertTrue(failed.text.contains("语音识别"), failed.text)
        XCTAssertTrue(failed.text.contains("不可达"), failed.text)
        XCTAssertEqual(failed.action?.title, "重试")
        state.dismissServiceLaunchNotice(.asr)
        XCTAssertNil(state.serviceLaunchNotices[.asr])
    }

    /// 接线哨兵：`ensure*` 返回显式结果、AppState 过提示、MainView 渲染提示条。
    func testLaunchOutcomeWiringIsPinned() throws {
        let control = try Self.code("Sources/AppUI/AppState+ModelControl.swift")
        XCTAssertTrue(control.contains(
            "func applyLocalServiceLaunchNotice(_ outcome: CoachServices.LocalServiceLaunchOutcome, kind: AIProviderKind)"),
            "开屏结果要有一个统一落点")
        let body = try Self.declBody(matching: "func applyLocalServiceLaunchNotice", in: control)
        XCTAssertTrue(body.contains("serviceLaunchNotices[kind] = AppNotice("), "没起来必须挂提示条")
        XCTAssertTrue(body.contains("pendingShellApproval = ShellApprovalRequest("),
                      "未授权要能直接弹 #S2-6 确认框")
        XCTAssertTrue(body.contains("serviceLaunchNotices[kind] = nil"), "正常结果要清掉旧提示")

        let appState = try Self.code("Sources/AppUI/AppState.swift")
        XCTAssertTrue(appState.contains("applyLocalServiceLaunchNotice(ttsOutcome, kind: .tts)"),
                      "开屏 TTS 结果要过提示")
        XCTAssertTrue(appState.contains("applyLocalServiceLaunchNotice(asrOutcome, kind: .asr)"),
                      "开屏 ASR 结果要过提示")

        let view = try Self.code("Sources/AppUI/Views/MainView.swift")
        XCTAssertTrue(view.contains("state.serviceLaunchNotices[kind]"), "提示条要在对话区渲染")

        let coach = try Self.code("Sources/AIServices/CoachServices.swift")
        XCTAssertTrue(coach.contains("public enum LocalServiceLaunchOutcome: Sendable, Equatable"),
                      "自启结果要有一个显式枚举")
        for marker in ["public func ensureEdgeTTSProxyOnLaunch() async -> LocalServiceLaunchOutcome",
                       "public func ensureLocalASROnLaunch() async -> LocalServiceLaunchOutcome"] {
            let ensureBody = try Self.declBody(matching: marker, in: coach)
            XCTAssertTrue(ensureBody.contains("return .needsApproval(command: command)"),
                          "\(marker) 未授权要带出命令原文")
            XCTAssertTrue(ensureBody.contains("return .failed("),
                          "\(marker) 失败要带出原因")
        }
    }
}
