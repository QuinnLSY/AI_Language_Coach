import AIDomain
import AppCore
import Foundation

// MARK: - 静态检查规则

/// 发布静态检查的规则表（来自 `Config/release-lint-rules.json`）。
///
/// 为什么要外置：规则里全是「路径 / 端口 / 遥测域名」这类字面量，
/// 写进 Swift 源码会被自己的扫描器扫出来——典型的自指。
public struct ReleaseRuleSet: Sendable, Decodable {
    public let absolutePathPatterns: [String]
    public let hardcodedPortPatterns: [String]
    public let telemetryHostPatterns: [String]
    public let audioLogPatterns: [String]
    /// 在本工程里**不可用**的 SwiftUI 跨导入叠加（cross-import overlay）API。
    ///
    /// 为什么单独一类：这类 API 编译期完全正常，却在**启动时**因类元数据无法初始化而崩溃，
    /// 只有真机跑一次才看得到。它不属于「路径/端口」那种泄密红线，也不是日志泄漏，
    /// 所以单列一类，而不是塞进现有 pattern 里凑数。
    public let unusableOverlayPatterns: [String]
    public let minimumLocalLocations: Int

    private enum CodingKeys: String, CodingKey {
        case absolutePathPatterns
        case hardcodedPortPatterns
        case telemetryHostPatterns
        case audioLogPatterns
        case unusableOverlayPatterns
        case minimumLocalLocations
    }

    public static func load() throws -> ReleaseRuleSet {
        guard let url = AppResourceBundle.module.url(
            forResource: "Config/release-lint-rules",
            withExtension: "json"
        ) else {
            throw AppError.configuration("缺少静态检查规则 release-lint-rules.json")
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ReleaseRuleSet.self, from: data)
    }
}

/// 发布就绪检查的**证据**：每个自动检查要的结论，都来自这里的一次真实动作。
public struct ReleaseEvidence: Sendable {

    /// 项目根（源码树）。打包后的 .app 里拿不到 → 依赖源码的静态检查降级为 manual/失败。
    public let projectRoot: URL?
    /// 静态检查规则（外置 JSON）。nil = 规则没加载出来，相关检查一律判失败。
    public let rules: ReleaseRuleSet?
    /// 规则加载失败的原因。
    public let ruleLoadError: String?

    public init(projectRoot: URL?, rules: ReleaseRuleSet? = nil, ruleLoadError: String? = nil) {
        self.projectRoot = projectRoot
        self.rules = rules
        self.ruleLoadError = ruleLoadError
    }

    /// 默认证据源：规则从资源包读取，读不到就把失败原因带上（不允许悄悄退化成「没问题」）。
    public static func bootstrap(projectRoot: URL? = AppPaths.projectRoot) -> ReleaseEvidence {
        do {
            return ReleaseEvidence(projectRoot: projectRoot, rules: try ReleaseRuleSet.load())
        } catch {
            return ReleaseEvidence(
                projectRoot: projectRoot,
                rules: nil,
                ruleLoadError: "静态检查规则加载失败：\(error.localizedDescription)"
            )
        }
    }

    // MARK: - 静态扫描

    /// 某棵子树里的所有 Swift 文件。
    func swiftFiles(in subtree: String) -> [URL] {
        guard let root = projectRoot else { return [] }
        let base = root.appendingPathComponent(subtree)
        guard let enumerator = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var files: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            // 快照目录里的历史产物不算源码。
            guard !url.path.contains("/Snapshots/") else { continue }
            files.append(url)
        }
        return files
    }

    /// 在源码里找违禁 pattern 的行（返回 `文件:行` 便于定位）。
    /// `scope == .sources` 只查正式代码，`.all` 连测试一起查。
    func matches(pattern: String, scope: ScanScope = .all) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        var hits: [String] = []
        for file in files(scope: scope) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in expression.matches(in: text, options: [], range: range) {
                // 注释里提到某个端口/域名（比如「本机代理会劫持 localhost」）不算违规，
                // 否则这种噪音会让这条检查永远红着，然后被所有人忽略。
                if text.isCommentLine(at: match.range.location) { continue }
                let line = text.lineNumber(of: match.range.location)
                hits.append("\(relativeName(of: file)):\(line)")
            }
        }
        return hits
    }

    /// 扫描范围：端口/端点的红线只约束**正式代码**——测试里的 127.0.0.1 桩服务是刻意为之。
    enum ScanScope {
        case sources
        case all
    }

    func files(scope: ScanScope) -> [URL] {
        switch scope {
        case .sources:
            return swiftFiles(in: "Sources")
        case .all:
            return swiftFiles(in: "Sources") + swiftFiles(in: "Tests") + manifestURLs()
        }
    }

    private func relativeName(of url: URL) -> String {
        guard let root = projectRoot else { return url.lastPathComponent }
        var name = url.path
        if name.hasPrefix(root.path) {
            name = String(name.dropFirst(root.path.count + 1))
        }
        return name
    }

    private func manifestURLs() -> [URL] {
        guard let root = projectRoot else { return [] }
        return [root.appendingPathComponent("Package.swift")]
    }

    func packageManifest() -> String {
        guard let url = manifestURLs().first else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    // MARK: - 数据

    /// 迁移：从空库一路跑到最新 schemaVersion，再开一次确认幂等。
    func migration() throws -> Int {
        let directory = URL.temporaryDirectory.appendingPathComponent("alc-release-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("learning.db").path
        _ = try LearningDatabase(path: path)
        let second = try LearningDatabase(path: path) // 幂等：同一份库再 migrate 一次不得报错
        _ = second
        return LearningDatabase.schemaVersion
    }

    /// 备份：真导出一份 zip，并检查它非空、可被列出。
    func backupExport() async throws -> Int64 {
        let root = URL.temporaryDirectory.appendingPathComponent("alc-backup-\(UUID().uuidString)", isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        let backups = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        // 造一份最小数据集：真库 + 真配置，否则这条检查等于没测。
        let database = try LearningDatabase(path: data.appendingPathComponent("learning.db").path)
        _ = database
        try "{}".write(to: data.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let store = DataBackup(dataDirectory: data, backupDirectory: backups)
        let snapshot = try await store.export()
        let listed = await store.snapshots()
        guard listed.first?.url.lastPathComponent == snapshot.url.lastPathComponent else {
            throw AppError.configuration("导出后清单里找不到这份备份")
        }
        let size = snapshot.sizeBytes
        guard size > 0 else { throw AppError.configuration("备份压缩包大小为 0") }
        try? FileManager.default.removeItem(at: root)
        return size
    }

    /// 坏数据：把 learning.db 换成随机字节，必须被隔离（不删除）并重建成功。
    func corruptedRecovery() throws -> String {
        let root = URL.temporaryDirectory.appendingPathComponent("alc-corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // 先建一个真库，再写坏它——这样才是「用着用着坏了」，而不是凭空一个垃圾文件。
        let url = root.appendingPathComponent("learning.db")
        _ = try LearningDatabase(path: url.path)
        try Data("这不是 SQLite —— 用来模拟磁盘写坏".utf8).write(to: url)

        let outcome = try DataResilience.openLearningDatabase(path: url.path)
        guard outcome.recovered else {
            throw AppError.database("坏库没有被识别/重建")
        }
        // 原文件必须在隔离区里还活着（绝不删除）。
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: DataResilience.quarantineDirectory(base: root),
            includingPropertiesForKeys: nil
        )
        guard !quarantined.isEmpty else {
            throw AppError.database("坏文件没有进隔离目录")
        }
        // 重建后的库要能接着用（第二次打开不应再次触发 recover）。
        let reopened = try DataResilience.openLearningDatabase(path: url.path)
        guard !reopened.recovered else {
            throw AppError.database("重建后的库再次被判定为损坏")
        }
        return quarantined.map(\.lastPathComponent).sorted().joined(separator: "、")
    }

    // MARK: - 产物 / 位置

    /// 基准产物里的原始条目（nil = 还没跑过基准）。
    func benchmarkEntries() -> [[String: Any]]? {
        guard let root = projectRoot else { return nil }
        let url = root.appendingPathComponent(".workbuddy/benchmark/latest.json", isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["entries"] as? [[String: Any]] else {
            return nil
        }
        return entries
    }

    func privacyLocations() -> [String] {
        PrivacyDataLocator.locations().map(\.title)
    }
}

private extension String {
    /// 把 NSRange 的位置换算成 1-based 行号。
    func lineNumber(of location: Int) -> Int {
        let index = self.index(self.startIndex, offsetBy: min(location, count))
        return self[..<index].reduce(1) { $0 + ($1 == "\n" ? 1 : 0) }
    }

    /// 该位置所在的行是不是注释（行首 trim 后是 `//`）。
    func isCommentLine(at location: Int) -> Bool {
        let clamped = min(max(location, 0), count)
        let position = index(startIndex, offsetBy: clamped)
        let start = range(of: "\n", options: .backwards, range: startIndex..<position)?.upperBound ?? startIndex
        let remainder = self[start...]
        let end = remainder.range(of: "\n")?.lowerBound ?? remainder.endIndex
        let line = String(remainder[..<end])
        return line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("//")
    }
}

// MARK: - Runner

/// 发布就绪检查执行器：**自动项真跑，人事项如实标注**。
///
/// 刻意不做的事：不会因为「这条自动检查不知道结论」就返回 passed。
/// 拿不到源码树（例如打包后的 .app）时，静态检查直接判失败并说明原因——
/// 一声不知道可以接受，一声假的通过不行。
public struct ReleaseReadinessRunner: Sendable {

    public let evidence: ReleaseEvidence

    public init(evidence: ReleaseEvidence = ReleaseEvidence.bootstrap()) {
        self.evidence = evidence
    }

    public func evaluate(now: Date = Date()) async -> ReleaseReadinessReport {
        var results: [ReleaseCheckResult] = []
        for item in ReleaseChecklist.items {
            let status: ReleaseCheckResult.Status = item.automated
                ? await verify(item)
                : .manual
            results.append(ReleaseCheckResult(item: item, status: status))
        }
        return ReleaseReadinessReport(generatedAt: now, results: results)
    }

    private func verify(_ item: ReleaseChecklist.Item) async -> ReleaseCheckResult.Status {
        switch item.id {
        case "build.noDebugDependency":
            return Self.checkNoDebugDependency(evidence: evidence)
        case "build.noHardcodedPaths":
            return Self.checkNoHardcodedPaths(evidence: evidence)
        case "build.noUnusableOverlay":
            return Self.checkNoUnusableOverlay(evidence: evidence)
        case "ai.unsupportedCapability":
            return Self.checkCapabilityCoverage()
        case "data.migration":
            return await migrateCheck()
        case "data.backupExport":
            return await backupCheck()
        case "data.corruptedHandled":
            return corruptedCheck()
        case "perf.memoryBench", "perf.latencyBench":
            return Self.checkBenchmark(evidence: evidence, wantsLatency: item.id == "perf.latencyBench")
        case "privacy.noUnintendedNetwork":
            return Self.checkNoUnintendedNetwork(evidence: evidence)
        case "privacy.noAudioInLogs":
            return Self.checkNoAudioInLogs(evidence: evidence)
        case "privacy.storageDocumented":
            return Self.checkStorageDocumented(evidence: evidence)
        default:
            // 清单说了可自动验证，那就必须有实现——漏实现是缺陷，不能悄悄变成 manual。
            return .failed("清单声明为自动检查，但没有对应实现")
        }
    }

    // MARK: 各项实现

    private static func checkNoDebugDependency(evidence: ReleaseEvidence) -> ReleaseCheckResult.Status {
        guard evidence.projectRoot != nil else {
            return .failed("拿不到源码树，无法静态检查")
        }
        let manifest = evidence.packageManifest()
        var offenders: [String] = []
        if manifest.contains(".package(path:") || manifest.contains(".package(name:") && manifest.contains("path:") {
            offenders.append("Package.swift 含本地路径依赖")
        }
        if manifest.contains("unsafeFlags") {
            offenders.append("Package.swift 使用了 unsafeFlags")
        }
        return offenders.isEmpty ? .passed : .failed(offenders.joined(separator: "；"))
    }

    private static func checkNoHardcodedPaths(evidence: ReleaseEvidence) -> ReleaseCheckResult.Status {
        guard evidence.projectRoot != nil else {
            return .failed("拿不到源码树，无法静态检查")
        }
        guard let rules = evidence.rules else {
            return .failed(evidence.ruleLoadError ?? "静态检查规则缺失")
        }
        var offenders: [String] = []
        let absolutePaths = rules.absolutePathPatterns.flatMap {
            evidence.matches(pattern: $0, scope: .all)
        }
        if !absolutePaths.isEmpty {
            offenders.append("硬编码绝对路径 \(absolutePaths.prefix(3).joined(separator: "、"))")
        }
        // 端口/端点红线只对正式代码生效（测试桩服务用 127.0.0.1 是合理的）。
        let endpoints = rules.hardcodedPortPatterns.flatMap {
            evidence.matches(pattern: $0, scope: .sources)
        }
        if !endpoints.isEmpty {
            offenders.append("正式代码出现硬编码端口 \(endpoints.prefix(3).joined(separator: "、"))")
        }
        return offenders.isEmpty ? .passed : .failed(offenders.joined(separator: "；"))
    }

    /// 核心能力必须有已经启用的供应商。
    ///
    /// 注意 VAD / embedding / 发音评测不在内：它们是本地算法能力，本来就不走供应商，
    /// 把它们算进来只会让这条检查永远红着，然后被人忽略掉。
    private static let providerBackedKinds: [AIProviderKind] = [.llm, .asr, .tts]

    private static func checkCapabilityCoverage() -> ReleaseCheckResult.Status {
        guard let configuration = try? DefaultConfiguration.load() else {
            return .failed("无法读取内置默认配置")
        }
        let enabledKinds = Set(configuration.providers.filter(\.enabled).map(\.kind))
        let missing = providerBackedKinds.filter { !enabledKinds.contains($0) }
        guard missing.isEmpty else {
            return .failed("这些核心能力没有默认启用的供应商：\(missing.map(\.displayName).joined(separator: "、"))")
        }
        return .passed
    }

    private func migrateCheck() async -> ReleaseCheckResult.Status {
        do {
            let version = try evidence.migration()
            return version == LearningDatabase.schemaVersion
                ? .passed
                : .failed("迁移后 schemaVersion=\(version)，期望 \(LearningDatabase.schemaVersion)")
        } catch {
            return .failed("迁移失败：\(error.localizedDescription)")
        }
    }

    private func backupCheck() async -> ReleaseCheckResult.Status {
        do {
            _ = try await evidence.backupExport()
            return .passed
        } catch {
            return .failed("导出备份失败：\(error.localizedDescription)")
        }
    }

    private func corruptedCheck() -> ReleaseCheckResult.Status {
        do {
            _ = try evidence.corruptedRecovery()
            return .passed
        } catch {
            return .failed("坏数据未被妥善隔离：\(error.localizedDescription)")
        }
    }

    /// 内存/时延基准：**看产物里到底有没有那列数据**，只看文件存在说明不了什么。
    private static func checkBenchmark(evidence: ReleaseEvidence, wantsLatency: Bool) -> ReleaseCheckResult.Status {
        guard let entries = evidence.benchmarkEntries() else {
            return .failed("没有基准产物，先跑 swift run alc-bench")
        }
        let llmEntries = entries.filter {
            ($0["name"] as? String ?? "").hasPrefix("generate")
                || ($0["name"] as? String ?? "").hasPrefix("stream")
        }
        guard !llmEntries.isEmpty else {
            return .failed("基准报告里没有 LLM 条目")
        }
        if wantsLatency {
            let hasLatency = llmEntries.contains { entry in
                let metrics = entry["metrics"] as? [String: Any] ?? [:]
                return (entry["durationSeconds"] as? Double) != nil
                    && (metrics["tokens_per_second"] != nil || metrics["ttft_seconds"] != nil)
            }
            guard hasLatency else {
                return .failed("基准条目缺少时延/吞吐字段（tokens_per_second 或 ttft_seconds）")
            }
        } else {
            let hasMemory = entries.contains { (($0["memoryBeforeBytes"] as? Int)) != nil }
            guard hasMemory else {
                return .failed("基准条目缺少内存采样字段（memoryBeforeBytes）")
            }
        }
        return .passed
    }

    private static func checkNoUnintendedNetwork(evidence: ReleaseEvidence) -> ReleaseCheckResult.Status {
        guard let rules = evidence.rules else {
            return .failed(evidence.ruleLoadError ?? "静态检查规则缺失")
        }
        let telemetry = rules.telemetryHostPatterns.flatMap {
            evidence.matches(pattern: $0, scope: .all)
        }
        if !telemetry.isEmpty {
            return .failed("源码出现遥测/上报域名：\(telemetry.prefix(3).joined(separator: "、"))")
        }
        guard let configuration = try? DefaultConfiguration.load() else {
            return .failed("无法读取内置默认配置")
        }
        let disclosure = PrivacyPolicy.disclosure(for: configuration)
        guard disclosure.isLocalOnly else {
            let flows = disclosure.flows.map { "\($0.displayName)→\($0.host)" }
            return .failed("默认配置就在外发：\(flows.joined(separator: "、"))（云端必须由用户显式启用）")
        }
        return .passed
    }

    private static func checkNoAudioInLogs(evidence: ReleaseEvidence) -> ReleaseCheckResult.Status {
        guard let rules = evidence.rules else {
            return .failed(evidence.ruleLoadError ?? "静态检查规则缺失")
        }
        let leaks = rules.audioLogPatterns.flatMap {
            evidence.matches(pattern: $0, scope: .sources)
        }
        return leaks.isEmpty
            ? .passed
            : .failed("日志疑似包含音频数据：\(leaks.prefix(3).joined(separator: "、"))")
    }

    /// SwiftUI 的**跨导入叠加** API 在本工程里不可用。
    ///
    /// 起因是一次真实事故：用 `AVKit` 的 `VideoPlayer` 渲染附件视频，
    /// 编译、单测、`swift build` 全部通过，应用一启动就 abort
    /// （叠加模块 `_AVKit_SwiftUI` 的类元数据初始化失败，栈顶停在 `getSuperclassMetadata`）。
    /// SwiftPM 对 cross-import overlay 的支持不完整，而症状只在运行时出现。
    ///
    /// 这类问题没法靠单测拦住（视图构建期就崩，测试根本跑不到那里），
    /// 所以放进发布静态检查：**用 AppKit 的 `AVPlayerView` 包一层是安全的替代**。
    /// 新增别的叠加 API 时把 token 加进规则表即可，不要在这里写死字面量（自指）。
    private static func checkNoUnusableOverlay(evidence: ReleaseEvidence) -> ReleaseCheckResult.Status {
        guard let rules = evidence.rules else {
            return .failed(evidence.ruleLoadError ?? "静态检查规则缺失")
        }
        let hits = rules.unusableOverlayPatterns.flatMap {
            evidence.matches(pattern: $0, scope: .sources)
        }
        return hits.isEmpty
            ? .passed
            : .failed("用了本工程不可用的 SwiftUI 叠加 API（启动时会崩）：\(hits.prefix(3).joined(separator: "、"))")
    }

    private static func checkStorageDocumented(evidence: ReleaseEvidence) -> ReleaseCheckResult.Status {
        let minimum = evidence.rules?.minimumLocalLocations ?? 3
        let titles = evidence.privacyLocations()
        guard titles.count >= minimum else {
            return .failed("本地存储清单只有 \(titles.count) 项，应至少覆盖 \(minimum) 项（学习库/配置/留痕）")
        }
        return .passed
    }
}

// MARK: - 产物落盘

/// 发布检查报告的存储（`.workbuddy/release/`）。
public struct ReleaseArtifactStore: Sendable {

    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }

    public static func defaultDirectory() -> URL {
        AppPaths.userDataDirectory()
            .deletingLastPathComponent() // .workbuddy/app-config → .workbuddy
            .appendingPathComponent("release", isDirectory: true)
    }

    /// 写一份带时间戳的 JSON + latest.json，并把 markdown 摘要写成 latest.md。
    @discardableResult
    public func write(_ report: ReleaseReadinessReport) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = Self.encoded(report)
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])

        let latest = directory.appendingPathComponent("latest.json")
        try data.write(to: latest)
        try report.markdownSummary().write(
            to: directory.appendingPathComponent("latest.md"),
            atomically: true,
            encoding: .utf8
        )
        let stamped = directory.appendingPathComponent("release-\(Self.fileStamp(report.generatedAt)).json")
        try data.write(to: stamped)
        return stamped
    }

    private static func encoded(_ report: ReleaseReadinessReport) -> [String: Any] {
        var results: [[String: Any]] = []
        for result in report.results {
            var row: [String: Any] = [
                "id": result.item.id,
                "title": result.item.title,
                "category": result.item.category.rawValue,
                "automated": result.item.automated,
                "status": StatusCoding.label(result.status),
            ]
            if case .failed(let reason) = result.status { row["reason"] = reason }
            row["guidance"] = result.item.guidance
            results.append(row)
        }
        return [
            "schemaVersion": ReleaseReadinessReport.schemaVersion,
            "generatedAt": Self.isoStamp(report.generatedAt),
            "passedCount": report.passedCount,
            "failedCount": report.failedResults.count,
            "manualCount": report.manualResults.count,
            "isReleaseReady": report.isReleaseReady,
            "results": results,
        ]
    }

    private enum StatusCoding {
        static func label(_ status: ReleaseCheckResult.Status) -> String {
            switch status {
            case .passed: "passed"
            case .manual: "manual"
            case .failed: "failed"
            }
        }
    }

    private static func isoStamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func fileStamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func pad(_ value: Int?) -> String { String(format: "%02d", value ?? 0) }
        return "\(pad(components.year))\(pad(components.month))\(pad(components.day))-\(pad(components.hour))\(pad(components.minute))\(pad(components.second))"
    }
}
