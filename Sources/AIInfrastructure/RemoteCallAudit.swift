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
    /// 单文件上限（测试可注入更小的值：不然为了触发轮转得真写满 1MB）。
    private let rotationMaxBytes: Int
    private var fileURL: URL { explicitFileURL ?? Self.logURL() }

    /// 审计文件位置（用户可直接打开核对，或用脚本与账单 diff）。
    ///
    /// 可用环境变量 `ALC_REMOTE_CALL_LOG` 重定向——自动化测试必须把留痕写到
    /// 临时目录，**不能污染用户自己的对账文件**（否则用户 diff 账单时会看到
    /// 一堆来源不明的记录，反而更慌）。
    ///
    /// ⚠️ 环境变量是**外部输入**（#S2-12）：原先任何值都照收，于是
    /// 「把留痕重定向到任意路径 + `.atomic` 覆写」= 既能抹掉别的文件的内容，
    /// 也能抹掉对账证据。现在只放行测试真正需要的形状（临时目录下的 `.jsonl`），
    /// 其余一律忽略并落日志说明。
    public nonisolated static func logURL() -> URL {
        let fallback = AppPaths.userDataDirectory().appendingPathComponent(fileName)
        guard let override = ProcessInfo.processInfo.environment["ALC_REMOTE_CALL_LOG"], !override.isEmpty else {
            return fallback
        }
        let url = URL(fileURLWithPath: override).standardizedFileURL
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL
        guard url.pathExtension == "jsonl", url.path.hasPrefix(tempRoot.path + "/") else {
            AppLog.warning(
                "已忽略 ALC_REMOTE_CALL_LOG：只允许指向临时目录下的 .jsonl（收到 \(url.path)）",
                category: "billing"
            )
            return fallback
        }
        return url
    }

    public init(fileURL: URL? = nil, rotationMaxBytes: Int = Rotation.maxBytes) {
        self.explicitFileURL = fileURL
        self.rotationMaxBytes = rotationMaxBytes
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // 不转义斜杠：模型名里带 `/`（如 `fnlp/MOSS-TTSD-v0.5`），转义成 `\/` 之后
        // 用户拿着这份留痕去 grep / diff 账单会很难受。
        encoder.outputFormatting = [.withoutEscapingSlashes]
        self.encoder = encoder
    }

    /// 留痕文件名（数据目录里）。轮转只在这个名字上派生历史份，别处不许再写一遍字面量。
    public static let fileName = "remote-calls.jsonl"

    /// 这份文件是不是对外调用留痕（当前那份或轮转出去的历史份）。
    ///
    /// 给「清理入口」和「空间明细」用：留痕跟会话流水一样可以清，但它是**对账证据**，
    /// 界面上要说清它是谁（见 `CacheManager` 的处理：进废纸篓，可捞回）。
    public nonisolated static func isCallLogFile(_ name: String) -> Bool {
        name == fileName || Rotation.isRotated(name, of: fileName)
    }

    /// 磁盘留痕的轮转规则（纯函数，可单测；#S3-5）。
    ///
    /// 为什么是**轮转**而不是截断：这份文件是用户拿去和服务商账单逐条对账的**证据**，
    /// 只许换名字、不许丢内容。但也不能无限涨 —— 跑几个月就是几十万行、几十 MB，
    /// 用户连编辑器都打不开。于是「单文件上限 + 保留份数」两头封顶。
    public enum Rotation {

        /// 单个文件的上限：约 5000 条调用记录。
        public static let maxBytes = 1024 * 1024

        /// 连同当前那份在内最多保留几份（当前 + 4 份历史）。
        public static let maxFiles = 5

        /// 该不该在写入这条记录**之前**轮转。
        ///
        /// 空文件（或文件不存在）不轮转 —— 否则第一条就把刚开的新文件换名，白折腾。
        public static func shouldRotate(currentBytes: Int,
                                        incomingBytes: Int,
                                        maxBytes: Int = Rotation.maxBytes) -> Bool {
            guard currentBytes > 0 else { return false }
            return currentBytes + incomingBytes > maxBytes
        }

        /// 历史文件名：`remote-calls.jsonl` → `remote-calls-20261010-161530123.jsonl`。
        ///
        /// 时间戳定宽（年月日-时分秒 + 毫秒）：按名字排序就是按时间排序，挑最老那份不必去读文件属性。
        /// `round` 是同一时刻的**去重后缀** —— 一秒里连转两次不能撞名，撞了 `moveItem` 会失败。
        public static func rotatedName(for fileName: String, at date: Date, round: Int = 0) -> String {
            let stem = (fileName as NSString).deletingPathExtension
            let ext = (fileName as NSString).pathExtension
            let dedupe = round == 0 ? "" : "-\(round)"
            return "\(stem)-\(stamp(date))\(dedupe).\(ext)"
        }

        /// `name` 是不是 `fileName` 轮转出去的历史份。
        public static func isRotated(_ name: String, of fileName: String) -> Bool {
            let stem = (fileName as NSString).deletingPathExtension
            let ext = (fileName as NSString).pathExtension
            guard (name as NSString).pathExtension == ext else { return false }
            return name.hasPrefix("\(stem)-")
        }

        /// 在已有的**历史份**里挑出该删的：按名字（= 时间）排序，只留最新 `keeping` 份。
        public static func namesToPrune(_ rotatedNames: [String],
                                        keeping: Int = Rotation.maxFiles - 1) -> [String] {
            let sorted = rotatedNames.sorted()
            guard sorted.count > keeping else { return [] }
            return Array(sorted.prefix(sorted.count - keeping))
        }

        private static func stamp(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmssSSS"
            return formatter.string(from: date)
        }
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
        } else if !intent.billable {
            // 免费调用（Provider 声明 billable=false）：照常留痕，但不进计费统计——
            // 「计费 N 次」必须始终等于用户真正花过钱的次数。
            discoveryTotal += 1
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
            detail: httpStatus.map { "HTTP \($0)" },
            isFreeCall: !intent.billable
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

    private func persist(_ record: RemoteCallRecord) {
        guard let data = try? encoder.encode(RecordDTO(record)),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        guard let payload = line.data(using: .utf8) else { return }
        rotateIfNeeded(incomingBytes: payload.count)
        appendLine(payload)
    }

    /// 超上限就把当前文件改名留档、再开新的（#S3-5）。
    ///
    /// ⚠️ 是**轮转**不是截断：改完名旧内容还在原地（`remote-calls-<时刻>.jsonl`），
    /// 用户仍能逐条对账。历史份数由 `Rotation.maxFiles` 封顶，超出的进废纸篓。
    private func rotateIfNeeded(incomingBytes: Int) {
        let url = fileURL
        guard Rotation.shouldRotate(currentBytes: Self.fileSize(of: url),
                                    incomingBytes: incomingBytes,
                                    maxBytes: rotationMaxBytes) else { return }

        // 同一时刻连转两次不能撞名（撞了 moveItem 直接失败）→ 依次试去重后缀。
        let now = Date()
        let directory = url.deletingLastPathComponent()
        var target = directory.appendingPathComponent(Rotation.rotatedName(for: url.lastPathComponent, at: now))
        var round = 1
        while FileManager.default.fileExists(atPath: target.path), round < Rotation.maxFiles {
            target = directory.appendingPathComponent(
                Rotation.rotatedName(for: url.lastPathComponent, at: now, round: round)
            )
            round += 1
        }
        do {
            try FileManager.default.moveItem(at: url, to: target)
        } catch {
            // 改不了名就继续往原文件追加：宁可它大一点，也不能把这一条丢了。
            AppLog.warning("对外调用留痕轮转失败，仍追加到原文件：\(error.localizedDescription)", category: "billing")
            return
        }
        pruneRotations(of: url)
    }

    /// 文件当前字节数（不存在 = 0）。
    ///
    /// ⚠️ 必须走 `attributesOfItem` **每次实时查**：`URL.resourceValues(forKeys:)` 会把结果
    /// 缓存在 URL 对象上，同一个 URL 第二次读拿到的是**写入前的旧值** —— 这里的结果是
    /// 「一直读到 195，文件实际已 23400」的根因（轮转永不触发）。
    private static func fileSize(of url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// 历史份数封顶：最老的那几份进废纸篓（可捞回，别直接删证据）。
    private func pruneRotations(of url: URL) {
        let directory = url.deletingLastPathComponent()
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { Rotation.isRotated($0, of: url.lastPathComponent) }
        let stale = Rotation.namesToPrune(names)
        guard !stale.isEmpty else { return }
        TrashItem.delete(stale.map { directory.appendingPathComponent($0) })
    }

    /// 追加一行 JSONL。失败静默（磁盘不可写时不打断用户操作）。
    ///
    /// ⚠️ 已有留痕**只能追加**（#S3-5）：打不开就放弃这一条并说明原因 ——
    /// 绝不能退到 `.atomic` 覆写，那会把用户用来对账的历史整份截断成一行。
    private func appendLine(_ payload: Data) {
        let url = fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            guard let handle = try? FileHandle(forWritingTo: url) else {
                AppLog.warning(
                    "对外调用留痕追加失败：文件存在但打不开，这一条不落盘（不覆写历史）",
                    category: "billing"
                )
                return
            }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            do {
                try handle.write(contentsOf: payload)
            } catch {
                AppLog.warning("对外调用留痕写入失败：\(error.localizedDescription)", category: "billing")
            }
            return
        }
        // 还没有留痕文件：此刻只有这一条，`.atomic` 建文件是安全的。
        try? payload.write(to: url, options: .atomic)
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
        /// true = 免费调用（不计入计费统计，照常留痕）。
        let free: Bool

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
            self.free = record.isFreeCall
        }
    }
}
