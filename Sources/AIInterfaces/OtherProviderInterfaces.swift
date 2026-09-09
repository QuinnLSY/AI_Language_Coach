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

public struct ASRResult: Sendable, Equatable {
    public var text: String
    public var language: String?
    public var confidence: Float?

    public init(text: String, language: String? = nil, confidence: Float? = nil) {
        self.text = text
        self.language = language
        self.confidence = confidence
    }
}

public protocol ASRProvider: AIProvider {
    func transcribe(_ request: ASRRequest) async throws -> ASRResult
}

// MARK: - TTS

public struct TTSRequest: Sendable {
    public var text: String
    public var voice: String?
    public var language: String?

    public init(text: String, voice: String? = nil, language: String? = nil) {
        self.text = text
        self.voice = voice
        self.language = language
    }
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
    public var overall: Double
    public var phonemes: [PhonemeScore]

    public init(overall: Double, phonemes: [PhonemeScore] = []) {
        self.overall = overall
        self.phonemes = phonemes
    }
}

public protocol PronunciationProvider: AIProvider {
    func evaluate(audioSamples: [Float], referenceText: String) async throws -> PronunciationScore
}
