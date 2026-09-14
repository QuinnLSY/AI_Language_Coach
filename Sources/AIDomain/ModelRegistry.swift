import AppCore
import Foundation

// MARK: - 模型注册表（Implementation Plan §7 Phase 3 — Managers and Model Registry）
//
// 设计上最要紧的一条：**不引入第二真相源**。
// 项目里「哪个 Provider 生效」的唯一真相源是 `AppConfiguration`
// （`provider.enabled` + `product.activeProviders`），写入只能走 `ConfigStore`。
// 如果注册表自己再存一份「当前默认 Provider」，两边迟早不一致 ——
// 那种不一致的表现就是「设置页显示已启用，实际调用却走了另一个模型」。
//
// 所以这里是一个**纯函数视图 + 纯函数变换**：
//   - 读：把 `AppConfiguration` 投影成 `[ModelConfig]`（含可用性 / 生效判定）；
//   - 写：返回变换后的 `AppConfiguration`，由调用方经 `ConfigStore` 落盘。
// 于是它天然可单测（不需要网络、不需要 actor），也天然不会和配置漂移。

/// 一个可选模型的**配置视图**（只读投影，不持久化）。
public struct ModelConfig: Sendable, Equatable, Identifiable {
    /// Provider id（与 `ProviderConfig.id` 一致）。
    public var id: String
    public var kind: AIProviderKind
    /// 用户可见名（如「本地模型」「DeepSeek」）。
    public var provider: String
    public var runtime: RuntimeKind
    /// 当前模型名（nil = 还没选 / Provider 没配默认）。
    public var model: String?
    public var candidateModels: [String]
    public var endpoint: String?
    /// Provider 是否处于启用状态。
    public var isEnabled: Bool
    /// 配置是否真的可用（云端必须已填 Key，见 `ProviderConfig.isUsable`）。
    public var isUsable: Bool
    /// 是不是该能力**当前生效**的那一个。
    public var isActive: Bool
    public var isRemote: Bool

    public init(
        id: String,
        kind: AIProviderKind,
        provider: String,
        runtime: RuntimeKind,
        model: String? = nil,
        candidateModels: [String] = [],
        endpoint: String? = nil,
        isEnabled: Bool = false,
        isUsable: Bool = true,
        isActive: Bool = false,
        isRemote: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.provider = provider
        self.runtime = runtime
        self.model = model
        self.candidateModels = candidateModels
        self.endpoint = endpoint
        self.isEnabled = isEnabled
        self.isUsable = isUsable
        self.isActive = isActive
        self.isRemote = isRemote
    }
}

/// 模型的运行时元信息（由 Adapter 自报，注册表只搬运）。
public struct ModelMetadata: Sendable, Equatable {
    public var id: String
    public var kind: AIProviderKind
    public var displayName: String
    public var runtime: RuntimeKind
    public var version: String?

    public init(id: String, kind: AIProviderKind, displayName: String, runtime: RuntimeKind, version: String? = nil) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.runtime = runtime
        self.version = version
    }
}

/// 健康检查的**委派目标**。
///
/// 注册表不自己探活：探活要发网络请求、要看 runtime 进程状态，属于 Manager / Adapter 的职责。
/// 这里只回答「该由谁去探、探哪儿」——「宁可给指引，也不给一个永远是 true 的假健康」。
public struct HealthTarget: Sendable, Equatable {
    public var providerID: String
    public var kind: AIProviderKind
    public var endpoint: String?
    /// 需要满足的前置条件（如「云端需填 API Key」），UI 可直接展示。
    public var prerequisite: String?

    public init(providerID: String, kind: AIProviderKind, endpoint: String? = nil, prerequisite: String? = nil) {
        self.providerID = providerID
        self.kind = kind
        self.endpoint = endpoint
        self.prerequisite = prerequisite
    }
}

public enum ModelRegistry {

    // MARK: - 读

    /// 列出可选的 Provider 视图。`kind` 为 nil 时列出全部。
    ///
    /// `activeID` 由调用方传入（= `product.activeProvider(for:)`），
    /// 这样注册表不用自己判断「谁生效」，只做投影、不持有状态。
    public static func listAvailable(
        _ configuration: AppConfiguration,
        kind: AIProviderKind? = nil
    ) -> [ModelConfig] {
        configuration.providers
            .filter { kind == nil || $0.kind == kind }
            .map { provider in
                ModelConfig(
                    id: provider.id,
                    kind: provider.kind,
                    provider: provider.userFacingName,
                    runtime: provider.runtime,
                    model: provider.model,
                    candidateModels: provider.candidateModels,
                    endpoint: provider.endpoint,
                    isEnabled: provider.enabled,
                    isUsable: provider.isUsable,
                    isActive: configuration.product.activeProvider(for: provider.kind) == provider.id,
                    isRemote: provider.isRemote
                )
            }
    }

    /// 某能力当前**生效**的那一个（委托 `AppConfiguration.resolvedProvider`，
    /// 不在注册表里重写一遍选择逻辑 —— 重写就会漂移）。
    public static func getDefault(_ configuration: AppConfiguration, for kind: AIProviderKind) -> ModelConfig? {
        guard let provider = configuration.resolvedProvider(for: kind) else { return nil }
        return listAvailable(configuration, kind: kind).first { $0.id == provider.id }
    }

    /// 该能力应当由谁去探活（nil = 没有可探的目标，UI 应提示用户先配 Provider）。
    public static func healthTarget(_ configuration: AppConfiguration, for kind: AIProviderKind) -> HealthTarget? {
        guard let provider = configuration.resolvedProvider(for: kind) else { return nil }
        return HealthTarget(
            providerID: provider.id,
            kind: kind,
            endpoint: provider.endpoint,
            prerequisite: provider.requiresAPIKey && !provider.isUsable ? "需要先填写 API Key" : nil
        )
    }

    // MARK: - 写（纯变换；落盘交给 ConfigStore）

    /// 注册（或按 id 覆盖）一个 Provider。
    public static func register(_ configuration: inout AppConfiguration, _ provider: ProviderConfig) {
        if let index = configuration.providers.firstIndex(where: { $0.id == provider.id }) {
            configuration.providers[index] = provider
        } else {
            configuration.providers.append(provider)
        }
    }

    /// 注销一个 Provider；若它正是当前生效的，一并把产品层的指向清掉
    /// （留下一个指向不存在 Provider 的 activeID 会变成幽灵状态）。
    @discardableResult
    public static func unregister(_ configuration: inout AppConfiguration, providerID: String) -> Bool {
        guard let index = configuration.providers.firstIndex(where: { $0.id == providerID }) else { return false }
        let kind = configuration.providers[index].kind
        configuration.providers.remove(at: index)
        if configuration.product.activeProvider(for: kind) == providerID {
            configuration.product.activateProvider(nil, for: kind)
        }
        return true
    }

    /// 启用某个 Provider：**同类只留一个**（与 `setCapabilityProvider` 同口径），
    /// 并把产品层选中模型对齐到该 Provider 自己的模型（没配就清空，绝不拿候选清单顶替）。
    @discardableResult
    public static func enable(_ configuration: inout AppConfiguration, providerID: String) -> Bool {
        guard let target = configuration.providers.first(where: { $0.id == providerID }) else { return false }
        let kind = target.kind
        for index in configuration.providers.indices where configuration.providers[index].kind == kind {
            configuration.providers[index].enabled = configuration.providers[index].id == providerID
        }
        let aligned = (target.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.product.activateProvider(providerID, for: kind)
        configuration.product.selectModel(aligned.isEmpty ? nil : aligned, for: kind)
        return true
    }

    /// 停用某个 Provider。它是当前生效的那一个时，产品层指向一并清空 ——
    /// 否则解析生效 Provider 时会以为用户选的是一个已停用的条目。
    @discardableResult
    public static func disable(_ configuration: inout AppConfiguration, providerID: String) -> Bool {
        guard let index = configuration.providers.firstIndex(where: { $0.id == providerID }) else { return false }
        configuration.providers[index].enabled = false
        let kind = configuration.providers[index].kind
        if configuration.product.activeProvider(for: kind) == providerID {
            configuration.product.activateProvider(nil, for: kind)
        }
        return true
    }

    /// 设默认（等价于启用）：保留 `setDefault` 这个名字以对齐计划的操作清单。
    @discardableResult
    public static func setDefault(_ configuration: inout AppConfiguration, providerID: String) -> Bool {
        enable(&configuration, providerID: providerID)
    }

    // MARK: - 一致性

    /// 体检：找出会让「生效 Provider」解析不出来的配置问题。
    ///
    /// 覆盖两个真实踩过的坑：activeID 指向不存在的 Provider、activeID 指向已停用/无 Key 的 Provider。
    public static func inconsistencies(_ configuration: AppConfiguration, kind: AIProviderKind) -> [String] {
        var problems: [String] = []
        let candidates = configuration.providers.filter { $0.kind == kind }
        if candidates.isEmpty {
            problems.append("没有任何\(kind.displayName) Provider")
            return problems
        }
        if let activeID = configuration.product.activeProvider(for: kind) {
            guard let active = candidates.first(where: { $0.id == activeID }) else {
                problems.append("生效的\(kind.displayName) Provider 已不存在：\(activeID)")
                return problems
            }
            if !active.enabled { problems.append("生效的\(kind.displayName) Provider 已停用：\(active.userFacingName)") }
            if !active.isUsable { problems.append("生效的\(kind.displayName) Provider 缺少 API Key：\(active.userFacingName)") }
        } else {
            let enabled = candidates.filter(\.enabled)
            if enabled.isEmpty { problems.append("没有启用的\(kind.displayName) Provider") }
            if !enabled.contains(where: \.isUsable) { problems.append("启用的\(kind.displayName) Provider 都不可用") }
        }
        return problems
    }
}
