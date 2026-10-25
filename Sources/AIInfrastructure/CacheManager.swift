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

    /// 数据目录内各条目的占用：**递归**进子目录，整个子目录汇总成一行。
    public static func snapshot() -> CacheSnapshot {
        snapshot(directory: AppPaths.userDataDirectory())
    }

    /// 统计本体（目录可注入，测试才能脱离真实数据目录）。
    ///
    /// ⚠️ **必须递归**：数据目录里有 `attachments/`、`corrupted/` 等子目录，
    /// 只数平铺文件会让面板报「合计 1 MB」，而这些子目录实际占了十几 MB ——
    /// 「磁盘被谁吃了」这件用户真正想问的事，答案是错的。
    /// 子目录**汇总成一行**而不是逐个文件铺开：面板要回答的是「哪一类东西占了多少」，
    /// 铺开成几百行文件名只会让用户看不清。
    ///
    /// 不跟随符号链接；隐藏条目（`.cache-cleared`、`.restore-pending/`）不计入 ——
    /// 它们是内部标记与暂存，不是用户该关心的占用。
    static func snapshot(directory: URL) -> CacheSnapshot {
        let items = scan(directory: directory, depth: 0).sorted { $0.bytes > $1.bytes }
        return CacheSnapshot(
            directory: directory.path,
            totalBytes: items.reduce(0) { $0 + $1.bytes },
            items: items,
            lastClearedAt: lastClearedMarker()
        )
    }

    /// 递归扫描的最深层数（再深就是异常目录结构，不该为统计去遍历整棵树）。
    private static let maxScanDepth = 4

    private static func scan(directory: URL, depth: Int) -> [CacheItemInfo] {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        let contents = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []

        var items: [CacheItemInfo] = []
        for url in contents {
            let name = url.lastPathComponent
            if name.hasPrefix(".") { continue }
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isSymbolicLink == true { continue }

            if values?.isDirectory == true {
                let nested = depth + 1 < maxScanDepth ? scan(directory: url, depth: depth + 1) : []
                items.append(CacheItemInfo(
                    name: displayName(forDirectory: name),
                    fileName: name,
                    bytes: nested.reduce(0) { $0 + $1.bytes },
                    kind: kind(forDirectory: name),
                    isDirectory: true,
                    fileCount: nested.reduce(0) { $0 + $1.fileCount }
                ))
                continue
            }

            guard values?.isRegularFile == true else { continue }
            items.append(CacheItemInfo(
                name: displayName(for: name),
                fileName: name,
                bytes: Int64(values?.fileSize ?? 0),
                kind: kind(forFile: name)
            ))
        }
        return items
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

    private static func kind(forFile fileName: String) -> CacheItemKind {
        if isLearningData(fileName) { return .learningData }
        if RemoteCallAudit.isCallLogFile(fileName) { return .callLog }
        return .other
    }

    private static func kind(forDirectory name: String) -> CacheItemKind {
        switch name {
        case "attachments": .attachments
        case "corrupted": .quarantine
        default: .other
        }
    }

    private static func displayName(for fileName: String) -> String {
        switch fileName {
        case "learning.db": return "学习数据库"
        case "learning.db-wal": return "数据库日志 (WAL)"
        case "learning.db-shm": return "数据库共享内存"
        case "config.json": return "应用配置"
        case "dictionaries.json": return "词典索引"
        case "shadowing-daily.json": return "跟读日缓存"
        default: break
        }
        if fileName.hasPrefix("config.json.bak-") { return "应用配置（历史份）" }
        return callLogDisplayName(fileName) ?? fileName
    }

    /// 子目录的显示名：说**它装的是什么**，而不是甩一个英文目录名。
    private static func displayName(forDirectory name: String) -> String {
        switch name {
        case "attachments": "聊天附件"
        case "corrupted": "坏库隔离"
        case "courses": "课程"
        case "materials": "学习材料"
        case "scenarios": "自定义情景"
        case "dictionaries": "词典书"
        case "voices": "音色参考音频"
        default: name
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
