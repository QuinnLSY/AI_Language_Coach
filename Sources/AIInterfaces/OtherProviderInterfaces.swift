import Foundation

// MARK: - ASR

public struct ASRRequest: Sendable {
    public var audioSamples: [Float]
    public var language: String?

    public init(audioSamples: [Float], language: String? = nil) {
        self.audioSamples = audioSamples
        self.language = language
    }
}

/// 一个词的时间戳（秒）。
///
/// ⚠️ `start` / `end` 的含义取决于 runtime：有的给的是**词级对齐**结果，
/// 有的只是把段级区间按字符均摊出来的估计值。调用方**不得**把它当成精确对齐去打分
/// （发音评测目前只用文本对齐，不看这些数字）。
public struct ASRWord: Sendable, Equatable {
    public var word: String
    /// 起始秒（相对音频开头）。
    public var start: Double
    /// 结束秒。
    public var end: Double
    /// runtime 自报的置信度（0...1）；不给就是 nil。
    public var confidence: Float?

    public init(word: String, start: Double, end: Double, confidence: Float? = nil) {
        self.word = word
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

/// 一个语音段的时间戳（秒）。
public struct ASRSegment: Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    /// 词级时间戳；runtime 没给就是空数组（不是 nil —— 空数组表示「这次确实没有」）。
    public var words: [ASRWord]

    public init(text: String, start: Double, end: Double, words: [ASRWord] = []) {
        self.text = text
        self.start = start
        self.end = end
        self.words = words
    }
}

public struct ASRResult: Sendable, Equatable {
    public var text: String
    public var language: String?
    public var confidence: Float?
    /// 段时间戳；**runtime 没提供就是 nil**（不是空数组）。
    ///
    /// 为什么是可选：不同 ASR 后端能力不同，把「没有时间戳」表达成 nil，
    /// 调用方就不会把空数组误读成「转写结果为空」。这是加法式扩展 —— 上层不读它也不受影响。
    public var segments: [ASRSegment]?

    public init(
        text: String,
        language: String? = nil,
        confidence: Float? = nil,
        segments: [ASRSegment]? = nil
    ) {
        self.text = text
        self.language = language
        self.confidence = confidence
        self.segments = segments
    }

    /// 摊平后的词级时间戳；没有就 nil。
    public var words: [ASRWord]? {
        guard let segments else { return nil }
        let flat = segments.flatMap(\.words)
        return flat.isEmpty ? nil : flat
    }
}

public protocol ASRProvider: AIProvider {
    func transcribe(_ request: ASRRequest) async throws -> ASRResult
}

// MARK: - TTS

/// 「这次合成是不是在用克隆音色」的**唯一定义**。
///
/// 曾经有两处各写一遍：`SpeechVoiceSelection.isCloned` 与 `TTSRequest.usesClonedVoice`。
/// 判定口径看起来都在问「有没有参考音频」，但一处查 `referenceAudioPath` 是否为空串、
/// 另一处若跟着改就容易只判 nil —— 于是「启用克隆音色」的开关在选音色一侧算生效、
/// 在请求一侧不算，症状是「设置里明明开着，读出来还是内置音色」。
///
/// 所以把口径收成一处纯函数：**非 nil 且去空白后非空**才算克隆。
public enum ClonedVoiceRule {
    public static func isCloned(referenceAudioPath: String?) -> Bool {
        guard let path = referenceAudioPath else { return false }
        return !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 朗读要用哪个声音（第 24 步）。
///
/// 它把「用内置音色」与「用克隆音色」收成**同一个入参**，调用方（UI / 服务）不必各写一条分支，
/// 也不会出现「克隆音色启用了，但朗读链路还在用内置音色名」这种两处口径漂移。
///
/// 克隆音色之所以必须带上 `referenceAudioPath`：克隆runtime 需要参考音频才能复现音色。
/// 只给一个本地生成的 id，任何 runtime 都无法还原出那是谁的声音 —— 那样「启用克隆」
/// 就只是个看起来生效的开关。
public struct SpeechVoiceSelection: Sendable, Equatable {
    /// 传给 runtime 的音色标识（内置音色名，或克隆音色档案 id）。
    public var voice: String
    /// 参考音频的**本地路径**。非克隆音色为 nil。
    public var referenceAudioPath: String?
    /// 参考音频对应的文本（部分克隆模型需要）。nil = runtime 自行转录。
    public var referenceText: String?

    public init(voice: String, referenceAudioPath: String? = nil, referenceText: String? = nil) {
        self.voice = voice
        self.referenceAudioPath = referenceAudioPath
        self.referenceText = referenceText
    }

    /// 内置音色（随模型发布，无需参考音频）。
    public static func builtin(_ voice: String) -> SpeechVoiceSelection {
        SpeechVoiceSelection(voice: voice)
    }

    public var isCloned: Bool {
        ClonedVoiceRule.isCloned(referenceAudioPath: referenceAudioPath)
    }
}

public struct TTSRequest: Sendable {
    public var text: String
    public var voice: String?
    public var language: String?
    /// 参考音频本地路径（音色克隆）。非克隆请求为 nil。
    public var referenceAudioPath: String?
    /// 参考音频对应的文本（可选）。
    public var referenceText: String?

    public init(
        text: String,
        voice: String? = nil,
        language: String? = nil,
        referenceAudioPath: String? = nil,
        referenceText: String? = nil
    ) {
        self.text = text
        self.voice = voice
        self.language = language
        self.referenceAudioPath = referenceAudioPath
        self.referenceText = referenceText
    }

    public init(text: String, voice: SpeechVoiceSelection, language: String? = nil) {
        self.init(
            text: text,
            voice: voice.voice,
            language: language,
            referenceAudioPath: voice.referenceAudioPath,
            referenceText: voice.referenceText
        )
    }

    /// 是否要用克隆音色合成（判定口径与 `SpeechVoiceSelection.isCloned` 同源）。
    public var usesClonedVoice: Bool { ClonedVoiceRule.isCloned(referenceAudioPath: referenceAudioPath) }
}

public struct TTSResult: Sendable {
    public var audioSamples: [Float]
    public var sampleRate: Int
    /// runtime 原始音频（如 WAV）。有则直接播放，避免解码后再封装的往返。
    public var audioData: Data?

    public init(audioSamples: [Float], sampleRate: Int, audioData: Data? = nil) {
        self.audioSamples = audioSamples
        self.sampleRate = sampleRate
        self.audioData = audioData
    }
}

public protocol TTSProvider: AIProvider {
    func synthesize(_ request: TTSRequest) async throws -> TTSResult
}

/// 可选能力：runtime 能自报可用音色（不是所有 TTS 都有）。
public protocol VoiceCatalogProvider: Sendable {
    func availableVoices() async -> [String]
}

/// 可选能力：runtime 能自报一句可读的运行信息（如「Qwen3-TTS · mps」）。
public protocol RuntimeInfoProvider: Sendable {
    func runtimeDescription() async -> String?
}

// MARK: - VAD

public struct VADSegment: Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }
}

public protocol VADProvider: AIProvider {
    func detectSpeech(in samples: [Float]) async throws -> [VADSegment]
}

// MARK: - Embedding

public protocol EmbeddingProvider: AIProvider {
    var dimensions: Int { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
    /// 列出 runtime 实际可用的嵌入模型（与 `LLMProvider.discoverModels` 同构）。
    ///
    /// 本地 Ollama 走 `/v1/models` + `/api/tags` 过滤出 embedding-only 的模型；
    /// 云端走 OpenAI 兼容 `/models` 并按能力归类；mock 直接回候选清单。
    /// 没有发现能力的实现返回空数组——交给上层用候选清单兜底。
    func discoverModels() async throws -> [DiscoveredModel]
}

// MARK: - Pronunciation

public struct PhonemeScore: Sendable, Equatable {
    public var phoneme: String
    public var score: Double

    public init(phoneme: String, score: Double) {
        self.phoneme = phoneme
        self.score = score
    }
}

public struct PronunciationScore: Sendable, Equatable {
    /// 逐词音素（有发音模型时才有：界面上那条 `world → w ✓ ɜː ✓ r △` 需要它）。
    public struct WordPhonemes: Sendable, Equatable {
        public var word: String
        public var phonemes: [PhonemeScore]

        public init(word: String, phonemes: [PhonemeScore] = []) {
            self.word = word
            self.phonemes = phonemes
        }
    }

    public var overall: Double
    /// 扁平音素序列（「音准」维度的口径）。
    public var phonemes: [PhonemeScore]
    /// 逐词音素明细（可为空：老实现只给扁平序列）。
    public var words: [WordPhonemes]

    public init(
        overall: Double,
        phonemes: [PhonemeScore] = [],
        words: [WordPhonemes] = []
    ) {
        self.overall = overall
        self.phonemes = phonemes
        self.words = words
    }
}

public protocol PronunciationProvider: AIProvider {
    func evaluate(audioSamples: [Float], referenceText: String) async throws -> PronunciationScore
}
