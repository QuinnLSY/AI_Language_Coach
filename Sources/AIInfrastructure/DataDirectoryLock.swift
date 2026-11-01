import Darwin
import Foundation

/// 数据目录的**跨进程**写锁。
///
/// 为什么需要它（这不是"防并发写"，SQLite 自己会防）：
/// 学习库是 WAL 模式的 SQLite，允许多个进程同时打开，但写只有一个能进去。
/// 第二个写者撞上 `SQLITE_BUSY` 之后，启动路径会把它当成"库打不开" →
/// 交给 `DataResilience` 走坏库隔离 → **把用户正在用的库改名挪走**。
/// 也就是：开着应用跑一次测试/CLI，用户的学习记录就被当成坏库隔离了。
///
/// 这道锁的唯一职责，是**在隔离判断之前**把「另一个实例在用」与「库真的坏了」分开。
///
/// 语义：`flock(LOCK_EX | LOCK_NB)` 顾问锁 —— 拦不住不守规矩的进程，
/// 只让守规矩的调用方知道"有人持锁"。持锁者退出时内核自动释放（含崩溃、SIGKILL），
/// 所以不存在"上次没清干净导致永久打不开"的死锁。
public final class DataDirectoryLock: @unchecked Sendable {

    public enum Acquisition {
        case acquired(DataDirectoryLock)
        /// 另一个进程正持有写锁。
        case busy
        /// 连锁文件都建不出来（目录不可写等）。调用方按"无锁"继续，别因此拒绝启动。
        case unavailable(String)
    }

    /// 锁文件名。放在数据目录里，与 `learning.db` 同级，便于用户/支持人员一眼找到。
    public static let fileName = ".data-lock"

    public let fileURL: URL

    private let descriptor: Int32
    private var released = false

    private init(descriptor: Int32, fileURL: URL) {
        self.descriptor = descriptor
        self.fileURL = fileURL
    }

    deinit { release() }

    /// 尝试取写锁（不等待）。拿不到立刻返回 `.busy`，由调用方决定给用户看什么。
    public static func acquire(directory: URL) -> Acquisition {
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            return .unavailable(String(cString: strerror(errno)))
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            // EWOULDBLOCK 是 macOS/Linux 上"已被别人持有"的标准返回值。
            return code == EWOULDBLOCK ? .busy : .unavailable(String(cString: strerror(code)))
        }
        writeHolderStamp(to: fd)
        return .acquired(DataDirectoryLock(descriptor: fd, fileURL: url))
    }

    public func release() {
        // ⚠️ 必须有这个幂等标记：`deinit` 会再调一次，而裸 `close` 一个已关闭的 fd
        // 可能正好关掉**别人刚拿到的同一个 fd 号** —— 那种 bug 只在并发下偶发。
        guard !released else { return }
        released = true
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    /// 把持有者写进锁文件，方便"到底谁占着"时 `cat` 一眼看出来。纯诊断用，失败不影响锁。
    private static func writeHolderStamp(to descriptor: Int32) {
        _ = ftruncate(descriptor, 0)
        let stamp = "pid \(getpid())\nsince \(Date().formatted(.iso8601))\n"
        _ = stamp.withCString { write(descriptor, $0, strlen($0)) }
    }
}
