import AIInfrastructure
import AIInterfaces
import AIProviders
import AppCore
import Foundation

/// 语音能力统一入口：**录音 → 识别** 与 **文本 → 朗读**。
///
/// UI 只跟本服务打交道，不接触麦克风 / 播放器 / 任何 Adapter。
public actor VoiceService {

    public let asr: ASRManager
    public let tts: TTSManager

    private let recorder = MicrophoneRecorder()
    private let playback = AudioPlayback()

    public private(set) var isRecording = false
    public private(set) var isTranscribing = false
    public private(set) var isSpeaking = false
    /// 最近一次语音相关的用户可读错误（nil = 正常）。
    public private(set) var lastError: String?
    /// runtime 自报的音色；为空时 UI 回退到内置预设。
    public private(set) var availableVoices: [String] = []

    public init(asr: ASRManager = ASRManager(), tts: TTSManager = TTSManager()) {
        self.asr = asr
        self.tts = tts
    }

    // MARK: - 识别（说）

    /// 麦克风权限（首次调用触发系统授权）。
    public func requestMicrophonePermission() async -> Bool {
        await recorder.requestPermission()
    }

    public func startRecording() async {
        guard await requestMicrophonePermission() else {
            lastError = "没有麦克风权限，请在「系统设置 → 隐私与安全性 → 麦克风」中开启"
            return
        }
        do {
            try recorder.start()
            isRecording = true
            lastError = nil
        } catch {
            lastError = "无法开始录音：\(error.localizedDescription)"
        }
    }

    /// 停止录音并识别；返回识别文本（失败返回 nil 并写入 lastError）。
    public func stopRecordingAndTranscribe(language: String? = nil) async -> String? {
        let samples = recorder.stop()
        isRecording = false
        guard !samples.isEmpty else {
            lastError = "没有录到声音，请再说一次"
            return nil
        }
        isTranscribing = true
        defer { isTranscribing = false }
        do {
            let result = try await asr.transcribe(ASRRequest(audioSamples: samples, language: language))
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            lastError = text.isEmpty ? "没有听清，请再说一次" : nil
            return text.isEmpty ? nil : text
        } catch {
            lastError = Self.describe(error)
            return nil
        }
    }

    public func cancelRecording() {
        _ = recorder.stop()
        isRecording = false
    }

    /// 实时电平（0…1），供 UI 画说话波纹。
    public var recordingLevel: Float { recorder.level }

    // MARK: - 朗读（听）

    /// 朗读文本。空文本直接忽略；合成中重复点击会被忽略（runtime 不允许并发推理）。
    public func speak(_ text: String, voice: String, language: String = "English") async {
        let trimmed = Self.cleanForSpeech(text)
        guard !trimmed.isEmpty else { return }
        guard !isSpeaking else { return }
        isSpeaking = true
        defer { isSpeaking = false }
        do {
            let result = try await tts.synthesize(
                TTSRequest(text: trimmed, voice: voice, language: language)
            )
            try playback.play(wavData: Self.wavData(for: result))
            lastError = nil
        } catch {
            lastError = Self.describe(error)
        }
    }

    public func stopSpeaking() {
        playback.stop()
        isSpeaking = false
    }

    /// 拉取 runtime 可用音色（失败返回空数组，UI 用内置预设兜底）。
    public func refreshVoices() async -> [String] {
        let voices = await tts.availableVoices()
        if !voices.isEmpty { availableVoices = voices }
        return availableVoices
    }

    // MARK: - 内部

    /// 去掉不适合朗读的标记（`[[FIX]]` 块、markdown 等），保留自然语句。
    public nonisolated static func cleanForSpeech(_ text: String) -> String {
        var lines: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("[[FIX]]") { continue }
            lines.append(line)
        }
        let joined = lines.joined(separator: " ")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "#", with: "")
        let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 400 ? String(trimmed.prefix(400)) : trimmed
    }

    /// 优先使用 runtime 原始 WAV；否则由采样重新封装。
    public nonisolated static func wavData(for result: TTSResult) -> Data {
        if let data = result.audioData, !data.isEmpty { return data }
        return WhisperASRAdapter.wavData(samples: result.audioSamples, sampleRate: result.sampleRate)
    }

    nonisolated static func describe(_ error: Error) -> String {
        if let providerError = error as? AIProviderError {
            switch providerError {
            case .runtimeUnavailable: return "本地语音服务未启动，请先运行 ~/AI_Models/start.sh"
            case .notInitialized: return "语音能力尚未就绪"
            case .timeout: return "语音服务响应超时，请稍后重试"
            default: return providerError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
