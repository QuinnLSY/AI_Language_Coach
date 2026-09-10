import AIDomain
import AIInterfaces
import Foundation

/// 发音评测编排服务（第 23 步 Pronunciation Engine）。
///
/// 职责只有一件：把「录音 + 文本对齐」交给 `AIDomain.PronunciationScorer` 这个纯函数，
/// 声学事实由 `SpeechAnalyzer` 从录音里直接量出 —— **首版不依赖任何发音模型**
/// （Implementation Plan §23 的硬要求）。
///
/// 音素级打分（`PronunciationProvider`）是**可插拔**的：将来接上 GOP / wav2vec 之类的
/// 音素模型，把它从 Provider 工厂装进来即可；模型缺席或报错时，评测照常进行，
/// 只是「音准」维度不显示（宁可少一项，也不拿别的维度冒充）。
public actor PronunciationService {

    /// 可选的音素级模型（nil = 未接入）。
    private let phonemeProvider: (any PronunciationProvider)?

    public init(phonemeProvider: (any PronunciationProvider)? = nil) {
        self.phonemeProvider = phonemeProvider
    }

    /// 评测一次发音。
    ///
    /// - Parameters:
    ///   - comparison: 传入跟读页已有的对齐结果，保证词准确度与逐词反馈**同源**。
    public func report(
        reference: String,
        recognized: String,
        samples: [Float],
        sampleRate: Double,
        comparison: ShadowingComparison? = nil
    ) async -> PronunciationReport {
        let metrics = SpeechAnalyzer.analyze(samples: samples, sampleRate: sampleRate)
        var phonemes: [PhonemeRating] = []
        if let phonemeProvider {
            do {
                let result = try await phonemeProvider.evaluate(
                    audioSamples: samples, referenceText: reference
                )
                phonemes = result.phonemes.map { PhonemeRating(phoneme: $0.phoneme, score: $0.score) }
            } catch {
                // 音素模型失败不阻塞评测：这一维本来就是可插拔的，缺席不算错误。
            }
        }
        return PronunciationScorer.report(
            reference: reference,
            recognized: recognized,
            metrics: metrics,
            phonemes: phonemes,
            comparison: comparison
        )
    }
}
