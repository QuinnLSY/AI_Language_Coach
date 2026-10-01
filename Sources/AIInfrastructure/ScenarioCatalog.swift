import AIDomain
import AppCore
import Foundation

/// 场景目录：**只从数据文件读取场景**，不在代码里内置任何场景内容。
///
/// 依据 Implementation Plan §21「Scenario logic should not be hard-coded」：
/// 内置场景放 `Resources/Scenarios/*.json`，未来用户自定义场景只需把 JSON 丢进目录即可扩展。
public enum ScenarioCatalog {

    /// 随包发布的内置场景（Bundle 资源）。
    /// 资源缺失或全部解析失败时返回空数组——由 UI 展示「场景资源缺失」的可操作提示，不崩不静默。
    public static func bundled() -> [Scenario] {
        loadBundled(logging: true)
    }

    /// 从指定目录读取全部 `*.json` 场景（单测 / 未来用户自定义场景入口）。
    /// - 单个文件损坏只跳过该文件（记录告警），不影响其余场景。
    public static func load(from directory: URL, logging: Bool = false) -> [Scenario] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else {
            if logging { AppLog.warning("场景目录不可读：\(directory.path)", category: "scenario") }
            return []
        }
        let decoder = JSONDecoder()
        var scenarios: [Scenario] = []
        for url in entries.filter({ $0.pathExtension.lowercased() == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                let data = try Data(contentsOf: url)
                scenarios.append(try decoder.decode(Scenario.self, from: data))
            } catch {
                if logging {
                    AppLog.warning("场景文件解析失败（已跳过）\(url.lastPathComponent)：\(error)", category: "scenario")
                }
            }
        }
        return deduplicated(scenarios)
    }

    /// 解析并去重（同 id 保留先出现的），并按难度 → 标题稳定排序。
    public static func deduplicated(_ scenarios: [Scenario]) -> [Scenario] {
        var seen = Set<String>()
        var unique: [Scenario] = []
        for scenario in scenarios where seen.insert(scenario.id).inserted {
            unique.append(scenario)
        }
        return unique.sorted {
            $0.difficulty == $1.difficulty ? $0.title < $1.title : $0.difficulty < $1.difficulty
        }
    }

    /// 按分组归类（保持传入顺序；分组名按首次出现顺序）。
    public static func grouped(_ scenarios: [Scenario]) -> [(category: String, items: [Scenario])] {
        Scenario.groups(scenarios)
    }

    // MARK: - 私有

    private static func loadBundled(logging: Bool) -> [Scenario] {
        // SwiftPM 会把 `Resources` 整目录复制进资源 bundle，故场景在 `Scenarios/` 子目录下。
        if let directory = AppResourceBundle.url(forResource: "Scenarios", withExtension: nil) {
            let loaded = load(from: directory, logging: logging)
            if !loaded.isEmpty { return loaded }
        }
        // 兜底：直接按扩展名在子目录中查找（不同打包方式对目录资源的处理略有差异）。
        if let urls = AppResourceBundle.urls(forResourcesWithExtension: "json", subdirectory: "Scenarios"), !urls.isEmpty {
            let decoder = JSONDecoder()
            let scenarios = urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).compactMap { url -> Scenario? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(Scenario.self, from: data)
            }
            let unique = deduplicated(scenarios)
            if !unique.isEmpty { return unique }
        }
        if logging { AppLog.warning("未找到内置场景资源（Resources/Scenarios/*.json）", category: "scenario") }
        return []
    }
}
