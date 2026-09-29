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

    /// 时长排序：小旋律 > 收词叮（语义上的长短关系钉住，防止配方被改反）。
    func testFanfareIsLongerThanDing() {
        let length = { (cue: SoundCue) -> Double in
            Double(WavTone.samples(for: cue).count) / Double(WavTone.sampleRate)
        }
        XCTAssertGreaterThan(length(.levelFanfare), length(.collectWord))
    }

    // MARK: - 物种叫声（2026-09-29 拆分：原来是全体共用一声啁啾）

    /// 八个物种各自成形：非空、确定性、互不相同、都是点一下就完的短促一声。
    ///
    /// 反证：把任意两个物种的配方改成同一个（比如 bear 直接抄 fox 的）→ 红。
    func testEachSpeciesHasItsOwnDeterministicShortVoice() {
        let kinds = AnimalKind.allCases
        XCTAssertEqual(kinds.count, 8, "物种表变了（增删了物种）就要补叫声配方")
        var voices: [AnimalKind: [Double]] = [:]
        for kind in kinds {
            let samples = WavTone.samples(for: kind)
            XCTAssertFalse(samples.isEmpty, "\(kind.rawValue) 的叫声不许是空波形")
            XCTAssertEqual(samples, WavTone.samples(for: kind),
                           "\(kind.rawValue) 两次合成必须逐样本一致（合成是纯函数）")
            let seconds = Double(samples.count) / Double(WavTone.sampleRate)
            XCTAssertLessThanOrEqual(seconds, 0.6,
                                     "\(kind.rawValue) 的叫声太长（\(seconds)s）—— 点一下不该演一整段")
            voices[kind] = samples
        }
        // 两两不同：叫声的意义就在「听得出是谁」，撞音等于没拆。
        for (index, a) in kinds.enumerated() {
            for b in kinds[(index + 1)...] {
                XCTAssertNotEqual(voices[a], voices[b],
                                  "\(a.rawValue) 与 \(b.rawValue) 的叫声撞了")
            }
        }
    }

    /// 叫声必须**收尾**：末段能量要低于全曲平均（不许切在半空、不许变成长鸣）。
    ///
    /// 为什么不是「尾 < 头 × 0.5」：多音节叫声（两声/两拍/四连音）后段会**重新起音**，
    /// 那是节奏设计不是缺陷 —— 钉住的是「最后一刻确实是收掉-ending」这一个形态不变量。
    func testSpeciesVoicesFadeOutAtTheEnd() {
        for kind in AnimalKind.allCases {
            let samples = WavTone.samples(for: kind)
            let rms = { (range: Range<Int>) -> Double in
                let slice = samples[range]
                let energy = slice.reduce(0.0) { $0 + $1 * $1 }
                return (energy / Double(slice.count)).squareRoot()
            }
            let overall = rms(0..<samples.count)
            let ending = rms((samples.count * 97 / 100)..<samples.count)
            XCTAssertLessThan(ending, overall,
                              "\(kind.rawValue) 的叫声末段没收住（末 \(ending) vs 全曲 \(overall)）")
        }
    }

    // MARK: - 开关分发

    /// 记账 spy：只记播放的数据，不碰音频硬件。
    private final class Recorder: SoundPlaying, @unchecked Sendable {
        private let lock = NSLock()
        private var played: [Data] = []
        var datas: [Data] {
            lock.lock(); defer { lock.unlock() }
            return played
        }
        func play(data: Data) {
            lock.lock(); defer { lock.unlock() }
            played.append(data)
        }
    }

    /// 开关默认关：没打开时发多少 cue 都是静默 no-op。
    ///
    /// 反证：删掉 SoundCueCenter.cue / animalVoice 里的 `guard enabled` → 红。
    @MainActor
    func testDisabledCenterStaysSilent() {
        let recorder = Recorder()
        let center = SoundCueCenter(player: recorder)
        XCTAssertFalse(center.enabled, "轻音效必须默认关")

        center.cue(.collectWord)
        center.cue(.levelFanfare)
        center.animalVoice(.fox)
        XCTAssertTrue(recorder.datas.isEmpty, "开关没开就出了声 —— 静默承诺被打破")
    }

    /// 打开后：cue 发什么播什么；叫声带的是**那只物种自己的**波形。
    @MainActor
    func testEnabledCenterPlaysExactlyTheCuesAndVoicesItWasGiven() {
        let recorder = Recorder()
        let center = SoundCueCenter(player: recorder)
        center.enabled = true

        center.cue(.collectWord)
        center.cue(.levelFanfare)
        center.animalVoice(.owl)
        center.animalVoice(.rabbit)
        XCTAssertEqual(recorder.datas, [
            WavTone.data(for: .collectWord),
            WavTone.data(for: .levelFanfare),
            WavTone.data(for: .owl),
            WavTone.data(for: .rabbit),
        ], "每次播放的数据必须与配方一一对应（叫声不许再共用一份波形）")
    }
}
