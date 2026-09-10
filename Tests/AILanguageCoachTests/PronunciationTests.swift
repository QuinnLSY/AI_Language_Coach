import AIDomain
import XCTest

/// 第 23 步 发音评测（Pronunciation Engine）单测。
///
/// 覆盖：声学分析（合成波形：静音 / 语音段 / 停顿 / 基频 / 音量起伏）、
/// 打分（各维度、权重归一、分档、建议）、以及「没有音频就不硬编分数」。
/// **全部脱机**：波形由测试自己合成，不碰麦克风 / 模型 / 数据库。
final class PronunciationTests: XCTestCase {

    // MARK: - 波形合成工具

    private let sampleRate = 16_000.0

    /// 纯净正弦（浊音近似）：自相关应有稳定基频。
    private func tone(f0: Double, seconds: Double, amplitude: Float = 0.6) -> [Float] {
        let count = Int(seconds * sampleRate)
        return (0..<count).map { position in
            let t = Double(position) / sampleRate
            return amplitude * Float(sin(2 * .pi * f0 * t))
        }
    }

    private func silence(seconds: Double) -> [Float] {
        Array(repeating: 0, count: Int(seconds * sampleRate))
    }

    private func concat(_ parts: [[Float]]) -> [Float] {
        parts.flatMap { $0 }
    }

    /// 「两句之间换一口气」的典型波形：0.4s 静音 → 1.2s 语音 → 0.5s 停顿 → 1.2s 语音 → 0.4s 静音。
    private func breathySample() -> [Float] {
        concat([
            silence(seconds: 0.4),
            tone(f0: 140, seconds: 1.2),
            silence(seconds: 0.5),
            tone(f0: 165, seconds: 1.2),
            silence(seconds: 0.4),
        ])
    }

    // MARK: - 声学分析

    func testEmptySamplesYieldEmptyMetrics() {
        XCTAssertEqual(SpeechAnalyzer.analyze(samples: [], sampleRate: sampleRate), .empty)
        XCTAssertEqual(SpeechAnalyzer.analyze(samples: tone(f0: 150, seconds: 1), sampleRate: 0), .empty)
        // 凑不满一帧的零散样本：只报时长，不该编出任何语音。
        let tiny = SpeechAnalyzer.analyze(samples: [0, 0, 0], sampleRate: sampleRate)
        XCTAssertFalse(tiny.hasSpeech)
        XCTAssertFalse(SpeechAnalyzer.analyze(samples: silence(seconds: 2), sampleRate: sampleRate).hasSpeech)
    }

    func testSilenceHasNoSpeech() {
        let metrics = SpeechAnalyzer.analyze(samples: silence(seconds: 2), sampleRate: sampleRate)
        XCTAssertFalse(metrics.hasSpeech)
        XCTAssertEqual(metrics.speechDuration, 0, accuracy: 0.05)
        XCTAssertEqual(metrics.pauseCount, 0, "纯静音里没有『句中停顿』可言")
    }

    func testDetectsSpeechDurationAndMidPause() {
        let metrics = SpeechAnalyzer.analyze(samples: breathySample(), sampleRate: sampleRate)
        XCTAssertTrue(metrics.hasSpeech, "两段各 1.2s 的语音应当被识别")
        XCTAssertEqual(metrics.speechDuration, 2.4, accuracy: 0.2)
        XCTAssertEqual(metrics.pauseCount, 1, "句中 0.5s 静音算一次停顿；首尾静音不算")
        XCTAssertEqual(metrics.longestPause, 0.5, accuracy: 0.1)
        XCTAssertEqual(metrics.pauseDuration, 0.5, accuracy: 0.1)
        XCTAssertEqual(metrics.speakingRatio, 2.4 / 3.7, accuracy: 0.05)
    }

    func testTinyGapsAreNotPauses() {
        // 词间 60ms 的自然间隙不该被数成停顿。
        let samples = concat([
            silence(seconds: 0.3),
            tone(f0: 150, seconds: 1.0),
            silence(seconds: 0.06),
            tone(f0: 150, seconds: 1.0),
            silence(seconds: 0.3),
        ])
        let metrics = SpeechAnalyzer.analyze(samples: samples, sampleRate: sampleRate)
        XCTAssertEqual(metrics.pauseCount, 0)
    }

    func testSteadyPitchYieldsFlatMetrics() {
        let metrics = SpeechAnalyzer.analyze(samples: tone(f0: 160, seconds: 2), sampleRate: sampleRate)
        XCTAssertGreaterThanOrEqual(metrics.voicedFrames, 20, "纯浊音应采到大量基频帧")
        XCTAssertEqual(metrics.pitchVariation, 0, accuracy: 0.6, "恒定音高的波动应接近 0 半音")
        XCTAssertEqual(metrics.pitchRange, 0, accuracy: 1.2)
    }

    func testPitchSweepYieldsMeasurableRange() {
        // 150Hz → 300Hz 扫频：正好跨一个八度 = 12 个半音的起伏。
        let count = Int(1.5 * sampleRate)
        var samples = [Float](repeating: 0, count: count)
        var phase = 0.0
        for position in 0..<count {
            let progress = Double(position) / Double(count)
            let f0 = 150.0 * pow(2, progress) // 对数扫频
            phase += 2 * .pi * f0 / sampleRate
            samples[position] = 0.6 * Float(sin(phase))
        }
        let metrics = SpeechAnalyzer.analyze(samples: samples, sampleRate: sampleRate)
        XCTAssertGreaterThanOrEqual(metrics.voicedFrames, 10)
        XCTAssertGreaterThan(metrics.pitchRange, 5, "一个八度的扫频应有明显起伏（≥5 半音）")
    }

    func testAmplitudeAlternationYieldsEnergyVariation() {
        let steady = SpeechAnalyzer.analyze(samples: tone(f0: 150, seconds: 2), sampleRate: sampleRate)
        let alternated = SpeechAnalyzer.analyze(
            samples: concat([tone(f0: 150, seconds: 0.5, amplitude: 0.25), tone(f0: 150, seconds: 0.5, amplitude: 0.9),
                             tone(f0: 150, seconds: 0.5, amplitude: 0.25), tone(f0: 150, seconds: 0.5, amplitude: 0.9)]),
            sampleRate: sampleRate
        )
        XCTAssertGreaterThan(alternated.energyVariation, steady.energyVariation + 0.1, "轻重交替的起伏应明显更大")
    }

    // MARK: - 打分

    /// 一次「标准朗读」的参考度量：语速/占比/起伏全部落在理想带内。
    private func idealMetrics() -> SpeechMetrics {
        SpeechMetrics(
            duration: 3.5,
            speechDuration: 2.8,
            pauseDuration: 0,
            pauseCount: 0,
            longestPause: 0,
            speakingRatio: 0.8,
            pitchRange: 7,
            pitchVariation: 2.4,
            energyVariation: 0.55,
            voicedFrames: 120
        )
    }

    func testIdealReadingScoresHigh() {
        let report = PronunciationScorer.report(
            reference: "Good morning how are you doing today",
            recognized: "Good morning how are you doing today",
            metrics: idealMetrics()
        )
        XCTAssertGreaterThanOrEqual(report.overall, 90, "标准朗读应当拿高分")
        XCTAssertEqual(report.verdict, .excellent)
        XCTAssertEqual(report.weakest?.rawValue.isEmpty, false)
        XCTAssertNil(report.line(.phonemeAccuracy), "没接音素模型就不该有这一维")
        XCTAssertTrue(report.tips.isEmpty, "满分不该给出建议")
    }

    func testMissingAudioScoresOnlyWordAccuracy() {
        let report = PronunciationScorer.report(
            reference: "Good morning how are you doing today",
            recognized: "Good morning how are you",
            metrics: .empty
        )
        XCTAssertEqual(report.lines.count, 1, "没有音频时只评文本层")
        XCTAssertEqual(report.lines.first?.dimension, .wordAccuracy)
        XCTAssertEqual(report.overall, report.line(.wordAccuracy)?.score ?? -1, accuracy: 0.0001)
        XCTAssertEqual(report.weakest, .wordAccuracy, "唯一可评的维度就是最弱项")
    }

    func testSlowSpeechIsPenalizedAndNamed() {
        var metrics = idealMetrics()
        // 7 个词说了 5 秒（每分钟 84 词）→ 明显偏慢。
        metrics.speechDuration = 5.0
        metrics.speakingRatio = 0.8
        let report = PronunciationScorer.report(
            reference: "Good morning how are you doing today",
            recognized: "Good morning how are you doing today",
            metrics: metrics
        )
        let speed = report.line(.speakingSpeed)
        XCTAssertNotNil(speed)
        XCTAssertLessThan(speed?.score ?? 100, 85, "每分钟 84 词应明显扣分")
        XCTAssertTrue(speed?.detail.contains("84") ?? false, "明细必须报出实测数字")
        XCTAssertTrue(report.tips.contains { $0.contains("语速") }, "建议必须点名维度")
    }

    func testSpeedOmittedForVeryShortUtterance() {
        // 两个词的短句折成 WPM 毫无意义：这一维应整体缺席。
        let metrics = idealMetrics()
        let report = PronunciationScorer.report(
            reference: "Hello there",
            recognized: "Hello there",
            metrics: metrics
        )
        XCTAssertNil(report.line(.speakingSpeed))
    }

    func testExcessivePausesArePenalized() {
        var metrics = idealMetrics()
        metrics.pauseCount = 3   // 2.8 秒的句子里停 3 次
        metrics.longestPause = 1.6
        metrics.pauseDuration = 2.2
        let report = PronunciationScorer.report(
            reference: "Good morning how are you doing today",
            recognized: "Good morning how are you doing today",
            metrics: metrics
        )
        let pauses = report.line(.pauses)
        XCTAssertLessThan(pauses?.score ?? 100, 70, "过密的停顿应明显扣分")
        XCTAssertTrue(report.tips.contains { $0.contains("停顿") })
    }

    func testFlatIntonationIsPenalized() {
        var metrics = idealMetrics()
        metrics.pitchRange = 1.0
        metrics.pitchVariation = 0.4
        let report = PronunciationScorer.report(
            reference: "Good morning how are you doing today",
            recognized: "Good morning how are you doing today",
            metrics: metrics
        )
        let intonation = report.line(.intonation)
        XCTAssertLessThan(intonation?.score ?? 100, 70, "语调太平应扣分")
        XCTAssertTrue(report.tips.contains { $0.contains("语调") })
    }

    func testPhonemeDimensionOnlyWhenProvided() {
        let phonemes = [PhonemeRating(phoneme: "θ", score: 0.5), PhonemeRating(phoneme: "r", score: 0.9)]
        let report = PronunciationScorer.report(
            reference: "three rivers",
            recognized: "three rivers",
            metrics: .empty,
            phonemes: phonemes
        )
        let line = report.line(.phonemeAccuracy)
        XCTAssertEqual(line?.score ?? 0, 70, accuracy: 0.0001, "两个音素均分 0.5 / 0.9")
        XCTAssertTrue(line?.detail.contains("θ") ?? false, "最弱的音要被点名")
    }

    func testWeightedScoreRenormalizesOverAvailableDimensions() {
        let lines = [
            PronunciationScoreLine(dimension: .wordAccuracy, score: 100, detail: ""),
            PronunciationScoreLine(dimension: .fluency, score: 50, detail: ""),
        ]
        // 权重 0.30 : 0.15 → 总分 = (100*0.30 + 50*0.15) / 0.45 ≈ 83.3
        XCTAssertEqual(PronunciationScorer.weightedScore(lines), 250.0 / 3.0, accuracy: 0.01)
        XCTAssertEqual(PronunciationScorer.weightedScore([]), 0)
    }

    func testVerdictBands() {
        XCTAssertEqual(PronunciationScorer.verdict(for: 90), .excellent)
        XCTAssertEqual(PronunciationScorer.verdict(for: 89.9), .good)
        XCTAssertEqual(PronunciationScorer.verdict(for: 78), .good)
        XCTAssertEqual(PronunciationScorer.verdict(for: 62), .fair)
        XCTAssertEqual(PronunciationScorer.verdict(for: 61.9), .needsWork)
    }

    func testBandScoreBoundaries() {
        XCTAssertEqual(PronunciationScorer.bandScore(5, ideal: 3...7, tolerance: 2), 100, "区间内满分")
        XCTAssertEqual(PronunciationScorer.bandScore(9, ideal: 3...7, tolerance: 2), 30, "超出一个完整容差 = 最低分")
        XCTAssertEqual(PronunciationScorer.bandScore(8, ideal: 3...7, tolerance: 2), 65, "半个容差扣一半")
    }

    func testReportRoundTripsThroughCodable() throws {
        let report = PronunciationScorer.report(
            reference: "Good morning how are you doing today",
            recognized: "Good morning how are you",
            metrics: idealMetrics()
        )
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(PronunciationReport.self, from: data)
        XCTAssertEqual(decoded, report, "报告要能 JSON 落库再原样读回")
    }
}
