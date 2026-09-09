import AVFoundation
import AppCore
import Foundation

/// 麦克风录音器：采集 16kHz 单声道 Float 采样，供 ASR 使用。
///
/// 只负责「把声音变成数字」，不含任何模型/业务逻辑。
public final class MicrophoneRecorder: @unchecked Sendable {

    /// 录音采样率（whisper 家族统一 16kHz）。
    public static let sampleRate: Double = 16_000

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var buffer: [Float] = []
    private var _isRecording = false

    public init() {}

    public var isRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isRecording
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
    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !_isRecording else { return }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AppError.audio("无法创建录音格式")
        }
        buffer = []
        buffer.reserveCapacity(Int(Self.sampleRate * 60))

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] pcm, _ in
            guard let self else { return }
            guard let channel = pcm.floatChannelData?[0] else { return }
            let count = Int(pcm.frameLength)
            self.lock.lock()
            self.buffer.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
            self.lock.unlock()
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        _isRecording = true
    }

    /// 停止录音并返回本段音频采样（已释放 tap 与引擎）。
    public func stop() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        guard _isRecording else { return [] }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        _isRecording = false
        let captured = buffer
        buffer = []
        return captured
    }

    /// 实时电平（0…1），供 UI 画波形；未录音时为 0。
    public var level: Float {
        lock.lock()
        defer { lock.unlock() }
        guard _isRecording else { return 0 }
        let tail = buffer.suffix(2048)
        guard !tail.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in tail { sum += sample * sample }
        return min(1, sqrt(sum / Float(tail.count)) * 4)
    }
}
