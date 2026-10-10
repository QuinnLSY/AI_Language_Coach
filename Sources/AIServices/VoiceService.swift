import AIDomain
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
    /// 最近一次录音的原始采样。跟读（Shadowing）需要「听我的」——
    /// 识别文本会丢掉的音长、语速、停顿，只有原音频留着才能回放对照。
    public private(set) var lastRecording: [Float] = []

    /// 相位变化回调（含当前朗读文本，供 UI 高亮对应消息）。
    public var onPhaseChange: (@Sendable (SpeechPhase, String?) -> Void)?
    /// 流式识别回调：录音过程中不断把「当前听到的整句」推给 UI，实现边说边出字。
    public var onPartialChange: (@Sendable (String) -> Void)?

    /// 注册相位回调（UI 侧装配用）。
    public func setPhaseHandler(_ handler: (@Sendable (SpeechPhase, String?) -> Void)?) {
        onPhaseChange = handler
    }

    /// 注册流式识别回调（UI 侧装配用）。
    public func setPartialHandler(_ handler: (@Sendable (String) -> Void)?) {
        onPartialChange = handler
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
    /// 同键**在途**的合成（#S3-7）。命中判断与写入之间夹着一次 `await tts.synthesize`，
    /// 那是个挂起点：同一句的第二次调用会重新走一遍「没命中」的分支。
    /// 后果有两个 —— 重复合成（真金白银）、同一个键被 append 两遍进 `cacheOrder`
    /// （FIFO 的账目从此对不上，淘汰时会错杀）。所以同键只跑一趟，后来者合流。
    private var synthInflight: [String: Task<Data, Error>] = [:]

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
            // 流式中间识别只在**本地 ASR** 上开：云端每一次中间识别都是一次完整的计费请求，
            // 一句话能被计成好几次（见 `VoiceCapturePolicy`）。云端只在松手时识别一次。
            if await asr.allowsStreamingPartials {
                startPartialLoop(language: partialLanguage)
            } else {
                stopPartialLoop()
            }
        } catch {
            lastError = "无法开始录音：\(error.localizedDescription)"
        }
    }

    /// 停止录音并识别；返回识别文本（失败返回 nil 并写入 lastError）。
    public func stopRecordingAndTranscribe(language: String? = nil) async -> String? {
        // ⚠️ 一次录音只允许收尾一次。重入的代价不是「什么都不做」而是**错报**：
        // 第二次 `recorder.stop()` 拿到的是空音频，会写 `lastError = "没有录到声音"`，
        // 把第一次那次真实识别的失败原因顶掉，用户看到的就是「我明明说了话，它说没录到」。
        guard !isTranscribing else { return nil }
        // 先停掉流式识别，避免它与最终识别抢同一个（串行的）语音服务。
        stopPartialLoop()
        let samples = recorder.stop()
        isRecording = false
        // 采集链路自身出过问题（如重采样失败）时优先报它，否则「没录到声音」会掩盖真因。
        if let captureError = recorder.captureError {
            lastError = captureError
            return nil
        }
        guard !samples.isEmpty else {
            lastError = "没有录到声音，请再说一次"
            return nil
        }
        isTranscribing = true
        defer { isTranscribing = false }
        // 留存原音频：跟读要能「听我的」，识别文本替代不了原声。
        lastRecording = samples
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
        stopPartialLoop()
        _ = recorder.stop()
        isRecording = false
    }

    // MARK: - 流式识别（边说边出字）

    /// 最近一次 startRecording 时指定的语言。
    private var partialLanguage: String?
    /// 流式识别的后台循环。
    private var partialTask: Task<Void, Never>?
    /// 流式识别的间隔：太密会拖慢（语音服务串行），太疏则不够"流式"。
    private static let partialInterval: TimeInterval = 1.2
    /// 触发一次中间识别所需的最少「新增音频」时长（秒）。
    private static let partialMinNewAudio: TimeInterval = 0.8
    /// 少于这个总时长不识别（避免把半秒钟的杂音当一句话）。
    private static let partialMinTotalAudio: TimeInterval = 1.0

    /// 记录本次录音希望识别的语言（供流式循环使用）。
    public func setPartialLanguage(_ language: String?) {
        partialLanguage = language
    }

    private func startPartialLoop(language: String?) {
        stopPartialLoop()
        partialLanguage = language
        // Task 继承本 actor 的隔离：循环里的调用都直接跑在本 actor 上，只有 asr.transcribe 需要 await。
        partialTask = Task { [weak self] in
            guard let self else { return }
            var lastCount = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.partialInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                let samples = await self.snapshot()
                let minimumTotal = Int(MicrophoneRecorder.sampleRate * Self.partialMinTotalAudio)
                let minimumNew = Int(MicrophoneRecorder.sampleRate * Self.partialMinNewAudio)
                guard samples.count >= minimumTotal, samples.count - lastCount >= minimumNew else { continue }
                lastCount = samples.count
                guard let text = await self.transcribePartial(samples: samples, language: language), !text.isEmpty else {
                    continue
                }
                guard !Task.isCancelled else { return }
                await self.emitPartial(text)
            }
        }
    }

    /// 把中间识别结果推给 UI（在 actor 内读取回调，避免跨隔离访问可变状态）。
    private func emitPartial(_ text: String) {
        onPartialChange?(text)
    }

    private func stopPartialLoop() {
        partialTask?.cancel()
        partialTask = nil
    }

    private func snapshot() -> [Float] {
        recorder.currentSamples()
    }

    /// 一次中间识别：失败静默（不打断录音，也不覆盖 lastError）。
    private func transcribePartial(samples: [Float], language: String?) async -> String? {
        do {
            let result = try await asr.transcribe(ASRRequest(audioSamples: samples, language: language))
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }

    // MARK: - 朗读（听）

    /// 朗读文本。投递方式由当前 TTS Provider 的 runtime 决定（见 `SpeechDelivery`）：
    ///
    /// - **本地模型** → 分句流水线：首句先出声，其余边播边合成，把首句等待降到最低。
    /// - **云端模型** → 整段一次合成：每句独立请求会割裂韵律，整段才读得连贯自然。
    ///
    /// 再次调用会**打断**上一段（用户重复点击 = 重新读，而不是被静默忽略）。
    /// - Parameter rate: 播放倍速（1 = 原速，由设置里的语速决定）。
    ///
    /// ⚠️ `language` **不给默认值**：它以前默认 `"English"`，于是漏传的调用点
    /// 也能编译通过、跑起来也「像是对的」—— 直到换语言那天才发现读的是英语。
    /// 现在漏传是编译错误。
    public func speak(_ text: String, voice: String, language: String, rate: Float = 1.0) async {
        await speak(text, voice: SpeechVoiceSelection.builtin(voice), language: language, rate: rate)
    }

    /// 朗读文本，音色用**选择结果**（含克隆音色的参考音频）。
    ///
    /// 与上面的 `String` 版本是同一件事：克隆音色除了音色名还要把参考音频交给 runtime，
    /// 所以真正的入口收的是 `SpeechVoiceSelection`，`String` 版本只是「内置音色」的简写。
    public func speak(
        _ text: String,
        voice: SpeechVoiceSelection,
        language: String,
        rate: Float = 1.0
    ) async {
        let delivery = await tts.delivery
        let cleaned = Self.cleanForSpeech(text, limit: delivery.maxCharacters)
        guard !cleaned.isEmpty else { return }

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

        switch delivery {
        case .whole:
            await speakWhole(cleaned, token: token, voice: voice, language: language, rate: rate)
        case .segmented:
            await speakSegmented(cleaned, token: token, voice: voice, language: language, rate: rate)
        }
    }

    /// 整段一次合成（云端）：只有一个请求，读完就是读完，句间韵律不被请求边界切断。
    private func speakWhole(
        _ text: String,
        token: UUID,
        voice: SpeechVoiceSelection,
        language: String,
        rate: Float
    ) async {
        let task = prefetchTask(text, voice: voice, language: language)
        inflight = task
        let wav: Data
        do {
            wav = try await task.value
        } catch {
            if speakToken == token { lastError = Self.describe(error) }
            return
        }
        guard speakToken == token else { return }
        inflight = nil
        setPhase(.speaking, speakingSource)
        do {
            try await playback.playAndWait(wavData: wav, rate: rate)
        } catch {
            if speakToken == token { lastError = Self.describe(error) }
        }
    }

    /// 分句流水线（本地）：首句立即开合成，播放期间预取下一句。
    private func speakSegmented(
        _ text: String,
        token: UUID,
        voice: SpeechVoiceSelection,
        language: String,
        rate: Float
    ) async {
        let sentences = SentenceSplitter.split(text)
        guard !sentences.isEmpty else { return }

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

            setPhase(.speaking, speakingSource)
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

    // MARK: - 回放自己的录音（跟读：听示范 → 跟读 → 听我的）

    /// 手上是否有可回放的录音。
    public var hasRecording: Bool { !lastRecording.isEmpty }

    /// 最近一次录音的采样率（发音评测要把采样数换算成秒）。
    public var recordingSampleRate: Double { MicrophoneRecorder.sampleRate }

    /// 回放最近一次录音。空录音时抛 `notInitialized`（由调用方转成可读文案）。
    public func replayLastRecording(rate: Float = 1.0) async throws {
        guard !lastRecording.isEmpty else { throw AIProviderError.notInitialized }
        playback.stop()
        let wav = WhisperASRAdapter.wavData(
            samples: lastRecording,
            sampleRate: Int(MicrophoneRecorder.sampleRate)
        )
        try await playback.playAndWait(wavData: wav, rate: rate)
    }

    /// 立刻停止一切播放（示范 / 回放共用）。
    public func stopPlayback() {
        playback.stop()
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

    /// 当前朗读投递方式（云端整段 / 本地分句），设置页展示用。
    public func deliveryMode() async -> SpeechDelivery {
        await tts.delivery
    }

    // MARK: - 内部

    private func setPhase(_ next: SpeechPhase, _ text: String?) {
        phase = next
        onPhaseChange?(next, text)
    }

    /// 后台合成一句（命中缓存则瞬时返回）。
    private func prefetchTask(_ sentence: String, voice: SpeechVoiceSelection, language: String) -> Task<Data, Error> {
        Task { [weak self] in
            guard let self else { throw AIProviderError.notInitialized }
            return try await self.synthesizeCached(sentence, voice: voice, language: language)
        }
    }

    /// ⚠️ internal 而非 private：并发合流的行为（同一句只发一次请求）要能直接单测 ——
    /// 走公开的 `speak` 会牵到真实播放设备，测不了（见 `ConcurrencyAndResourceTests`）。
    func synthesizeCached(_ text: String, voice: SpeechVoiceSelection, language: String) async throws -> Data {
        // 缓存键必须带上参考音频：换了克隆音色（或换了参考音频）就是另一个声音，
        // 沿用旧键会让「刚换的音色」听起来毫无变化，且怎么查都查不出原因。
        let key = "\(voice.voice)|\(voice.referenceAudioPath ?? "")|\(language)|\(text)"
        if let hit = audioCache[key] { return hit }
        // 同键已经在合成 → 直接等它那一趟，不再发一次请求（#S3-7）。
        if let running = synthInflight[key] { return try await running.value }

        let task = Task<Data, Error> { [weak self] in
            guard let self else { throw AIProviderError.notInitialized }
            let result = try await self.tts.synthesize(
                TTSRequest(text: text, voice: voice, language: language)
            )
            return Self.wavData(for: result)
        }
        synthInflight[key] = task
        // 不论成功还是抛错都要把在途登记撤掉，否则这个键永远合流到一个已结束的任务上。
        defer { synthInflight[key] = nil }

        let wav = try await task.value
        remember(key: key, wav: wav)
        return wav
    }

    /// 记进 FIFO 缓存（**同一个键只占一格**）。
    ///
    /// ⚠️ 先查重再淘汰：合流的后来者也会走到这里，此时的键已经在队里 ——
    /// 不查重就会「新键没加、老键被删」两头错位，淘汰时把谁都算错。
    private func remember(key: String, wav: Data) {
        if let existing = cacheOrder.firstIndex(of: key) {
            cacheOrder.remove(at: existing)
        } else if audioCache.count >= cacheLimit, let oldest = cacheOrder.first {
            audioCache[oldest] = nil
            cacheOrder.removeFirst()
        }
        audioCache[key] = wav
        cacheOrder.append(key)
    }

    /// 去掉不适合朗读的标记（`[[FIX]]` 块、markdown 等），保留自然语句。
    ///
    /// - Parameter limit: 截断上限。默认是**本地分句**的上限（400 字符，控制用户等待）；
    ///   云端整段合成时由调用方传入更宽松的上限（见 `SpeechDelivery.maxCharacters`）。
    public nonisolated static func cleanForSpeech(
        _ text: String,
        limit: Int = SpeechDelivery.segmented.maxCharacters
    ) -> String {
        var lines: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            // 纠错行不进朗读：它本来就是写给应用看的（识别口径与解析那边共用一份）。
            if GrammarCorrectionLine.isTagged(line) { continue }
            lines.append(line)
        }
        let joined = lines.joined(separator: " ")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "#", with: "")
        // emoji / 装饰符号在**朗读这一侧**去掉：合成器会把它们念成奇怪的词或吐碎音，
        // 而它们在文字气泡里是有意义的（语气、表情），所以正文一个字不动、只清洗送去合成的文本。
        // （这也是本方法的唯一收口点：本地分句与云端整段都从这里拿文本。）
        let speakable = SpeechTextSanitizer.strip(joined)
        let trimmed = speakable.trimmingCharacters(in: .whitespacesAndNewlines)
        // 上限由调用方给：本地 400（合成总时长与文本长度成正比，实测 RTF≈2.7，
        // 放宽只会让用户等更久）；云端 2000（响应快，长段落也读得完、读得连贯）。
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit))
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
