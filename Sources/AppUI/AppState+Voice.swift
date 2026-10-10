import AIDomain
import AIInterfaces
import AIServices
import AppCore
import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - AppState · 语音（ASR/TTS）+ 克隆音色
// #267 自 AppState.swift 拆出（2026-09-20）：单文件 5136 行超载，按域切为扩展。
// 同模块 extension，语义与拆分前完全一致；成员访问级别已放宽到 internal。
extension AppState {
    // MARK: - 语音（第 17/18 步）

    /// 装配语音能力。**不阻断启动**：runtime 不在线时仅展示状态。
    public func bootstrapVoice() async {
        // 朗读相位回到主线程驱动 UI（分句流水线的「准备中/朗读中」提示）
        await services.voice.setPhaseHandler { [weak self] phase, text in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.speechPhase = phase
                self.speakingText = phase == .idle ? nil : text
            }
        }
        // 流式识别：录音期间不断把「当前听到的整句」送回主线程，UI 实时写进输入框。
        await services.voice.setPartialHandler { [weak self] text in
            Task { @MainActor [weak self] in
                self?.voiceTranscript = text
            }
        }
        let health = await services.bootstrapVoice()
        asrHealth = health.asr
        ttsHealth = health.tts
        let voices = await services.availableVoices()
        if !voices.isEmpty {
            availableVoices = voices
            await normalizeVoice(voices)
        }
        ttsRuntimeInfo = await services.voice.ttsRuntimeDescription()
        // 朗读投递方式随 Provider 变化：云端整段、本地分句（设置页会说明当前用的是哪种）。
        speechDelivery = await services.voice.deliveryMode()
        await refreshVoiceProfiles()
    }

    /// 把配置里的音色对齐到 runtime 自报列表（大小写不敏感），避免选择器空选。
    func normalizeVoice(_ voices: [String]) async {
        guard !voices.isEmpty else { return }
        if let matched = voices.first(where: { $0.caseInsensitiveCompare(product.teacherVoice) == .orderedSame }) {
            if matched != product.teacherVoice {
                product.teacherVoice = matched
                await persistProduct()
            }
        } else if product.teacherVoice.isEmpty {
            product.teacherVoice = voices[0]
            await persistProduct()
        }
    }

    /// 点击麦克风：开始录音（录音期间流式把识别结果送到 `voiceTranscript`）。
    public func startVoiceInput() async {
        // ⚠️ 识别中**不接受**新一段：上一段的结果还在路上（本地 whisper 可能要几十秒），
        // 这时重开麦克风会让两次识别在串行的语音服务上排队，新一段迟迟没有中间结果
        // ——用户看到的就是「说完一句话，一个字都不出」。等上一次结束或点取消。
        guard voicePhase == .idle else { return }
        // 语音识别模型不在运行 → 资源管理挂起的自动恢复；用户关闭的才提示怎么打开。
        // ⚠️ 状态一律问**服务层真源**（`services.isModelRunning`），绝不用 `isModelRunning`
        // 那份界面快照：巡检挂起后它不会立刻刷新，会让这里误判「还在跑」而跳过自动恢复，
        // 请求打到已停的 whisper 上（2026-09-19 连接失败的根因）。
        // `resumeIfSuspended` 对「没被挂起」是廉价空操作；用户显式关闭的不会被自动拉起。
        _ = (try? await services.resumeIfSuspended(.asr)) ?? false
        await syncModelRunStates()
        guard await services.isModelRunning(.asr) else {
            voiceError = "\(await services.modelLabel(for: .asr)) 已关闭，请在设置里点绿色的「启动」后再用语音输入。"
            return
        }
        voiceError = nil
        isSpeaking = false
        voiceTranscript = nil
        await services.voice.stopSpeaking()
        await services.voice.setPartialLanguage(learningLanguageName)
        // 本段语音的令牌：取消 / 重开都会换掉它，让在途识别自己作废。
        voiceInputToken = UUID()
        await services.voice.startRecording()
        // 起不来（没权限 / 麦克风被别的进程占着）→ 留在空闲态，
        // 不能乐观地先置成 `recording`：那会让「取消录音」对着一个没开的麦。
        guard await services.voice.isRecording else {
            voicePhase = .idle
            if let error = await services.voice.lastError { voiceError = error }
            return
        }
        voicePhase = .recording
    }

    /// 再次点击：停止录音 → 识别 → 纠正拼写 → 填入输入框（由调用方接收文本）。
    ///
    /// **拼写纠正只在这里发生**：手打的文字一个都不改。
    public func finishVoiceInput() async -> String? {
        // 只有「正在录音」才谈得上停止并识别。识别中再点一次不该重入：
        // 第二次 `stopRecordingAndTranscribe` 拿到的是空音频，会报出假的
        // 「没有录到声音」并把前一次的真实结果顶掉。
        guard voicePhase == .recording else { return nil }
        let token = voiceInputToken
        // ⚠️ 状态**先落**再 await：识别这段是本流程里最长的一段（本地 whisper 数秒到数十秒），
        // 界面必须立刻进入「识别中」——这既是对用户的交代，也是让主按钮知道自己该变成
        // 「作废这次识别」而不是「再录一段」的唯一依据。
        voicePhase = .transcribing
        voiceTranscript = nil
        let recognized = await services.voice.stopRecordingAndTranscribe(language: learningLanguageName)
        voiceError = await services.voice.lastError
        // 这期间用户点了取消（或重开了一段）→ 这次结果已经没有归属，丢弃：
        // 不写输入框、不改状态。用户按下取消时看到的内容必须原样留着。
        guard token == voiceInputToken else { return nil }
        guard let recognized, !recognized.isEmpty else {
            voicePhase = .idle
            return nil
        }
        let corrected = await services.correctSpelling(recognized)
        // 拼写纠正也是一次服务调用，同样可能被取消追上。
        guard token == voiceInputToken else { return nil }
        voicePhase = .idle
        return corrected.isEmpty ? recognized : corrected
    }

    /// 取消这一整段语音：不识别、不填进输入框。
    ///
    /// **录音中与识别中都能取消**。识别已经开始时无法中途掐断（请求在服务端跑着），
    /// 但可以**换令牌**让结果回来时发现自己已过期 —— 用户按下取消就应该立刻看到
    /// 界面回到空闲、输入框保持他改过的样子，而不是几秒后被识别结果覆盖一遍。
    public func cancelVoiceInput() async {
        guard voicePhase != .idle else { return }
        voiceInputToken = UUID()
        await services.voice.cancelRecording()
        voiceTranscript = nil
        voicePhase = .idle
    }

    /// 关闭对话区的语音错误提示。
    public func clearVoiceError() {
        voiceError = nil
    }

    /// 朗读教师回复（按设置里的语速播放）。分句流水线：首句先出声。
    ///
    /// 注意：曾经尝试「发消息时并行预热 TTS」，实测**有害**——LLM 与 TTS 共用 MPS，
    /// 预热在 LLM 生成期间会被挤到显存外，实测单次预热耗时可达 185s，还反过来拖慢回复。
    /// 因此朗读只依赖分句流水线 + 服务端自身的启动预热。
    public func speak(_ text: String) async {
        // 教师语音模型不在运行 → 资源管理挂起的自动恢复；用户关闭的才明确提示。
        // ⚠️ 同 ASR：判断用服务层真源，不用会过期的界面快照（见 `isModelRunning` 的说明）。
        _ = (try? await services.resumeIfSuspended(.tts)) ?? false
        await syncModelRunStates()
        guard await services.isModelRunning(.tts) else {
            voiceError = "\(await services.modelLabel(for: .tts)) 已关闭，请在设置里点绿色的「启动」后再朗读。"
            return
        }
        isSpeaking = true
        // S4-12：世代令牌。连点两条「听老师读」时，前一条的收尾代码可能在后一条
        // 已经开始之后才跑完 —— 它会把**过期快照**（phase / lastError）写回界面。
        // 底层 `VoiceService.speak` 令牌化解决的是「声音」；这里解决「界面」。
        let token = UUID()
        speakRequestToken = token
        // 音色取值统一走 `effectiveSpeechVoiceSelection()`：启用克隆音色时它带档案 id **和参考音频**，
        // 否则是内置音色名。UI 不自己判断该用哪个 —— 那会让两处口径漂移。
        // 调门与语气同理收在 `currentSpeechPlayback()`，六个朗读入口取同一份。
        let playback = await currentSpeechPlayback()
        await services.voice.speak(
            text,
            voice: await services.effectiveSpeechVoiceSelection(),
            language: learningLanguageName,
            rate: Float(product.speechRate),
            pitch: playback.pitch,
            tone: playback.tone
        )
        // 令牌已换 → 这次朗读已被后一次作废，**一个字都不许回写**。
        guard speakRequestToken == token else { return }
        isSpeaking = await services.voice.isSpeaking
        speechPhase = await services.voice.phase
        voiceError = await services.voice.lastError
    }

    public func stopSpeaking() async {
        await services.voice.stopSpeaking()
        // 作废收尾回写：在途的那一次朗读随后跑完时别再把状态写回来。
        speakRequestToken = nil
        isSpeaking = false
        speechPhase = .idle
        speakingText = nil
    }

    /// 设置页：切换自动朗读。
    public func setAutoSpeak(_ enabled: Bool) async {
        autoSpeak = enabled
        if !enabled { await stopSpeaking() }
    }

    /// 音色切换时自动试听一句短示例（受设置开关控制）。
    public func setVoice(_ voice: String) async {
        // 选内置音色 = 停用克隆音色。否则 `effectiveSpeechVoice()` 仍会返回克隆档案 id，
        // 用户看到的表现是「换了个音色，老师却还用克隆的声音说话」。
        if product.activeVoiceProfileID != nil {
            try? await services.deactivateClonedVoice()
            await reloadProduct()
            await refreshVoiceProfiles()
        }
        product.teacherVoice = voice
        await persistProduct()
        if product.voicePreview {
            // 试听也带上当前的调门与语气：否则用户刚调完调门点试听，听到的还是老调子，
            // 会以为「设置没生效」而反复再调一次。
            let playback = await currentSpeechPlayback()
            await services.voice.speak(
                "Nice to meet you!",
                voice: voice,
                language: learningLanguageName,
                rate: Float(product.speechRate),
                pitch: playback.pitch,
                tone: playback.tone
            )
            voiceError = await services.voice.lastError
        }
    }

    // MARK: - 克隆音色（第 24 步）

    /// 刷新音色档案，以及当前供应商的语音能力（克隆 / 风格 / 情感）与语气候选值。
    ///
    /// 三类一次取齐：设置页的能力徽标读 `voiceCapabilities`、语气选择器读 `speechToneOptions`。
    /// 分两次取会出现「徽标写着支持风格、选择器却是空的」这种自相矛盾的画面。
    public func refreshVoiceProfiles() async {
        voiceProfiles = await services.voiceProfiles()
        let capabilities = await services.ttsVoiceCapabilities()
        voiceCapabilities = capabilities
        voiceCloningSupported = capabilities.voiceCloning
        var options: [VoiceCapability: [String]] = [:]
        for capability in [VoiceCapability.style, .emotion] {
            let values = await services.ttsSpeechToneOptions(for: capability)
            if !values.isEmpty { options[capability] = values }
        }
        speechToneOptions = options
    }

    /// 本次朗读的播放参数：调门（播放侧变调）与语气（合成侧透传）。
    ///
    /// 收成一处的理由：它们是两条**不同链路**上的设置，而所有朗读入口（对话区、试听、
    /// 跟读 / 段落 / 听力示范…）都得同时带上 —— 各取各的必然出现
    /// 「对话区生效、跟读示范没生效」这类一半生效。语气还要先过供应商能力
    /// （`CoachServices.effectiveSpeechTone` 里判），这一步同样不该让每个调用点自己判。
    func currentSpeechPlayback() async -> (pitch: SpeechPitch, tone: SpeechTone) {
        (SpeechPitch.nearest(to: product.speechPitch), await services.effectiveSpeechTone())
    }

    /// 新建一份克隆音色档案：把选中的本地参考音频**复制**进应用目录，并记下授权说明。
    ///
    /// 只存不启用 —— 启用要单独走 `activateClonedVoice`（那里做合规校验）。
    /// 这样「先填好、以后再开」不会被合规闸门拦住，而「真的要用」时一道都少不了。
    @discardableResult
    public func createClonedVoice(
        name: String,
        referenceURL: URL,
        consentStatement: String,
        referenceText: String? = nil
    ) async -> VoiceProfile? {
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let statement = consentStatement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else {
            voiceProfileNotice = "请先给这个音色起个名字。"
            return nil
        }
        guard !statement.isEmpty else {
            voiceProfileNotice = VoiceAccessPolicy.Violation.emptyConsent.userMessage
            return nil
        }
        do {
            let path = try await services.importVoiceReference(from: referenceURL)
            let profile = VoiceProfile(
                id: "cloned." + UUID().uuidString.prefix(8).lowercased(),
                displayName: displayName,
                kind: .cloned,
                referenceAudioPath: path,
                referenceText: referenceText?.trimmingCharacters(in: .whitespacesAndNewlines),
                consent: VoiceConsent(statement: statement)
            )
            try await services.saveVoiceProfile(profile)
            await refreshVoiceProfiles()
            voiceProfileNotice = "已保存音色「\(profile.displayName)」，启用后老师就用它说话。"
            return profile
        } catch {
            // **原样透出，不再拼「保存音色失败：」**。这条路的两处失败都自带动作了：
            // `importVoiceReference` 说「没能把这个音频文件读进来（x.wav）：…」，
            // `VoiceProfileStore.save` 说「保存音色档案失败：…」。补一句更笼统的动作名
            // 只会得到「保存音色失败：保存音色档案失败：…」。
            voiceProfileNotice = error.localizedDescription
            return nil
        }
    }

    /// 启用克隆音色。违规时给出**可读原因**（缺授权 / 参考音频不是本地文件 / 供应商不支持），
    /// 不静默失败，也不「先启用再说」。
    public func activateClonedVoice(id: String) async {
        busyVoiceProfileID = id
        defer { busyVoiceProfileID = nil }
        do {
            try await services.activateVoiceProfile(id: id)
            await reloadProduct()
            await refreshVoiceProfiles()
            voiceProfileNotice = activeVoiceIndicator
        } catch {
            voiceProfileNotice = error.localizedDescription
        }
    }

    /// 停用克隆音色，回到内置音色。
    public func deactivateClonedVoice() async {
        do {
            try await services.deactivateClonedVoice()
            await reloadProduct()
            await refreshVoiceProfiles()
            voiceProfileNotice = "已切回内置音色「\(product.teacherVoice)」。"
        } catch {
            voiceProfileNotice = error.localizedDescription
        }
    }

    /// 删除音色档案（若正被使用会一并停用）。
    public func deleteClonedVoice(id: String) async {
        do {
            try await services.deleteVoiceProfile(id: id)
            await reloadProduct()
            await refreshVoiceProfiles()
            voiceProfileNotice = "已删除这个音色档案。"
        } catch {
            voiceProfileNotice = error.localizedDescription
        }
    }

    public func clearVoiceProfileNotice() { voiceProfileNotice = nil }

}
