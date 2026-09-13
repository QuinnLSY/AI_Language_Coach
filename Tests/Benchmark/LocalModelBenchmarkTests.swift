import AIInfrastructure
import AIServices
import AppCore
import Foundation
import XCTest

/// 真实本地模型的基准。
///
/// 默认**跳过**（需要本地 runtime 与模型，CI 里没有）。
/// 想跑真机：`ALC_BENCH_REAL=1 swift test --disable-sandbox --filter LocalModelBenchmarkTests`
final class LocalModelBenchmarkTests: XCTestCase {

    /// 供应商选择是纯逻辑，不需要真机——这里必须覆盖。
    func testLocalLLMProviderIsPickedFromConfiguration() throws {
        let configuration = try DefaultConfiguration.load()
        let provider = try XCTUnwrap(LocalLLMBenchmark.localLLMProvider(in: configuration))
        XCTAssertEqual(provider.kind, .llm)
        XCTAssertEqual(provider.runtime, .ollama)
        XCTAssertFalse(provider.endpoint?.isEmpty ?? true)

        let empty = AppConfiguration()
        XCTAssertNil(LocalLLMBenchmark.localLLMProvider(in: empty))
    }

    func testUnavailableBenchmarkExplainsItself() async throws {
        // 空配置 → 既不能伪装成功，也不该崩。
        let benchmark = LocalLLMBenchmark(rounds: 1)
        do {
            _ = try await benchmark.run(configuration: AppConfiguration())
            XCTFail("空配置不该跑出结果")
        } catch let unavailable as LocalLLMBenchmark.BenchmarkUnavailable {
            XCTAssertNotNil(unavailable.errorDescription)
        }
    }

    /// 真机基准：跑本地 Ollama，产出版本化报告，并断言口径合理（不是 0 秒、不是空文本）。
    func testLocalRuntimeBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["ALC_BENCH_REAL"] == "1" else {
            throw XCTSkip("需要本地 runtime：用 ALC_BENCH_REAL=1 开启")
        }

        let configuration = await ConfigStore.shared.current
        let benchmark = LocalLLMBenchmark(rounds: 1)
        let result: LocalLLMBenchmark.Result
        do {
            result = try await benchmark.run(configuration: configuration)
        } catch let unavailable as LocalLLMBenchmark.BenchmarkUnavailable {
            throw XCTSkip("本地 runtime 不可用：\(unavailable.localizedDescription)")
        }

        XCTAssertFalse(result.samples.isEmpty)
        let generate = result.samples.filter { $0.name.hasPrefix("generate") }
        XCTAssertFalse(generate.isEmpty)
        XCTAssertTrue(generate.allSatisfy { $0.durationSeconds > 0 })

        let store = BenchmarkArtifactStore()
        _ = try store.write(BenchmarkReport(
            entries: result.samples,
            notes: "真机基准 · \(result.model)"
        ))
    }
}
