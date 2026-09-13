import AppCore
import Foundation

/// 云端调用的「单一模型铁律」与费用护栏（纯函数，脱机可测）。
///
/// 事故背景：用户只点了一次「朗读」，云端账单上却出现了十几个**不同模型**的 token 计费。
/// 逐行审计后确认：应用代码里没有任何遍历模型的循环；但**确实存在一个隐患**——
/// 云端 Adapter 在「没选定模型」时会静默回退到 `candidateModels.first`，
/// 那可以是账号里的**任意一个**模型。隐患必须从结构上消除：
///
/// 1. `resolvedModel` **只认显式选定的模型**，绝不回退候选列表（没选就拒绝发请求）；
/// 2. `decide` 在真正发请求前做准入：模型必须存在、频率必须正常、单次运行总量有上限；
/// 3. 每一次放行 / 拦截都留下审计记录（见 `RemoteCallAudit`），账单可逐条对账。
public enum RemoteCallPolicy {

    // MARK: - 调用意图

    /// 一次云端调用的语义。区分「计费」与「只读探测」——两者的护栏不一样。
    public enum Operation: String, Sendable, Equatable, CaseIterable {
        /// 模型列表探测（OpenAI 兼容 `GET /models`）：只读，不产生 token / 音频计费。
        case models
        case chat
        case speech
        case transcriptions

        /// 该操作会不会产生费用（决定是否受频率与总量护栏约束）。
        public var isBillable: Bool { self != .models }

        public var displayName: String {
            switch self {
            case .models: "模型列表探测"
            case .chat: "对话生成"
            case .speech: "教师朗读"
            case .transcriptions: "语音识别"
            }
        }
    }

    /// 发请求前的描述（不含任何用户文本、提示词内容）。
    public struct Intent: Sendable, Equatable {
        public var kind: AIProviderKind
        public var providerID: String
        public var model: String
        /// 端点主机名（审计展示用；不含路径与密钥）。
        public var host: String
        public var operation: Operation

        public init(kind: AIProviderKind, providerID: String, model: String, host: String, operation: Operation) {
            self.kind = kind
            self.providerID = providerID
            self.model = model
            self.host = host
            self.operation = operation
        }
    }

    // MARK: - 唯一允许调用的模型

    /// 唯一允许调用的模型：**只认显式选定的那个**。
    ///
    /// - Parameters:
    ///   - selected: 用户在设置里选定的模型（产品层 `selectedModels` 优先）。
    ///   - providerDefault: Provider 记录里显式写入过的模型（装配时已与产品层对齐）。
    /// - Returns: 可以调用的模型 id；两者都为空时返回 `nil`。
    ///
    /// ⚠️ 返回 `nil` 时调用方必须**拒绝发送请求**，而不是去猜一个。
    /// 历史实现正是在这里写成了 `?? candidateModels.first`——在没有选中模型时
    /// 会拿候选列表的第一个（可能是账号里任意一个模型）去发请求，这正是本次事故
    /// 里最需要被杜绝的行为。
    public static func resolvedModel(selected: String?, providerDefault: String?) -> String? {
        for candidate in [selected, providerDefault] {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    // MARK: - 护栏

    /// 一条历史调用记录（只留最近窗口够用的信息）。
    public struct Stamp: Sendable, Equatable {
        public var at: Date
        public var model: String
        public var operation: Operation

        public init(at: Date, model: String, operation: Operation) {
            self.at = at
            self.model = model
            self.operation = operation
        }
    }

    /// 护栏阈值。取「正常使用永远碰不到、失控调用立刻被掐断」的量级。
    public struct Limits: Sendable, Equatable {
        /// 一分钟内各操作的放行上限。
        public var perMinute: [Operation: Int]
        /// 单次运行（进程生命周期）内计费请求总量上限。
        public var billablePerSession: Int
        /// 统计窗口（秒）。
        public var window: TimeInterval

        /// 默认每分钟上限：
        /// - 对话一轮最多 2 次（流式 + 非流式兜底），正常聊天远低于 20；
        /// - 「重复点朗读」是正常行为（每次 1 个请求），给到 40；
        /// - 语音输入是流式上屏（录音期间每 ~1.2s 一次），给到 150；
        /// - 模型列表探测只读不计费，仅用于防失控循环，给到 200。
        public static let standardPerMinute: [Operation: Int] = [
            Operation.chat: 20,
            Operation.speech: 40,
            Operation.transcriptions: 150,
            Operation.models: 200
        ]

        public init(
            perMinute: [Operation: Int] = Limits.standardPerMinute,
            billablePerSession: Int = 3000,
            window: TimeInterval = 60
        ) {
            self.perMinute = perMinute
            self.billablePerSession = billablePerSession
            self.window = window
        }

        public static let `default` = Limits()

        public func perMinute(for operation: Operation) -> Int {
            perMinute[operation] ?? 20
        }
    }

    public enum Decision: Sendable, Equatable {
        case allowed
        /// 拦截。`reason` 会直接展示给用户，务必说清楚「为什么」和「怎么办」。
        case denied(reason: String)
    }

    /// 准入判定。
    public static func decide(
        intent: Intent,
        history: [Stamp],
        sessionBillableCount: Int,
        limits: Limits = .default,
        now: Date = Date()
    ) -> Decision {
        // 「必须选定模型」只约束**计费**调用：模型列表探测本来就没有模型参数，
        // 若也要求它带模型，健康检查会平白无故失败。
        if intent.operation.isBillable {
            let model = intent.model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else {
                return .denied(reason: "未选择模型，已阻止这次云端调用（应用不会自动改用候选列表里的其它模型）。请到设置里选定模型后重试。")
            }
        }

        let windowStart = now.addingTimeInterval(-limits.window)
        let recent = history.filter { $0.at >= windowStart }
        let sameOperation = recent.filter { $0.operation == intent.operation }
        let limit = limits.perMinute(for: intent.operation)
        if sameOperation.count >= limit {
            return .denied(reason: """
                已拦截：\(intent.operation.displayName)在 \(Int(limits.window)) 秒内已发起 \(sameOperation.count) 次云端请求，\
                超过安全上限 \(limit) 次。为避免持续产生费用，应用已暂停该能力的云端调用；\
                请稍后再试，若你并未连续操作，请立即到服务商后台核对用量与密钥。
                """)
        }

        if intent.operation.isBillable, sessionBillableCount >= limits.billablePerSession {
            return .denied(reason: """
                已拦截：本次运行累计云端计费请求已达上限 \(limits.billablePerSession) 次。\
                这通常意味着出现了异常调用，请重启应用并在服务商后台核对用量。
                """)
        }

        return .allowed
    }

    // MARK: - 异常扇出预警

    /// 「同一分钟内出现了多个不同模型」的预警文案（正常使用永远为 nil）。
    ///
    /// 正常产品行为里，一次运行只会用**一个**模型：用户选定谁就用谁。
    /// 同一分钟内冒出 ≥3 个不同模型，只可能是出现了遍历模型的调用——
    /// 这正是本次事故的形态，所以宁可误报也要报出来。
    ///
    /// ⚠️ 空模型名（「未选择模型」被拦截的记录）不算一个「模型」，
    /// 否则护栏自己的拦截记录会把预警顶起来，变成自己吓自己。
    public static func fanOutWarning(history: [Stamp], limits: Limits = .default, now: Date = Date()) -> String? {
        let windowStart = now.addingTimeInterval(-limits.window)
        let models = Set(
            history
                .filter { $0.at >= windowStart }
                .map { $0.model.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        guard models.count >= 3 else { return nil }
        let list = models.sorted().prefix(6).joined(separator: "、")
        return "检测到一分钟内调用了 \(models.count) 个不同模型（\(list)…），请核对服务商账单。"
    }
}

// MARK: - 审计记录（UI 展示用，不含任何请求正文）

/// 一条对外调用的审计记录。
///
/// 硬约束（AGENTS.md §7）：只记录**元数据**——能力、供应商、模型、主机、结果、时间；
/// 绝不记录用户文本、提示词、密钥。
public struct RemoteCallRecord: Sendable, Equatable, Identifiable {

    public enum Outcome: String, Sendable, Equatable {
        case ok
        case httpError
        case failed
        case blocked

        public var displayName: String {
            switch self {
            case .ok: "成功"
            case .httpError: "服务端拒绝"
            case .failed: "失败"
            case .blocked: "已拦截"
            }
        }
    }

    public let id: UUID
    public let at: Date
    public let kind: AIProviderKind
    public let providerID: String
    public let model: String
    public let host: String
    public let operation: RemoteCallPolicy.Operation
    public let outcome: Outcome
    /// 极简补充说明（HTTP 状态码等），不含响应正文。
    public let detail: String?

    public init(
        id: UUID = UUID(),
        at: Date,
        kind: AIProviderKind,
        providerID: String,
        model: String,
        host: String,
        operation: RemoteCallPolicy.Operation,
        outcome: Outcome,
        detail: String? = nil
    ) {
        self.id = id
        self.at = at
        self.kind = kind
        self.providerID = providerID
        self.model = model
        self.host = host
        self.operation = operation
        self.outcome = outcome
        self.detail = detail
    }

    /// 是否是一次真正发出去的（计费）请求。被拦截的记录不计费。
    public var isBillable: Bool { operation.isBillable && outcome != .blocked }
}

/// 本次运行的对外调用汇总——给用户一条「应用到底调了什么」的可核对结论。
public struct RemoteCallSummary: Sendable, Equatable {
    /// 本次运行真正发出的计费请求数。
    public var billableTotal: Int
    /// 只读探测（模型列表）次数，不计费。
    public var discoveryTotal: Int
    /// 被护栏拦截的次数（>0 说明有异常调用被打断）。
    public var blockedTotal: Int
    /// 本次运行涉及过的**不同计费模型**（正常永远只有用户选定的那些）。
    public var models: [String]
    /// 各计费操作的次数（`RemoteCallPolicy.Operation.rawValue` → 次数）。
    public var countsByOperation: [String: Int]
    /// 异常扇出预警（nil = 正常）。
    public var fanOutWarning: String?

    public init(
        billableTotal: Int = 0,
        discoveryTotal: Int = 0,
        blockedTotal: Int = 0,
        models: [String] = [],
        countsByOperation: [String: Int] = [:],
        fanOutWarning: String? = nil
    ) {
        self.billableTotal = billableTotal
        self.discoveryTotal = discoveryTotal
        self.blockedTotal = blockedTotal
        self.models = models
        self.countsByOperation = countsByOperation
        self.fanOutWarning = fanOutWarning
    }

    /// 一句话结论（设置页直接展示）。
    public var headline: String {
        "本次运行对外请求：计费 \(billableTotal) 次 · 探测 \(discoveryTotal) 次 · 拦截 \(blockedTotal) 次 · 涉及模型 \(models.count) 个"
    }

    public func count(for operation: RemoteCallPolicy.Operation) -> Int {
        countsByOperation[operation.rawValue] ?? 0
    }
}
