import AIDomain
import AIServices
import Foundation

/// 本地测速结果的**展示格式化**（纯函数：不碰 SwiftUI，可直接单测）。
///
/// 单独抽出来的理由：这几个数是给人看的（「0.92 s」而不是 0.9184772），
/// 格式一律只有一种写法，散在视图里就会出现「同一个数字两处长得不一样」。
enum BenchmarkText {

    /// 时延：小到毫秒才读得出来，大到几十秒就别再报两位小数。
    static func seconds(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        if value < 1 { return "\(Int((value * 1000).rounded())) ms" }
        if value < 10 { return String(format: "%.2f s", value) }
        return String(format: "%.1f s", value)
    }

    /// 吞吐（tokens/秒）。
    static func tokensPerSecond(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        return String(format: "%.1f tok/s", value)
    }

    /// 采样说明（中位值的可信度靠它：6 次和 1 次不是一回事）。
    static func samples(generate: Int, firstToken: Int) -> String {
        switch (generate, firstToken) {
        case (0, 0): return "没有采到样本"
        case (_, 0): return "\(generate) 次完整生成"
        case (0, _): return "\(firstToken) 次流式"
        default: return "\(generate) 次完整生成 · \(firstToken) 次流式"
        }
    }
}

/// 设置页「本地模型测速」卡片读的快照。
///
/// ⚠️ 存**格式化后的字符串**而不是原始 `LocalLLMBenchmark.Result`：卡片只需要显示，
/// 留着原始样本会让 AppState 一直抱着一堆数组（且 `BenchmarkSample` 不是 UI 该碰的类型）。
public struct BenchmarkSnapshot: Sendable, Equatable {
    /// 被测模型名（来自配置，代码里不写字面量）。
    public let model: String
    /// 整段生成的中位时延。
    public let generateText: String
    /// 流式首 token 的中位时延。
    public let firstTokenText: String
    /// 中位吞吐。
    public let throughputText: String
    /// 采样量说明。
    public let sampleText: String

    public init(
        model: String,
        generateText: String,
        firstTokenText: String,
        throughputText: String,
        sampleText: String
    ) {
        self.model = model
        self.generateText = generateText
        self.firstTokenText = firstTokenText
        self.throughputText = throughputText
        self.sampleText = sampleText
    }

    /// 从基准结果构造。
    ///
    /// - Returns: 三项指标一项都没采到时返回 nil —— 那种结果摆出来是一整列「—」，
    ///   看着像测过了其实什么都没测出来，不如如实说「这次没跑出数据」。
    public init?(result: LocalLLMBenchmark.Result) {
        let generate = result.generateLatency
        let firstToken = result.timeToFirstToken
        let throughput = result.throughput
        guard generate != nil || firstToken != nil || throughput != nil else { return nil }
        self.init(
            model: result.model,
            generateText: generate.map { BenchmarkText.seconds($0.p50) } ?? "—",
            firstTokenText: firstToken.map { BenchmarkText.seconds($0.p50) } ?? "—",
            throughputText: throughput.map { BenchmarkText.tokensPerSecond($0.p50) } ?? "—",
            sampleText: BenchmarkText.samples(
                generate: generate?.count ?? 0,
                firstToken: firstToken?.count ?? 0
            )
        )
    }
}
