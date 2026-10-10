import Foundation

/// 跑一条外部命令并**等它结束**：边跑边排空输出，等待期间让出线程。
///
/// ⚠️ 为什么所有子进程都要走这里（#S3-2 / #S3-3）：
///
/// 1. **管道必须边跑边读**。管道缓冲区只有 64KB，命令输出超过它就会卡在 `write` 上、
///    永远不退出 —— 表现是「一秒钟就该干完的命令，等满超时后报超时」。
///    所以不能等进程结束再去读（那时读到的恰好是「已经写满、已经卡死」的那条管道）。
/// 2. **等待不能堵线程**。`waitUntilExit()` 是阻塞调用；它若跑在 Swift 并发线程池的线程上
///    （actor 的执行器就是其中之一），堵一条就少一条 —— 池子只有内核数量级条线程，
///    堵几条足以把整个应用的并发拖停。这里一律轮询 `isRunning` + `Task.sleep`，
///    等待期间是**挂起**，线程让给别的任务。
enum ProcessRunner {

    struct Result: Sendable, Equatable {
        /// 退出码。
        let status: Int32
        /// 合并后的标准输出 + 标准错误（只留末尾若干字节，见 `OutputCollector`）。
        let output: String
    }

    enum Failure: Error, LocalizedError, Sendable {
        case launchFailed(String)
        /// 超时仍未结束（已 `terminate()`）。
        case timedOut(seconds: Int, output: String)
        /// 等待期间被取消（已 `terminate()`）。
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .launchFailed(let reason): "无法执行命令：\(reason)"
            case .timedOut(let seconds, let output):
                output.isEmpty ? "命令超过 \(seconds) 秒仍未结束" : "命令超过 \(seconds) 秒仍未结束：\(output)"
            case .cancelled: "命令在完成前被中断"
            }
        }
    }

    /// 合并输出的保留上限。
    static let outputLimit = OutputCollector.defaultLimit

    /// 跑一条命令并等它结束。
    ///
    /// - Parameters:
    ///   - timeout: 超过这个时间就 `terminate()` 并抛 `.timedOut`。
    ///   - pollInterval: 轮询间隔（秒）。够小才不至于把「已经结束」看漏，够大才不至于空转。
    static func run(executable: String,
                    arguments: [String],
                    timeout: TimeInterval,
                    pollInterval: TimeInterval = 0.05) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let collected = OutputCollector(limit: outputLimit)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil   // EOF：子进程把所有写端都关了
                collected.markDrained()
            } else {
                collected.append(chunk)
            }
        }
        // 每条出口都要摘掉处理块：留着它，读端会被一直持有（进程结束后也没人清）。
        func stopCollecting() { pipe.fileHandleForReading.readabilityHandler = nil }

        do {
            try process.run()
        } catch {
            stopCollecting()
            throw Failure.launchFailed(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                stopCollecting()
                throw Failure.cancelled
            }
            if Date() >= deadline {
                process.terminate()
                await collected.waitForDrain()     // 让最后一段输出落地，超时提示里能带上它
                stopCollecting()
                throw Failure.timedOut(seconds: Int(timeout.rounded()), output: collected.text())
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        // 进程已退出，但管道里可能还剩最后一段（失败原因就靠它）。等排空完成，最多再等 0.2 秒。
        await collected.waitForDrain()
        stopCollecting()
        return Result(status: process.terminationStatus, output: collected.text())
    }

    /// 边跑边排空管道用的收集器（#S3-2）。
    ///
    /// ⚠️ 只留**末尾** `limit` 字节：命令失败时最有用的那句（错误、异常类型）总在最后，
    /// 而刷屏的进度输出在前面。但**读取不能停** —— 一旦不读就又回到 64KB 写阻塞，
    /// 超出上限的部分照读不误、只是丢掉。
    final class OutputCollector: @unchecked Sendable {

        /// 保留上限：够放下一条完整报错，又不至于让一条乱输出的命令把内存吃干。
        static let defaultLimit = 64 * 1024

        private let lock = NSLock()
        private let limit: Int
        private var buffer = Data()
        private var drained = false

        init(limit: Int = OutputCollector.defaultLimit) {
            self.limit = limit
        }

        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            guard limit > 0 else { return }
            if chunk.count >= limit {
                buffer = Data(chunk.suffix(limit))
                return
            }
            buffer.append(chunk)
            if buffer.count > limit { buffer.removeFirst(buffer.count - limit) }
        }

        /// 读到 EOF（子进程把所有写端都关了）。
        func markDrained() {
            lock.lock(); defer { lock.unlock() }
            drained = true
        }

        /// 等排空完成（含已经在队列上、还没跑完的那一次读取），最多等 `timeout`。
        ///
        /// 有界等待是必需的：若命令留下的孙进程还攥着管道写端，EOF 永远不来，
        /// 无界等待就会把调用方挂死 —— 那正是这一条要修的毛病。
        func waitForDrain(timeout: TimeInterval = 0.2) async {
            let deadline = Date().addingTimeInterval(timeout)
            while !isDrained, Date() < deadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        var isDrained: Bool {
            lock.lock(); defer { lock.unlock() }
            return drained
        }

        /// 已收集的输出（去首尾空白）。用容错解码：截断点可能把一个多字节字符切成两半。
        func text() -> String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: buffer, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
