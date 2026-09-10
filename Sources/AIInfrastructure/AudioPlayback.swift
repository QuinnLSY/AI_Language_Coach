@preconcurrency import AVFoundation
import Foundation

/// 音频播放器：播放 runtime 返回的 WAV（教师语音）。用完即释放，不驻留缓存。
///
/// 变速播放走 `AVAudioEngine` + `AVAudioUnitTimePitch`：**只改快慢、不改音调**，
/// 且支持 0.5×–3× 全区间（AVAudioPlayer.rate 只到 2× 且会变调）。
///
/// `playAndWait` 用于「逐句合成、边播边取下一句」的流水线：调用方能精确知道一句播完，
/// 从而在播放期间并行合成下一句；被打断（stop）时也会立即返回，不会永久挂起。
///
/// 并发说明：`NSLock` 只允许在同步函数里使用（Swift 6 禁止在 async 上下文持锁），
/// 因此所有状态读写都收敛到下面的同步私有访问器。
public final class AudioPlayback: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {

    private let lock = NSLock()
    private var player: AVAudioPlayer?
    private var engine: AVAudioEngine?
    private var tempFileURL: URL?
    /// 等待播放结束的挂起者；resume 后立即置空，保证只恢复一次。
    private var finishContinuation: CheckedContinuation<Void, Never>?

    public override init() { super.init() }

    public var isPlaying: Bool {
        lock.lock(); defer { lock.unlock() }
        if let player { return player.isPlaying }
        return engine?.isRunning ?? false
    }

    /// 播放 WAV 数据并等待播完（或被打断）；供分句流水线使用。
    public func playAndWait(wavData: Data, rate: Float = 1.0) async throws {
        stop()
        if abs(rate - 1.0) < 0.01 {
            let player = try AVAudioPlayer(data: wavData)
            player.delegate = self
            player.prepareToPlay()
            install(player: player)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                park(continuation)
                player.play()
            }
            return
        }
        try await playWithEngine(wavData: wavData, rate: rate)
    }

    public func stop() {
        lock.lock()
        player?.stop()
        player = nil
        let runningEngine = engine
        engine = nil
        let url = tempFileURL
        tempFileURL = nil
        let continuation = finishContinuation
        finishContinuation = nil
        lock.unlock()

        runningEngine?.stop()
        if let url { try? FileManager.default.removeItem(at: url) }
        continuation?.resume()
    }

    // MARK: - AVAudioPlayerDelegate

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finishCurrent()
    }

    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        finishCurrent()
    }

    /// 唤醒等待者（幂等：只有第一个调用者能取到 continuation）。
    private func finishCurrent() {
        takeContinuation()?.resume()
    }

    // MARK: - 状态访问（同步，供 async 上下文安全调用）

    private func install(player: AVAudioPlayer) {
        lock.lock(); defer { lock.unlock() }
        self.player = player
    }

    private func park(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock(); defer { lock.unlock() }
        finishContinuation = continuation
    }

    private func takeContinuation() -> CheckedContinuation<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        let continuation = finishContinuation
        finishContinuation = nil
        return continuation
    }

    private func install(engine: AVAudioEngine, url: URL) {
        lock.lock(); defer { lock.unlock() }
        self.engine = engine
        self.tempFileURL = url
    }

    /// 释放指定引擎（仅当它仍是当前引擎时），返回需要删除的临时文件。
    private func release(engine: AVAudioEngine) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard self.engine === engine else { return nil }
        self.engine = nil
        let url = tempFileURL
        tempFileURL = nil
        return url
    }

    // MARK: - 变速链路（引擎 + 时间拉伸）

    /// 引擎播放：临时落盘 → AVAudioFile 读取 → 时间拉伸节点 → 输出，并等待整段播完。
    private func playWithEngine(wavData: Data, rate: Float) async throws {
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
        install(engine: engine, url: url)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            park(continuation)
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.finishCurrent()
            }
            node.play()
        }
        teardown(engine: engine, url: url)
    }

    /// 停引擎 + 删临时文件（幂等）。
    private func teardown(engine: AVAudioEngine, url: URL) {
        engine.stop()
        try? FileManager.default.removeItem(at: url)
        _ = release(engine: engine)
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
