import AIDomain
import AIInfrastructure
import AIInterfaces
import AppCore
import Foundation

/// 跟读（Shadowing）编排服务（第 22 步）。
///
/// 链路：参考句 → **听示范**（复用朗读的分句流水线）→ 学员**跟读**（录音）
///      → **原始** ASR 结果 → 逐词对齐 → 反馈 → 落库。
///
/// 两条硬规则：
/// 1. **识别结果不做拼写纠正**。纠正会把「学员实际说的」改写成「他大概想说的」，
///    正好抹掉跟读要评的东西（漏词、换词）。这里一律用 ASR 原始输出。
/// 2. UI 不碰麦克风 / 播放器 / ASR：一切经由本服务。
public actor ShadowingService {

    private let voice: VoiceService
    private let pronunciation: PronunciationService
    private let learning: LearningDatabase?
    /// 素材在进程内只读一次（资源文件，永不变化）。
    private var drillCache: [ShadowingDrill]?
    /// 刚结束的这次跟读录音。在 `finishRecording` 时截存，
    /// 避免 `evaluate` 时读到学员在对话区留下的旧录音。
    private var pendingSamples: [Float] = []

    public init(
        voice: VoiceService,
        pronunciation: PronunciationService = PronunciationService(),
        learning: LearningDatabase?
    ) {
        self.voice = voice
        self.pronunciation = pronunciation
        self.learning = learning
    }

    // MARK: - 素材

    /// 内置跟读素材（按难度升序）。资源缺失时返回空数组，由 UI 给出可操作提示。
    public func drills() -> [ShadowingDrill] {
        if let drillCache { return drillCache }
        let loaded = ShadowingCatalog.bundled()
        drillCache = loaded
        return loaded
    }

    public func drill(id: String) -> ShadowingDrill? {
        drills().first { $0.id == id }
    }

    // MARK: - 听示范 / 跟读 / 回放

    /// 听示范：复用朗读链路（分句流水线 + 变速），与对话区听到的是同一个老师声音。
    public func playReference(
        _ drill: ShadowingDrill,
        voiceName: String,
        language: String,
        rate: Float
    ) async {
        await voice.speak(drill.text, voice: voiceName, language: language, rate: rate)
    }

    /// 开始跟读录音（录音期间 VoiceService 会流式把识别结果推给 UI）。
    public func startRecording(language: String?) async {
        await voice.setPartialLanguage(language)
        await voice.startRecording()
    }

    /// 结束录音并返回**原始**识别文本（nil = 没听清 / 出错，原因见 `lastError()`）。
    ///
    /// 成功时把这次录音截存下来 —— 发音评测（第 23 步）要用原始音频量语速、停顿、
    /// 音高，识别文本替代不了这些。
    public func finishRecording(language: String?) async -> String? {
        let text = await voice.stopRecordingAndTranscribe(language: language)
        pendingSamples = text != nil ? await voice.lastRecording : []
        return text
    }

    public func cancelRecording() async {
        await voice.cancelRecording()
        pendingSamples = []
    }

    /// 听我的：回放刚才录的音。
    public func replayRecording(rate: Float) async throws {
        try await voice.replayLastRecording(rate: rate)
    }

    /// 停掉一切声音（示范 / 回放）。
    public func stopAudio() async {
        await voice.stopSpeaking()
        await voice.stopPlayback()
    }

    public var hasRecording: Bool {
        get async { await voice.hasRecording }
    }

    public func lastError() async -> String? {
        await voice.lastError
    }

    // MARK: - 评测与记录

    /// 评测一次跟读并落库：文本对齐（`AIDomain.ShadowingScorer`）+
    /// 发音评测（`AIDomain.PronunciationScorer`，有录音才算）。本服务只负责编排。
    public func evaluate(drill: ShadowingDrill, recognized: String) async -> ShadowingResult {
        let comparison = ShadowingScorer.compare(reference: drill.text, recognized: recognized)

        // 发音评测需要原始音频；纯文本场景（预览钩子 / 没录上音）报告为 nil，不硬编。
        var report: PronunciationReport?
        if !pendingSamples.isEmpty {
            report = await pronunciation.report(
                reference: drill.text,
                recognized: recognized,
                samples: pendingSamples,
                sampleRate: await voice.recordingSampleRate,
                comparison: comparison
            )
        }
        pendingSamples = []

        if let learning {
            let attempt = ShadowingAttempt(
                drillID: drill.id,
                referenceText: drill.text,
                recognizedText: recognized,
                accuracy: comparison.accuracy,
                pronunciation: report
            )
            try? await learning.appendShadowingAttempt(attempt)
        }
        return ShadowingResult(comparison: comparison, pronunciation: report)
    }

    /// 最近的跟读记录（新 → 旧）。
    public func recentAttempts(limit: Int = 50) async -> [ShadowingAttempt] {
        guard let learning else { return [] }
        return (try? await learning.recentShadowingAttempts(limit: limit)) ?? []
    }

    /// 跟读汇总（次数 / 最佳 / 平均 / 最近一次）。
    public func stats(limit: Int = 100) async -> ShadowingStats {
        ShadowingStats.from(await recentAttempts(limit: limit))
    }
}
