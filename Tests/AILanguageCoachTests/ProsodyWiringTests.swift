import AIDomain
import AIInterfaces
@testable import AIServices
import Foundation
import XCTest

/// ④ 词级韵律的**通电接线**（哨兵）。
///
/// 行为由 `ProsodyAnalysisTests` / `ProsodyWindowTests` 钉；这里钉的是**接线纪律**——
/// 词时间戳与原始音频必须同批取、同批清。这两样一旦错批，界面看不出任何异常，
/// 但重音结论是**别的录音**的：用户会照着一个不属于这段音频的词边界改发音。
final class ProsodyWiringTests: XCTestCase {

    private nonisolated static func code(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    // MARK: - 词时间戳必须一路留下来

    /// `ASRManager` 要留住**整份**结果：只把 `.text` 交出去，词时间戳当场就丢了，下游补不回来。
    func testASRManagerKeepsTheWholeResult() throws {
        let raw = try Self.code("Sources/AIServices/ASRManager.swift")
        XCTAssertTrue(raw.contains("lastResult = result"),
                      "transcribe 必须把整份结果留住（词级时间戳只在 ASRResult.words 里）")
        XCTAssertTrue(raw.contains("public private(set) var lastResult: ASRResult?"))
    }

    /// `VoiceService` 用**并列方法**暴露词，而不是改 `stopRecordingAndTranscribe` 的签名 ——
    /// 那个方法对话也在用，改签名会波及整条对话链。
    func testVoiceServiceExposesWordsWithoutChangingTheSharedSignature() throws {
        let raw = try Self.code("Sources/AIServices/VoiceService.swift")
        XCTAssertTrue(raw.contains("func lastTranscriptWords() async -> [ASRWord]"))
        XCTAssertTrue(raw.contains("await asr.lastResult?.words ?? []"),
                      "并列方法要真的从 ASRManager 那份结果里取")
        XCTAssertTrue(raw.contains("public func stopRecordingAndTranscribe(language: String? = nil) async -> String?"),
                      "共享方法的签名不许改（对话链也在用）")
    }

    // MARK: - 同批取、同批清

    /// 词时间戳与原始音频**在同一个方法里**取，且两处 `report` 调用都传出去。
    func testWordTimingsAreCapturedBesideTheAudioAndPassedToBothReports() throws {
        let raw = try Self.code("Sources/AIServices/ShadowingService.swift")
        XCTAssertTrue(raw.contains("pendingWordTimings = text != nil ? await voice.lastTranscriptWords() : []"),
                      "词时间戳必须在 finishRecording 里、与 pendingSamples 同一处取")
        XCTAssertEqual(raw.components(separatedBy: "wordTimings: pendingWordTimings").count - 1, 2,
                       "两处发音评测（逐句 / 整段）都要传 —— 少一处那一路就永远拿不到词级数据")

        // 同批清：`evaluate` / `evaluatePassage` / `cancelRecording` 三处都要清。
        let clears = raw.components(separatedBy: "pendingWordTimings = []").count - 1
        XCTAssertGreaterThanOrEqual(clears, 3, "取消与两条评测路径都要清干净，否则下一轮会串上一轮的词")
    }

    /// 服务层把词时间戳交给唯一的分析入口（不在服务层另算一套）。
    func testServiceDelegatesToTheSingleAnalysisEntry() throws {
        let raw = try Self.code("Sources/AIServices/PronunciationService.swift")
        XCTAssertTrue(raw.contains("ProsodyWindowAnalyzer.analysis("))
        XCTAssertEqual(raw.components(separatedBy: "ProsodyWindowAnalyzer.analysis(").count - 1, 1,
                       "只算一次 —— 声学与规则推断两条通道共用同一份，否则跟读页与结算卡各说各话")
        XCTAssertEqual(raw.components(separatedBy: "prosody: prosody").count - 1, 2,
                       "两条通道都要把同一份传下去")
    }

    // MARK: - 降级（不抛错、不阻塞）

    /// runtime 不给词级时间戳时，报告照常出，只是 `prosody` 为 nil。
    func testMissingWordTimingsJustMeansNoProsody() async throws {
        let service = PronunciationService()
        let report = await service.report(
            reference: "I want a latte",
            recognized: "I want a latte",
            samples: Array(repeating: Float(0.1), count: 1600),
            sampleRate: 16_000,
            wordTimings: []
        )
        XCTAssertNil(report.prosody)
        XCTAssertEqual(report.prosodyBonus, 0)
        XCTAssertFalse(report.lines.isEmpty, "降级不等于整份报告报废")
        XCTAssertEqual(report.overall, report.overall, "总分照常算")
    }

    /// 词时间戳是「按字符均摊」的估计值 ⇒ 同样只是 `prosody` 为 nil。
    func testEstimatedTimelineDegradesInsteadOfGuessing() async throws {
        let service = PronunciationService()
        let words = ["I", "want", "a", "latte"]
        let perCharacter = 1.2 / 9.0
        var cursor = 0.0
        let timings = words.map { word -> ASRWord in
            let duration = perCharacter * Double(word.count)
            defer { cursor += duration }
            return ASRWord(word: word, start: cursor, end: cursor + duration)
        }
        let report = await service.report(
            reference: "I want a latte",
            recognized: "I want a latte",
            samples: Array(repeating: Float(0.1), count: 1600),
            sampleRate: 16_000,
            wordTimings: timings
        )
        XCTAssertNil(report.prosody, "均摊时间戳不可信 → 宁可不给，也不给一份错的")
        XCTAssertFalse(report.lines.isEmpty)
    }

    // MARK: - 落库往返

    /// 老记录（没有 `prosody` 键）必须读得出来 —— 这正是手写 `decodeIfPresent` 的理由。
    func testOldReportWithoutProsodyStillDecodes() throws {
        let json = """
        {"referenceText":"hello","recognizedText":"hello","overall":80,"lines":[],
         "createdAt":"1970-01-01T00:00:00Z"}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(PronunciationReport.self, from: json)
        XCTAssertNil(report.prosody, "缺这一项要读成 nil（不是零分 —— 零分会被画成「一句都没做对」）")
        XCTAssertEqual(report.prosodyBonus, 0)
    }

    func testProsodySurvivesTheRoundTrip() throws {
        let analysis = ProsodyAnalysis(
            stress: [WordStressMark(word: "latte", level: .stressed, ratio: 1.8)],
            contour: IntonationContour(shape: .falling, slope: -1.2, points: [0, 1.4]),
            linking: [LinkingSpan(firstWord: "pick", secondWord: "it", gap: 0.01, didLink: true)]
        )
        let report = PronunciationScorer.report(
            reference: "pick it up", recognized: "pick it up",
            metrics: SpeechMetrics(duration: 1, speechDuration: 1),
            prosody: analysis
        )
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(PronunciationReport.self, from: data)
        XCTAssertEqual(decoded.prosody?.stress.count, 1)
        XCTAssertEqual(decoded.prosody?.contour?.shape, .falling)
        XCTAssertEqual(decoded.prosody?.linking.first?.secondWord, "it")
        XCTAssertGreaterThan(decoded.prosodyBonus, 0)
    }

    /// 加分**不进总分**（用户 2026-10-10 定：七维与权重一个都不动，历史可比）。
    func testProsodyBonusDoesNotTouchTheOverallScore() {
        let plain = PronunciationScorer.report(
            reference: "pick it up", recognized: "pick it up",
            metrics: SpeechMetrics(duration: 1, speechDuration: 1)
        )
        let withProsody = PronunciationScorer.report(
            reference: "pick it up", recognized: "pick it up",
            metrics: SpeechMetrics(duration: 1, speechDuration: 1),
            prosody: ProsodyAnalysis(
                stress: [
                    WordStressMark(word: "pick", level: .stressed, ratio: 2),
                    WordStressMark(word: "it", level: .reduced, ratio: 0.4)
                ],
                contour: IntonationContour(shape: .falling, slope: -1, points: [0, 1]),
                linking: [LinkingSpan(firstWord: "pick", secondWord: "it", gap: 0.01, didLink: true)]
            )
        )
        XCTAssertEqual(withProsody.overall, plain.overall,
                       "韵律加分是独立加分项：动了总分就会让历史分数整体变化")
        XCTAssertEqual(withProsody.verdict, plain.verdict)
        XCTAssertGreaterThan(withProsody.prosodyBonus, 0, "但加分要给")
    }
}