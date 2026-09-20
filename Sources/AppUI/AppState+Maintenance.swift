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
    public func exportBackup() async {
        guard !isExportingBackup else { return }
        isExportingBackup = true
        defer { isExportingBackup = false }
        do {
            _ = try await services.exportBackup()
            backupError = nil
            await refreshBackups()
        } catch {
            backupError = error.localizedDescription
        }
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
