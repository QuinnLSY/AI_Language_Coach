import Foundation
import AppCore

/// 隐私策略的**纯逻辑**（Phase 29 / 路线图第 29 步）。
///
/// 三条铁律（来自 Implementation Plan §33）：
/// 1. **默认本地优先**：不配置云端时，音频、画像、学习记忆、音色参考一律不出本机；
/// 2. **外发必须显式启用且被披露**：哪条能力在往哪个域名发什么，能算得出来、能显示给用户；
/// 3. **敏感数据不进日志**：要描述一段音频/文本时，只说它多大，不说它是什么。
///
/// 这里不碰 I/O、不认识 UI，只回答「这件事允不允许、该怎么说」。
public enum PrivacyPolicy {

    // MARK: - 数据类别

    public enum DataCategory: String, Codable, Sendable, CaseIterable {
        /// 麦克风录音、跟读音频。
        case audio
        /// 语音识别的转写文本。
        case transcript
        /// 交给语音合成朗读的文本。
        case speechText
        /// 对话正文与上下文。
        case conversation
        /// 学习记忆（错题、进度、词汇、跟读记录）。
        case learningMemory
        /// 用户画像（母语、学习目标语、水平）。
        case profile
        /// 音色参考音频。
        case voiceReference

        public var displayName: String {
            switch self {
            case .audio: "录音音频"
            case .transcript: "转写文本"
            case .speechText: "待朗读文本"
            case .conversation: "对话内容"
            case .learningMemory: "学习记忆"
            case .profile: "用户画像"
            case .voiceReference: "音色参考"
            }
        }

        /// 默认存储位置：**一律仅本地**。云端不是默认项，是用户自己打开的选择。
        public var defaultStorage: Storage { .localOnly }
    }

    public enum Storage: Sendable, Equatable {
        case localOnly
        case remote(providerID: String, host: String)
    }

    /// 某项能力实际会外发的数据类别。
    ///
    /// - Note: 画像永远不进这条映射（它只作为上下文在本地组装）。
    ///   ⚠️ 但**学习记忆要进**（#S2-9）：嵌入服务收的就是错句与学习记忆原文 ——
    ///   早先这里只有 llm/asr/tts 三项，embedding/pronunciation 落到 `default: []`，
    ///   于是「学习记忆永不出本机」这句断言在配了云端嵌入时不成立，而披露里一个字都没有。
    public static func outboundCategories(for kind: AIProviderKind) -> [DataCategory] {
        switch kind {
        case .asr: [.audio, .transcript]
        case .tts: [.speechText]
        case .llm: [.conversation]
        case .embedding: [.learningMemory]
        case .pronunciation: [.audio, .speechText]
        case .vad: []
        }
    }

    // MARK: - 披露

    public struct OutboundFlow: Sendable, Equatable, Identifiable {
        public let kind: AIProviderKind
        public let providerID: String
        public let displayName: String
        /// 数据发往的主机（域名或 IP），不含路径——路径属于服务商的计费细节，不该在这里露。
        public let host: String
        public let categories: [DataCategory]

        public var id: String { "\(kind.rawValue)-\(providerID)" }

        public init(kind: AIProviderKind, providerID: String, displayName: String,
                    host: String, categories: [DataCategory]) {
            self.kind = kind
            self.providerID = providerID
            self.displayName = displayName
            self.host = host
            self.categories = categories
        }
    }

    /// 一条**公共服务**的外发（#604 天气预报）。
    ///
    /// 为什么不塞进 `OutboundFlow`：那个结构的 `kind` 是 `AIProviderKind`，
    /// 而公共服务既没有供应商也没有模型 —— 硬塞就得假造一个「 Provider」出来，
    /// 披露列表里于是出现一行没有供应商、没有模型的「云端能力」。
    /// 用户要看的是「谁在收走我的什么」，不是一个结构上的将就。
    public struct PublicServiceFlow: Sendable, Equatable, Identifiable {
        public let service: PublicService
        /// 这一路会送出什么（给用户看的短句：说什么，不说多少字节）。
        public let outboundNote: String

        public var id: String { service.rawValue }
        public var host: String { service.host }

        public init(service: PublicService, outboundNote: String) {
            self.service = service
            self.outboundNote = outboundNote
        }
    }

    /// 当前会联系哪些公共服务。
    ///
    /// 与云端能力同一把尺 —— **只在真的会发请求时才列出来**：
    /// 「跟随天气」关着时一次请求都不发出去，披露里就不该出现 `ipwho.is`；
    /// 否则用户看到「正在联系第三方」，而开关明明是关着的，那比不披露更糟。
    public static func publicServiceFlows(for configuration: AppConfiguration) -> [PublicServiceFlow] {
        guard configuration.product.forestFollowsWeather else { return [] }
        return PublicService.allCases.map { service in
            PublicServiceFlow(service: service, outboundNote: outboundNote(for: service))
        }
    }

    /// 这项服务会收到什么。
    ///
    /// ⚠️ 每个 case 都得写满 —— `PublicService.allCases` 会让未来新增的服务
    /// 自动出现在披露里，这里漏一个就不是「没披露」，是**替这笔外发说谎**。
    private static func outboundNote(for service: PublicService) -> String {
        switch service {
        case .ipGeolocation:
            "你的公网出口 IP（用于推断城市级位置）"
        case .weatherForecast:
            "两位小数的近似坐标（约 1 公里精度，用于取当地天气）"
        }
    }

    public struct Disclosure: Sendable, Equatable {
        public let flows: [OutboundFlow]
        /// 公共服务（天气预报）外发，与云端能力分开列——两者的对象完全不同。
        public let publicServiceFlows: [PublicServiceFlow]

        public init(flows: [OutboundFlow], publicServiceFlows: [PublicServiceFlow] = []) {
            self.flows = flows
            self.publicServiceFlows = publicServiceFlows
        }

        /// 没有任何外发 = 纯本地。**两类都要空**才算。
        public var isLocalOnly: Bool { flows.isEmpty && publicServiceFlows.isEmpty }

        /// 有外发就必须让用户看见（§33：must be clearly disclosed）。
        public var requiresDisclosure: Bool { !isLocalOnly }

        public var hosts: [String] {
            Array(Set(flows.map(\.host) + publicServiceFlows.map(\.host))).sorted()
        }

        public var summary: String {
            guard !isLocalOnly else { return "全部数据仅在本机处理" }
            var parts: [String] = []
            if !flows.isEmpty { parts.append("\(flows.count) 项能力正在使用云端服务") }
            if !publicServiceFlows.isEmpty { parts.append("\(publicServiceFlows.count) 项公共服务") }
            return parts.joined(separator: " · ")
        }
    }

    /// 从配置推导**当前真正生效**的外发情况。
    ///
    /// 只看「已启用」是不够的：用户可能给某家供应商填过 Key 但当前仍用本地模型，
    /// 把那些也算成外发会制造恐慌。因此这里按**各能力当前生效的 Provider**判定
    /// （与设置页小绿点的口径一致）。
    ///
    /// - Note: 端点在**本机回环**上的 Provider 不算外发，见下。判定外发的标准是
    ///   「数据会不会离开这台机器」，不是「它自称哪种 runtime」。
    public static func disclosure(for configuration: AppConfiguration) -> Disclosure {
        // ⚠️ 别用 `AIProviderKind.allCases`：vad 不外发任何数据（本地判静音），
        // 列进来会让「N 项能力在使用云端服务」平白多一项。列全 + 过滤，与
        // `outboundCategories` 的口径一致（#S2-9：原先漏了 embedding / pronunciation）。
        let kinds: [AIProviderKind] = [.llm, .asr, .tts, .embedding, .pronunciation]
        var flows: [OutboundFlow] = []
        for kind in kinds {
            guard let provider = configuration.resolvedProvider(for: kind),
                  provider.runtime == .remoteAPI else { continue }
            // 回环端点上的服务跑在用户自己机器里（如 Edge-TTS 代理 127.0.0.1:8856）：
            // 数据交给它不等于离开本机，因此既不该出现在披露里，也不该触发
            // 「默认配置不得外发」的发布闸门。这类 Provider 只是「用 HTTP 说话的本机服务」。
            if PrivacyRedactor.isLoopbackEndpoint(provider.endpoint) { continue }
            flows.append(OutboundFlow(
                kind: kind,
                providerID: provider.id,
                displayName: provider.displayName ?? provider.id,
                host: PrivacyRedactor.host(of: provider.endpoint),
                categories: outboundCategories(for: kind)
            ))
        }
        return Disclosure(flows: flows, publicServiceFlows: publicServiceFlows(for: configuration))
    }
}

// MARK: - 脱敏

/// 把敏感值变成**可安全写入日志 / 显示在界面**的摘要。
///
/// 文档 §33 明令：音频字节、音色参考、完整对话不得进入普通调试日志。
/// 约束写在注释里会被忘记，写成一个函数才会被顺手用上。
public enum PrivacyRedactor {

    /// 文本 → 只说长度。
    public static func text(_ value: String) -> String {
        "文本 \(value.count) 字符"
    }

    /// 可选文本 → 只说有没有、多长。
    public static func text(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "文本（空）" }
        return text(value)
    }

    /// 音频 / 二进制 → 只说体积。
    public static func binary(_ data: Data?) -> String {
        guard let data else { return "音频（无数据）" }
        return "音频 \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))"
    }

    /// 采样点数 → 折算时长（不给出波形本身）。
    public static func audio(samples: Int, sampleRate: Int) -> String {
        guard sampleRate > 0 else { return "音频 \(samples) 采样点" }
        let seconds = Double(samples) / Double(sampleRate)
        return String(format: "音频 %.2fs（%d 采样点）", seconds, samples)
    }

    /// 端点 → 只留主机。拿不到就给占位符，绝不把整条 URL（可能带签名/路径）带进日志。
    public static func host(of endpoint: String?) -> String {
        guard let endpoint, let url = URL(string: endpoint), let host = url.host, !host.isEmpty else {
            return "未知主机"
        }
        return host
    }

    /// 主机名是否指向**本机回环**——数据压根没离开这台机器。
    ///
    /// 有些「云端」Provider 的端点其实开在用户自己的机器上（例如 Edge-TTS 代理
    /// `http://127.0.0.1:8856`）。判外发的尺子是「数据会不会出机器」，不是「它挂哪个
    /// runtime 标签」：回环上的服务与本地进程无异，不该被算成外发、也不该去吓用户。
    ///
    /// 只认真正的回环：`localhost`（含 `*.localhost`）、`::1` 及其展开写法、
    /// `0.0.0.0`（连它就等于连本机）、以及整个 `127.0.0.0/8`。
    /// **局域网名（`*.local`）与内网 IP 不算**——那些数据确实离开了本机。
    public static func isLoopback(host: String) -> Bool {
        let value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return false }
        if value == "localhost" || value.hasSuffix(".localhost") { return true }
        if value == "::1" || value == "0:0:0:0:0:0:0:1" { return true }
        if value == "0.0.0.0" { return true }
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets[0] == "127" else { return false }
        return octets.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    /// 端点 → 是否指向本机回环。
    ///
    /// 解析不出来（nil / 不是 URL / 没有主机）时返回 `false`：**未知一律当成「可能外发」**，
    /// 宁可多披露一条，也不替用户假设它安全。
    public static func isLoopbackEndpoint(_ endpoint: String?) -> Bool {
        guard let endpoint, let url = URL(string: endpoint), let host = url.host, !host.isEmpty else {
            return false
        }
        return isLoopback(host: host)
    }

    /// 密钥 → 只说有没有、多长。绝不出字符（前几位+后几位的「掩码」依然是可被社工利用的信息）。
    public static func secret(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "未设置" }
        return "已设置（\(value.count) 位）"
    }
}
