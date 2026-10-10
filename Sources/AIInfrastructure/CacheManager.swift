import AppCore
import Foundation

// MARK: - 缓存管理

/// 数据目录空间统计与清理。
/// 设计约束：
/// - 学习记忆（learning.db、config.json）是**资产**，清理时绝不触碰；
/// - 可清理对象：WAL/SHM 伴生文件（checkpoint 后归零）、过期会话消息（可再生的对话流水）；
/// - 清理后对数据库做 VACUUM 回收文件空洞。
public enum CacheManager {

    /// 「可清理」会话的保留窗口：更早的会话与消息视为缓存。
    public static let cacheSessionCutoffDays = 30

    /// 数据目录内各文件占用（不跟随符号链接，不递归进子目录——当前为平铺结构）。
    public static func snapshot() -> CacheSnapshot {
        let directory = AppPaths.userDataDirectory()
        let fileManager = FileManager.default
        let contents = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])) ?? []

        var items: [CacheItemInfo] = []
        var total: Int64 = 0
        for url in contents {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let bytes = Int64(values?.fileSize ?? 0)
            total += bytes
            let fileName = url.lastPathComponent
            items.append(CacheItemInfo(name: displayName(for: fileName),
                                       fileName: fileName,
                                       bytes: bytes,
                                       isLearningData: isLearningData(fileName),
                                       isCallLog: RemoteCallAudit.isCallLogFile(fileName)))
        }
        items.sort { $0.bytes > $1.bytes }

        return CacheSnapshot(
            directory: directory.path,
            totalBytes: total,
            items: items,
            lastClearedAt: lastClearedMarker()
        )
    }

    /// 清理可再生的缓存：
    /// 1. 将超过保留窗口的旧会话（含消息、纠错引用）移出主表（纠错本体保留）；
    /// 2. WAL checkpoint 落盘；
    /// 3. VACUUM 回收文件空洞；
    /// 4. 对外调用留痕（当前那份 + 轮转出去的历史份）进废纸篓（#S3-5）。
    /// 返回回收前的快照，便于 UI 展示「释放了多少」。
    ///
    /// ⚠️ 留痕走**废纸篓**而不是直接删：它是用户拿去和服务商账单逐条对账的证据，
    /// 点错一次不该永久消失（与附件 / 材料 / 词典书同一口径，见 `TrashItem`）。
    public static func clearCaches(database: LearningDatabase?) async -> CacheSnapshot {
        let before = snapshot()
        if let database {
            try? await database.purgeSessionsOlderThan(days: cacheSessionCutoffDays)
            try? await database.checkpoint()
            try? await database.vacuum()
        }
        clearCallLogs()
        writeLastClearedMarker()
        return before
    }

    // MARK: - 内部

    /// 清掉「对外调用留痕」：当前那份 + 轮转出去的历史份，全部进废纸篓（#S3-5）。
    ///
    /// ⚠️ 清完一会儿又冒出一个同名文件是**正常的**：应用下一次真发云端调用时会重新建它。
    private static func clearCallLogs() {
        let directory = AppPaths.userDataDirectory()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let targets = names.filter(RemoteCallAudit.isCallLogFile)
        guard !targets.isEmpty else { return }
        TrashItem.delete(targets.map { directory.appendingPathComponent($0) })
    }

    private static func isLearningData(_ fileName: String) -> Bool {
        switch fileName {
        case "learning.db", "config.json": true
        default: false
        }
    }

    private static func displayName(for fileName: String) -> String {
        switch fileName {
        case "learning.db": "学习数据库"
        case "learning.db-wal": "数据库日志 (WAL)"
        case "learning.db-shm": "数据库共享内存"
        case "config.json": "应用配置"
        default: callLogDisplayName(fileName) ?? fileName
        }
    }

    /// 留痕要**点名**：它是用户跟服务商账单对账的证据，混在一堆文件名里被顺手清掉不合适（#S3-5）。
    private static func callLogDisplayName(_ fileName: String) -> String? {
        guard RemoteCallAudit.isCallLogFile(fileName) else { return nil }
        return fileName == RemoteCallAudit.fileName ? "对外调用留痕" : "对外调用留痕（历史份）"
    }

    private static var lastClearedMarkerURL: URL {
        AppPaths.userDataDirectory().appendingPathComponent(".cache-cleared", isDirectory: false)
    }

    private static func lastClearedMarker() -> Date? {
        guard let values = try? lastClearedMarkerURL.resourceValues(forKeys: [.contentModificationDateKey]) else { return nil }
        return values.contentModificationDate
    }

    private static func writeLastClearedMarker() {
        FileManager.default.createFile(atPath: lastClearedMarkerURL.path, contents: Data())
    }
}
