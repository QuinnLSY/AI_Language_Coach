import AIDomain
import Foundation

/// 用户材料的落盘仓库：一份材料一个 JSON，落在 `.workbuddy/app-config/materials/`。
///
/// 与 `DictionaryBookStore` 同构：一个 actor 管一个目录，写入只有一条路。
/// **坏文件不删**：单个 JSON 写坏只跳过那一份（并在 `corruptIDs` 里留个名），
/// 绝不悄悄清空整个目录 —— 材料是学员亲手挑的，丢了没法再生。
public actor MaterialStore {

    private let directory: URL
    /// 读坏了的文件名（诊断用，UI 不展示）。
    public private(set) var corruptIDs: [String] = []

    public init(directory: URL? = nil) {
        let base = AppPaths.userDataDirectory()
        self.directory = directory ?? base.appendingPathComponent("materials", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    /// 全部材料（按生成时间倒序）。每次都从盘上读：材料是个位数规模，不值得做缓存失效。
    public func all() -> [MaterialKit] {
        corruptIDs = []
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> MaterialKit? in
                guard let data = try? Data(contentsOf: url) else {
                    corruptIDs.append(url.lastPathComponent)
                    return nil
                }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                guard let kit = try? decoder.decode(MaterialKit.self, from: data) else {
                    corruptIDs.append(url.lastPathComponent)
                    return nil
                }
                return kit
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// 落盘一份材料（同 id 覆盖 —— 重复生成是更新，不是堆积）。
    public func save(_ kit: MaterialKit) throws {
        let url = directory.appendingPathComponent("\(kit.id).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(kit)
        try data.write(to: url, options: .atomic)
    }

    public func delete(id: String) {
        // id 是「material-<hex>」，只可能是文件名本身；但仍拼一次 path 前缀，防手滑传绝对路径。
        let name = id.components(separatedBy: "/").last ?? id
        let url = directory.appendingPathComponent("\(name).json")
        try? FileManager.default.removeItem(at: url)
    }
}
