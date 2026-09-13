import AIDomain
import AppCore
import Foundation

/// 云端调用的**唯一闸门**：所有发往云端的请求都必须先过 `authorize`、后过 `record`。
///
/// 存在的理由（生产事故复盘）：应用必须在结构上做到「一次操作 = 一个模型、一次请求」，
/// 而且要**可被用户核对**。这里做三件事：
///
/// 1. **准入**：按 `RemoteCallPolicy` 判定（模型必须显式选定、频率与总量有上限）；
/// 2. **记账**：每次调用落一条元数据记录（能力 / 供应商 / 模型 / 主机 / 结果 / 时间）；
/// 3. **留痕**：同步追加到 `.workbuddy/app-config/remote-calls.jsonl`，账单可逐条对账。
///
/// ⚠️ 只记元数据，绝不记录用户文本、提示词、密钥（AGENTS.md §7）。
public actor RemoteCallAudit {

    public static let shared = RemoteCallAudit()

    private var records: [RemoteCallRecord] = []
    private var stamps: [RemoteCallPolicy.Stamp] = []
    private var billableTotal = 0
    private var discoveryTotal = 0
    private var blockedTotal = 0

    /// 内存里保留的记录条数（UI 只展示最近若干条）。
    private let capacity = 300
    private let limits = RemoteCallPolicy.Limits.default
    private let encoder: JSONEncoder

    /// 显式指定的审计文件（测试注入用）；nil 时按 `logURL()` 动态解析。
    private let explicitFileURL: URL?
    private var fileURL: URL { explicitFileURL ?? Self.logURL() }

    /// 审计文件位置（用户可直接打开核对，或用脚本与账单 diff）。
    ///
    /// 可用环境变量 `ALC_REMOTE_CALL_LOG` 重定向——自动化测试必须把留痕写到
    /// 临时目录，**不能污染用户自己的对账文件**（否则用户 diff 账单时会看到
    /// 一堆来源不明的记录，反而更慌）。
    public nonisolated static func logURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["ALC_REMOTE_CALL_LOG"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return AppPaths.userDataDirectory().appendingPathComponent("remote-calls.jsonl")
    }

    public init(fileURL: URL? = nil) {
        self.explicitFileURL = fileURL
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // 不转义斜杠：模型名里带 `/`（如 `fnlp/MOSS-TTSD-v0.5`），转义成 `\/` 之后
        // 用户拿着这份留痕去 grep / diff 账单会很难受。
        encoder.outputFormatting = [.withoutEscapingSlashes]
        self.encoder = encoder
    }

    // MARK: - 准入

    /// 发请求前的准入判定。返回 `.denied` 时调用方**必须中止**，不得继续发请求。
    public func authorize(_ intent: RemoteCallPolicy.Intent, now: Date = Date()) -> RemoteCallPolicy.Decision {
        let decision = RemoteCallPolicy.decide(
            intent: intent,
            history: stamps,
            sessionBillableCount: billableTotal,
            limits: limits,
            now: now
        )
        if case .denied = decision {
            blockedTotal += 1
            append(RemoteCallRecord(
                at: now, kind: intent.kind, providerID: intent.providerID,
                model: intent.model.isEmpty ? "(未选择)" : intent.model,
                host: intent.host, endpoint: intent.endpoint, operation: intent.operation,
                outcome: .blocked, detail: "费用护栏拦截"
            ))
            AppLog.warning(
                "云端调用被拦截：\(intent.operation.rawValue) · \(intent.providerID)",
                category: "remote-call"
            )
        }
        return decision
    }

    // MARK: - 记账

    /// 记录一次**已经发出**的云端调用（放行后调用，含最终结果）。
    /// - Parameter httpStatus: 有 HTTP 响应时传状态码（仅用于审计展示，不含正文）。
    ///
    /// 被拦截（`.blocked`）的调用**没有发出去**，因此既不计入「计费次数」，
    /// 也不进入模型统计——否则汇总会把没花的钱算成花掉的钱，反而误导用户。
    public func record(
        _ intent: RemoteCallPolicy.Intent,
        outcome: RemoteCallRecord.Outcome,
        httpStatus: Int? = nil,
        now: Date = Date()
    ) {
        if outcome == .blocked {
            blockedTotal += 1
        } else {
            switch intent.operation {
            case .models:
                discoveryTotal += 1
            default:
                billableTotal += 1
                stamps.append(RemoteCallPolicy.Stamp(at: now, model: intent.model, operation: intent.operation))
                pruneStamps(now: now)
            }
        }
        append(RemoteCallRecord(
            at: now, kind: intent.kind, providerID: intent.providerID, model: intent.model,
            host: intent.host, endpoint: intent.endpoint, operation: intent.operation, outcome: outcome,
            detail: httpStatus.map { "HTTP \($0)" }
        ))
    }

    // MARK: - 查询

    /// 最近若干条记录（新的在前）。
    public func recent(limit: Int = 20) -> [RemoteCallRecord] {
        Array(records.suffix(limit).reversed())
    }

    /// 本次运行的汇总 + 异常扇出预警。
    public func summary(now: Date = Date()) -> RemoteCallSummary {
        let billableModels = records.filter(\.isBillable).map(\.model)
        var counts: [String: Int] = [:]
        for record in records where record.isBillable {
            counts[record.operation.rawValue, default: 0] += 1
        }
        return RemoteCallSummary(
            billableTotal: billableTotal,
            discoveryTotal: discoveryTotal,
            blockedTotal: blockedTotal,
            models: Array(Set(billableModels)).sorted(),
            countsByOperation: counts,
            fanOutWarning: RemoteCallPolicy.fanOutWarning(history: stamps, limits: limits, now: now)
        )
    }

    /// 清空内存记录（不动磁盘留痕，便于事后对账）。
    public func reset() {
        records.removeAll()
        stamps.removeAll()
        billableTotal = 0
        discoveryTotal = 0
        blockedTotal = 0
    }

    // MARK: - 内部

    private func pruneStamps(now: Date) {
        let windowStart = now.addingTimeInterval(-limits.window)
        stamps.removeAll { $0.at < windowStart }
    }

    private func append(_ record: RemoteCallRecord) {
        records.append(record)
        if records.count > capacity { records.removeFirst(records.count - capacity) }
        persist(record)
    }

    /// 追加一行 JSONL。失败静默（磁盘不可写时不打断用户操作）。
    private func persist(_ record: RemoteCallRecord) {
        guard let data = try? encoder.encode(RecordDTO(record)), var line = String(data: data, encoding: .utf8) else {
            return
        }
        line += "\n"
        guard let payload = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        } else {
            try? payload.write(to: fileURL, options: .atomic)
        }
    }

    /// 落盘结构（字段名稳定，便于用户/脚本直接 diff 账单）。
    private struct RecordDTO: Encodable {
        let at: Date
        let kind: String
        let provider: String
        let model: String
        let host: String
        /// 实际请求路径——与服务商账单的计费项一一对应（如 `/v1/audio/speech`）。
        let endpoint: String
        let operation: String
        let outcome: String
        let detail: String?

        init(_ record: RemoteCallRecord) {
            self.at = record.at
            self.kind = record.kind.rawValue
            self.provider = record.providerID
            self.model = record.model
            self.host = record.host
            self.endpoint = record.endpoint
            self.operation = record.operation.rawValue
            self.outcome = record.outcome.rawValue
            self.detail = record.detail
        }
    }
}
