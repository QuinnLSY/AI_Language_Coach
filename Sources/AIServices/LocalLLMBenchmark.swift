import AIDomain
import AIInfrastructure
import AIInterfaces
import AIProviders
import AppCore
import Foundation

/// 本地大模型的真实基准（Implementation Plan §32 的 LLM 维度：TTFT / tokens-per-second / 内存）。
///
/// 放在服务层而不是测试里的原因：它要被两处复用——
/// ① `alc-bench` 命令行（开发者手动跑）；② 需要真机的基准用例（用环境变量开启）。
/// 全部走本地 runtime，**不产生任何云端费用**。
public struct LocalLLMBenchmark: Sendable {

    public struct Result: Sendable {
        /// 被测模型名（来自配置，代码里没有字面量）。
        public let model: String
        /// 被测端点（来自配置）。
        public let endpoint: String
        public let samples: [BenchmarkSample]
        /// 非流式生成的时延分布。
        public let generateLatency: BenchmarkMetrics.LatencySummary?
        /// 流式首 token 时延分布。
        public let timeToFirstToken: BenchmarkMetrics.LatencySummary?
        /// 吞吐分布（tokens/秒）。
        public let throughput: BenchmarkMetrics.LatencySummary?

        public init(model: String, endpoint: String, samples: [BenchmarkSample]) {
            self.model = model
            self.endpoint = endpoint
            self.samples = samples
            // 只看默认档位：关思考那一档是对照项，混进来会把结论搅浑。
            let generate = samples.filter { $0.name.hasPrefix("generate#") }
            self.generateLatency = BenchmarkMetrics.latencySummary(generate.map(\.durationSeconds))
            let ttft = samples.compactMap(\.timeToFirstEventSeconds)
            self.timeToFirstToken = BenchmarkMetrics.latencySummary(ttft)
            self.throughput = BenchmarkMetrics.latencySummary(
                samples.compactMap { $0.metrics["tokens_per_second"] }
            )
        }
    }

    /// 基准无法进行的原因（这些不是「失败」，是「没条件跑」）。
    public enum BenchmarkUnavailable: Error, LocalizedError, Sendable {
        case noLocalProvider
        case missingModel
        case runtimeUnavailable(String)

        public var errorDescription: String? {
            switch self {
            case .noLocalProvider:
                "配置里没有可用的本地 LLM 供应商"
            case .missingModel:
                "本地供应商没有配置模型名"
            case .runtimeUnavailable(let reason):
                "本地 runtime 不可用：\(reason)"
            }
        }
    }

    /// 基准用的固定提示词：短、确定、能代表真实对话负载。
    private static let prompts = [
        "Please correct this sentence and explain briefly: I has went to the store yesterday.",
        "Give me a short reply as my English coach: how do I ask for a window seat at a cafe?",
        "Translate to natural English: 我昨天本来想去，但是临时有事。",
    ]

    /// 推理档位对照：nil = 尊重用户配置；`"none"` = 关掉思考（确定性短任务该这么做）。
    static let efforts: [(label: String, value: String?)] = [
        ("generate", nil),
        ("generate-nothink", LLMRequest.noThinkingEffort),
    ]

    public let rounds: Int
    private let runner: BenchmarkRunner

    public init(rounds: Int = 3, runner: BenchmarkRunner = BenchmarkRunner()) {
        self.rounds = max(1, rounds)
        self.runner = runner
    }

    /// 跑一轮完整基准（非流式 + 流式）。
    public func run(configuration: AppConfiguration) async throws -> Result {
        guard let provider = Self.localLLMProvider(in: configuration) else {
            throw BenchmarkUnavailable.noLocalProvider
        }
        guard let model = provider.model, !model.isEmpty else {
            throw BenchmarkUnavailable.missingModel
        }
        let endpoint = provider.endpoint ?? ""

        let adapter = OllamaLLMAdapter(providerID: provider.id)
        do {
            try await adapter.initialize(config: provider)
            try await adapter.load()
        } catch {
            throw BenchmarkUnavailable.runtimeUnavailable(error.localizedDescription)
        }

        var samples: [BenchmarkSample] = []

        for round in 1...rounds {
            for (index, prompt) in Self.prompts.enumerated() {
                // ① 非流式：拿得到 usage，算出真实吞吐。
                //    默认档位与「关思考」档位各跑一次——推理模型（qwen3 / deepseek-r1）
                //    的思考段会吃掉 max_tokens，正文反而为空，两档对照才有决策价值。
                for effort in Self.efforts {
                    let request = LLMRequest(
                        messages: [LLMMessage(role: .user, content: prompt)],
                        model: model,
                        maxTokens: 256,
                        streaming: false,
                        reasoningEffort: effort.value
                    )
                    let generate = try await runner.measure(
                        dimension: .llm,
                        case: "\(effort.label)#\(round)-\(index + 1)",
                        metrics: { response, duration in
                            var metrics: [String: Double] = [:]
                            if let completion = response.usage?.completionTokens {
                                metrics["completion_tokens"] = Double(completion)
                                if let tps = BenchmarkMetrics.tokensPerSecond(tokens: completion, seconds: duration) {
                                    metrics["tokens_per_second"] = tps
                                }
                            }
                            let reasoning = (response.reasoning ?? "").count
                            metrics["characters"] = Double(response.text.count)
                            metrics["reasoning_characters"] = Double(reasoning)
                            return metrics
                        },
                        body: { try await adapter.generate(request) }
                    )
                    samples.append(generate.sample)
                }

                // ② 流式：测首 token 时延（用户体感的「卡不卡」）。
                let streamRequest = LLMRequest(
                    messages: [LLMMessage(role: .user, content: prompt)],
                    model: model,
                    maxTokens: 256,
                    streaming: true
                )
                let stream = try await runner.measure(
                    dimension: .llm,
                    case: "stream#\(round)-\(index + 1)",
                    metrics: { run, _ in
                        var metrics: [String: Double] = [
                            "chunks": Double(run.chunks),
                            "characters": Double(run.characters),
                            "reasoning_characters": Double(run.reasoningCharacters),
                        ]
                        if let ttft = run.timeToFirstTokenSeconds {
                            metrics["ttft_seconds"] = ttft
                        }
                        return metrics
                    },
                    body: { () async throws -> StreamRun in
                        let start = Date()
                        var firstAt: Date?
                        var chunks = 0
                        var characters = 0
                        var reasoning = 0
                        for try await chunk in adapter.stream(streamRequest) {
                            if firstAt == nil { firstAt = Date() }
                            chunks += 1
                            characters += chunk.textDelta.count
                            reasoning += chunk.reasoningDelta?.count ?? 0
                        }
                        return StreamRun(
                            chunks: chunks,
                            characters: characters,
                            reasoningCharacters: reasoning,
                            timeToFirstTokenSeconds: firstAt.map {
                                BenchmarkMetrics.timeToFirstTokenSeconds(start: start, first: $0)
                            }
                        )
                    }
                )
                var streamSample = stream.sample
                if let ttft = stream.value.timeToFirstTokenSeconds {
                    streamSample = BenchmarkSample(
                        dimension: streamSample.dimension,
                        name: streamSample.name,
                        durationSeconds: streamSample.durationSeconds,
                        timeToFirstEventSeconds: ttft,
                        memoryBeforeBytes: streamSample.memoryBeforeBytes,
                        memoryAfterBytes: streamSample.memoryAfterBytes,
                        peakMemoryDeltaBytes: streamSample.peakMemoryDeltaBytes,
                        metrics: streamSample.metrics
                    )
                }
                samples.append(streamSample)
            }
        }

        return Result(model: model, endpoint: endpoint, samples: samples)
    }

    /// 选出「本地 runtime + 已启用」的 LLM 供应商。
    public static func localLLMProvider(in configuration: AppConfiguration) -> ProviderConfig? {
        configuration.providers.first {
            $0.kind == .llm && $0.runtime == .ollama && $0.enabled
        } ?? configuration.providers.first {
            $0.kind == .llm && $0.runtime == .ollama
        }
    }

    private struct StreamRun: Sendable {
        let chunks: Int
        let characters: Int
        let reasoningCharacters: Int
        let timeToFirstTokenSeconds: Double?
    }
}
