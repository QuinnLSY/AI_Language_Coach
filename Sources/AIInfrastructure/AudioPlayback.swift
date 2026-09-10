@preconcurrency import AVFoundation
import Foundation

/// 音频播放器：播放 runtime 返回的 WAV（教师语音）。用完即释放，不驻留缓存。
///
/// 变速播放走 `AVAudioEngine` + `AVAudioUnitTimePitch`：**只改快慢、不改音调**，
/// 且支持 0.5×–3× 全区间（AVAudioPlayer.rate 只到 2× 且会变调）。
public final class AudioPlayback: @unchecked Sendable {

    private let lock = NSLock()
    private var player: AVAudioPlayer?
    private var engine: AVAudioEngine?
    private var tempFileURL: URL?

    public init() {}

    public var isPlaying: Bool {
        lock.lock(); defer { lock.unlock() }
        if let player { return player.isPlaying }
        return engine?.isRunning ?? false
    }

    /// 播放 WAV 数据；播放前自动停止上一段。
    /// - Parameter rate: 播放倍速（1 = 原速）。非 1 时启用引擎链路变速。
    public func play(wavData: Data, rate: Float = 1.0) throws {
        stop()
        if abs(rate - 1.0) < 0.01 {
            let player = try AVAudioPlayer(data: wavData)
            player.prepareToPlay()
            lock.lock()
            self.player = player
            lock.unlock()
            player.play()
            return
        }
        try playWithEngine(wavData: wavData, rate: rate)
    }

    public func stop() {
        lock.lock()
        player?.stop()
        player = nil
        let runningEngine = engine
        engine = nil
        let url = tempFileURL
        tempFileURL = nil
        lock.unlock()

        runningEngine?.stop()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - 变速链路（引擎 + 时间拉伸）

    /// 引擎播放：临时落盘 → AVAudioFile 读取 → 时间拉伸节点 → 输出。
    private func playWithEngine(wavData: Data, rate: Float) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("coach-tts-\(UUID().uuidString).wav")
        try wavData.write(to: url)

        let file = try AVAudioFile(forReading: url)
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        pitch.rate = rate

        engine.attach(node)
        engine.attach(pitch)
        engine.connect(node, to: pitch, format: file.processingFormat)
        engine.connect(pitch, to: engine.mainMixerNode, format: file.processingFormat)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else {
            try? FileManager.default.removeItem(at: url)
            throw AudioPlaybackError.bufferUnavailable
        }
        try file.read(into: buffer)
        try engine.start()

        lock.lock()
        self.engine = engine
        self.tempFileURL = url
        lock.unlock()

        node.scheduleBuffer(buffer) { [weak self] in
            // 播完即释放引擎与临时文件（回到后台队列，内部加锁保护）。
            DispatchQueue.global(qos: .utility).async {
                engine.stop()
                try? FileManager.default.removeItem(at: url)
                guard let self else { return }
                self.lock.lock()
                if self.engine === engine {
                    self.engine = nil
                    self.tempFileURL = nil
                }
                self.lock.unlock()
            }
        }
        node.play()
    }
}

public enum AudioPlaybackError: LocalizedError, Sendable {
    case bufferUnavailable

    public var errorDescription: String? {
        switch self {
        case .bufferUnavailable: "音频缓冲创建失败，无法变速播放"
        }
    }
}
