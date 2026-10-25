import AIInterfaces
import AIDomain
import AppCore
import Foundation

/// 云端「模型目录」的短时缓存（#671）。
///
/// 为什么需要它：开屏链路把同一个 `GET {base}/v1/models` 连打了**三遍** ——
/// `bootstrapLLM` 的 `load()`（内部走 `healthCheck`）、`refreshStatus` 的 `llmHealth()`、
/// 以及 `availableLLMModels()`（走 `discoverModels`）。实测三趟合计约 1.4 秒，
/// 而它们问的是**同一个问题**：这家供应商现在有哪些模型、我选的那个在不在里面。
/// 一次开屏付三份网络往返，是最典型的「串行起来才发现的启动墙」。
///
/// 设计取舍：
/// - **只缓存成功**：一次超时不写进缓存 —— 用户可能正巧在这半分钟里把服务拉起来了，
///   缓存失败会让后面每一次都接着报「连不上」，那是把一次抖动放大成半小时的假故障。
/// - **在途合流**：并发的同一个键只发一趟（与 `VoiceService` 的合成合流同理）。
///   没有它，两个同时来的调用会在缓存写入之前各发一次，去重就白做了。
/// - **只住内存**：不落盘、不外发。密钥只以**指纹**参与键名，原文不进缓存。
/// - **键带端点与密钥指纹**：换了供应商 / 换了 Key 就是另一个键 —— 缓存不会把
///   「上家的模型列表」当成这一家的。
public actor RemoteCatalogCache {

    public static let shared = RemoteCatalogCache()

    /// 缓存有效期（秒）。
    ///
    /// 定 30 秒的理由：它被**开屏那几步**共用（装配 → 状态刷新，间隔不到一秒），
    /// 同时又要短到「用户在设置页改完 Key 立刻再测」不会被旧结果糊住 ——
    /// 改 Key 会换键（必然 miss），改端点也会换键，真正落到同一个键上的
    /// 只剩「什么都没改、又问了一次」，那本来就该复用。
    public static let ttl: TimeInterval = 30

    /// 键的数量上限（防单调增长：供应商就那么几个，超了先淘汰最旧的）。
    public static let keyLimit = 32

    private struct Entry {
        let models: [DiscoveredModel]
        let at: Date
    }

    private var entries: [String: Entry] = [:]
    private var inflight: [String: Task<[DiscoveredModel], Error>] = [:]

    public init() {}

    // MARK: - 读写

    /// 取模型目录：命中缓存或在途 → 不发请求；否则发一次并记下来。
    ///
    /// - Parameters:
    ///   - key: 缓存键（见 `key(base:apiKey:kind:)`）。
    ///   - now: 「此刻」。判据要能喂一个确定时刻（TTL 断言不能依赖机器跑多快）。
    ///   - fetch: 真正发请求的闭包；**只在未命中时**调用。
    public func models(
        key: String,
        now: Date = Date(),
        fetch: @escaping @Sendable () async throws -> [DiscoveredModel]
    ) async throws -> [DiscoveredModel] {
        if let entry = entries[key], now.timeIntervalSince(entry.at) < Self.ttl {
            return entry.models
        }
        if let running = inflight[key] { return try await running.value }

        let task = Task<[DiscoveredModel], Error> { try await fetch() }
        inflight[key] = task
        // 不论成败都要撤掉在途登记：否则这个键会永远合流到一个已结束的任务上。
        defer { inflight[key] = nil }

        let models = try await task.value
        // ⚠️ 有效期从**取到那一刻**起算（不是发起那一刻）：一趟慢请求不该
        // 让它带回来的结果一进门就过期。
        remember(key: key, models: models, at: Date())
        return models
    }

    /// 缓存键：端点 + 能力 + 密钥指纹。
    ///
    /// ⚠️ 密钥走 `StableFingerprint` 而不是明文：缓存是进程内共享的，
    /// 键名会被日志 / 调试器看到；指纹足够区分「换过 Key」，又不留凭据。
    public nonisolated static func key(
        base: URL,
        apiKey: String?,
        kind: AIProviderKind
    ) -> String {
        let credential = StableFingerprint.hex(prefix: "k", of: apiKey ?? "")
        return "\(kind.rawValue)|\(base.absoluteString)|\(credential)"
    }

    /// 清空（切供应商 / 退出登录 / 测试隔离用）。
    public func invalidate() {
        entries.removeAll()
        inflight.removeAll()
    }

    /// 已缓存的键数（测试用）。
    public var cachedKeyCount: Int { entries.count }

    // MARK: - 内部

    private func remember(key: String, models: [DiscoveredModel], at: Date) {
        entries[key] = Entry(models: models, at: at)
        guard entries.count > Self.keyLimit else { return }
        guard let oldest = entries.min(by: { $0.value.at < $1.value.at }) else { return }
        entries.removeValue(forKey: oldest.key)
    }
}
