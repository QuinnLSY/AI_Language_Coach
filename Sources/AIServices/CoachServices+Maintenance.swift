import AIDomain
import AIInfrastructure
import AppCore
import Foundation

// MARK: - CoachServices · 缓存 / 隐私 / 备份 / 天气 / 调用审计（第 29-30 步 / #604）
//
// #660 自 CoachServices.swift 拆出（2026-10-24）：原文件 3165 行单 actor 超载，按域切为扩展。
// 同模块 extension，语义与拆分前完全一致；跨文件调用的成员已从 private 放宽到
// internal（模块内可见，跨模块零影响，public API 不变）。
extension CoachServices {
// MARK: - 缓存管理（设置页）

public func cacheSnapshot() async -> CacheSnapshot {
    CacheManager.snapshot()
}

/// 清理缓存，返回清理前的快照（供 UI 展示释放量）。
///
/// ⚠️ 磁盘那部分由 `CacheManager` 管；**进程内**的几份缓存（词典查词结果）也得在这条路上一起倒掉 ——
/// 否则用户点了「清缓存」、内存占用纹丝不动，那个按钮就只是心理安慰（#S3-6）。
@discardableResult
public func clearCaches() async -> CacheSnapshot {
    let snapshot = await CacheManager.clearCaches(database: learning)
    await dictionary.clearCache()
    return snapshot
}

// MARK: - 隐私（设置页「隐私与安全」）

/// 隐私状况：当前有没有数据外发、发往哪里，以及本地数据都存在哪。
///
/// 每次都**实时从配置推导**——用户切回本地模型后，这里必须立刻变回「纯本地」，
/// 不能停留在上一次的快照上（否则等于谎报）。
public func privacyReport() async -> PrivacyReport {
    let configuration = await config.current
    // 附件与音色档案这两份「用户资产」的落点由本服务给出：它们各自有唯一出口
    // （`AttachmentStore.storageDirectory` / `VoiceProfileStore.storageLocation`），
    // 在别处重拼一次路径就多一份会漂移的真相。
    return PrivacyReport(
        disclosure: PrivacyPolicy.disclosure(for: configuration),
        locations: PrivacyDataLocator.locations(
            attachmentDirectory: await attachmentDirectory,
            voiceProfilesFile: await voiceProfilesLocation()
        ),
        dataDirectory: PrivacyDataLocator.dataDirectory()
    )
}

// MARK: - 数据备份（第 30 步：Release checklist / Data）

/// 导出一份完整备份（学习库 + 配置 + 调用留痕），返回压缩包位置。
@discardableResult
public func exportBackup() async throws -> BackupRecord {
    BackupRecord(try await backup.export())
}

/// 已有备份，新的在前。
public func backups() async -> [BackupRecord] {
    await backup.snapshots().map(BackupRecord.init)
}

/// 备份总占用的展示文本（nil = 还没有任何备份）。
public var backupTotalDisplay: String? {
    get async {
        let bytes = await backup.totalBytes
        return bytes > 0 ? ByteFormatter.string(UInt64(bytes)) : nil
    }
}

/// 清理旧备份：保留最近 `keeping` 份，其余进废纸篓。
/// 自动备份补了新包之后调用 —— 自动化自己堆的文件自己收，不许悄悄吃满磁盘。
@discardableResult
public func pruneBackups(keeping: Int = DataBackup.maxKeptBackups) async -> Int {
    (try? await backup.prune(keeping: keeping)) ?? 0
}

/// 删除一份备份（进废纸篓，可恢复）。
public func deleteBackup(at url: URL) async throws {
    try await backup.deleteBackup(at: url)
}

/// 回收超出保留窗口的坏库隔离副本（进废纸篓，最近那份永不碰）。
///
/// 隔离目录过去**只进不出**：每坏一次多一份，攒几年就是几百 MB，
/// 而存储面板还报着「1 MB」——谁也不知道磁盘被谁吃了（#674）。
@discardableResult
public func pruneQuarantine(base: URL = AppPaths.userDataDirectory()) -> (removed: Int, freedBytes: Int64) {
    DataResilience.pruneQuarantine(base: base)
}

/// 把学习记录导出成人类可读的文件：Markdown（会话 + 错题）与 CSV（单词本）。
///
/// 这是「数据出得去」的那一半：备份 zip 是给本应用恢复用的机器格式，
/// 用户始终应该有一条**不依赖本应用也能读**的路。
///
/// - Returns: 写好的两个文件（`学习记录_时间戳.md`、`单词本_时间戳.csv`）。
public func exportLearningRecords(to directory: URL) async throws -> (markdown: URL, csv: URL) {
    guard let learning else { throw AppError.database("学习库尚未就绪") }
    let summaries = try await learning.recentSessions(limit: 500)
    var transcripts: [LearningDataExporter.SessionTranscript] = []
    transcripts.reserveCapacity(summaries.count)
    for summary in summaries {
        let messages = (try? await learning.messages(sessionID: summary.sessionID)) ?? []
        transcripts.append(.init(summary: summary, messages: messages))
    }
    let vocabulary = try await learning.allVocabulary()
    let output = LearningDataExporter.export(sessions: transcripts, vocabulary: vocabulary, now: Date())

    let manager = FileManager.default
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let stamp = Self.exportStamp(Date())
    let markdownURL = directory.appendingPathComponent("学习记录_\(stamp).md")
    let csvURL = directory.appendingPathComponent("单词本_\(stamp).csv")
    try output.markdown.write(to: markdownURL, atomically: true, encoding: .utf8)
    try output.csv.write(to: csvURL, atomically: true, encoding: .utf8)
    return (markdownURL, csvURL)
}

/// 导出文件名的时间戳（`yyyyMMdd-HHmmss`，与备份包同一形状）。
static func exportStamp(_ date: Date) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    func pad(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
    return "\(pad(components.year))\(pad(components.month))\(pad(components.day))-\(pad(components.hour))\(pad(components.minute))\(pad(components.second))"
}

/// 备份放在哪儿（UI 直达用）。
public var backupDirectory: URL {
    get async { await backup.directory }
}

/// 学习库出过什么状况（nil = 一切正常）。界面要把它显示出来。
public var recoveryNote: String? { databaseRecoveryNote }

/// 校验一份备份（导入确认框用）：坏包在这里就被拦下，给出明确原因。
public func inspectBackup(at path: String) async throws -> DataBackup.ImportPlan {
    try await backup.inspectBackup(at: URL(fileURLWithPath: path))
}

/// 安排恢复：校验 → 当前数据自动留底 → 新文件落暂存（重启时才真正替换）。
@discardableResult
public func stageRestore(at path: String) async throws -> DataBackup.ImportPlan {
    try await backup.stageRestore(at: URL(fileURLWithPath: path))
}

/// 本轮启动应用的备份恢复说明（nil = 没有）。
public var restoreNote: String? { pendingRestoreNote }

// MARK: - 天气预报（#604）

/// 今日降水结论（真实天气预报：IP 定位 → Open-Meteo）。取不到 = nil。
///
/// 这里返回的是 **应用层自己的答案**（今天有没有降水、是雨还是雪），
/// 不是 `ForestWeather` 那种「画面档位」—— 应用层不认识插画有几档，
/// 换算留给 AppUI（`AppState.applyWeatherForecast`）。跨界偷渡类型只会让
/// 「加一档天气」变成改两次 AIServices。
public func todayPrecipitation() async -> WeatherForecast.Precipitation? {
    await ForestWeatherService().todayPrecipitation()
}

// MARK: - 云端调用审计（费用护栏留痕）

/// 本次运行的对外调用汇总：计费 / 探测 / 拦截次数、涉及模型、异常扇出预警。
/// 用户拿它跟服务商账单对账——「应用到底调了什么」不再是个黑盒。
public func remoteCallSummary() async -> RemoteCallSummary {
    await RemoteCallAudit.shared.summary()
}

/// 最近若干条对外调用记录（新的在前，只含元数据）。
public func recentRemoteCalls(limit: Int = 20) async -> [RemoteCallRecord] {
    await RemoteCallAudit.shared.recent(limit: limit)
}

/// 清空内存记录（磁盘留痕保留，便于事后对账）。
public func resetRemoteCalls() async {
    await RemoteCallAudit.shared.reset()
}

/// 审计文件位置（用户可直接打开核对）。
public nonisolated static func remoteCallLogURL() -> URL {
    RemoteCallAudit.logURL()
}
}
