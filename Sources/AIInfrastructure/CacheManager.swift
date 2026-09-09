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
            items.append(CacheItemInfo(name: displayName(for: url.lastPathComponent),
                                       fileName: url.lastPathComponent,
                                       bytes: bytes,
                                       isLearningData: isLearningData(url.lastPathComponent)))
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
    /// 3. VACUUM 回收文件空洞。
    /// 返回回收前的快照，便于 UI 展示「释放了多少」。
    public static func clearCaches(database: LearningDatabase?) async -> CacheSnapshot {
        let before = snapshot()
        if let database {
            try? await database.purgeSessionsOlderThan(days: cacheSessionCutoffDays)
            try? await database.checkpoint()
            try? await database.vacuum()
        }
        writeLastClearedMarker()
        return before
    }

    // MARK: - 内部

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
        default: fileName
        }
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
