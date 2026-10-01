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
///
/// ⚠️ 采纳 `AVAudioPlayerDelegate` 会把整个类推断成主 actor 类型（Swift 6.4 起，
/// 连"在别的 actor 里持有它"都成了错误）。**只有** `stop()` 被标成 `nonisolated`：
/// 打断播放必须能从语音服务（actor）的同步方法里立刻生效，而它内部全程持锁、
/// 不碰任何主 actor 状态 —— 这才是这条豁免站得住的理由。
public final class AudioPlayback: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {

    private let lock = NSLock()
    // ⚠️ 下面这批状态标 `nonisolated(unsafe)`：它们一律在 `lock` 保护下读写（见文件头），
    // 而打断播放（`stop()`）必须能从非主 actor 的**同步**上下文里生效。留作主 actor 属性时
    // Swift 6.4 会把这些读写全判成跨 actor 访问；锁就是这里自己担起来的那份责任。
    private nonisolated(unsafe) var player: AVAudioPlayer?
    private nonisolated(unsafe) var engine: AVAudioEngine?
    private nonisolated(unsafe) var tempFileURL: URL?
    /// 等待播放结束的挂起者；resume 后立即置空，保证只恢复一次。
    private nonisolated(unsafe) var finishContinuation: CheckedContinuation<Void, Never>?

    /// `nonisolated` 是刻意的：本类因采纳 `AVAudioPlayerDelegate` 被推断成主 actor 类型，
    /// 于是连 `AudioPlayback()` 都只能在主 actor 上求 —— 语音服务（actor）根本拿不到实例。
    /// 构造期间对象还没被共享，此时豁免是安全的。
    public nonisolated override init() { super.init() }

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

    /// ⚠️ `nonisolated` 是刻意的：打断播放要能从语音服务的**同步**方法里立刻生效
    /// （不能等一次 `await MainActor.run`），而本方法全程持锁、不碰主 actor 状态。
    public nonisolated func stop() {
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
    ///
    /// `nonisolated`：播放结束的回调（引擎的 completion / 播放器的 delegate）不在主 actor 上打来，
    /// 而这里只走锁保护的 `takeContinuation()`，不碰任何主 actor 状态。
    private nonisolated func finishCurrent() {
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

    private nonisolated func takeContinuation() -> CheckedContinuation<Void, Never>? {
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

    // MARK: - 容器识别

    /// 按音频数据的魔数猜扩展名。
    ///
    /// 本地 TTS 固定返回 WAV；**云端 TTS 可能返回 mp3 / m4a**（各家默认格式不同）。
    /// 扩展名必须跟着内容走：把 mp3 写成 `.wav` 会让 `AVAudioFile` 读不出来，
    /// 表现就是「云端语音启用成功了，却一点声音都没有」。
    public nonisolated static func containerExtension(of data: Data) -> String {
        let bytes = [UInt8](data.prefix(64))
        guard bytes.count >= 12 else { return "wav" }
        if ascii(bytes, 0) == "RIFF", ascii(bytes, 8) == "WAVE" { return "wav" }
        if ascii(bytes, 0) == "ID3" { return "mp3" }
        if bytes[0] == 0xFF, (bytes[1] & 0xE0) == 0xE0 { return "mp3" }
        if ascii(bytes, 4) == "ftyp" { return "m4a" }
        if ascii(bytes, 0) == "OggS" { return "ogg" }
        if ascii(bytes, 0) == "fLaC" { return "flac" }
        return "wav"
    }

    private nonisolated static func ascii(_ bytes: [UInt8], _ offset: Int) -> String {
        guard offset + 4 <= bytes.count else { return "" }
        return String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii) ?? ""
    }

    // MARK: - 变速链路（引擎 + 时间拉伸）

    /// 引擎播放：临时落盘 → AVAudioFile 读取 → 时间拉伸节点 → 输出，并等待整段播完。
    private func playWithEngine(wavData: Data, rate: Float) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("coach-tts-\(UUID().uuidString).\(Self.containerExtension(of: wavData))")
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
