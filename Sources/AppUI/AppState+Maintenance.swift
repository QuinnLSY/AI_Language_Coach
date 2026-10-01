import AIDomain
import AIServices
import AppCore
import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - AppState · 缓存管理 / 运行环境 / 数据备份
// #267 自 AppState.swift 拆出（2026-09-20）：单文件 5136 行超载，按域切为扩展。
// 同模块 extension，语义与拆分前完全一致；成员访问级别已放宽到 internal。
extension AppState {
    // MARK: - 缓存管理

    public func refreshCacheInfo() async {
        cacheSnapshot = await services.cacheSnapshot()
    }

    /// 刷新隐私状况（打开设置页时调用；切换供应商时由 `refreshCapabilityInfos` 自动带上）。
    public func refreshPrivacy() async {
        privacyReport = await services.privacyReport()
    }

    // MARK: - 运行环境 / 配置体检（设置页「运行环境」卡片）

    /// 刷新「数据在哪、配置读没读进来」这类环境信息。
    public func refreshRuntimeLocations() async {
        configLocationPath = await services.configStore.storageLocation.path
        configLoadFailure = await services.configStore.loadFailureReason
    }

    /// 配置体检：每个能力「该由谁生效、为什么生不生效」。
    ///
    /// 读的是注册表那三条投影接口（`modelConfigs` / `defaultModelConfig` /
    /// `registryInconsistencies`）—— 它们以前没有任何消费方，
    /// 于是「配置一致性体检」这件事实际从未发生。
    public func refreshRegistryCheck() async {
        var rows: [RegistryCheckRow] = []
        for kind in AIProviderKind.allCases {
            let all = await services.modelConfigs(kind: kind)
            let effective = await services.defaultModelConfig(for: kind)
            let issues = await services.registryInconsistencies(for: kind)
            rows.append(
                RegistryCheckRow(
                    kind: kind,
                    effective: effective,
                    providerCount: all.count,
                    enabledCount: all.filter(\.isEnabled).count,
                    issues: issues,
                    // 体检要回答的不只是「配置对不对」，还有「配好了但真的在走那条路吗」：
                    // LLM 报连接状态，发音评测报「这次是实测还是推断」。
                    healthDescription: await registryHealthNote(for: kind)
                )
            )
        }
        registryCheckRows = rows
    }

    /// 配置体检那一行下面补的一句「实际情况」（没有就不补）。
    func registryHealthNote(for kind: AIProviderKind) async -> String? {
        switch kind {
        case .llm:
            llmHealthDescription
        case .pronunciation:
            await services.pronunciationChannelSummary()
        case .asr:
            // 词级时间戳是「转写结果里逐词带不带起止秒」的能力位。
            // 它以前只有产出方、没有消费方 —— 于是既没人看它，
            // 也没人发现它哪天退化成不填（`ASRResult.words` 变空数组是静默的）。
            await services.asrWordTimestampSupport()
                ? "转写返回词级时间戳（每个词带起止秒）"
                : "转写只给整段文本，不带词级时间戳"
        default:
            nil
        }
    }

    /// 刷新「语义记忆索引通没通」。
    ///
    /// 模型管理中心的嵌入区块已经报了健康态，这里补它没说的：用的**多少维**、
    /// 以及没接通时下一步去哪儿接（见 `SemanticMemoryStatus.detail`）。
    ///
    /// ⚠️ 必须先 `ensureEmbeddingReady()`（2026-10-01 修）：嵌入 provider 是**惰性装配**
    /// 的（只有真要嵌入时才注册），启动时并没有人装配它。冷启动后直接开设置页，
    /// 这里读到的 `supportsSemanticRanking` 恒为 false —— 界面于是永久显示「未接通」，
    /// 而同一页上方的记忆索引区块却写着「已接通」，自己打自己。
    public func refreshSemanticMemory() async {
        await services.ensureEmbeddingReady()
        let info = await services.semanticMemoryInfo()
        semanticMemoryStatus = SemanticMemoryStatus(isEnabled: info.enabled, dimensions: info.dimensions)
    }

    // MARK: - 本机资源 / 本地模型测速（设置页「运行环境」）

    /// 刷新本机可用内存。
    ///
    /// 本地模型加载后要吃掉几 GB，界面上给一个数，「卡」才有解释。
    public func refreshMemoryPressure() async {
        guard let bytes = await services.availableMemoryBytes(), bytes > 0 else {
            availableMemoryText = ""
            return
        }
        availableMemoryText = MemoryText.available(bytes)
    }

    /// 跑一轮本地模型测速（只打本地 runtime，零云端费用）。
    ///
    /// ⚠️ `isRunningBenchmark` 必须 `defer` 复位：这条路径会抛错（没配本地供应商 /
    /// runtime 没起 / 模型名没填），只在成功分支复位的话，失败一次按钮就永久转圈。
    public func runLocalBenchmark() async {
        guard !isRunningBenchmark else { return }
        isRunningBenchmark = true
        defer { isRunningBenchmark = false }
        benchmarkError = nil
        do {
            let result = try await services.runLocalBenchmark()
            let snapshot = BenchmarkSnapshot(result: result)
            benchmarkSnapshot = snapshot
            // 三项指标一项都没有 = 这次等于没测，如实说出来，别摆一整列「—」。
            if snapshot == nil {
                benchmarkError = "这次没采到样本：本地模型返回为空，测速结果不予采用。"
            }
        } catch {
            // 动作名只写一次：这里就是「测速」这个动作本身，底层
            // `LocalLLMBenchmark.BenchmarkUnavailable` 自带完整原因（如「配置里没有
            // 可用的本地 LLM 供应商」），透出即可，不再叠一层「测速失败：」。
            benchmarkError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        // 模型刚跑完，内存水位最有参考价值：顺手刷一次。
        await refreshMemoryPressure()
    }

    /// 从磁盘重新载入配置，并把运行时**重接一遍**。
    ///
    /// 为什么需要它：配置是「内置默认 + 用户覆盖」两层合并出来的，用户在外面手改了
    /// `config.json`（或把备份的配置拷回来）之后，旧版本只能重启应用才生效。
    /// 而只把配置读回内存是不够的 —— 真正干活的是已经装配好的 provider，
    /// 不重装配就会出现「设置页按新配置显示、实际还在打旧端点」这种最难查的错位。
    public func reloadConfigurationFromDisk() async {
        await services.configStore.reload()
        await services.rebootstrapAll()
        await reloadProduct()
        await refreshRuntimeLocations()
        await refreshStatus()
        await refreshCapabilityInfos()
        await refreshRegistryCheck()
        await refreshVoiceProfiles()
        await refreshPrivacy()
        // 供应商重接之后，语义索引可能刚从「没接上」变成接上（或反过来）：一并刷新，
        // 否则界面会一直停在上一次的判断上。
        await refreshSemanticMemory()
        await refreshMemoryPressure()
        if let failure = configLoadFailure {
            configReloadNotice = "重新载入了，但内置默认配置读不出来：\(failure)"
        } else {
            let count = await services.configuration.providers.count
            configReloadNotice = "已按磁盘上的 config.json 重新载入（\(count) 个供应商），运行时已重接。"
        }
    }

    /// 关掉「重新载入配置」的回执。
    public func dismissConfigReloadNotice() {
        configReloadNotice = nil
    }

    /// 清理可再生的缓存（学习记忆与配置始终保留）。
    public func clearCache() async {
        let before = await services.clearCaches()
        let after = await services.cacheSnapshot()
        cacheSnapshot = after
        cacheFreedBytes = max(before.totalBytes - after.totalBytes, 0)
    }

    // MARK: - 数据备份（第 30 步）

    /// 刷新备份清单与学习库健康状况。
    public func refreshBackups() async {
        backupSnapshots = await services.backups()
        databaseRecoveryNote = await services.recoveryNote
    }

    // MARK: - 备份导入（#209：换机迁移 / 误删恢复）

    /// 第一步：校验备份。通过后存下恢复计划等用户确认；坏包在这里就被拦下。
    public func inspectBackup(at path: String) async {
        backupError = nil
        do {
            let plan = try await services.inspectBackup(at: path)
            backupImportPlan = BackupImportPlan(plan)
            backupImportPath = path
        } catch {
            backupError = error.localizedDescription
        }
    }

    /// 第二步（用户确认后）：覆盖前自动留底当前数据，把新文件落进暂存，重启时自动替换。
    public func confirmBackupImport() async {
        guard backupImportPlan != nil else { return }
        backupImportPlan = nil
        do {
            try await services.stageRestore(at: backupImportPath ?? "")
            backupImportNotice = "已安排恢复。重启应用时自动替换，当前数据已先自动备份一份（含「恢复前」标记）。"
            await refreshBackups()
        } catch {
            backupError = error.localizedDescription
        }
    }

    /// 导入确认框取消。
    public func cancelBackupImport() {
        backupImportPlan = nil
        backupImportPath = nil
    }

    /// 关掉「已安排恢复」回执。
    public func dismissBackupImportNotice() {
        backupImportNotice = nil
    }

    /// 导出一份完整备份，成功后刷新清单。失败要把原因显示出来，
    /// 否则用户会以为「备份做好了」——那比没有备份更危险。
    ///
    /// 返回是否成功：自动备份（下面那条）要用它决定要不要挂一条「没做成」的提示。
    @discardableResult
    public func exportBackup() async -> Bool {
        guard !isExportingBackup else { return false }
        isExportingBackup = true
        defer { isExportingBackup = false }
        do {
            _ = try await services.exportBackup()
            backupError = nil
            await refreshBackups()
            return true
        } catch {
            backupError = error.localizedDescription
            return false
        }
    }

    // MARK: - 自动备份（#415）

    /// 自动备份开关 / 间隔天数（设置页读取；写入走 `product` 持久化）。
    public var autoBackupEnabled: Bool { product.autoBackupEnabled }
    public var autoBackupIntervalDays: Int { product.autoBackupIntervalDays }

    /// 开 / 关自动备份。
    ///
    /// 打开时**立刻按当前口径补一份**：否则用户开了开关，要等到下次启动才第一次见到它干活，
    /// 期间会以为「开了没用」。
    public func setAutoBackupEnabled(_ enabled: Bool) async {
        product.autoBackupEnabled = enabled
        await persistProduct()
        if enabled {
            autoBackupNotice = nil
            await ensureAutoBackupIfNeeded()
        }
    }

    /// 改自动备份间隔（1...30 天）。
    public func setAutoBackupIntervalDays(_ days: Int) async {
        product.autoBackupIntervalDays = min(max(days, 1), 30)
        await persistProduct()
    }

    /// 距上次备份多久了（界面展示与自动备份判定**共用同一口径**，不会各说各话）。
    public func backupFreshness(now: Date = Date()) -> BackupFreshness.Status {
        BackupFreshness.status(
            latestBackupAt: backupSnapshots.first?.createdAt,
            now: now,
            intervalDays: product.autoBackupIntervalDays
        )
    }

    /// 启动时（以及刚打开开关时）检查一次：开了 且 距上次备份已超过间隔 → 补一份。
    ///
    /// ⚠️ 判定前必须 `refreshBackups`：依据是备份目录里的**真实文件**，
    /// 拿内存里的旧清单会重复备份（同一天开十次应用就是十份）。
    public func ensureAutoBackupIfNeeded(now: Date = Date()) async {
        guard product.autoBackupEnabled else { return }
        await refreshBackups()
        guard backupFreshness(now: now).isDue else { return }
        if await exportBackup() {
            autoBackupNotice = nil
            return
        }
        // 自动备份是后台做的：失败了必须自己出声，否则用户会一直以为备份还在按时进行。
        autoBackupNotice = AppNotice(
            text: "自动备份没做成：\(backupError ?? "原因未知")",
            action: NoticeAction(title: "现在备份") { [weak self] in
                Task { await self?.exportBackup() }
            }
        )
    }

    /// 关掉「自动备份没做成」的提示。
    public func dismissAutoBackupNotice() {
        autoBackupNotice = nil
    }

    // MARK: - 高级（普通用户不需要）

    public func setLLMEndpoint(_ endpoint: String) async {
        do {
            try await services.setLLMProviderField(endpoint: endpoint)
            bootMessage = nil
        } catch {
            bootMessage = error.localizedDescription
        }
        await refreshStatus()
    }

    public func setLLMTemperature(_ temperature: Double) async {
        do {
            try await services.setLLMProviderField(temperature: temperature)
        } catch {
            bootMessage = error.localizedDescription
        }
    }

    func persistProduct() async {
        try? await services.updateProduct(product)
    }

    /// 配置在 Services 侧被改过之后，把 UI 的缓存对齐。
    ///
    /// `product` 是 UI 缓存：别处（如启用克隆音色）写了配置却不重读，界面就会一直显示旧值。
    func reloadProduct() async {
        product = await services.configuration.product
    }
}

/// 备份新鲜度（#415：纯函数，不碰 SwiftUI，可直接单测）。
///
/// 「上次备份是 N 天前」这件事，展示与自动备份判定用的是同一个值 ——
/// 界面说「3 天前」、判定却按 24 小时算，就会出现「界面说还早、后台天天在备份」这种自相矛盾。
public enum BackupFreshness {

    /// `never` = 一份都还没有；`fresh` = 还在间隔内；`due` = 该补一份了。
    public enum Level: String, Sendable, Equatable {
        case never
        case fresh
        case due
    }

    public struct Status: Sendable, Equatable {
        /// 展示文案：「还没有备份过」/「今天已备份」/「昨天备份过」/「3 天前备份过」。
        public let text: String
        public let level: Level
        /// 距上次备份的**日历天数**；nil = 从没备份过。
        public let daysSinceLastBackup: Int?
        /// 该不该自动补一份（从没备份过，或已超出间隔）。
        ///
        /// ⚠️ 与开关无关：这里只回答「按间隔算是不是到点了」，
        /// 开没开自动备份由调用方判 —— 否则关着的时候界面会显示成「该备份了」，吓人。
        public let isDue: Bool
    }

    /// 日历天数差：跨天按**自然日**算，不按 24 小时 —— 晚上 23 点备份的，
    /// 第二天早上就该算「1 天前」（用户的直觉是「昨天」）。
    ///
    /// 时钟回拨导致未来日期时按 0 天处理（负数会让「N 天前」变成鬼话）。
    public static func days(since date: Date?, now: Date, calendar: Calendar = .current) -> Int? {
        guard let date else { return nil }
        let start = calendar.startOfDay(for: date)
        let end = calendar.startOfDay(for: now)
        let raw = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        return max(0, raw)
    }

    public static func status(
        latestBackupAt: Date?,
        now: Date,
        intervalDays: Int,
        calendar: Calendar = .current
    ) -> Status {
        let interval = min(max(intervalDays, 1), 30)
        guard let days = days(since: latestBackupAt, now: now, calendar: calendar) else {
            return Status(text: "还没有备份过", level: .never, daysSinceLastBackup: nil, isDue: true)
        }
        let isDue = days >= interval
        let text: String
        switch days {
        case 0: text = "今天已备份"
        case 1: text = "昨天备份过"
        default: text = "\(days) 天前备份过"
        }
        return Status(
            text: text,
            level: isDue ? .due : .fresh,
            daysSinceLastBackup: days,
            isDue: isDue
        )
    }
}

/// 内存读数的展示格式化（纯函数：不碰 SwiftUI，可直接单测）。
enum MemoryText {
    /// 「3.2 GB 可用」——不足 1 GB 时按 MB 报，免得显示「0.4 GB」这种没人读的单位。
    static func available(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB 可用", gb) }
        return String(format: "%.0f MB 可用", Double(bytes) / 1_048_576)
    }
}
