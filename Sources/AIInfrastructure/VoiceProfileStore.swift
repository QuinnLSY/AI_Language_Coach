import AIDomain
import AppCore
import Foundation

/// 克隆音色档案仓库（Implementation Plan §28 Phase 24）。
///
/// 与 `ConfigStore` **分开存放**是有意的：
/// - `config.json` 是「应用怎么跑」的配置，用户重置配置 / 换模型时不该牵连音色授权；
/// - 音色档案是**用户资产**（参考音频路径 + 授权记录），要能单独备份与审计；
/// - 授权留痕放在独立的文件里，将来做「导出我授权过什么」这类功能才有据可依。
///
/// 写入仍然只有一条路（本 actor 的 `upsert` / `remove`），不做缓存副本，
/// 因此不存在「内存里改了、文件里没改」的漂移。
public actor VoiceProfileStore {

    public static let shared = VoiceProfileStore()

    private var profiles: [VoiceProfile]
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        // 读不出来（文件不存在 / 写坏）时按「还没有任何音色」处理，
        // **不删也不改名**：授权留痕宁可留着让人来查，也不能悄悄丢掉。
        self.profiles = Self.read(from: self.fileURL) ?? []
    }

    /// 默认落 `.workbuddy/app-config/voice-profiles.json`（项目空间内，不进 git）。
    public static func defaultFileURL() -> URL {
        AppPaths.userDataDirectory().appendingPathComponent("voice-profiles.json")
    }

    public var all: [VoiceProfile] { profiles }
    public var storageLocation: URL { fileURL }
    public var isEmpty: Bool { profiles.isEmpty }

    /// 参考音频（克隆音色的样本）存放目录：`voice-profiles.json` 旁边的 `voices/`。
    ///
    /// **从 `fileURL` 派生，不直接读 `AppPaths`** —— 这样注入一个临时 `fileURL` 的仓库
    /// 连音频目录一起被隔离。原先 `CoachServices.importVoiceReference` 自己拼
    /// `AppPaths.userDataDirectory()/voices`，于是测试进程（同罪：会写真实数据目录）
    /// 一碰「保存音色」就会在开发机的 `.workbuddy/app-config/` 里造目录。
    public var referenceAudioDirectory: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("voices", isDirectory: true)
    }

    public func profile(id: String) -> VoiceProfile? {
        profiles.first { $0.id == id }
    }

    /// 新增或按 id 覆盖（覆盖不改变创建时间以外的字段语义，由调用方给完整档案）。
    public func upsert(_ profile: VoiceProfile) throws {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        try persist()
    }

    @discardableResult
    public func remove(id: String) throws -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return false }
        profiles.remove(at: index)
        try persist()
        return true
    }

    // MARK: - 持久化

    private func persist() throws {
        do {
            try Self.write(profiles, to: fileURL)
        } catch {
            throw AppError.storage("保存音色档案失败：\(error.localizedDescription)")
        }
    }

    private static func read(from url: URL) -> [VoiceProfile]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode([VoiceProfile].self, from: data)
    }

    private static func write(_ profiles: [VoiceProfile], to url: URL) throws {
        // 目录可能还不存在（首次运行 / 手工清过 app-config）。
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(profiles).write(to: url, options: .atomic)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
