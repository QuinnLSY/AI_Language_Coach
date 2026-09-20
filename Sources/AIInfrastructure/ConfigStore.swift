import AppCore
import Foundation

// MARK: - 内置默认配置（来自 Resources/Config，代码内不含任何模型/端点字面量）

public enum DefaultConfiguration {
    public static func load() throws -> AppConfiguration {
        guard let url = AppResourceBundle.module.url(forResource: "Config/default-config", withExtension: "json") else {
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
///
/// ⚠️ **发布版必须有可写的数据目录**。历史实现直接用编译期 `#filePath` 上溯找 `Sources`
/// 目录并在旁边建 `.workbuddy/app-config/`：只做字符串上溯、不校验存在性，
/// 于是分发出去的 `.app` 里那串路径是**构建机**的源码路径。在别人机器上
/// `/Users/<构建者>/` 通常连创建权限都没有 → `createDirectory` 被 `try?` 吞掉 →
/// 配置 / learning.db / 音色档案**全部写不进去且一声不响**。
/// 现在改为：项目空间目录**必须在本机真实可写**才用，否则退到 Application Support。
public enum AppPaths {

    /// 数据根目录。解析要做一次可写性探测，而它被全项目高频调用，故缓存一次。
    public static func userDataDirectory() -> URL { resolvedUserDataDirectory }

    private static let resolvedUserDataDirectory: URL = resolveDataDirectory(
        projectRoot: projectRoot,
        supportBase: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
        tempBase: FileManager.default.temporaryDirectory
    )

    /// 数据目录决策本体（三级降级）。抽成函数是为了让**三个分支都能被测试**：
    /// 真机上发布环境那两档没法伪造，不抽出来就只能靠人眼。
    static func resolveDataDirectory(projectRoot: URL?, supportBase: URL?, tempBase: URL) -> URL {
        // 1) 开发环境：项目空间内 `.workbuddy/app-config/`（不进 git）。
        //    这一档必须排在前面：开发机上 `swift run` 与打包后的 .app 要共用同一份数据，
        //    否则同一个人的进度会分成两套。（`projectRoot` 已校验「本机真的存在」，
        //    所以分发出去的 .app 会在这一步落空，自然走下一档。）
        if let projectRoot,
           let directory = usableDirectory(
               projectRoot.appendingPathComponent(".workbuddy/app-config", isDirectory: true),
               label: "项目空间"
           ) {
            return directory
        }

        // 2) 发布环境（或项目空间不可写）：系统应用支持目录。
        if let supportBase,
           let directory = usableDirectory(
               supportBase.appendingPathComponent("AILanguageCoach", isDirectory: true),
               label: "应用支持目录"
           ) {
            return directory
        }

        // 3) 最后一档：临时目录。走到这里说明连 Application Support 都建不出来，
        //    数据会随重启丢失——必须留下明确记录，不许静默。
        let fallback = tempBase.appendingPathComponent("AILanguageCoach", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        AppLog.error(
            "数据目录降级到临时目录（重启后会丢）：\(fallback.path)。请检查磁盘权限。",
            category: "paths"
        )
        return fallback
    }

    /// 建目录并确认**真的可写**；任一步失败都记一条 warning 后返回 nil。
    private static func usableDirectory(_ url: URL, label: String) -> URL? {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            AppLog.warning("数据目录不可建（\(label)：\(url.path)）：\(error.localizedDescription)", category: "paths")
            return nil
        }
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            AppLog.warning("数据目录不可写（\(label)：\(url.path)），改走下一档", category: "paths")
            return nil
        }
        return url
    }

    /// 通过 `#filePath`（编译期源码路径）向上定位包含 `Sources` 的项目根。
    ///
    /// ⚠️ 必须再校验一次「本机真的存在这个目录」：`#filePath` 是**编译期**常量，
    /// 打包分发后它指向构建机的源码树。只做字符串上溯的话，任何机器上都会
    /// 得到一个「看起来合理、实际不存在」的路径。
    public static let projectRoot: URL? = {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent() // .../Sources/AIInfrastructure
        for _ in 0..<6 {
            if url.lastPathComponent == "Sources" {
                let root = url.deletingLastPathComponent()
                let sources = root.appendingPathComponent("Sources", isDirectory: true)
                guard FileManager.default.fileExists(atPath: sources.path) else { return nil }
                return root
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
    /// 内置默认配置载入失败的原因（nil = 正常）。
    ///
    /// ⚠️ 以前这里是 `(try? load()) ?? AppConfiguration()`：载入失败会**静默**退成一份
    /// 「零 provider」配置，表现是「应用里一个模型都没有」却没有任何提示，极难排查。
    /// 现在把原因留下来给设置页展示，同时落一条 error 日志。
    private var loadFailure: String?

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        let (base, failure) = Self.loadBase()
        self.configuration = base
        self.loadFailure = failure
        if let saved = try? Self.read(from: self.fileURL) {
            self.configuration = Self.merge(base: self.configuration, override: saved)
        }
    }

    /// 用户配置默认写回**项目空间内**（`.workbuddy/app-config/`，不进 git）。
    public static func defaultFileURL() -> URL {
        AppPaths.userDataDirectory().appendingPathComponent("config.json")
    }

    public var current: AppConfiguration { configuration }
    /// 用户覆盖层（`config.json`）的绝对路径。设置页「在 Finder 中打开」用它。
    public var storageLocation: URL { fileURL }
    /// 内置默认配置载入失败的原因（nil = 正常）。
    public var loadFailureReason: String? { loadFailure }

    /// 重新从磁盘载入：内置默认配置 + 用户覆盖层。
    ///
    /// 用途：外部手改了 `config.json`（或把备份的配置拷回来）之后不必重启应用。
    public func reload() {
        let (base, failure) = Self.loadBase()
        configuration = base
        loadFailure = failure
        if let saved = try? Self.read(from: fileURL) {
            configuration = Self.merge(base: configuration, override: saved)
        }
        AppLog.info("配置已重新载入（\(configuration.providers.count) 个供应商）", category: "config")
    }

    /// 载入内置默认配置。失败时**留痕**，不静默吞掉。
    private static func loadBase() -> (AppConfiguration, String?) {
        do {
            return (try DefaultConfiguration.load(), nil)
        } catch {
            let reason = "内置默认配置载入失败：\(error.localizedDescription)"
            AppLog.error(reason + "（本次以空配置启动）", category: "config")
            return (AppConfiguration(), reason)
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

    // MARK: - 原子局部更新
    //
    // ⚠️ 调用方**不要**在函数开头 `let configuration = await config.current` 然后再
    // `updateProvider(...)` 逐个写回：那用的是**过期快照**，同一批写入里后一个字段会
    // 把前一个刚写的字段覆盖回旧值（实测把刚保存的 API Key / 模型名抹成空，
    // 表现为「显示已启用云端，卡片却写着未配置 / 未填写 API Key」）。
    // 需要改配置时一律走下面三个方法：在 actor 内部对着**最新**值做局部修改。

    /// 原子修改单个 Provider 的字段（基于最新配置，只动闭包里改过的字段）。
    @discardableResult
    public func mutateProvider(id: String, _ body: @Sendable (inout ProviderConfig) -> Void) throws -> Bool {
        guard let index = configuration.providers.firstIndex(where: { $0.id == id }) else { return false }
        body(&configuration.providers[index])
        try persist()
        return true
    }

    /// 原子修改某一类能力的**全部** Provider（如「只保留一个 enabled」）。
    public func mutateProviders(kind: AIProviderKind, _ body: @Sendable (inout ProviderConfig) -> Void) throws {
        for index in configuration.providers.indices where configuration.providers[index].kind == kind {
            body(&configuration.providers[index])
        }
        try persist()
    }

    /// 原子修改产品配置（只动闭包里改过的字段）。
    public func mutateProduct(_ body: @Sendable (inout ProductConfig) -> Void) throws {
        body(&configuration.product)
        try persist()
    }

    /// 原子应用一次**整份配置**变换。
    ///
    /// 供 `ModelRegistry` 这类纯逻辑层使用：变换在 actor 内部对着**最新**值执行
    /// （不会出现「取快照再写回」覆盖并发写入的老问题），
    /// 而落盘依然只有这一条路 —— 注册表不持有状态，也就不会长出第二份真相。
    public func mutate(_ body: @Sendable (inout AppConfiguration) -> Void) throws {
        body(&configuration)
        try persist()
    }

    /// 资源管理策略（第 27 步，AUTO_MANAGED 级别）：暂无 UI 入口，供配置与测试调整。
    public func mutateResourcePolicy(_ body: @Sendable (inout ResourcePolicyConfig) -> Void) throws {
        body(&configuration.resourcePolicy)
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
        result.resourcePolicy = override.resourcePolicy
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
