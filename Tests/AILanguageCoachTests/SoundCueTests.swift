@testable import AppUI
import Foundation
import XCTest

/// 批次六 · F 轻音效：合成波形、WAV 容器、开关分发三件事。
///
/// 为什么不测「听不听得见」：音频硬件不在测试范围里。能钉住的是
/// 「波形确实是衰减的乐音」「容器确实是标准 WAV」「开关确实拦得住」——
/// 这三件对了，声音就是对的；这三件错了，听感再「差不多」也是错的。
final class SoundCueTests: XCTestCase {

    // MARK: - WAV 容器

    /// 44 字节标准头 + 16-bit 单声道 PCM：字段错一个位置，播放器就解不出声。
    ///
    /// 反证：把 WavTone.wav 的采样率字段写成别的 → 红。
    func testWavHeaderMatchesTheCanonicalLayout() throws {
        let samples = WavTone.samples(for: .collectWord)
        let data = WavTone.wav(samples: samples)

        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: data.subdata(in: 12..<16), encoding: .ascii), "fmt ")

        // 块对齐：fmt 块 16 字节、PCM 编码、单声道、44100Hz、16-bit。
        let fmtSize = data.subdata(in: 16..<20).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        XCTAssertEqual(fmtSize, 16)
        let format = data.subdata(in: 20..<22).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
        XCTAssertEqual(format, 1, "必须是 PCM")
        let channels = data.subdata(in: 22..<24).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
        XCTAssertEqual(channels, 1)
        let sampleRate = data.subdata(in: 24..<28).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        XCTAssertEqual(sampleRate, 44_100)
        let bits = data.subdata(in: 34..<36).withUnsafeBytes { $0.load(as: UInt16.self).littleEndian }
        XCTAssertEqual(bits, 16)

        // 数据块大小 = 采样数 × 2 字节，且总长恰好 = 44 + 数据块。
        let dataSize = data.subdata(in: 40..<44).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        XCTAssertEqual(Int(dataSize), samples.count * 2)
        XCTAssertEqual(data.count, 44 + Int(dataSize))
    }

    // MARK: - 波形本身

    /// 每条 cue 都得是「起得来、衰减得下去」的乐音，且两次合成完全一致
    /// （同一动作的听感必须稳定，合成里混进随机就是「每次响得不一样」）。
    func testEveryCueIsDeterministicAndDecays() {
        for cue in SoundCue.allCases {
            let samples = WavTone.samples(for: cue)
            XCTAssertFalse(samples.isEmpty, "\(cue.rawValue) 不许是空波形")
            XCTAssertEqual(samples, WavTone.samples(for: cue),
                           "\(cue.rawValue) 两次合成必须逐样本一致（合成是纯函数）")

            let peak = samples.map(abs).max() ?? 0
            XCTAssertGreaterThan(peak, 0.5, "\(cue.rawValue) 音量起不来（峰值 \(peak)）")

            let rms = { (range: Range<Int>) -> Double in
                let slice = samples[range]
                let energy = slice.reduce(0.0) { $0 + $1 * $1 }
                return (energy / Double(slice.count)).squareRoot()
            }
            let head = rms(0..<(samples.count / 4))
            let tail = rms((samples.count * 3 / 4)..<samples.count)
            XCTAssertLessThan(tail, head * 0.5,
                              "\(cue.rawValue) 尾段没衰减下去（头 \(head) vs 尾 \(tail)）—— 会变成长鸣")
        }
    }

    /// 时长排序：小旋律 > 收词叮 > 一声叫（语义上的长短关系钉住，防止配方被改反）。
    func testFanfareIsLongerThanDingAndChirp() {
        let length = { (cue: SoundCue) -> Double in
            Double(WavTone.samples(for: cue).count) / Double(WavTone.sampleRate)
        }
        XCTAssertGreaterThan(length(.levelFanfare), length(.collectWord))
        XCTAssertGreaterThan(length(.collectWord), length(.animalTap))
    }

    // MARK: - 开关分发

    /// 记账 spy：只记 cue 名，不碰音频硬件。
    private final class Recorder: SoundPlaying, @unchecked Sendable {
        private let lock = NSLock()
        private var played: [SoundCue] = []
        var cues: [SoundCue] {
            lock.lock(); defer { lock.unlock() }
            return played
        }
        func play(cue: SoundCue, data: Data) {
            lock.lock(); defer { lock.unlock() }
            played.append(cue)
        }
    }

    /// 开关默认关：没打开时发多少 cue 都是静默 no-op。
    ///
    /// 反证：删掉 SoundCueCenter.cue 里的 `guard enabled` → 红。
    @MainActor
    func testDisabledCenterStaysSilent() {
        let recorder = Recorder()
        let center = SoundCueCenter(player: recorder)
        XCTAssertFalse(center.enabled, "轻音效必须默认关")

        center.cue(.collectWord)
        center.cue(.levelFanfare)
        center.cue(.animalTap)
        XCTAssertTrue(recorder.cues.isEmpty, "开关没开就出了声 —— 静默承诺被打破")
    }

    /// 打开后：发什么 cue 记什么 cue，一一对应不串音。
    @MainActor
    func testEnabledCenterPlaysExactlyTheCuesItWasGiven() {
        let recorder = Recorder()
        let center = SoundCueCenter(player: recorder)
        center.enabled = true

        center.cue(.collectWord)
        center.cue(.levelFanfare)
        XCTAssertEqual(recorder.cues, [.collectWord, .levelFanfare])
    }
}
