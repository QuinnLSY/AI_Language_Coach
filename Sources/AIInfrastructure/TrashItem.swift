import AppCore
import Foundation

/// 删除用户资产时**统一走废纸篓**（#S2-13）。
///
/// 为什么：项目里 `trashItem` 的正确用法原先只用在备份包上 —— 恰恰是最不该优先保护的那一项；
/// 而附件、词典书、材料包、自定义情景、音色这些**用户自己攒的东西**一律
/// `removeItem` + `try?`，点错一次就永久没了，且失败无声。
///
/// 为什么不直接 `trashItem`：废纸篓在某些环境（容器目录、受限沙盒、不支持废纸篓的卷）
/// 不可用，那时若直接抛错会把「清理孤儿文件」这类 housekeeping 卡死。所以**回落**到永久删除，
/// 但要落一条日志 —— 用户需要知道「这条没能进废纸篓，删掉了就找不回来」。
public enum TrashItem {

    /// 删一个文件；`url` 为 nil 或文件不存在时返回 false（不算失败）。
    ///
    /// - Returns: 是否确实删掉了。
    @discardableResult
    public static func delete(_ url: URL?) -> Bool {
        guard let url else { return false }
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return false }
        do {
            try manager.trashItem(at: url, resultingItemURL: nil)
            return true
        } catch {
            AppLog.warning(
                "进废纸篓失败，改为直接删除（找不回来了）：\(url.lastPathComponent) —— \(error.localizedDescription)",
                category: "storage"
            )
        }
        do {
            try manager.removeItem(at: url)
            return true
        } catch {
            AppLog.error(
                "删除失败：\(url.lastPathComponent) —— \(error.localizedDescription)",
                category: "storage"
            )
            return false
        }
    }

    /// 批量删（清理孤儿附件那一类）。
    @discardableResult
    public static func delete(_ urls: [URL]) -> Int {
        urls.reduce(into: 0) { total, url in
            if delete(url) { total += 1 }
        }
    }
}