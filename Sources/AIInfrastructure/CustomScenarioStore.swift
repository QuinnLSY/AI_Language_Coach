import AIDomain
import Foundation

/// 用户自建情景的落盘仓库：一份草稿一个 JSON，落在 `.workbuddy/app-config/scenarios/`。
///
/// 与 `MaterialStore` 同构：一个 actor 管一个目录，写入只有一条路。
/// **坏文件不删**：单个 JSON 写坏只跳过那一份（并在 `corruptIDs` 里留个名），
/// 绝不悄悄清空整个目录 —— 情景是学员自己一句话一句话描述出来的，丢了没法再生。
///
/// ⚠️ 与**内置**情景（`Resources/Scenarios/*.json`，随包只读）是两个地方：
/// 内置的在 app bundle 里、由 `ScenarioCatalog.bundled()` 读；这里的在用户数据目录、
/// 由本 actor 读。两处互不污染，删掉整个用户目录也只是回到「只有内置情景」。
public actor CustomScenarioStore {

    private let directory: URL
    /// 读坏了的文件名（诊断用，UI 不展示）。
    public private(set) var corruptIDs: [String] = []

    public init(directory: URL? = nil) {
        let base = AppPaths.userDataDirectory()
        self.directory = directory ?? base.appendingPathComponent("scenarios", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    /// 全部草稿（按生成时间倒序）。
    ///
    /// 每次从盘上读、不做进程内缓存：草稿是个位数规模，少一个缓存就少一个失效点
    /// （生成 / 删除之后 `availableScenarios` 的缓存才是真正要刷的那个）。
    public func all() -> [ScenarioDraft] {
        corruptIDs = []
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> ScenarioDraft? in
                guard let data = try? Data(contentsOf: url) else {
                    corruptIDs.append(url.lastPathComponent)
                    return nil
                }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                guard let draft = try? decoder.decode(ScenarioDraft.self, from: data) else {
                    corruptIDs.append(url.lastPathComponent)
                    return nil
                }
                return draft
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// 落盘一份草稿（同 id 覆盖 —— 同一句话重复生成是更新，不是堆积）。
    public func save(_ draft: ScenarioDraft) throws {
        let url = directory.appendingPathComponent("\(draft.id).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(draft).write(to: url, options: .atomic)
    }

    /// 删除一份草稿（对应情景立即从「我的情景」里消失）。
    public func delete(id: String) {
        // id 是「custom-scenario-<hex>」，只可能是文件名本身；仍拼一次前缀防手滑传绝对路径。
        let name = id.components(separatedBy: "/").last ?? id
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(name).json"))
    }
}
