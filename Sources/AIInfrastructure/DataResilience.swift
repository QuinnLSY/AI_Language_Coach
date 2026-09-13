import AppCore
import Foundation

/// 本地数据的韧性策略：**坏了先保住证据，再让它能用**。
///
/// 学习记忆是用户最不能丢的东西。一个损坏的 SQLite 文件过去会让整条持久化链路
/// 降级关闭（应用还能开，但所有写入静默消失）——比崩溃更糟，因为没人告诉你。
/// 这里的策略是两句话：
/// 1. 可疑文件**改名隔离，绝不删除**（用户还有机会找回里面的会话）；
/// 2. 立刻重建空库继续服务，并把这件事**说清楚**（返回值 + 日志 + 界面可见）。
public enum DataResilience {

    /// 隔离文件的命名前缀：`learning.db.corrupted-20260914-003000`。
    public static let quarantinePrefix = "corrupted-"

    /// 隔离目录（数据目录下的 `corrupted/`，不在 git 里）。
    public static func quarantineDirectory(base: URL = AppPaths.userDataDirectory()) -> URL {
        base.appendingPathComponent("corrupted", isDirectory: true)
    }

    // MARK: - 学习库

    /// 打开学习库；打不开时先把可疑文件隔离，再重建空库。
    ///
    /// - Returns: `(database, recovered)`。`recovered == true` 表示这次是「抢险成功」，
    ///   调用方有责任把这件事告诉用户（见 `CoachServices.databaseRecoveryNote`）。
    /// - Throws: 隔离后**仍然**打不开才真的抛错（大概率是磁盘不可写，不是数据问题）。
    ///
    /// ⚠️ `path` 可能是 SQLite 的特殊值 `:memory:`：一旦把它当文件路径去做 URL 转换，
    /// 它就会被解析成**当前工作目录下的一个真实文件**——实测在项目根落盘成一个近 100KB 的库，
    /// 而且跨测试共享，导致用例之间互相污染。内存库因此走独立分支，绝不参与隔离逻辑。
    public static func openLearningDatabase(
        path: String,
        now: Date = Date()
    ) throws -> (database: LearningDatabase, recovered: Bool) {
        guard !Self.isInMemory(path) else {
            return (try LearningDatabase(path: path), false)
        }
        let url = URL(fileURLWithPath: path)
        do {
            return (try LearningDatabase(path: url.path), false)
        } catch let firstFailure {
            AppLog.warning(
                "学习库打开失败，准备隔离重建: \(url.lastPathComponent) — \(firstFailure.localizedDescription)",
                category: "database"
            )
            Self.moveToQuarantine(url, now: now)
            do {
                let rebuilt = try LearningDatabase(path: url.path)
                AppLog.info(
                    "已用新库接管，原文件保留在 corrupted/ 目录: \(url.lastPathComponent)",
                    category: "database"
                )
                return (rebuilt, true)
            } catch let secondFailure {
                AppLog.error(
                    "隔离后仍无法打开学习库: \(url.lastPathComponent) — \(secondFailure.localizedDescription)",
                    category: "database"
                )
                throw secondFailure
            }
        }
    }

    /// SQLite 的特殊值：内存库（含 `file::memory:` 变体）。
    public static func isInMemory(_ path: String) -> Bool {
        path == ":memory:" || path.hasPrefix("file::memory:")
    }

    /// 把数据库文件连同 WAL/SHM 伴生文件一起挪进隔离目录。
    ///
    /// SQLite 的三个文件是一套：只挪主库、留下 `-wal`，恢复时就是一半的数据。
    @discardableResult
    public static func moveToQuarantine(_ url: URL, now: Date = Date()) -> [URL] {
        let manager = FileManager.default
        let directory = quarantineDirectory(base: url.deletingLastPathComponent())
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)

        let stamp = Self.timestamp(now)
        var moved: [URL] = []
        for companion in Self.companions(of: url) where manager.fileExists(atPath: companion.path) {
            let target = directory
                .appendingPathComponent("\(companion.lastPathComponent).\(quarantinePrefix)\(stamp)")
            do {
                try manager.moveItem(at: companion, to: target)
                moved.append(target)
            } catch {
                // 挪不动就原地留着——这种情况极少（多半是权限），交给上层报错处理。
                AppLog.warning(
                    "隔离失败，文件仍在原处: \(companion.lastPathComponent) — \(error.localizedDescription)",
                    category: "database"
                )
            }
        }
        return moved
    }

    /// 主库 + WAL + SHM。
    static func companions(of url: URL) -> [URL] {
        [url, url.appendingPathExtension("-wal"), url.appendingPathExtension("-shm")]
    }

    private static func timestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let parts = [
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0,
        ]
        let values = parts.map { String(format: "%02d", $0) }
        return "\(values[0])\(values[1])\(values[2])-\(values[3])\(values[4])\(values[5])"
    }
}
