import AIDomain
import AIInfrastructure
import AIInterfaces
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

    /// 录音时传给 ASR 的语言标签。跟读页与词汇复习卡的「读一遍」共用同一个 ——
    /// 两处各写一份，日后改一处必漏另一处（而漏的那处只表现为「识别莫名其妙变差」）。
    ///
    /// 值由 `LearningLanguage` 派生（当前仍是 `English`）：这里不再自己写一份语言名，
    /// 只在语言表变的时候跟着变。
    public static let practiceLanguage = LearningLanguage.english.serviceName

    private let voice: VoiceService
    private let pronunciation: PronunciationService
    private let learning: LearningDatabase?
    /// 落库失败记账（CoachServices 注入共享实例）。
    private let failures: PersistenceFailureRecorder
    /// 素材在进程内只读一次（资源文件，永不变化）。
    private var drillCache: [ShadowingDrill]?
    /// 刚结束的这次跟读录音。在 `finishRecording` 时截存，
    /// 避免 `evaluate` 时读到学员在对话区留下的旧录音。
    private var pendingSamples: [Float] = []

    public init(
        voice: VoiceService,
        pronunciation: PronunciationService = PronunciationService(),
        learning: LearningDatabase?,
        failures: PersistenceFailureRecorder
    ) {
        self.voice = voice
        self.pronunciation = pronunciation
        self.learning = learning
        self.failures = failures
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
    ///
    /// 收 `SpeechVoiceSelection` 而不是音色名：启用了克隆音色时，示范也必须用同一个声音
    /// （只换对话区的音色、跟读示范仍是内置音色，是最容易被忽略的「一半生效」）。
    ///
    /// 入参叫 `selection` 而不是 `voice`：本类型的 `voice` 是 VoiceService 属性，
    /// 再挂一个同名参数会让 `voice.speak` 到底指谁都看不出来。
    public func playReference(
        _ drill: ShadowingDrill,
        selection: SpeechVoiceSelection,
        language: String,
        rate: Float
    ) async {
        await voice.speak(drill.text, voice: selection, language: language, rate: rate)
    }

    /// 听整段示范：把段落连成一段交给朗读流水线（分句 / 变速都在里面处理）。
    ///
    /// 不逐句拼着播：逐句播会在句间插一次合成边界，学员听到的是「四句各自读一遍」，
    /// 而段落模式要练的恰恰是**句与句之间的连贯**。
    public func playPassage(
        _ passage: ShadowingPassage,
        selection: SpeechVoiceSelection,
        language: String,
        rate: Float
    ) async {
        await voice.speak(passage.text, voice: selection, language: language, rate: rate)
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
            do {
                try await learning.appendShadowingAttempt(attempt)
            } catch {
                await failures.record("保存这次跟读成绩", error)
            }
        }
        return ShadowingResult(comparison: comparison, pronunciation: report)
    }

    /// 评测一次**段落跟读**并落库：整段识别文本回填到每一句 → 逐句对齐 + 整段发音评测。
    ///
    /// 落库口径与一句一练**同一把尺**：每一句记一条 `ShadowingAttempt`，
    /// 否则「练了几次 / 平均匹配率」会把「一段」和「一句」混着算，统计立刻失真。
    ///
    /// ⚠️ 发音报告是**整段**量出来的，只挂在**第一句**那条记录上：
    /// 一段挂 N 条，统计里同一份发音分就被平均 N 遍。
    public func evaluatePassage(_ passage: ShadowingPassage, recognized: String) async -> ShadowingPassageEvaluation {
        let result = ShadowingPassageScorer.evaluate(passage: passage, recognized: recognized)

        var report: PronunciationReport?
        if !pendingSamples.isEmpty {
            report = await pronunciation.report(
                reference: passage.text,
                recognized: recognized,
                samples: pendingSamples,
                sampleRate: await voice.recordingSampleRate
            )
        }
        pendingSamples = []

        if let learning {
            for (index, drill) in passage.drills.enumerated() {
                let sentence = result.sentences.indices.contains(index) ? result.sentences[index] : nil
                let attempt = ShadowingAttempt(
                    drillID: drill.id,
                    referenceText: drill.text,
                    recognizedText: sentence?.recognizedText ?? "",
                    accuracy: sentence?.accuracy ?? 0,
                    pronunciation: index == 0 ? report : nil
                )
                // 段落里少一条，「练了几次 / 平均匹配率」就静默失真一段。
                do {
                    try await learning.appendShadowingAttempt(attempt)
                } catch {
                    await failures.record("保存这段跟读成绩", error)
                }
            }
        }
        return ShadowingPassageEvaluation(result: result, pronunciation: report)
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

    // MARK: - 单次开口读的评测（词汇复习的单词朗读复用这条链路）

    /// 评测一次「开口读」（参考文本任意 —— 词汇复习卡读的就是**单个词**）。
    ///
    /// 与跟读**共用**同一条链路：录音 → 原始 ASR → 音素双通道（声学实测 / 规则推断）。
    /// 唯一区别是**不落库**：词汇复习另有一套流水（`vocabulary_reviews`），
    /// 把单词评测塞进跟读记录里，会把跟读的平均分与历史一起带偏。
    ///
    /// 返回 nil 表示这次没拿到音频（没录上 / 纯文本调用）——
    /// 调用方据此**不给分数**，而不是拿一个 0 分冒充「读得很差」。
    public func evaluateSpeech(reference: String, recognized: String) async -> PronunciationReport? {
        guard !pendingSamples.isEmpty else { return nil }
        let report = await pronunciation.report(
            reference: reference,
            recognized: recognized,
            samples: pendingSamples,
            sampleRate: await voice.recordingSampleRate
        )
        pendingSamples = []
        return report
    }
}
