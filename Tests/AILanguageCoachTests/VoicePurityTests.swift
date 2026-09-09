import AIProviders
import AIServices
import AppCore
import XCTest

/// 第 17/18 步：语音链路纯函数测试（WAV 封装 / 解析、朗读文本清洗、时间戳格式）。
final class VoicePurityTests: XCTestCase {

    // MARK: - WAV 封装（ASR 上行）

    func testWavDataRoundTrip() throws {
        let samples: [Float] = [0, 0.5, -0.5, 1, -1]
        let wav = WhisperASRAdapter.wavData(samples: samples, sampleRate: 16_000)

        XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav.subdata(in: 8..<12), encoding: .ascii), "WAVE")

        let (decoded, rate) = Qwen3TTSAdapter.decodeWAV(wav)
        XCTAssertEqual(rate, 16_000)
        XCTAssertEqual(decoded.count, samples.count)
        // 16bit 量化误差
        for (a, b) in zip(decoded, samples) {
            XCTAssertEqual(a, b, accuracy: 0.001)
        }
    }

    func testWavDataEmptySamples() {
        let wav = WhisperASRAdapter.wavData(samples: [], sampleRate: 16_000)
        XCTAssertEqual(wav.count, 44, "空音频也应有完整 44 字节头")
        let (decoded, _) = Qwen3TTSAdapter.decodeWAV(wav)
        XCTAssertTrue(decoded.isEmpty)
    }

    // MARK: - WAV 解析（TTS 下行）

    func testDecodeWAVRejectsGarbage() {
        let (samples, rate) = Qwen3TTSAdapter.decodeWAV(Data([1, 2, 3, 4]))
        XCTAssertTrue(samples.isEmpty)
        XCTAssertEqual(rate, 0)
    }

    // MARK: - 朗读清洗

    func testCleanForSpeechStripsCorrectionBlocks() {
        let text = """
        Hello! How was your day?
        [[FIX]] I goed to school => I went to school => 动词过去式
        See you tomorrow!
        """
        let cleaned = VoiceService.cleanForSpeech(text)
        XCTAssertTrue(cleaned.contains("How was your day"))
        XCTAssertTrue(cleaned.contains("See you tomorrow"))
        XCTAssertFalse(cleaned.contains("[[FIX]]"))
        XCTAssertFalse(cleaned.contains("goed"))
    }

    func testCleanForSpeechTruncatesLongText() {
        let long = String(repeating: "a", count: 900)
        XCTAssertEqual(VoiceService.cleanForSpeech(long).count, 400)
    }

    // MARK: - 时间戳格式（日期 时间 星期几）

    func testStampFormat() {
        // 用本地时区构造日期（stamp 按本地时区展示），2026-09-09 是周三
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 9, hour: 18, minute: 5))!
        let stamp = Timestamps.stamp(date)
        XCTAssertTrue(stamp.contains("9月9日"), "应包含日期: \(stamp)")
        XCTAssertTrue(stamp.contains("18:05"), "应包含时间: \(stamp)")
        XCTAssertTrue(stamp.contains("周三"), "应包含星期: \(stamp)")
    }
}
