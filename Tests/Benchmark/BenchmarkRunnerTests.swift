import AIInfrastructure
import AppCore
import Foundation
import XCTest

/// 运行器与产物落盘的测试。
///
/// 内存用「脚本化的假监控」驱动，避免真机内存波动让断言变成抽奖。
final class BenchmarkRunnerTests: XCTestCase {

    func testMeasureRecordsDurationAndMetrics() async throws {
        let runner = BenchmarkRunner(monitor: ScriptedMemoryMonitor([1_000, 1_000, 1_000]))
        let (value, sample) = try await runner.measure(
            dimension: .llm,
            case: "mock-generate",
            metrics: { text, duration in
                ["characters": Double(text.count), "duration_seen": duration]
            }
        ) {
            try? await Task.sleep(nanoseconds: 60_000_000)
            return "hello"
        }

        XCTAssertEqual(value, "hello")
        XCTAssertEqual(sample.dimension, .llm)
        XCTAssertEqual(sample.name, "mock-generate")
        XCTAssertGreaterThan(sample.durationSeconds, 0.05)
        XCTAssertLessThan(sample.durationSeconds, 5)
        XCTAssertEqual(sample.metrics["characters"], 5)
        // metrics 闭包拿得到实测耗时，才能算出 tokens/秒这类派生指标。
        XCTAssertEqual(sample.metrics["duration_seen"] ?? 0, sample.durationSeconds, accuracy: 1e-6)
    }

    func testMemorySamplerReportsPeakDelta() async throws {
        // 基线 1000，采样期间最低掉到 700 → 峰值增量 300。
        let runner = BenchmarkRunner(
            monitor: ScriptedMemoryMonitor([1_000, 900, 700, 850]),
            samplingIntervalNanoseconds: 5_000_000
        )
        let (_, sample) = try await runner.measure(dimension: .asr, case: "mock-transcribe") {
            try? await Task.sleep(nanoseconds: 120_000_000)
            return 42
        }
        let peak = try XCTUnwrap(sample.peakMemoryDeltaBytes)
        XCTAssertGreaterThanOrEqual(peak, 100)
        XCTAssertLessThanOrEqual(peak, 300)
        XCTAssertEqual(sample.memoryBeforeBytes, 1_000)
    }

    func testRepeatedRunsProduceOneSamplePerRound() async throws {
        let runner = BenchmarkRunner(monitor: ScriptedMemoryMonitor([1_000]))
        let samples = try await runner.repeated(dimension: .tts, case: "mock-speak", times: 3) {
            try? await Task.sleep(nanoseconds: 1_000_000)
            return 1
        }
        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(samples.map(\.name), ["mock-speak#1", "mock-speak#2", "mock-speak#3"])
    }

    // MARK: - 产物

    func testReportRoundTripsThroughDiskAndIsVersioned() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = BenchmarkArtifactStore(directory: directory)
        let entries = [
            BenchmarkSample(dimension: .llm, name: "generate#1", durationSeconds: 1.25,
                            timeToFirstEventSeconds: 0.3, metrics: ["tokens_per_second": 24.5]),
            BenchmarkSample(dimension: .asr, name: "transcribe#1", durationSeconds: 0.8,
                            metrics: ["wer": 0.12]),
        ]
        let report = BenchmarkReport(entries: entries, notes: "单元测试")
        let url = try store.write(report)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.lastPathComponent.hasPrefix("benchmark-"), true)

        let decoded = try XCTUnwrap(try store.loadLatest())
        XCTAssertEqual(decoded.schemaVersion, BenchmarkReport.currentSchemaVersion)
        XCTAssertEqual(decoded.entries.count, 2)
        XCTAssertEqual(decoded.entries.first?.metrics["tokens_per_second"], 24.5)
        XCTAssertEqual(decoded.entries.first?.timeToFirstEventSeconds, 0.3)
        XCTAssertEqual(decoded.notes, "单元测试")
    }

    func testHistoryKeepsEveryRunAsSeparateArtifact() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = BenchmarkArtifactStore(directory: directory)
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        try store.write(BenchmarkReport(
            entries: [BenchmarkSample(dimension: .system, name: "cold-start", durationSeconds: 2)],
            generatedAt: first
        ))
        try store.write(BenchmarkReport(
            entries: [BenchmarkSample(dimension: .system, name: "cold-start", durationSeconds: 3)],
            generatedAt: first.addingTimeInterval(120)
        ))

        let history = try store.loadHistory()
        XCTAssertEqual(history.count, 2)
        // 升序：老的在前面，方便做「升级前后对比」。
        XCTAssertEqual(history.first?.entries.first?.durationSeconds, 2)
        XCTAssertEqual(history.last?.entries.first?.durationSeconds, 3)
    }

    func testMarkdownSummaryIsHumanReadable() {
        let report = BenchmarkReport(entries: [
            BenchmarkSample(dimension: .llm, name: "generate#1", durationSeconds: 1.5,
                            timeToFirstEventSeconds: 0.2, peakMemoryDeltaBytes: 512 * 1_048_576,
                            metrics: ["tokens_per_second": 30]),
        ])
        let text = report.markdownSummary()
        XCTAssertTrue(text.contains("llm"))
        XCTAssertTrue(text.contains("generate#1"))
        XCTAssertTrue(text.contains("tokens_per_second=30.000"))
        XCTAssertTrue(text.contains("512MB"))
    }

    // MARK: - 辅助

    private func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("alc-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// 按脚本返回可用内存的假监控（读到底后停在最后一个值）。
private final class ScriptedMemoryMonitor: MemoryPressureMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private let values: [UInt64]
    private var index = 0

    init(_ values: [UInt64]) {
        self.values = values
    }

    func availableMemoryBytes() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard index < values.count else { return values.last }
        let value = values[index]
        index += 1
        return value
    }
}
