import AVFoundation
@testable import AIInfrastructure
import XCTest

/// 麦克风采集链路的格式契约与重采样正确性。
///
/// **回归背景（2026-09-10）**：`MicrophoneRecorder.start()` 把 16kHz 的格式交给
/// 48kHz 输入节点的 `installTap`，AVAudioEngine 内部断言失败抛的 Objective-C 异常
/// Swift 根本 catch 不到 → 进程直接 SIGABRT。用户看到的现象是
/// 「点麦克风 → 弹系统授权 → 点确定 → 应用直接退出」。
/// 下面第一组测试就是钉死这条契约，防止有人再把 16kHz 直接塞回 installTap。
final class MicrophoneRecorderTests: XCTestCase {

    private func format(_ rate: Double,
                        channels: AVAudioChannelCount,
                        interleaved: Bool = false) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: rate,
                      channels: channels,
                      interleaved: interleaved)!
    }

    // MARK: - installTap 格式契约（崩溃回归）

    func testTapFormatAlwaysKeepsHardwareSampleRate() {
        // 采样率只要对不上，installTap 就会把整个进程带走 —— 这条断言是本次崩溃的护栏。
        for rate in [8_000.0, 16_000.0, 44_100.0, 48_000.0, 96_000.0] {
            for channels in [AVAudioChannelCount(1), AVAudioChannelCount(2)] {
                let hardware = format(rate, channels: channels)
                let tap = MicrophoneRecorder.tapFormat(for: hardware)
                XCTAssertEqual(tap.sampleRate, hardware.sampleRate,
                               "\(rate)Hz/\(channels)ch：tap 采样率必须等于硬件采样率")
                XCTAssertEqual(tap.channelCount, hardware.channelCount)
            }
        }
    }

    func testTapFormatNormalizesToNonInterleavedFloat32() {
        let interleaved = format(48_000, channels: 2, interleaved: true)
        let tap = MicrophoneRecorder.tapFormat(for: interleaved)
        XCTAssertEqual(tap.commonFormat, .pcmFormatFloat32)
        XCTAssertFalse(tap.isInterleaved)
        XCTAssertEqual(tap.sampleRate, 48_000, "规整采样格式时不能顺带改采样率")

        let alreadyNormalized = format(48_000, channels: 2)
        XCTAssertTrue(MicrophoneRecorder.tapFormat(for: alreadyNormalized) === alreadyNormalized,
                      "格式本就合规时应原样返回，不额外造对象")
    }

    func testTargetFormatMatchesWhisperExpectation() {
        let target = MicrophoneRecorder.targetFormat()
        XCTAssertEqual(MicrophoneRecorder.sampleRate, 16_000)
        XCTAssertEqual(target?.sampleRate, 16_000)
        XCTAssertEqual(target?.channelCount, 1)
        XCTAssertEqual(target?.commonFormat, .pcmFormatFloat32)
    }

    func testConverterIsAvailableForTypicalMacHardware() throws {
        // 本机默认输入设备是 48kHz；转换器建不出来就意味着录音必然失败。
        let hardware = format(48_000, channels: 1)
        let tap = MicrophoneRecorder.tapFormat(for: hardware)
        let target = try XCTUnwrap(MicrophoneRecorder.targetFormat())
        XCTAssertFalse(MicrophoneRecorder.isSameLayout(tap, target))
        XCTAssertNotNil(AVAudioConverter(from: tap, to: target))
    }

    func testSameLayoutDetection() throws {
        let target = try XCTUnwrap(MicrophoneRecorder.targetFormat())
        XCTAssertTrue(MicrophoneRecorder.isSameLayout(target, format(16_000, channels: 1)))
        XCTAssertFalse(MicrophoneRecorder.isSameLayout(target, format(48_000, channels: 1)),
                       "采样率不同必须判定为需要转换")
        XCTAssertFalse(MicrophoneRecorder.isSameLayout(target, format(16_000, channels: 2)))
    }

    // MARK: - 重采样正确性

    private func sineBuffer(rate: Double,
                            channels: AVAudioChannelCount,
                            frames: Int,
                            amplitude: Float = 0.5,
                            frequency: Double = 440) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format(rate, channels: channels),
                                      frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(channels) {
            let pointer = buffer.floatChannelData![channel]
            for index in 0..<frames {
                let phase = 2 * Double.pi * frequency * Double(index) / rate
                pointer[index] = amplitude * Float(sin(phase))
            }
        }
        return buffer
    }

    private func rms(_ samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1 * $1) }
        return (sum / Double(samples.count)).squareRoot()
    }

    func testResample48kTo16kKeepsDurationAndAmplitude() throws {
        let target = try XCTUnwrap(MicrophoneRecorder.targetFormat())
        let tap = MicrophoneRecorder.tapFormat(for: format(48_000, channels: 1))
        let converter = try XCTUnwrap(AVAudioConverter(from: tap, to: target))
        let pcm = sineBuffer(rate: 48_000, channels: 1, frames: 12_000)  // 0.25s

        let samples = try XCTUnwrap(
            MicrophoneRecorder.samples(from: pcm, converter: converter, target: target)
        )

        XCTAssertEqual(Double(samples.count), 4_000, accuracy: 200, "16kHz 下 0.25s 应约 4000 帧")
        // 440Hz 远低于 8kHz 奈奎斯特，幅度应基本保留：0.5 幅度 → RMS ≈ 0.354
        XCTAssertEqual(rms(samples.dropFirst(200)), 0.354, accuracy: 0.08)
    }

    func testRepeatedConversionDoesNotDropSamples() throws {
        // 真实录音是「同一个 converter 反复喂 4096 帧的 tap 缓冲」，
        // AVAudioConverter 最容易在这里静默丢样本（.inputRanDry 处理不当）。
        let target = try XCTUnwrap(MicrophoneRecorder.targetFormat())
        let tap = MicrophoneRecorder.tapFormat(for: format(48_000, channels: 1))
        let converter = try XCTUnwrap(AVAudioConverter(from: tap, to: target))

        let bufferCount = 10
        let framesPerBuffer = 4_096
        var total = 0
        for _ in 0..<bufferCount {
            let pcm = sineBuffer(rate: 48_000, channels: 1, frames: framesPerBuffer)
            let samples = try XCTUnwrap(
                MicrophoneRecorder.samples(from: pcm, converter: converter, target: target)
            )
            total += samples.count
        }

        let expected = Double(bufferCount * framesPerBuffer) / 3
        XCTAssertEqual(Double(total), expected, accuracy: expected * 0.05,
                       "连续转换的总样本数不应明显少于输入时长对应值")
    }

    func testStereoHardwareIsDownmixedToMono() throws {
        // 真实录音是连续多段缓冲共用同一个 converter。注意：单次转换在**立体声**下
        // 会因预置（priming）少产出约一个缓冲的量，但连续流式累积能补回来 ——
        // 所以这里按流式校验，单次断言会误报。
        let target = try XCTUnwrap(MicrophoneRecorder.targetFormat())
        let tap = MicrophoneRecorder.tapFormat(for: format(48_000, channels: 2))
        let converter = try XCTUnwrap(AVAudioConverter(from: tap, to: target))

        let bufferCount = 10
        let framesPerBuffer = 4_096
        var collected: [Float] = []
        for _ in 0..<bufferCount {
            let pcm = sineBuffer(rate: 48_000, channels: 2, frames: framesPerBuffer)
            collected += try XCTUnwrap(
                MicrophoneRecorder.samples(from: pcm, converter: converter, target: target)
            )
        }

        let expected = Double(bufferCount * framesPerBuffer) / 3
        XCTAssertEqual(Double(collected.count), expected, accuracy: expected * 0.05)
        XCTAssertGreaterThan(rms(collected.dropFirst(200)), 0.1, "立体声下混后不应变成静音")
    }

    func testPassthroughWhenHardwareAlreadyMatchesTarget() throws {
        // converter == nil 表示硬件本就是 16kHz 单声道，应原样取用。
        let target = try XCTUnwrap(MicrophoneRecorder.targetFormat())
        let pcm = sineBuffer(rate: 16_000, channels: 1, frames: 1_600)

        let samples = try XCTUnwrap(
            MicrophoneRecorder.samples(from: pcm, converter: nil, target: target)
        )

        XCTAssertEqual(samples.count, 1_600)
        XCTAssertEqual(rms(samples[...]), 0.354, accuracy: 0.05)
    }
}
