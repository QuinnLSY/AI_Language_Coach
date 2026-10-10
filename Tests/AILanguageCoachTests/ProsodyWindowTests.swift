import AIDomain
@testable import AIDomain
import Foundation
import XCTest

/// ④ 逐词开窗：把整句的声学统计按词时间戳再切一遍。
///
/// ⚠️ 这一层的存在意义是「**只有一份分帧与基频算法**」：
/// 它直接复用 `SpeechAnalyzer` 的 internal `frameEnergies` / `fundamentalFrequency` / `median`
/// —— 服务层拿不到这些（不是 public），所以也不许在那里重写一遍。
final class ProsodyWindowTests: XCTestCase {

    // MARK: - 夹具：合成一段「响-轻-更响」的语音

    private let sampleRate = 16_000.0

    /// 一段音频：按 `[(秒, 相对音量, 基频)]` 逐段生成。
    private func makePCM(_ segments: [(duration: Double, amplitude: Float, pitch: Double)]) -> [Float] {
        var pcm: [Float] = []
        for segment in segments {
            let count = Int(segment.duration * sampleRate)
            guard count > 0 else { continue }
            for index in 0..<count {
                let t = Double(index) / sampleRate
                pcm.append(segment.amplitude * Float(sin(2 * .pi * segment.pitch * t)))
            }
        }
        return pcm
    }

    /// 三词：quiet(轻) / loud(响) / mid(中)，时长长短不一 → 时间戳可信。
    private func words() -> [ProsodyWordSample] {
        [
            ProsodyWordSample(word: "quiet", start: 0.00, end: 0.35),
            ProsodyWordSample(word: "loud", start: 0.37, end: 0.75),
            ProsodyWordSample(word: "middle", start: 0.77, end: 1.10)
        ]
    }

    private func pcm() -> [Float] {
        makePCM([
            (0.35, 0.06, 160),
            (0.38, 0.42, 200),
            (0.33, 0.20, 175)
        ])
    }

    // MARK: - 逐词填值

    func testEachWordGetsItsOwnEnergyAndPitch() throws {
        let annotated = ProsodyWindowAnalyzer.annotate(words(), pcm: pcm(), sampleRate: sampleRate)
        XCTAssertEqual(annotated.count, 3)
        for sample in annotated {
            XCTAssertGreaterThan(sample.energy, 0, "\(sample.word) 没切到能量")
            XCTAssertNotNil(sample.pitch, "\(sample.word) 没切到基频")
        }
        // 响的那个词能量必须最高。
        let loudest = try XCTUnwrap(annotated.max { $0.energy < $1.energy })
        XCTAssertEqual(loudest.word, "loud")
        // 基频对得上：合成时用的是 160 / 200 / 175。
        let pitches = Dictionary(uniqueKeysWithValues: annotated.compactMap { sample in
            sample.pitch.map { (sample.word, $0) }
        })
        XCTAssertEqual(pitches["loud"]!, 200, accuracy: 6)
        XCTAssertEqual(pitches["quiet"]!, 160, accuracy: 6)
    }

    func testSilenceInsideAWordYieldsNoPitch() {
        // quiet 这一段是静音 → 有能量窗但没有基频（清音/无声就是 nil，不该编一个）。
        let mixed = ProsodyWindowAnalyzer.annotate(words(), pcm: pcm(), sampleRate: sampleRate)
        XCTAssertNotNil(mixed[0].pitch)

        let withSilentWord = [
            ProsodyWordSample(word: "quiet", start: 0.00, end: 0.35),
            ProsodyWordSample(word: "loud", start: 0.37, end: 0.75),
            ProsodyWordSample(word: "silent", start: 0.77, end: 1.10)
        ]
        let annotated = ProsodyWindowAnalyzer.annotate(
            withSilentWord,
            pcm: makePCM([(1.10, 0.001, 180)]),
            sampleRate: sampleRate
        )
        XCTAssertNil(annotated[2].pitch, "静音段不该给出基频")
    }

    func testDegenerateInputsFallBackToTheInputUnchanged() {
        XCTAssertTrue(ProsodyWindowAnalyzer.annotate([], pcm: pcm(), sampleRate: sampleRate).isEmpty)
        let noAudio = ProsodyWindowAnalyzer.annotate(words(), pcm: [], sampleRate: sampleRate)
        XCTAssertTrue(noAudio.allSatisfy { $0.energy == 0 }, "没有音频就别填能量")
        XCTAssertTrue(ProsodyWindowAnalyzer.annotate(words(), pcm: pcm(), sampleRate: 0)
            .allSatisfy { $0.energy == 0 }, "采样率非法也别填")
        // 太短、连一帧都凑不齐。
        XCTAssertTrue(ProsodyWindowAnalyzer.annotate(words(), pcm: [0.1, 0.2], sampleRate: sampleRate)
            .allSatisfy { $0.energy == 0 })
    }

    func testFrameRangeIsClampedToTheAvailableFrames() {
        let range = ProsodyWindowAnalyzer.frameRange(
            start: -1.0, end: 99.0, frameCount: 50, hop: 160, sampleRate: sampleRate
        )
        XCTAssertEqual(range, 0..<50, "越界的时间戳要夹到可用帧内，不能崩也不能越界读")
        XCTAssertTrue(ProsodyWindowAnalyzer.frameRange(
            start: 1.0, end: 0.5, frameCount: 50, hop: 160, sampleRate: sampleRate
        ).isEmpty, "结束早于开始 → 空区间")
    }

    // MARK: - 端到端（仍然纯函数）

    func testAnalysisProducesStressContourAndLinking() throws {
        let analysis = try XCTUnwrap(
            ProsodyWindowAnalyzer.analysis(words: words(), pcm: pcm(), sampleRate: sampleRate)
        )
        XCTAssertEqual(analysis.stress.first { $0.word == "loud" }?.level, .stressed)
        XCTAssertEqual(analysis.stress.first { $0.word == "quiet" }?.level, .reduced)
        XCTAssertNotNil(analysis.contour)
        XCTAssertFalse(analysis.isEmpty)
    }

    /// 时间戳是「按字符均摊」的估计值 ⇒ **整份分析不给**。
    ///
    /// 这是本批最要紧的一条：拿均摊值切能量会把重音位置指错，
    /// 而「给出错的结论」比「不给结论」糟得多。
    /// ⚠️ 夹具必须让**时长正比于字符数** —— 「每词等长」不是均摊（那是另一种数据）。
    func testAnalysisRefusesWhenTheTimelineIsOnlyEstimated() {
        let words = ["quiet", "loud", "middle"]
        let perCharacter = 1.2 / Double(words.reduce(0) { $0 + $1.count })
        var cursor = 0.0
        let evenly = words.map { word -> ProsodyWordSample in
            let duration = perCharacter * Double(word.count)
            defer { cursor += duration }
            return ProsodyWordSample(word: word, start: cursor, end: cursor + duration)
        }
        XCTAssertEqual(WordTimelineTrust.assess(evenly), .estimated)
        XCTAssertNil(ProsodyWindowAnalyzer.analysis(words: evenly, pcm: pcm(), sampleRate: sampleRate))
    }

    /// 全静音 → 没有可分析的（不产出「全是弱读」那种假结论）。
    func testAnalysisRefusesOnSilence() {
        let silent = makePCM([(1.2, 0.0005, 180)])
        XCTAssertNil(ProsodyWindowAnalyzer.analysis(words: words(), pcm: silent, sampleRate: sampleRate))
    }

    /// 连读只在「该连」的位置产出，并如实报告连没连上。
    ///
    /// ⚠️ 「it→up」也会被判成候选 —— 这是**已知且刻意接受**的过判：
    /// 纯文本层拿不到词性，「辅音结尾 + 元音开头」就是第一序启发式
    /// （用户 2026-10-10 拍板「只提示不扣分」正是为这种过判留的余地）。
    /// 要收窄就得引入词典判断实词 / 功能词，那是另一个量级的依赖。
    func testLinkingIsReportedSeparatelyFromStress() throws {
        let words = [
            ProsodyWordSample(word: "pick", start: 0.00, end: 0.30),
            ProsodyWordSample(word: "it", start: 0.30, end: 0.40),
            ProsodyWordSample(word: "up", start: 0.42, end: 0.70)
        ]
        let analysis = try XCTUnwrap(ProsodyWindowAnalyzer.analysis(
            words: words,
            pcm: makePCM([(0.70, 0.25, 190)]),
            sampleRate: sampleRate
        ))
        XCTAssertEqual(analysis.linking.count, 2, "pick→it 与 it→up 都是「辅音结尾 + 元音开头」")
        XCTAssertTrue(analysis.linking.allSatisfy(\.didLink))
        XCTAssertEqual(analysis.linkedCount, 2)
        XCTAssertEqual(analysis.linking[0].firstWord, "pick")
    }
}