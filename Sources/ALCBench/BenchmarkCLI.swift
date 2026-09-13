import AIInfrastructure
import AIServices
import Foundation

/// 本地模型基准命令行：`swift run alc-bench`。
///
/// 全部走本地 runtime（Ollama），**零云端费用**；报告落到 `.workbuddy/benchmark/`。
/// 环境变量：
/// - `ALC_BENCH_ROUNDS`：每个提示词跑几轮（默认 3）。
@main
struct BenchmarkCLI {

    static func main() async {
        do {
            try await run()
        } catch {
            print("[alc-bench] 失败：\(error.localizedDescription)")
            exit(1)
        }
    }

    static func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        let rounds = Int(environment["ALC_BENCH_ROUNDS"] ?? "") ?? 3

        let configuration = await ConfigStore.shared.current
        let benchmark = LocalLLMBenchmark(rounds: rounds)

        let result: LocalLLMBenchmark.Result
        do {
            result = try await benchmark.run(configuration: configuration)
        } catch let unavailable as LocalLLMBenchmark.BenchmarkUnavailable {
            print("[alc-bench] 已跳过：\(unavailable.localizedDescription)")
            print("提示：先启动 Ollama，并在「设置 → 模型管理」里选好本地模型后再跑。")
            return
        }

        let report = BenchmarkReport(
            entries: result.samples,
            notes: "本地模型 \(result.model) · \(result.endpoint) · \(rounds) 轮"
        )
        let store = BenchmarkArtifactStore()
        let url = try store.write(report)

        print(report.markdownSummary())
        print("")
        if let latency = result.generateLatency {
            print("生成耗时：p50 \(Self.number(latency.p50))s · p95 \(Self.number(latency.p95))s")
        }
        if let ttft = result.timeToFirstToken {
            print("首 token： p50 \(Self.number(ttft.p50))s · p95 \(Self.number(ttft.p95))s")
        }
        if let throughput = result.throughput {
            print("吞吐：     p50 \(Self.number(throughput.p50)) tok/s · p95 \(Self.number(throughput.p95)) tok/s")
        }
        print("产物：\(url.path)")
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
