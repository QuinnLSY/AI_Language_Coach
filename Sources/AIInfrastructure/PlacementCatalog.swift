import AIDomain
import AppCore
import Foundation

/// 入学定级题库目录：**只从数据文件读取**，代码里不内置任何题目。
///
/// 与 `ShadowingCatalog` 同一套路：题放 `Resources/Placement/*.json`，
/// 增删题目只改数据文件。资源缺失时返回空数组，由 UI 如实说明
/// 「题库没读到」—— 不崩、不静默、更不内置几道兜底题假装能用
///（假题库会给出一个真结果，那比没有结果更糟）。
public enum PlacementCatalog {

    /// 随包发布的题库。
    public static func bundled() -> [PlacementQuestion] {
        loadBundled(logging: true)
    }

    /// 从指定目录读取全部 `*.json`（单测 / 将来支持自定义题库）。
    /// 单个文件坏了只跳过它（记告警），不影响其余。
    public static func load(from directory: URL, logging: Bool = false) -> [PlacementQuestion] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else {
            if logging { AppLog.warning("定级题库目录不可读：\(directory.path)", category: "placement") }
            return []
        }
        var questions: [PlacementQuestion] = []
        for url in entries.filter({ $0.pathExtension.lowercased() == "json" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                questions.append(contentsOf: try decode(try Data(contentsOf: url)))
            } catch {
                if logging {
                    AppLog.warning(
                        "定级题库解析失败（已跳过）\(url.lastPathComponent)：\(error)",
                        category: "placement"
                    )
                }
            }
        }
        return deduplicated(questions)
    }

    /// 解析一个题库文件。兼容 `{ "version": 1, "questions": [ … ] }` 与裸数组两种写法。
    public static func decode(_ data: Data) throws -> [PlacementQuestion] {
        let decoder = JSONDecoder()
        if let file = try? decoder.decode(PlacementQuestionFile.self, from: data) {
            return file.questions
        }
        return try decoder.decode([PlacementQuestion].self, from: data)
    }

    /// 去重（同 id 保留先出现的）→ 按档位升序、同档内按 id 稳定排序。
    ///
    /// 排序放在这里而不是出卷时：`EntrancePlacementRule.paper` 要按「池子顺序」
    /// 轮转取题，池子顺序不稳就等于同一颗种子每次抽到不同的题。
    public static func deduplicated(_ questions: [PlacementQuestion]) -> [PlacementQuestion] {
        var seen = Set<String>()
        var unique: [PlacementQuestion] = []
        for question in questions where seen.insert(question.id).inserted {
            unique.append(question)
        }
        return unique.sorted {
            if $0.level != $1.level { return $0.level < $1.level }
            return $0.id < $1.id
        }
    }

    // MARK: - 私有

    private static func loadBundled(logging: Bool) -> [PlacementQuestion] {
        // SwiftPM 把 `Resources` 整目录复制进资源 bundle，故题库在 `Placement/` 子目录下。
        if let directory = AppResourceBundle.url(forResource: "Placement", withExtension: nil) {
            let loaded = load(from: directory, logging: logging)
            if !loaded.isEmpty { return loaded }
        }
        // 兜底：直接按扩展名在子目录里找（不同打包方式对目录资源的处理略有差异）。
        if let urls = AppResourceBundle.urls(
            forResourcesWithExtension: "json", subdirectory: "Placement"
        ), !urls.isEmpty {
            let unique = deduplicated(urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
                .compactMap { url -> [PlacementQuestion]? in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return try? decode(data)
                }
                .flatMap { $0 })
            if !unique.isEmpty { return unique }
        }
        if logging { AppLog.warning("未找到入学定级题库（Resources/Placement/*.json）", category: "placement") }
        return []
    }
}

/// 题库文件（`Resources/Placement/*.json`）。
public struct PlacementQuestionFile: Codable, Sendable, Equatable {
    public var version: Int
    public var questions: [PlacementQuestion]

    public init(version: Int = 1, questions: [PlacementQuestion] = []) {
        self.version = version
        self.questions = questions
    }
}
