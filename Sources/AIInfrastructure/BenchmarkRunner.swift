import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 基准维度（Implementation Plan §32：ASR / LLM / TTS / Pronunciation / System）。
public enum BenchmarkDimension: String, Codable, Sendable, CaseIterable {
    case asr
    case llm
    case tts
    case pronunciation
    case system
}

/// 一次基准测量的结果。
///
/// 只保留**可比对的量**：耗时、首事件时延、内存前后与峰值增量，
/// 以及各维度自己的指标（WER / tokens-per-second / RTF…）。
/// 指标名散落在各处容易对不上，因此统一走 `metrics` 字典，键由各基准用例自行定义。
public struct BenchmarkSample: Codable, Sendable, Equatable {
    public let dimension: BenchmarkDimension
    public let name: String
    public let durationSeconds: Double
    public let timeToFirstEventSeconds: Double?
    public let memoryBeforeBytes: UInt64?
    public let memoryAfterBytes: UInt64?
    /// 采样期间「可用内存下降的最大值」，用来近似本次任务的峰值占用。
    public let peakMemoryDeltaBytes: UInt64?
    public let metrics: [String: Double]

    public init(
        dimension: BenchmarkDimension,
        name: String,
        durationSeconds: Double,
        timeToFirstEventSeconds: Double? = nil,
        memoryBeforeBytes: UInt64? = nil,
        memoryAfterBytes: UInt64? = nil,
        peakMemoryDeltaBytes: UInt64? = nil,
        metrics: [String: Double] = [:]
    ) {
        self.dimension = dimension
        self.name = name
        self.durationSeconds = durationSeconds
        self.timeToFirstEventSeconds = timeToFirstEventSeconds
        self.memoryBeforeBytes = memoryBeforeBytes
        self.memoryAfterBytes = memoryAfterBytes
        self.peakMemoryDeltaBytes = peakMemoryDeltaBytes
        self.metrics = metrics
    }
}

/// 机器环境快照——没有它，两份报告之间的数字差异无从解释。
public struct BenchmarkEnvironment: Codable, Sendable, Equatable {
    public let operatingSystem: String
    public let modelIdentifier: String
    public let memoryBytes: UInt64
    public let processorCount: Int

    public init(operatingSystem: String, modelIdentifier: String, memoryBytes: UInt64, processorCount: Int) {
        self.operatingSystem = operatingSystem
        self.modelIdentifier = modelIdentifier
        self.memoryBytes = memoryBytes
        self.processorCount = processorCount
    }

    public static var current: BenchmarkEnvironment {
        BenchmarkEnvironment(
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            modelIdentifier: Self.sysctlString("hw.model") ?? "unknown",
            memoryBytes: Self.sysctlUInt64("hw.memsize") ?? 0,
            processorCount: ProcessInfo.processInfo.processorCount
        )
    }

    private static func sysctlString(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return nil }
        let raw = buffer.withUnsafeBufferPointer { Data(buffer: $0) }
        return String(decoding: raw, as: UTF8.self).trimmingCharacters(in: ["\0"])
    }

    private static func sysctlUInt64(_ key: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(key, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}

/// 一份**版本化**的基准报告（§32 要求结果作为版本化产物留存）。
public struct BenchmarkReport: Codable, Sendable, Equatable {
    /// 报告结构版本：结构变了就 +1，老报告仍能被读懂（解码时据此兼容）。
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: Date
    public let environment: BenchmarkEnvironment
    public let entries: [BenchmarkSample]
    public let notes: String?

    public init(entries: [BenchmarkSample], environment: BenchmarkEnvironment = .current,
                generatedAt: Date = Date(), notes: String? = nil) {
        self.schemaVersion = Self.currentSchemaVersion
        self.generatedAt = generatedAt
        self.environment = environment
        self.entries = entries
        self.notes = notes
    }

    /// 人类可读摘要（用于日志与终端输出）。
    public func markdownSummary() -> String {
        var lines: [String] = []
        lines.append("# Benchmark Report v\(schemaVersion)")
        lines.append("")
        lines.append("- 生成时间：\(Self.isoString(generatedAt))")
        lines.append("- 环境：\(environment.operatingSystem) · \(environment.modelIdentifier) · "
            + "\(ByteFormatter.string(environment.memoryBytes)) 内存 · \(environment.processorCount) 核")
        if let notes, !notes.isEmpty {
            lines.append("- 备注：\(notes)")
        }
        lines.append("")
        lines.append("| 维度 | 用例 | 耗时(s) | 首事件(s) | 峰值内存 | 指标 |")
        lines.append("| --- | --- | --- | --- | --- | --- |")
        for entry in entries {
            let metrics = entry.metrics
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\(Self.number($0.value))" }
                .joined(separator: ", ")
            lines.append("| \(entry.dimension.rawValue) | \(entry.name) | \(Self.number(entry.durationSeconds)) | "
                + "\(entry.timeToFirstEventSeconds.map { Self.number($0) } ?? "-") | "
                + "\(entry.peakMemoryDeltaBytes.map { ByteFormatter.string($0) } ?? "-") | \(metrics) |")
        }
        return lines.joined(separator: "\n")
    }

    /// 按需创建：Formatter 不是 Sendable，做成静态常量会在 Swift 6 下被判为共享可变状态。
    public static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func number(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

/// 字节数的人类可读表示（MB/GB）。
public enum ByteFormatter {
    public static func string(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1fGB", gb) }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.0fMB", mb) }
        let kb = Double(bytes) / 1024
        if kb >= 1 { return String(format: "%.0fKB", kb) }
        return "\(bytes)B"
    }
}

/// 基准运行器：负责**计时与内存采样**，不关心被测的是什么。
///
/// 用法：
/// ```swift
/// let (value, sample) = try await runner.measure(dimension: .llm, case: "greeting") {
///     try await llm.generate(request)
/// }
/// ```
public actor BenchmarkRunner {
    private let monitor: any MemoryPressureMonitoring
    private let samplingIntervalNanoseconds: UInt64

    public init(monitor: any MemoryPressureMonitoring = OSMemoryPressureMonitor(),
                samplingIntervalNanoseconds: UInt64 = 50_000_000) {
        self.monitor = monitor
        self.samplingIntervalNanoseconds = samplingIntervalNanoseconds
    }

    /// 跑一次测量。
    /// - Parameter metrics: 由调用方给出的维度专属指标（WER / tokens-per-second / RTF…）。
    public func measure<Value: Sendable>(
        dimension: BenchmarkDimension,
        case name: String,
        metrics: @Sendable (Value, Double) async -> [String: Double] = { _, _ in [:] },
        body: @Sendable () async throws -> Value
    ) async throws -> (value: Value, sample: BenchmarkSample) {
        let sampler = monitor
        let before = sampler.availableMemoryBytes()
        let tracker = MinimumTracker()
        let samplerTask = Task.detached(priority: .utility) { [samplingIntervalNanoseconds] in
            while !Task.isCancelled {
                if let available = sampler.availableMemoryBytes() {
                    tracker.observe(available)
                }
                try? await Task.sleep(nanoseconds: samplingIntervalNanoseconds)
            }
        }
        defer { samplerTask.cancel() }

        let clock = ContinuousClock()
        let start = clock.now
        let value = try await body()
        let elapsed = clock.now - start
        let duration = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18

        let after = sampler.availableMemoryBytes()
        let lowest = tracker.minimum
        var peak: UInt64?
        if let before, let lowest {
            // 可用内存掉得越多，说明这次任务吃得越多；系统其他进程也会扰动，因此是估算值。
            peak = before > lowest ? before - lowest : 0
        }

        let sample = BenchmarkSample(
            dimension: dimension,
            name: name,
            durationSeconds: duration,
            timeToFirstEventSeconds: nil,
            memoryBeforeBytes: before,
            memoryAfterBytes: after,
            peakMemoryDeltaBytes: peak,
            metrics: await metrics(value, duration)
        )
        return (value, sample)
    }

    /// 批量跑同一用例多次，返回原始样本（分布统计交给 `BenchmarkMetrics`）。
    public func repeated<Value: Sendable>(
        dimension: BenchmarkDimension,
        case name: String,
        times: Int,
        body: @Sendable () async throws -> Value
    ) async throws -> [BenchmarkSample] {
        guard times > 0 else { return [] }
        var samples: [BenchmarkSample] = []
        for round in 1...times {
            let (_, sample) = try await measure(
                dimension: dimension,
                case: "\(name)#\(round)",
                body: body
            )
            samples.append(sample)
        }
        return samples
    }
}

/// 采样过程中的最小值记录器（跨 Task 共享，用锁保护）。
private final class MinimumTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64?

    func observe(_ candidate: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if let current = value {
            value = min(current, candidate)
        } else {
            value = candidate
        }
    }

    var minimum: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// 基准产物的落盘与读取（§32：results stored as versioned artifacts）。
public struct BenchmarkArtifactStore: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            self.directory = root.appendingPathComponent(".workbuddy/benchmark", isDirectory: true)
        }
    }

    /// 文件名用的时间戳（同样按需创建，避免共享可变状态）。
    private static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "benchmark-\(formatter.string(from: date)).json"
    }

    /// 写入一份**带时间戳**的报告，并同步刷新 `latest.json`。
    @discardableResult
    public func write(_ report: BenchmarkReport) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = Self.fileName(for: report.generatedAt)
        let url = directory.appendingPathComponent(name)
        let data = try Self.encoder.encode(report)
        try data.write(to: url, options: .atomic)
        try data.write(to: directory.appendingPathComponent("latest.json"), options: .atomic)
        return url
    }

    public func loadLatest() throws -> BenchmarkReport? {
        let url = directory.appendingPathComponent("latest.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try Self.decoder.decode(BenchmarkReport.self, from: data)
    }

    /// 目录下的全部历史报告（按文件名升序 = 时间升序）。
    public func loadHistory() throws -> [BenchmarkReport] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("benchmark-") && $0.pathExtension == "json" }
        return try contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try Self.decoder.decode(BenchmarkReport.self, from: Data(contentsOf: $0)) }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
