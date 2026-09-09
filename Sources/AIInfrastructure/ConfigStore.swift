import AIInterfaces
import AppCore
import Foundation

// MARK: - 内置默认配置（来自 Resources/Config，代码内不含任何模型/端点字面量）

public enum DefaultConfiguration {
    public static func load() throws -> AppConfiguration {
        guard let url = Bundle.module.url(forResource: "Config/default-config", withExtension: "json") else {
            throw AppError.configuration("缺少内置默认配置 default-config.json")
        }
        let data = try Data(contentsOf: url)
        return try Self.decoder.decode(AppConfiguration.self, from: data)
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

// MARK: - 应用路径

/// 统一的项目空间路径定位。约束来自用户要求：所有文件操作仅限项目空间。
public enum AppPaths {

    /// 用户数据默认写回**项目空间内**（`.workbuddy/app-config/`，不进 git）。
    /// 找不到项目根（例如未来打包成 .app 发布）时才回退到系统应用支持目录。
    public static func userDataDirectory() -> URL {
        if let projectRoot {
            let directory = projectRoot.appendingPathComponent(".workbuddy/app-config", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("AILanguageCoach", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 通过 `#filePath`（编译期源码路径）向上定位包含 `Sources` 的项目根。
    public static let projectRoot: URL? = {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent() // .../Sources/AIInfrastructure
        for _ in 0..<6 {
            if url.lastPathComponent == "Sources" {
                return url.deletingLastPathComponent()
            }
            url = url.deletingLastPathComponent()
        }
        return nil
    }()
}

// MARK: - 配置仓库

/// 配置仓库：内置默认配置 + 用户覆盖层。
/// 用户覆盖写入应用支持目录；写入失败时降级为「仅内存中生效」，不影响使用。
public actor ConfigStore {

    public static let shared = ConfigStore()

    private var configuration: AppConfiguration
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.configuration = (try? DefaultConfiguration.load()) ?? AppConfiguration()
        if let saved = try? Self.read(from: self.fileURL) {
            self.configuration = Self.merge(base: self.configuration, override: saved)
        }
    }

    /// 用户配置默认写回**项目空间内**（`.workbuddy/app-config/`，不进 git）。
    public static func defaultFileURL() -> URL {
        AppPaths.userDataDirectory().appendingPathComponent("config.json")
    }

    public var current: AppConfiguration { configuration }
    public var storageLocation: URL { fileURL }

    public func reload() {
        configuration = (try? DefaultConfiguration.load()) ?? AppConfiguration()
        if let saved = try? Self.read(from: fileURL) {
            configuration = Self.merge(base: configuration, override: saved)
        }
    }

    public func updateProduct(_ product: ProductConfig) throws {
        configuration.product = product
        try persist()
    }

    public func selectModel(_ model: String, for kind: AIProviderKind) throws {
        configuration.product.selectModel(model, for: kind)
        try persist()
    }

    public func updateProvider(_ provider: ProviderConfig) throws {
        if let index = configuration.providers.firstIndex(where: { $0.id == provider.id }) {
            configuration.providers[index] = provider
        } else {
            configuration.providers.append(provider)
        }
        try persist()
    }

    // MARK: - 持久化

    private func persist() throws {
        do {
            try Self.write(configuration, to: fileURL)
        } catch {
            throw AppError.storage("保存配置失败：\(error.localizedDescription)")
        }
    }

    private static func read(from url: URL) throws -> AppConfiguration {
        let data = try Data(contentsOf: url)
        return try decoder.decode(AppConfiguration.self, from: data)
    }

    private static func write(_ configuration: AppConfiguration, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        try data.write(to: url, options: .atomic)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// 用户覆盖层与默认配置合并：产品字段整体覆盖，Provider 按 id 覆盖。
    private static func merge(base: AppConfiguration, override: AppConfiguration) -> AppConfiguration {
        var result = base
        result.product = override.product
        for provider in override.providers {
            if let index = result.providers.firstIndex(where: { $0.id == provider.id }) {
                result.providers[index] = provider
            } else {
                result.providers.append(provider)
            }
        }
        return result
    }
}
