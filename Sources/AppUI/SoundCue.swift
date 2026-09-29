import AVFoundation
import Foundation
import Observation

// MARK: - 轻音效（批次六 · F）
//
// 设计约束（与教师语音的 AudioPlayback 严格分开）：
// - 教师语音走「合成 → 播放并等待」的流水线，一条通道被 UI 音效挤占会打断朗读；
// - UI 音效是**发后即忘**的短促声音：内存里现场合成 WAV（不落盘、不打包音频资源），
//   独立的 AVAudioPlayer 播放，播完自摘。
// - 总开关默认**关**（`ProductConfig.soundEffects`）：有人喜欢安静，声音必须主动选择才有。

/// 三种 UI 音效 cue。rawValue 同时是可读标识（测试与日志用）。
public enum SoundCue: String, CaseIterable, Sendable {
    /// 收进一个生词：清脆的一声「叮」。
    case collectWord
    /// 通关：一小段上行的琶音小旋律。
    case levelFanfare
    /// 点了一下小动物：短促上滑的一声叫。
    case animalTap
}

/// 纯函数音色合成：波形 → 标准 16-bit 单声道 WAV（内存 Data，不落盘）。
///
/// 为什么是纯函数：同一条 cue 永远合成出**同一份**波形——可单测（头部布局、
/// 衰减形状、时长排序都是一条断言的事），也保证重复触发听感一致。
public enum WavTone {

    public static let sampleRate = 44_100
    /// 峰值音量（留足余量，UI 音效不该比教师语音响）。
    private static let peak: Double = 0.72
    /// 起音 / 收音的防爆音斜坡（秒）：波形骤起骤停会有「啪」的杂音。
    private static let ramp: Double = 0.004

    // MARK: 三条 cue 的配方

    /// 收词「叮」：E6 基音 + 一个八度泛音，指数衰减。
    static func collectWord() -> [Double] {
        tone(duration: 0.42, decay: 9.0,
             partials: [(1_318.51, 1.0), (2_637.02, 0.32)])
    }

    /// 通关小旋律：C5–E5–G5–C6 琶音，末音拖长并衰减（总长约 0.8s）。
    static func levelFanfare() -> [Double] {
        let notes: [(frequency: Double, duration: Double)] = [
            (523.25, 0.14), (659.26, 0.14), (783.99, 0.14), (1_046.50, 0.40),
        ]
        var mixed: [Double] = []
        for (index, note) in notes.enumerated() {
            let isLast = index == notes.count - 1
            let segment = tone(duration: note.duration, decay: isLast ? 5.5 : 2.2,
                               partials: [(note.frequency, 1.0), (note.frequency * 2, 0.2)])
            if isLast {
                mixed = overlapped(mixed, segment, overlap: 0.03)
            } else {
                mixed += segment
            }
        }
        return mixed
    }

    /// 小动物的一声叫：频率上滑的短促啁啾。
    static func animalTap() -> [Double] {
        chirp(from: 720, to: 1_350, duration: 0.13, decay: 11.0)
    }

    /// cue → 波形（唯一入口，测试与播放共用这一张映射表）。
    public static func samples(for cue: SoundCue) -> [Double] {
        switch cue {
        case .collectWord: collectWord()
        case .levelFanfare: levelFanfare()
        case .animalTap: animalTap()
        }
    }

    /// cue → WAV Data（SoundCueCenter 播放用的成品）。
    public static func data(for cue: SoundCue) -> Data {
        wav(samples: samples(for: cue))
    }

    // MARK: 波形基元

    /// 叠加多分音、指数衰减的稳定音色。
    static func tone(duration: Double, decay: Double,
                     partials: [(frequency: Double, gain: Double)]) -> [Double] {
        let count = Int(duration * Double(sampleRate))
        guard count > 0 else { return [] }
        var out = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / Double(sampleRate)
            var value = 0.0
            for partial in partials {
                value += partial.gain * sin(2 * .pi * partial.frequency * t)
            }
            out[i] = value * envelope(t: t, duration: duration, decay: decay)
        }
        return normalized(out)
    }

    /// 频率上滑的啁啾（相位要按瞬时频率积分，不能直接 sin(2πf(t)·t)）。
    static func chirp(from low: Double, to high: Double, duration: Double, decay: Double) -> [Double] {
        let count = Int(duration * Double(sampleRate))
        guard count > 0 else { return [] }
        var out = [Double](repeating: 0, count: count)
        var phase = 0.0
        for i in 0..<count {
            let t = Double(i) / Double(sampleRate)
            let progress = t / duration
            let frequency = low + (high - low) * progress
            phase += 2 * .pi * frequency / Double(sampleRate)
            out[i] = sin(phase) * envelope(t: t, duration: duration, decay: decay)
        }
        return normalized(out)
    }

    /// 包络：起音斜坡 × 指数衰减 × 收音斜坡。
    private static func envelope(t: Double, duration: Double, decay: Double) -> Double {
        let attack = min(t / ramp, 1)
        let release = min(max(duration - t, 0) / ramp, 1)
        return attack * release * exp(-decay * t)
    }

    /// 把一段尾巴叠进前一段开头（琶音的连贯感），不裁掉任何一边。
    private static func overlapped(_ base: [Double], _ tail: [Double], overlap: Double) -> [Double] {
        let back = max(0, base.count - Int(overlap * Double(sampleRate)))
        var out = base
        out.replaceSubrange(back..<base.count, with: tail.prefix(base.count - back))
        out.append(contentsOf: tail.suffix(from: min(tail.count, base.count - back)))
        return out
    }

    private static func normalized(_ samples: [Double]) -> [Double] {
        guard let maxAbs = samples.map(abs).max(), maxAbs > 0 else { return samples }
        let gain = peak / maxAbs
        return samples.map { $0 * gain }
    }

    // MARK: WAV 容器

    /// 波形 → 标准 44 字节头 + 16-bit 单声道 PCM 小端 WAV。
    public static func wav(samples: [Double]) -> Data {
        let dataSize = samples.count * 2
        var data = Data(capacity: 44 + dataSize)
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func appendASCII(_ text: String) { data.append(contentsOf: text.utf8) }

        appendASCII("RIFF")
        append(UInt32(36 + dataSize))
        appendASCII("WAVE")
        appendASCII("fmt ")
        append(16)                          // fmt 块长度
        append16(1)                         // PCM
        append16(1)                         // 单声道
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))      // 字节率 = 采样率 × 块对齐
        append16(2)                         // 块对齐（16-bit 单声道）
        append16(16)                        // 位深
        appendASCII("data")
        append(UInt32(dataSize))
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            append16(UInt16(bitPattern: Int16(clamped * Double(Int16.max))))
        }
        return data
    }
}

// MARK: - 播放通道

/// 播放抽象：真身走 AVAudioPlayer，测试换记账 spy。
public protocol SoundPlaying: AnyObject, Sendable {
    func play(cue: SoundCue, data: Data)
}

/// UI 音效播放器：发后即忘，播完自摘；最多同时挂 4 个实例防连点刷爆。
public final class UISoundPlayer: NSObject, SoundPlaying, AVAudioPlayerDelegate, @unchecked Sendable {

    private let lock = NSLock()
    private var players: [AVAudioPlayer] = []

    public override init() { super.init() }

    public func play(cue: SoundCue, data: Data) {
        guard let player = try? AVAudioPlayer(data: data) else { return }
        player.volume = 0.4
        player.delegate = self
        lock.lock()
        players.append(player)
        if players.count > 4 { players.removeFirst(players.count - 4) }
        lock.unlock()
        player.play()
    }

    private func remove(_ player: AVAudioPlayer) {
        lock.lock()
        players.removeAll { $0 === player }
        lock.unlock()
    }

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        remove(player)
    }

    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        remove(player)
    }
}

// MARK: - 开关与分发（AppUI 侧的唯一入口）

/// 轻音效中心：`enabled` 是唯一开关（默认关），`cue(_:)` 是唯一分发口。
///
/// AppState 持有它并在启动 / 设置页切换时同步 `enabled`；事件总线那条路
/// （收词 / 通关）与视图回调那条路（点小动物）都汇到这里。
@MainActor
@Observable
public final class SoundCueCenter {

    /// 声音全部默认关：像动画一样，必须让用户自己选择要热闹。
    public var enabled = false

    private let player: any SoundPlaying

    public init(player: any SoundPlaying = UISoundPlayer()) {
        self.player = player
    }

    /// 发一条 cue：没开开关就是静默 no-op（调用方不必各自判断）。
    public func cue(_ cue: SoundCue) {
        guard enabled else { return }
        player.play(cue: cue, data: WavTone.data(for: cue))
    }
}
