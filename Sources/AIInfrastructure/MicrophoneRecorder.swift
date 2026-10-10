@preconcurrency import AVFoundation
import AppCore
import Foundation

/// 麦克风录音器：采集 16kHz 单声道 Float 采样，供 ASR 使用。
///
/// 只负责「把声音变成数字」，不含任何模型/业务逻辑。
///
/// ⚠️ 最关键的一条约束（2026-09-10 崩溃修复，勿改）：
/// `AVAudioNode.installTap` 要求的格式**采样率必须与输入节点的硬件格式完全一致**。
/// 传一个 16kHz 的格式给 48kHz 的输入节点，`AVAudioEngine` 内部会抛 Objective-C 异常
/// （`required condition is false: format.sampleRate == hwFormat.sampleRate`），
/// 这不是 Swift 错误、**catch 不到**，进程直接 SIGABRT 退出。
/// 而 whisper 需要 16kHz、本机默认输入设备是 48kHz，两者必然不一致 ——
/// 因此正确做法是：**用硬件格式收流，再自行重采样到 16kHz**。
public final class MicrophoneRecorder: @unchecked Sendable {

    /// 录音采样率（whisper 家族统一 16kHz）。
    public static let sampleRate: Double = 16_000

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var buffer: [Float] = []
    /// 录音生命周期的并发闸门（#S3-10，见 `RecordingGate`）。
    private let gate = RecordingGate()
    /// 采集链路上的故障（重采样失败等）；nil = 正常。
    private var _captureError: String?

    public init() {}

    public var isRecording: Bool { gate.isRecording }

    /// 采集过程中的错误（重采样失败、引擎异常等），供上层提示用户。
    public var captureError: String? {
        lock.lock(); defer { lock.unlock() }
        return _captureError
    }

    /// 麦克风权限。首次调用会弹系统授权框（.app 需声明 NSMicrophoneUsageDescription）。
    public func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default: return false
        }
    }

    /// 开始录音。已授权但未安装 tap 时抛错由调用方处理。
    ///
    /// ⚠️ `starting` 期间的重入一律**直接返回**（不抛错）：双击麦克风是常态，
    /// 第二次调用应该什么都不做，而不是再造一套引擎（见 `Lifecycle` 的说明）。
    public func start() throws {
        // ⚠️ 先占坑：解锁之后的整段构建过程里，谁再进来都看到「占用中」（#S3-10）。
        guard gate.beginStarting() else { return }
        lock.lock()
        buffer = []
        buffer.reserveCapacity(Int(Self.sampleRate * 60))
        _captureError = nil
        lock.unlock()

        guard let target = Self.targetFormat() else {
            gate.release()
            throw AppError.audio("无法创建录音格式")
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        // 没有可用输入设备时硬件格式是 0Hz/0 声道；带着这种格式去 installTap 同样会崩，先拦掉。
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            gate.release()
            throw AppError.audio("没有可用的麦克风输入设备")
        }

        // installTap 只接受「与硬件同采样率」的格式，其余差异（声道数、采样格式、采样率）
        // 全部交给 AVAudioConverter 处理。
        let tapFormat = Self.tapFormat(for: hardware)
        let isPassthrough = Self.isSameLayout(tapFormat, target)
        let converter = isPassthrough ? nil : AVAudioConverter(from: tapFormat, to: target)
        if !isPassthrough, converter == nil {
            gate.release()
            throw AppError.audio("无法把麦克风音频转换成识别所需格式")
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] pcm, _ in
            guard let self else { return }
            guard let samples = Self.samples(from: pcm, converter: converter, target: target) else {
                self.noteCaptureError("麦克风音频重采样失败")
                return
            }
            guard !samples.isEmpty else { return }
            self.lock.lock()
            self.buffer.append(contentsOf: samples)
            self.lock.unlock()
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            // 失败路径必须拆掉 tap，否则本地 engine 释放时仍挂着回调。
            input.removeTap(onBus: 0)
            gate.release()
            throw AppError.audio("无法启动录音：\(error.localizedDescription)")
        }

        lock.lock()
        self.engine = engine
        lock.unlock()
        gate.markRecording()
    }

    /// 停止录音并返回本段音频采样（已释放 tap 与引擎）。
    public func stop() -> [Float] {
        lock.lock()
        guard gate.isRecording else {
            lock.unlock()
            return []
        }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        let captured = buffer
        buffer = []
        lock.unlock()
        // 先解锁再放闸门：两把锁方向永远是 `lock → gate`，绝不反过来（否则会死锁）。
        gate.release()
        return captured
    }

    /// 当前已采集音频的快照（**不断流**）。
    ///
    /// 供「流式识别」用：边说边把已录到的音频送去识别，把中间结果实时显示出来。
    /// 返回的是副本，调用方随便处理；未录音时返回空数组。
    public func currentSamples() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        guard gate.isRecording else { return [] }
        return buffer
    }

    // MARK: - 格式（可测的纯逻辑）

    /// 识别链路的统一目标格式：16kHz 单声道 Float32（whisper 要求）。
    static func targetFormat() -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: sampleRate,
                      channels: 1,
                      interleaved: false)
    }

    /// 计算 `installTap` 允许使用的格式。
    ///
    /// **采样率原样保留**（这是硬约束），只把采样格式规整成 Float32 非交错，
    /// 便于后续重采样；规整失败时原样返回硬件格式。
    static func tapFormat(for hardware: AVAudioFormat) -> AVAudioFormat {
        if hardware.commonFormat == .pcmFormatFloat32, !hardware.isInterleaved {
            return hardware
        }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32,
                             sampleRate: hardware.sampleRate,
                             channels: hardware.channelCount,
                             interleaved: false) ?? hardware
    }

    /// 两个格式是否完全同构（同采样率 / 同声道数 / 同采样格式），同构则无需转换。
    static func isSameLayout(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }

    /// 把 tap 回调拿到的 PCM 转成 16kHz 单声道 Float 采样。
    ///
    /// `converter == nil` 表示硬件本就与目标格式同构，直接取用。
    /// 多声道经 AVAudioConverter 自动下混为单声道。
    static func samples(from pcm: AVAudioPCMBuffer,
                        converter: AVAudioConverter?,
                        target: AVAudioFormat) -> [Float]? {
        guard let converter else {
            guard let channel = pcm.floatChannelData?[0] else { return nil }
            return Array(UnsafeBufferPointer(start: channel, count: Int(pcm.frameLength)))
        }

        let ratio = target.sampleRate / pcm.format.sampleRate
        let capacity = AVAudioFrameCount((Double(pcm.frameLength) * ratio).rounded(.up)) + 64
        guard capacity > 0,
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return nil
        }

        // 一个输入缓冲只喂一次；之后必须报 noDataNow，否则转换器会反复索要同一个缓冲。
        // ⚠️ 回调签名是 `@Sendable`，直接捕获局部 `var` 会被判「在并发执行的代码里改可变状态」；
        // 该回调其实是同步调用的，「只喂一次」的语义用一次性标志位表达，顺带线程安全。
        let feedOnce = OneShotFlag()
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard feedOnce.consume() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return pcm
        }

        guard status != .error,
              output.frameLength > 0,
              let channel = output.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    /// 一次性许可：第一次 `consume()` 拿得到，之后一律拿不到。
    ///
    /// 专门为 `AVAudioConverter.convert(to:error:inputBlock:)` 这类
    /// 「`@Sendable` 但同步调用」的回调服务——用锁把「只喂一次」变成线程安全的，
    /// 免得在闭包里捕获可变的局部变量（那会被并发检查判为数据竞争）。
    private final class OneShotFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var consumed = false

        /// 返回 true 表示**本次**拿到了许可；返回 false 表示之前已经有人拿过。
        func consume() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if consumed { return false }
            consumed = true
            return true
        }
    }

    private func noteCaptureError(_ message: String) {
        lock.lock()
        _captureError = message
        lock.unlock()
    }
}

/// 录音生命周期的并发闸门（#S3-10）。
///
/// 为什么不能只用「`isRecording` 布尔 + 两段加锁」：`start()` 里**检查与置位之间**
/// 隔着一整段不加锁的代码 —— 建引擎、装 tap、`engine.start()`。并发进来的第二次
/// `start()` 会看到「还没在录」，于是**再造一套引擎与 tap**，后写覆盖 `engine` 引用；
/// 前一套再也无人引用、无人停止，麦克风就这样常开着。
///
/// 三态而不是布尔：`starting` 这一段**也算占用**（这正是原来缺的那一格）。
/// 抽成独立类型是为了能直接单测这个竞态（见 `ConcurrencyAndResourceTests`）——
/// 真去并发调 `start()` 要碰真麦克风，测不了。
final class RecordingGate: @unchecked Sendable {

    enum Phase { case idle, starting, recording }

    private let lock = NSLock()
    private var phase: Phase = .idle

    /// 尝试开始一次录音。**只有从 `idle` 出发的那一次**拿得到 true；
    /// 其余（已在录、或正在启动）一律 false，调用方应当直接返回。
    func beginStarting() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard phase == .idle else { return false }
        phase = .starting
        return true
    }

    /// 构建成功，进入录音中。
    func markRecording() {
        lock.lock(); defer { lock.unlock() }
        phase = .recording
    }

    /// 回到空闲（停止录音、或构建中途失败）。
    func release() {
        lock.lock(); defer { lock.unlock() }
        phase = .idle
    }

    var isRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        return phase == .recording
    }
}
