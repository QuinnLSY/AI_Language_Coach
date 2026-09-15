import AIDomain
import AIInfrastructure
import AIInterfaces
import AppCore
import Foundation

/// 发音评测编排服务（第 23 步 Pronunciation Engine）。
///
/// 职责：把「录音 + 文本对齐 + 音素」三样东西汇成一份 `PronunciationReport`。
/// 声学事实（语速 / 停顿 / 流利度 / 重音 / 语调）由 `SpeechAnalyzer` 从录音里直接量出。
///
/// **音素级打分是双通道的**（2026-09-15 接入）：
///
/// | 通道 | 触发条件 | 性质 |
/// |---|---|---|
/// | 声学实测 | 装了 `PronunciationProvider`（云端发音评估）且调用成功 | 真·逐音素声学打分 |
/// | 规则推断 | 没有 provider，或 provider 调用失败 | 参考句与识别结果的音素加权对齐 |
///
/// 两条通道**如实标注来源**（`PhonemeSource`）：推断 ≠ 实测，用户有权知道卡片上
/// 那个「ɹ 42」是录音量出来的，还是按发音部位推算出来的。
/// 降级不报错、不阻塞：音素这一维拿不到就不显示（宁可少一项，也不拿别的维度冒充）。
public actor PronunciationService {

    /// 声学通道：可选的音素级 Provider（nil = 未接入）。
    private var phonemeProvider: (any PronunciationProvider)?
    /// 规则推断用的词库。
    private let lexicon: PhonemeLexicon

    public init(
        phonemeProvider: (any PronunciationProvider)? = nil,
        lexicon: PhonemeLexicon? = nil
    ) {
        self.phonemeProvider = phonemeProvider
        // 词库是随包静态资源，默认取进程内缓存（解析一次，长期复用）。
        self.lexicon = lexicon ?? PhonemeLexiconStore.shared()
    }

    /// 装配 / 卸下声学通道（配置变化后由 Application Service 调用）。
    ///
    /// 用「就地挂载」而不是重建服务实例：`ShadowingService` 等已经持有本实例的引用，
    /// 换实例会让它们手里的引用指向一个永远没有声学通道的旧对象。
    public func attachAcousticProvider(_ provider: (any PronunciationProvider)?) {
        phonemeProvider = provider
    }

    /// 当前是否有声学通道（诊断 / UI 可据此说明「这次是实测还是推断」）。
    public var hasAcousticChannel: Bool { phonemeProvider != nil }

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

        // ① 声学通道：拿到就用实测结论。
        if let phonemeProvider,
           let acoustic = await acousticResult(
               provider: phonemeProvider, samples: samples, reference: reference
           ) {
            return PronunciationScorer.report(
                reference: reference, recognized: recognized, metrics: metrics,
                phonemes: acoustic.ratings,
                phonemeWords: acoustic.words,
                phonemeSource: .acoustic,
                comparison: comparison
            )
        }

        // ② 规则推断通道：音素序列对齐。参考句没有可读词时结论为「无音素」。
        let words = PhonemeAssessment.assess(
            reference: reference, recognized: recognized, lexicon: lexicon
        )
        return PronunciationScorer.report(
            reference: reference, recognized: recognized, metrics: metrics,
            phonemeWords: words,
            phonemeSource: words.isEmpty ? .none : .inference,
            comparison: comparison
        )
    }

    /// 调一次声学通道；失败返回 nil（降级到规则推断，而不是整份报告报废）。
    ///
    /// 音素模型失败**不阻塞评测**：这一维本来就是可插拔的，缺席不算错误。
    private func acousticResult(
        provider: any PronunciationProvider,
        samples: [Float],
        reference: String
    ) async -> (ratings: [PhonemeRating], words: [PhonemeWordAssessment])? {
        do {
            let result = try await provider.evaluate(audioSamples: samples, referenceText: reference)
            let ratings = result.phonemes.map { PhonemeRating(phoneme: $0.phoneme, score: $0.score) }
            guard !ratings.isEmpty else { return nil }
            let words = result.words.map { word in
                PhonemeWordAssessment(
                    word: word.word,
                    phonemes: word.phonemes.map { PhonemeRating(phoneme: $0.phoneme, score: $0.score) },
                    score: word.phonemes.isEmpty
                        ? 0
                        : word.phonemes.map(\.score).reduce(0, +) / Double(word.phonemes.count),
                    status: .aligned
                )
            }
            return (ratings, words)
        } catch {
            AppLog.warning(
                "发音声学通道失败，本次降级为规则推断：\(error.localizedDescription)",
                category: "pronunciation"
            )
            return nil
        }
    }
}
