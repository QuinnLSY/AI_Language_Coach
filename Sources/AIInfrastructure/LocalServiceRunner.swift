import AppCore
import Foundation

/// 本地模型服务的进程级启停工具。
///
/// 用途：设置里点「启动 / 关闭」时，真的把本机的模型服务拉起来或停掉。
/// **命令本身一律来自配置文件**（`ProviderConfig.serviceStartCommand / serviceStopCommand`），
/// 本文件只负责执行，不内置任何服务路径、端口或脚本名。
///
/// 约束：
/// - 不阻塞 UI：启动命令以「后台进程 + 输出丢弃」的方式运行，不等待其退出。
/// - 不继承应用的标准输入输出：脚本里的 `nohup`/重定向不会被应用退出带走。
public enum LocalServiceRunner {

    public enum Failure: Error, LocalizedError, Sendable {
        case emptyCommand
        case launchFailed(String)
        case commandExited(code: Int32, output: String)
        /// 命令超时仍未结束。⚠️ 原来伪装成 `commandExited(code: -1, output: "超时未结束")`，
        /// 用户看到的是「启停命令失败（退出码 -1）」—— 那个退出码是编的，进程根本没退出过。
        case timedOut(seconds: Int, output: String)
        /// 等待期间被取消（切服务 / 退出应用）。
        case cancelled
        case notReachable(endpoint: String)
        /// 命令没被用户确认过（#S2-6）。**带出命令原文**，让 UI 能把它显示给用户看。
        case notApproved(command: String)

        public var errorDescription: String? {
            switch self {
            case .emptyCommand: "没有配置该模型服务的启停命令"
            case .notApproved(let command):
                "这条启停命令还没得到你的确认：\(command.prefix(120))"
            case .launchFailed(let reason): "无法执行启停命令：\(reason)"
            case .commandExited(let code, let output):
                output.isEmpty ? "启停命令失败（退出码 \(code)）" : "启停命令失败（退出码 \(code)）：\(output)"
            case .timedOut(let seconds, let output):
                output.isEmpty
                    ? "启停命令超过 \(seconds) 秒仍未结束"
                    : "启停命令超过 \(seconds) 秒仍未结束：\(output)"
            case .cancelled: "启停命令在完成前被中断"
            case .notReachable(let endpoint): "服务启动后仍不可达：\(endpoint)"
            }
        }
    }

    /// 后台启动一条命令（**不等待结束**）。用于拉起常驻服务。
    ///
    /// ⚠️ 这里**故意不持有**那个 `Process`：拉起的常驻服务本就该活过本应用（脚本里的 nohup /
    /// 重定向不会被应用退出带走），而且 Foundation 的 `Process` 自带独立于对象的回收机制。
    /// 实测（2026-10-10，判据见 `ConcurrencyAndResourceTests`）：
    /// - `run()` 到对象释放耗时 0.000s —— 释放**不阻塞**，拉起常驻服务不会卡住调用方；
    /// - 子进程退出后 `kill(pid, 0)` 得 ESRCH、`waitpid` 得 ECHILD —— **没有 `<defunct>` 僵尸**；
    /// - 对照组（裸 `posix_spawn` 且无人 wait）确实是僵尸 —— 判据不是空转的。
    ///
    /// 所以**不要**为了「防僵尸」再引入什么进程注册表：那是白加的复杂度。
    public static func launch(_ command: String) throws {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyCommand }
        // ⚠️ 授权闸门（#S2-6）：配置里的命令会被 `/bin/sh -lc` 执行，而配置文件
        // **能被备份包覆盖** —— 不经用户确认就等于给了「导入备份 → 重启 → 任意命令执行」。
        guard ShellCommandApproval.isApproved(trimmed) else { throw Failure.notApproved(command: trimmed) }
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            // 登录 shell：脚本里的 $HOME、PATH 等按用户环境解析。
            process.arguments = ["-lc", trimmed]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        } catch {
            throw Failure.launchFailed(error.localizedDescription)
        }
    }

    /// 执行一条命令并**等待结束**。返回退出码与输出（供上层判断与提示）。
    /// 异步等待，避免阻塞调用方 actor；等待期间被取消会立刻终止子进程。
    ///
    /// 真正跑子进程的活儿在 `ProcessRunner` —— 边跑边排空管道、等待不堵并发线程池（#S3-2）。
    @discardableResult
    public static func run(_ command: String, timeout: TimeInterval = 20) async throws -> (code: Int32, output: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.emptyCommand }
        // 同 launch：执行前必须有用户授权（#S2-6）。
        guard ShellCommandApproval.isApproved(trimmed) else { throw Failure.notApproved(command: trimmed) }

        do {
            let result = try await ProcessRunner.run(
                executable: "/bin/sh",
                arguments: ["-lc", trimmed],
                timeout: timeout
            )
            return (result.status, result.output)
        } catch let failure as ProcessRunner.Failure {
            // 翻成本模块自己的错误档：UI 只认这套文案（`ModelDiagnostics` 直接取 localizedDescription）。
            switch failure {
            case .launchFailed(let reason): throw Failure.launchFailed(reason)
            case .timedOut(let seconds, let output): throw Failure.timedOut(seconds: seconds, output: output)
            case .cancelled: throw Failure.cancelled
            }
        }
    }

    /// 轮询端点，直到**服务接受连接**（任何 HTTP 应答都算，含 404）或超时。
    ///
    /// 只做「起来了没有」的判断，具体的健康语义仍由各 Adapter 的 `healthCheck()` 负责。
    public static func waitUntilReachable(endpoint: String,
                                          timeout: TimeInterval = 60,
                                          interval: TimeInterval = 0.8) async -> Bool {
        guard let url = normalizedURL(endpoint) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let client = HTTPClient()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let _ = try? await client.perform(request, timeout: 2) { return true }
            if Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        return false
    }

    private static func normalizedURL(_ endpoint: String) -> URL? {
        var text = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.scheme != nil else { return nil }
        return url
    }
}

// MARK: - 面向 Adapter 的统一启停

/// 把 `ProviderConfig` 里的启停命令变成「启动 / 停止一个本地模型服务」的动作。
///
/// 各 Adapter 只需转发配置，不重复实现进程管理与等待逻辑。
public enum LocalServiceControl {

    /// 启动本地服务：执行启动命令 → 等端点接受连接。
    /// 端点为空（无 HTTP 服务的场景）时只执行命令，不做可达性等待。
    public static func start(config: ProviderConfig, reachTimeout: TimeInterval = 60) async throws {
        try LocalServiceRunner.launch(config.serviceStartCommand ?? "")
        guard let endpoint = config.endpoint, !endpoint.isEmpty else { return }
        let reachable = await LocalServiceRunner.waitUntilReachable(endpoint: endpoint, timeout: reachTimeout)
        guard reachable else { throw LocalServiceRunner.Failure.notReachable(endpoint: endpoint) }
    }

    /// 停止本地服务：执行停止命令。
    ///
    /// 退出码 1 视为成功——`pkill` 在「本来就没有该进程」时正是返回 1，
    /// 对「关闭」这个动作而言这就是幂等成功，不该报错吓唬用户。
    public static func stop(config: ProviderConfig) async throws {
        let result = try await LocalServiceRunner.run(config.serviceStopCommand ?? "")
        guard result.code == 0 || result.code == 1 else {
            throw LocalServiceRunner.Failure.commandExited(code: result.code, output: result.output)
        }
    }
}
