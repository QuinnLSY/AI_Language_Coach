import AVFoundation
import Foundation

/// 音频播放器：播放 runtime 返回的 WAV（教师语音）。用完即释放，不驻留缓存。
public final class AudioPlayback: @unchecked Sendable {

    private let lock = NSLock()
    private var player: AVAudioPlayer?

    public init() {}

    public var isPlaying: Bool {
        lock.lock(); defer { lock.unlock() }
        return player?.isPlaying ?? false
    }

    /// 播放 WAV 数据；播放前自动停止上一段。
    public func play(wavData: Data) throws {
        lock.lock()
        player?.stop()
        player = nil
        let player = try AVAudioPlayer(data: wavData)
        player.prepareToPlay()
        self.player = player
        lock.unlock()
        player.play()
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        player?.stop()
        player = nil
    }
}
