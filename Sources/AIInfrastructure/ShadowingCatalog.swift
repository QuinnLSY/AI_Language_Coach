import AIDomain
import AppCore
import Foundation

/// 跟读素材目录：**只从数据文件读取**，代码里不内置任何句子。
///
/// 依据 Implementation Plan §22「Shadowing」与 §21 的数据驱动原则：
/// 素材放 `Resources/Shadowing/*.json`，未来增删素材只改数据文件，不动代码。
public enum ShadowingCatalog {

    /// 随包发布的内置素材。资源缺失或全部解析失败时返回空数组——
    /// 由 UI 展示「素材资源缺失」的可操作提示，不崩、不静默、不内置兜底句子。
    public static func bundled() -> [ShadowingDrill] {
        loadBundled(logging: true)
    }

    /// 从指定目录读取全部 `*.json` 素材（单测 / 未来用户自定义素材入口）。
    /// 单个文件损坏只跳过该文件（记告警），不影响其余素材。
    public static func load(from directory: URL, logging: Bool = false) -> [ShadowingDrill] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else {
            if logging { AppLog.warning("跟读素材目录不可读：\(directory.path)", category: "shadowing") }
            return []
        }
        let decoder = JSONDecoder()
        var drills: [ShadowingDrill] = []
        let files = entries
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in files {
            do {
                let data = try Data(contentsOf: url)
                drills.append(contentsOf: try decode(data))
            } catch {
                if logging {
                    AppLog.warning("跟读素材解析失败（已跳过）\(url.lastPathComponent)：\(error)", category: "shadowing")
                }
            }
        }
        return deduplicated(drills)
    }

    /// 解析一个素材文件。兼容两种写法：
    /// - `{ "version": 1, "drills": [ … ] }`（推荐，便于将来加字段）
    /// - `[ … ]`（裸数组，手写素材时更省事）
    public static func decode(_ data: Data) throws -> [ShadowingDrill] {
        let decoder = JSONDecoder()
        if let file = try? decoder.decode(ShadowingDrillFile.self, from: data) {
            return file.drills
        }
        return try decoder.decode([ShadowingDrill].self, from: data)
    }

    /// 去重（同 id 保留先出现的）→ 按难度升序、同难度按主题稳定排序。
    public static func deduplicated(_ drills: [ShadowingDrill]) -> [ShadowingDrill] {
        var seen = Set<String>()
        var unique: [ShadowingDrill] = []
        for drill in drills where seen.insert(drill.id).inserted {
            unique.append(drill)
        }
        return unique.sorted {
            if $0.difficulty != $1.difficulty { return $0.difficulty < $1.difficulty }
            if $0.topic != $1.topic { return $0.topic < $1.topic }
            return $0.id < $1.id
        }
    }

    /// 按主题分组（保持素材顺序；分组名按首次出现顺序）。
    public static func grouped(_ drills: [ShadowingDrill]) -> [(topic: String, items: [ShadowingDrill])] {
        var order: [String] = []
        var buckets: [String: [ShadowingDrill]] = [:]
        for drill in drills {
            let key = drill.topic.isEmpty ? "其他" : drill.topic
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(drill)
        }
        return order.map { (topic: $0, items: buckets[$0] ?? []) }
    }

    // MARK: - 私有

    private static func loadBundled(logging: Bool) -> [ShadowingDrill] {
        // SwiftPM 把 `Resources` 整目录复制进资源 bundle，故素材在 `Shadowing/` 子目录下。
        if let directory = AppResourceBundle.module.url(forResource: "Shadowing", withExtension: nil) {
            let loaded = load(from: directory, logging: logging)
            if !loaded.isEmpty { return loaded }
        }
        // 兜底：直接按扩展名在子目录里找（不同打包方式对目录资源的处理略有差异）。
        if let urls = AppResourceBundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Shadowing"),
           !urls.isEmpty {
            let unique = deduplicated(urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
                .compactMap { url -> [ShadowingDrill]? in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return try? decode(data)
                }
                .flatMap { $0 })
            if !unique.isEmpty { return unique }
        }
        if logging { AppLog.warning("未找到内置跟读素材（Resources/Shadowing/*.json）", category: "shadowing") }
        return []
    }
}
