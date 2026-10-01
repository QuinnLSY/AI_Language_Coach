import AIDomain
import AppCore
import Foundation

/// 考卷目录：**只从数据文件读取**，不在代码里内置任何题目。
///
/// 依据与场景一致（Implementation Plan §21「Scenario logic should not be hard-coded」）：
/// 题目是学习内容，放 `Resources/Exams/*.json`；加一套考卷只需丢一个 JSON 进去。
public enum ExamCatalog {

    /// 随包发布的全部考卷。资源缺失或全部解析失败时返回空数组 ——
    /// 由 UI 展示「考卷资源缺失」的可操作提示，不崩也不静默当成功。
    public static func bundled() -> [ExamBlueprint] {
        loadBundled(logging: true)
    }

    /// 从指定目录读取全部 `*.json` 考卷（单测 / 未来自定义考卷入口）。
    /// - 单个文件损坏只跳过该文件（记录告警），不影响其余考卷。
    public static func load(from directory: URL, logging: Bool = false) -> [ExamBlueprint] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else {
            if logging { AppLog.warning("考卷目录不可读：\(directory.path)", category: "exam") }
            return []
        }
        let decoder = JSONDecoder()
        var blueprints: [ExamBlueprint] = []
        for url in entries
            .filter({ $0.pathExtension.lowercased() == "json" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                blueprints.append(try decoder.decode(ExamBlueprint.self, from: Data(contentsOf: url)))
            } catch {
                if logging {
                    AppLog.warning("考卷解析失败（已跳过）\(url.lastPathComponent)：\(error)", category: "exam")
                }
            }
        }
        return deduplicated(blueprints)
    }

    /// 同 id 保留先出现的。
    public static func deduplicated(_ blueprints: [ExamBlueprint]) -> [ExamBlueprint] {
        var seen = Set<String>()
        var unique: [ExamBlueprint] = []
        for blueprint in blueprints where seen.insert(blueprint.id).inserted {
            unique.append(blueprint)
        }
        return unique
    }

    /// 按形式分组（保持传入顺序；空环节的考卷不出现 —— 那种卷子进去就结束了）。
    public static func grouped(_ blueprints: [ExamBlueprint])
        -> [(format: ExamFormat, items: [ExamBlueprint])] {
        ExamFormat.allCases.compactMap { format in
            let items = blueprints.filter { $0.format == format && $0.questionCount > 0 }
            return items.isEmpty ? nil : (format, items)
        }
    }

    // MARK: - 私有

    private static func loadBundled(logging: Bool) -> [ExamBlueprint] {
        // SwiftPM 会把 `Resources` 整目录复制进资源 bundle，故考卷在 `Exams/` 子目录下。
        if let directory = AppResourceBundle.url(forResource: "Exams", withExtension: nil) {
            let loaded = load(from: directory, logging: logging)
            if !loaded.isEmpty { return loaded }
        }
        // 兜底：直接按扩展名在子目录中查找（不同打包方式对目录资源的处理略有差异）。
        if let urls = AppResourceBundle.urls(
            forResourcesWithExtension: "json", subdirectory: "Exams"
        ), !urls.isEmpty {
            let decoder = JSONDecoder()
            let loaded = urls
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                .compactMap { url -> ExamBlueprint? in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return try? decoder.decode(ExamBlueprint.self, from: data)
                }
            let unique = deduplicated(loaded)
            if !unique.isEmpty { return unique }
        }
        if logging { AppLog.warning("未找到内置考卷资源（Resources/Exams/*.json）", category: "exam") }
        return []
    }
}
