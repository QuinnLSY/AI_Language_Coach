import AIInfrastructure
import AIInterfaces
import AIProviders
import AppCore
import Foundation

/// 朗读相位：UI 据此显示「准备中 / 朗读中」，让等待过程可见。
public enum SpeechPhase: Sendable, Equatable {
    case idle
    /// 正在合成首句（尚无声音）
    case preparing
    /// 已有声音在播
    case speaking
}

/// 语音能力统一入口：**录音 → 识别** 与 **文本 → 朗读**。
///
/// UI 只跟本服务打交道，不接触麦克风 / 播放器 / 任何 Adapter。
///
/// 朗读采用**分句流水线**（2026-09-10 优化）：本地 TTS 合成耗时 ≈ 2.6 × 音频时长且近似线性，
/// 整段一次性合成会让用户干等几十秒。这里把文本切成短句，首句合成完立即播放，
/// 播放期间并行预取下一句，感知延迟从「全文合成」降为「首句合成」。成品音频按
/// (音色, 语言, 文本) 缓存，重复朗读同一句直接命中。
public actor VoiceService {

    public let asr: ASRManager
    public let tts: TTSManager

    private let recorder = MicrophoneRecorder()
    private let playback = AudioPlayback()

    public private(set) var isRecording = false
    public private(set) var isTranscribing = false
    public private(set) var isSpeaking = false
    /// 当前朗读相位（准备中 / 朗读中 / 空闲）。
    public private(set) var phase: SpeechPhase = .idle
    /// 最近一次语音相关的用户可读错误（nil = 正常）。
    public private(set) var lastError: String?
    /// runtime 自报的音色；为空时 UI 回退到内置预设。
    public private(set) var availableVoices: [String] = []

    /// 相位变化回调（含当前朗读文本，供 UI 高亮对应消息）。
    public var onPhaseChange: (@Sendable (SpeechPhase, String?) -> Void)?

    /// 注册相位回调（UI 侧装配用）。
    public func setPhaseHandler(_ handler: (@Sendable (SpeechPhase, String?) -> Void)?) {
        onPhaseChange = handler
    }

    /// 当前朗读会话令牌：换值即作废上一段朗读（用于「再点一次 = 重新读」）。
    private var speakToken = UUID()
    /// 在途的合成请求：打断时必须取消，否则它会继续占住串行的本地 runtime，
    /// 让新请求排队（实测未取消时单次要等数百秒）。
    private var inflight: Task<Data, Error>?
    /// 本次朗读的原始文本（供 UI 匹配高亮）。
    private var speakingSource: String?

    /// 合成结果缓存：key = 音色|语言|文本。
    private var audioCache: [String: Data] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 48

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

    /// 朗读文本。采用分句流水线：首句先出声，其余边播边合成。
    ///
    /// 再次调用会**打断**上一段（用户重复点击 = 重新读，而不是被静默忽略）。
    /// - Parameter rate: 播放倍速（1 = 原速，由设置里的语速决定）。
    public func speak(_ text: String, voice: String, language: String = "English", rate: Float = 1.0) async {
        let sentences = SentenceSplitter.split(Self.cleanForSpeech(text))
        guard !sentences.isEmpty else { return }

        // 作废上一段朗读并停声，保证「再点一次」立即生效
        let token = UUID()
        speakToken = token
        speakingSource = text
        // 取消在途合成，避免它占住串行的本地 runtime 让新请求排队
        inflight?.cancel()
        inflight = nil
        playback.stop()

        isSpeaking = true
        lastError = nil
        setPhase(.preparing, text)
        defer {
            if speakToken == token {
                isSpeaking = false
                speakingSource = nil
                setPhase(.idle, nil)
            }
        }

        // 首句立即开合成
        var pending: Task<Data, Error>? = prefetchTask(sentences[0], voice: voice, language: language)
        inflight = pending

        for (index, _) in sentences.enumerated() {
            guard speakToken == token, let task = pending else { return }
            let wav: Data
            do {
                wav = try await task.value
            } catch {
                if speakToken == token { lastError = Self.describe(error) }
                return
            }
            guard speakToken == token else { return }

            // 播放本句的同时预取下一句：服务端串行合成，正好与播放时长重叠
            if index + 1 < sentences.count {
                pending = prefetchTask(sentences[index + 1], voice: voice, language: language)
                inflight = pending
            } else {
                pending = nil
                inflight = nil
            }

            setPhase(.speaking, text)
            do {
                try await playback.playAndWait(wavData: wav, rate: rate)
            } catch {
                if speakToken == token { lastError = Self.describe(error) }
                return
            }
        }
    }

    public func stopSpeaking() {
        speakToken = UUID()
        speakingSource = nil
        inflight?.cancel()
        inflight = nil
        playback.stop()
        isSpeaking = false
        setPhase(.idle, nil)
    }

    /// 预热本地语音模型（合成一个极短句）。
    ///
    /// 背景：实测 MPS 上的 TTS 在空闲一段时间后首次请求要 37~60s（显存被系统换出，
    /// 需要重新换入），热态只需 ~10s。与 LLM 生成并行预热，可让随后的朗读落在热态。
    /// 正在朗读时不抢占；失败静默（预热只是优化，不影响正确性）。
    /// - Returns: 预热是否成功；失败不影响正确性，只为诊断与观测。
    @discardableResult
    public func warmUp(voice: String, language: String = "English") async -> Bool {
        guard !isSpeaking, !isRecording else { return false }
        do {
            _ = try await tts.synthesize(TTSRequest(text: "Hi.", voice: voice, language: language))
            AppLog.info("语音预热完成", category: "voice")
            return true
        } catch {
            AppLog.warning("语音预热失败：\(Self.describe(error))", category: "voice")
            return false
        }
    }

    /// 拉取 runtime 可用音色（失败返回空数组，UI 用内置预设兜底）。
    public func refreshVoices() async -> [String] {
        let voices = await tts.availableVoices()
        if !voices.isEmpty { availableVoices = voices }
        return availableVoices
    }

    /// runtime 自报描述（本地语音模型与运行设备），设置页展示用。
    public func ttsRuntimeDescription() async -> String? {
        await tts.runtimeDescription()
    }

    // MARK: - 内部

    private func setPhase(_ next: SpeechPhase, _ text: String?) {
        phase = next
        onPhaseChange?(next, text)
    }

    /// 后台合成一句（命中缓存则瞬时返回）。
    private func prefetchTask(_ sentence: String, voice: String, language: String) -> Task<Data, Error> {
        Task { [weak self] in
            guard let self else { throw AIProviderError.notInitialized }
            return try await self.synthesizeCached(sentence, voice: voice, language: language)
        }
    }

    private func synthesizeCached(_ text: String, voice: String, language: String) async throws -> Data {
        let key = "\(voice)|\(language)|\(text)"
        if let hit = audioCache[key] { return hit }

        let result = try await tts.synthesize(
            TTSRequest(text: text, voice: voice, language: language)
        )
        let wav = Self.wavData(for: result)
        // 简单的 FIFO 淘汰，足够覆盖「反复朗读同一句」的场景
        if audioCache.count >= cacheLimit, let oldest = cacheOrder.first {
            audioCache[oldest] = nil
            cacheOrder.removeFirst()
        }
        audioCache[key] = wav
        cacheOrder.append(key)
        return wav
    }

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
        // 上限 400 字符：合成总时长与文本长度成正比（实测 RTF≈2.7），放宽只会让用户等更久。
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
