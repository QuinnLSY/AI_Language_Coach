import AIDomain
import AIInterfaces
import AIServices
import AppCore
import Foundation
import Observation
import SwiftUI

/// 一个能力（ASR/TTS/VAD/Embedding/Pronunciation）当前模型情况的 UI 快照。
public struct CapabilityModelInfo: Sendable, Equatable {
    public let kind: AIProviderKind
    public let healthOK: Bool
    public let healthText: String
    /// 当前选中的模型名（可能来自 runtime 自报或配置）。
    public let currentModel: String?
    /// 来源描述（如「本地 · /Users/…/ggml-small.en.bin」或「DeepSeek 提供的云端模型」）。
    public let sourceDescription: String
    /// ~/AI_Models 下自动检测到的本地模型。
    public let localModels: [LocalModel]
}

/// UI 唯一状态源。**只依赖 Application Services，不碰 Provider / HTTP / SQL。**
@MainActor
@Observable
public final class AppState {

    public let services: CoachServices
    public let chat: ChatService

    public var themeMode: ThemeMode = .day
    public var systemIsDark: Bool = false
    /// 侧边栏展开/收起（供主界面参与宽度分配）。
    public var isSidebarExpanded = true
    /// 真实进度：来自学习数据库；首次启动为种子关卡。
    public var progress: LearnerProgress = .seed()

    public private(set) var availableModels: [DiscoveredModel] = []
    public private(set) var health: ProviderHealth = .configurationInvalid(reason: "尚未初始化")
    public private(set) var isBooting = true
    public private(set) var bootMessage: String?
    public var modelDraft: String = ""
    public var showingSettings = false
    // MARK: 模型 Provider（本地 + 云端并存）
    /// 当前生效的 LLM Provider（决定实际调用本地还是云端）。
    public private(set) var activeProvider: ProviderConfig?
    /// 设置页当前选中的 Provider 标签（可编辑未生效的 Provider）。
    public var selectedProviderID: String = "ollama.llm"
    /// 云端 API Key 草稿（按 provider id 存，避免切换标签互相覆盖）。
    public var apiKeyDrafts: [String: String] = [:]
    /// 云端探测到的模型列表（按 provider id 缓存）。
    public private(set) var remoteModels: [String: [DiscoveredModel]] = [:]
    /// 云端推理强度草稿（low / medium / high；nil = 标准）。
    public var reasoningEffortDraft: String?
    public private(set) var isFetchingRemoteModels = false
    /// 云端配置操作结果（成功提示或错误）。
    public var remoteMessage: String?
    /// 上下文窗口（token），nil = 未知。
    public private(set) var contextLimit: Int?
    /// 生效模型的推理强度（low / medium / high；nil = 标准）。
    public private(set) var activeReasoningEffort: String?
    /// 今日全局 token 用量（侧边栏黑板 / 督促气泡判定）。
    public private(set) var todayTokens: Int = 0
    // MARK: 语音（第 17/18 步）
    /// 是否正在录音。
    public private(set) var isRecording = false
    /// 是否正在识别。
    public private(set) var isTranscribing = false
    /// 是否正在朗读教师回复。
    public private(set) var isSpeaking = false
    /// 教师回复完成后自动朗读（设置里可关）。
    public var autoSpeak = false
    /// 当前教师音色（runtime 自报的候选 + 配置值兜底）。
    public private(set) var availableVoices: [String] = ["Serena", "Vivian", "Ryan", "Aiden", "Eric"]
    /// 本地语音 runtime 自报描述（如「Qwen3-TTS 0.6B · mps」），nil = 未知。
    public private(set) var ttsRuntimeInfo: String?
    /// 最近语音错误（nil = 正常）。
    public private(set) var voiceError: String?
    /// 语音服务健康状态。
    public private(set) var asrHealth: ProviderHealth = .configurationInvalid(reason: "尚未初始化")
    public private(set) var ttsHealth: ProviderHealth = .configurationInvalid(reason: "尚未初始化")
    // MARK: 模型管理中心（本地检测 ~/AI_Models + 外部模型统一入口）
    /// 每个能力的模型信息（当前模型/来源/本地检测列表）。
    public private(set) var capabilityInfos: [AIProviderKind: CapabilityModelInfo] = [:]
    /// 外部模型 API Key 草稿（providerID -> key）。
    public var externalKeyDrafts: [String: String] = [:]
    /// 外部模型探测结果（providerID -> models）。
    public private(set) var externalModels: [String: [DiscoveredModel]] = [:]
    /// 每个能力当前展开的外部 Provider 标签。
    public var externalSelectedProvider: [String: String] = [:]
    /// 外部 Provider 候选缓存（kind -> options，设置页打开时拉一次）。
    public var externalProviderCache: [String: [(id: String, name: String)]] = [:]
    public private(set) var isFetchingExternal = false
    /// 外部模型操作结果消息（providerID -> message）。
    public var externalMessages: [String: String] = [:]
    /// 手动填写模型名草稿（kind -> name）。
    public var customModelDrafts: [String: String] = [:]
    /// 中栏切换：学习记录页（false = 练习对话）。
    public var showingRecords = false
    /// 学习记录数据（进入页面时加载）。
    public private(set) var records: [SessionSummary] = []
    public private(set) var mistakes: [GrammarCorrection] = []
    /// 练习复盘：最新一份（本次会话或最近一次）。nil = 还没生成过。
    public private(set) var latestReview: SessionReview?
    /// 历史复盘（学习记录页可回看）。
    public private(set) var reviews: [SessionReview] = []
    /// 是否正在生成复盘（按钮 loading）。
    public private(set) var isGeneratingReview = false
    /// 数据目录缓存快照（设置页「缓存管理」卡片）。
    public private(set) var cacheSnapshot: CacheSnapshot = .empty
    /// 上一次清理释放的字节数（展示用，0 = 无）。
    public private(set) var cacheFreedBytes: Int64 = 0

    /// 产品配置缓存（Sendable，可在 MainActor 直接修改后整体回写）。
    private var product: ProductConfig = ProductConfig()

    public init() {
        let services = CoachServices()
        self.services = services
        self.chat = ChatService(services: services)
    }

    public var theme: ForestTheme {
        ForestThemeResolver.resolve(mode: themeMode, systemIsDark: systemIsDark)
    }

    // 供设置页读取的产品字段
    public var productPracticeMode: PracticeMode { product.practiceMode }
    public var learningLanguage: String { product.learningLanguage }
    public var nativeLanguage: String { product.nativeLanguage }
    public var teacherVoice: String { product.teacherVoice }
    public var teacherBubblesEnabled: Bool { product.teacherBubbles }
    public var animalBubblesEnabled: Bool { product.animalBubbles }
    public var animalActivityEnabled: Bool { product.animalActivity }
    /// 活动频率（0...1）。
    public var animalActivityFrequency: Double { product.animalActivityFrequency }
    /// 音色切换自动试听开关。
    public var voicePreviewEnabled: Bool { product.voicePreview }
    /// 教师朗读语速（倍速，1 = 正常）。
    public var speechRate: Double { product.speechRate }
    /// 实际生效的活动开关：配置开 && 非夜晚（夜晚自动安静）。
    public var animalActivityEffective: Bool { product.animalActivity && !theme.isNight }

    /// 老师形象（侧边栏底部 + 聊天区 AI 头像）。
    public var teacherAnimalKind: AnimalKind {
        AnimalKind(rawValue: product.teacherAnimal) ?? .panda
    }
    /// 小学员形象（聊天区学员位 + 右侧爬树形象）。
    public var studentAnimalKind: AnimalKind {
        AnimalKind(rawValue: product.studentAnimal) ?? .bear
    }

    public var currentModelName: String? {
        if let resolved = availableModels.first(where: { $0.id == modelDraft })?.name { return resolved }
        return modelDraft.isEmpty ? nil : modelDraft
    }

    /// 状态栏用：生效 Provider 的展示名（如「本地模型」「DeepSeek」）。
    public var activeProviderName: String { activeProvider?.userFacingName ?? "未配置" }
    /// 生效 Provider 是否为云端 API。
    public var isActiveProviderRemote: Bool { activeProvider?.runtime == .remoteAPI }

    /// 设置页 Provider 标签列表（id + 展示名），来自配置文件。
    public func llmProviderOptions() async -> [(id: String, name: String, isRemote: Bool)] {
        let configuration = await services.configuration
        return configuration.providers
            .filter { $0.kind == .llm }
            .map { ($0.id, $0.userFacingName, $0.runtime == .remoteAPI) }
    }

    // MARK: - 启动

    public func start() async {
        let configuration = await services.configuration
        product = configuration.product
        themeMode = configuration.product.themeMode
        chat.profile.learningLanguage = configuration.product.learningLanguage
        chat.profile.nativeLanguage = configuration.product.nativeLanguage
        progress = await services.loadProgress()

        isBooting = true
        do {
            try await services.bootstrapLLM()
            bootMessage = nil
        } catch {
            bootMessage = error.localizedDescription
        }
        // 恢复上次会话的聊天内容（无历史则保持空白）
        await chat.restoreLastSessionIfNeeded()
        await bootstrapVoice()
        await refreshStatus()
        refreshTodayTokens()
        isBooting = false
    }

    /// 刷新今日 token 用量（每次回复完成 / 打开侧边栏时调用）。
    public func refreshTodayTokens() {
        todayTokens = DailyTokenCounter.todayTokens()
    }

    // MARK: - 语音（第 17/18 步）

    /// 装配语音能力。**不阻断启动**：runtime 不在线时仅展示状态。
    public func bootstrapVoice() async {
        let health = await services.bootstrapVoice()
        asrHealth = health.asr
        ttsHealth = health.tts
        let voices = await services.availableVoices()
        if !voices.isEmpty {
            availableVoices = voices
            await normalizeVoice(voices)
        }
        ttsRuntimeInfo = await services.voice.ttsRuntimeDescription()
    }

    /// 把配置里的音色对齐到 runtime 自报列表（大小写不敏感），避免选择器空选。
    private func normalizeVoice(_ voices: [String]) async {
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

    /// 点击麦克风：开始录音。
    public func startVoiceInput() async {
        guard !isRecording else { return }
        isSpeaking = false
        await services.voice.stopSpeaking()
        await services.voice.startRecording()
        let state = await services.voice.isRecording
        isRecording = state
        if let error = await services.voice.lastError { voiceError = error }
    }

    /// 再次点击：停止录音 → 识别 → 填入输入框（由调用方接收文本）。
    public func finishVoiceInput() async -> String? {
        guard isRecording else { return nil }
        let text = await services.voice.stopRecordingAndTranscribe(language: "English")
        isRecording = false
        isTranscribing = await services.voice.isTranscribing
        voiceError = await services.voice.lastError
        return text
    }

    public func cancelVoiceInput() async {
        await services.voice.cancelRecording()
        isRecording = false
    }

    /// 朗读教师回复（按设置里的语速播放）。
    public func speak(_ text: String) async {
        await services.voice.speak(text, voice: product.teacherVoice, language: "English",
                                   rate: Float(product.speechRate))
        isSpeaking = await services.voice.isSpeaking
        voiceError = await services.voice.lastError
    }

    public func stopSpeaking() async {
        await services.voice.stopSpeaking()
        isSpeaking = false
    }

    /// 设置页：切换自动朗读。
    public func setAutoSpeak(_ enabled: Bool) async {
        autoSpeak = enabled
        if !enabled { await stopSpeaking() }
    }

    /// 音色切换时自动试听一句短示例（受设置开关控制）。
    public func setVoice(_ voice: String) async {
        product.teacherVoice = voice
        await persistProduct()
        if product.voicePreview {
            await services.voice.speak("Nice to meet you!", voice: voice, language: "English",
                                       rate: Float(product.speechRate))
            voiceError = await services.voice.lastError
        }
    }

    public func refreshStatus() async {
        health = await services.llmHealth()
        let models = await services.availableLLMModels()
        availableModels = models.filter { !$0.isEmbeddingOnly }
        activeProvider = await services.activeLLMProvider()
        if activeProvider == nil { selectedProviderID = "" } else if !isActiveProviderRemote || selectedProviderID.isEmpty {
            selectedProviderID = activeProvider?.id ?? selectedProviderID
        }
        if let current = await services.currentLLMModel() {
            modelDraft = current
        } else {
            modelDraft = availableModels.first?.id ?? ""
        }
        // 上下文窗口：优先取 runtime 发现的当前模型长度，其次配置值。
        let configured = await services.contextWindow()
        contextLimit = availableModels.first(where: { $0.id == modelDraft })?.contextLength ?? configured
        // 生效模型的推理强度（头部胶囊展示用）。
        activeReasoningEffort = await services.activeReasoningEffort()
        // 关键：同步本地 product 缓存。否则切换 Provider 后，任何一次 persistProduct
        // 都会用旧缓存回写配置，把 activeProviders/apiKey 决策抹掉（重启回到 qwen3 的根源）。
        product = await services.configuration.product
    }

    // MARK: - 模型管理中心（本地检测 + 外部模型）

    /// 刷新各能力的模型信息快照（设置页打开 / 检测按钮时调用）。
    public func refreshCapabilityInfos() async {
        let configuration = await services.configuration
        var result: [AIProviderKind: CapabilityModelInfo] = [:]
        for kind in [AIProviderKind.asr, .tts, .vad, .embedding, .pronunciation] {
            let provider = configuration.resolvedProvider(for: kind)
            let localModels = LocalModelScanner.scan(kind: kind)

            let healthOK: Bool
            let healthText: String
            switch kind {
            case .asr: healthOK = asrHealth.isUsable; healthText = asrHealth.userFacingDescription
            case .tts: healthOK = ttsHealth.isUsable; healthText = ttsHealth.userFacingDescription
            default:
                // VAD / Embedding / Pronunciation V1 尚无独立 runtime，如配置了本地 Provider 才有意义
                healthOK = false
                healthText = provider?.runtime == .externalLocalRuntime ? "等待接入" : "内置模拟"
            }

            let current = product.selectedModel(for: kind) ?? provider?.model
            let source: String
            switch provider?.runtime {
            case .remoteAPI:
                source = "\(provider?.userFacingName ?? "云端") 提供的云端模型"
            case .externalLocalRuntime:
                if let current, let path = LocalModelScanner.path(of: current, kind: kind) {
                    source = "本地 · \(path)"
                } else if let endpoint = provider?.endpoint {
                    source = "本地服务 · \(endpoint)"
                } else {
                    source = "本地模型"
                }
            default:
                source = provider == nil ? "未配置" : "内置模拟（无需配置）"
            }

            result[kind] = CapabilityModelInfo(
                kind: kind,
                healthOK: healthOK,
                healthText: healthText,
                currentModel: current,
                sourceDescription: source,
                localModels: localModels
            )
        }
        capabilityInfos = result
    }

    /// 选择本地检测到的模型（~/AI_Models）并重装配。
    public func selectLocalModel(_ kind: AIProviderKind, name: String) async {
        do {
            try await services.setCapabilityModel(kind, model: name)
            bootMessage = nil
        } catch {
            bootMessage = error.localizedDescription
        }
        await refreshCapabilityInfos()
    }

    /// 手动填写模型名并应用。
    public func applyCustomModel(_ kind: AIProviderKind, name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await selectLocalModel(kind, name: trimmed)
        customModelDrafts[kind.rawValue] = ""
    }

    /// 某能力配置里的外部 Provider 候选（id + 展示名）。
    public func remoteProviderOptions(for kind: AIProviderKind) async -> [(id: String, name: String)] {
        let configuration = await services.configuration
        return configuration.providers
            .filter { $0.kind == kind && $0.runtime == .remoteAPI }
            .map { ($0.id, $0.userFacingName) }
    }

    /// 外部模型：校验 API Key 并拉取模型列表（不落盘）。
    public func fetchExternalModels(kind: AIProviderKind, providerID: String) async {
        let apiKey = await resolvedExternalAPIKey(providerID: providerID)
        guard !apiKey.isEmpty else {
            externalMessages[providerID] = "请先填写 API Key"
            return
        }
        isFetchingExternal = true
        externalMessages[providerID] = nil
        do {
            let models = try await services.fetchRemoteModels(providerID: providerID, apiKey: apiKey, kind: kind)
            externalModels[providerID] = models.filter { !$0.isEmbeddingOnly }
            externalMessages[providerID] = "验证成功，获取到 \(models.count) 个模型"
        } catch {
            externalMessages[providerID] = error.localizedDescription
        }
        isFetchingExternal = false
    }

    /// 外部模型：保存 Key/模型并激活该 Provider。
    public func applyExternalModel(_ kind: AIProviderKind, providerID: String, model: String) async {
        let apiKey = await resolvedExternalAPIKey(providerID: providerID)
        guard !apiKey.isEmpty else {
            externalMessages[providerID] = "请先填写 API Key"
            return
        }
        do {
            try await services.applyRemoteProvider(providerID: providerID, apiKey: apiKey, model: model, kind: kind)
            externalMessages[providerID] = "已启用 \(model)"
            if kind == .asr || kind == .tts { await bootstrapVoice() }
        } catch {
            externalMessages[providerID] = error.localizedDescription
        }
        await refreshCapabilityInfos()
    }

    private func resolvedExternalAPIKey(providerID: String) async -> String {
        let draft = externalKeyDrafts[providerID] ?? ""
        if !draft.trimmingCharacters(in: .whitespaces).isEmpty { return draft }
        let configuration = await services.configuration
        return configuration.providers.first { $0.id == providerID }?.apiKey ?? ""
    }

    // MARK: - 模型 Provider（本地 / 云端切换）

    /// API Key 解析：草稿优先，为空则回退到已保存的密钥。
    private func resolvedAPIKey(for providerID: String) async -> String {
        let draft = apiKeyDrafts[providerID] ?? ""
        if !draft.trimmingCharacters(in: .whitespaces).isEmpty { return draft }
        let configuration = await services.configuration
        return configuration.providers.first { $0.id == providerID }?.apiKey ?? ""
    }

    /// 设置页：切换选中的 Provider 标签（仅改 UI，不生效）。
    public func selectProviderTab(_ id: String) {
        selectedProviderID = id
        remoteMessage = nil
        reasoningEffortDraft = id == activeProvider?.id ? activeProvider?.reasoningEffort : reasoningEffortDraft
    }

    /// 设置页：激活某个 Provider（本地或云端）。
    public func activateProvider(_ id: String) async {
        do {
            try await services.switchLLMProvider(id)
            bootMessage = nil
            remoteMessage = nil
        } catch {
            remoteMessage = error.localizedDescription
        }
        await refreshStatus()
    }

    /// 设置页：校验云端 API Key 并拉取模型列表（不落盘）。
    public func fetchRemoteModels() async {
        let apiKey = await resolvedAPIKey(for: selectedProviderID)
        guard !apiKey.isEmpty else {
            remoteMessage = "请先填写 API Key"
            return
        }
        isFetchingRemoteModels = true
        remoteMessage = nil
        do {
            let models = try await services.fetchRemoteModels(providerID: selectedProviderID, apiKey: apiKey)
            remoteModels[selectedProviderID] = models.filter { !$0.isEmbeddingOnly }
            remoteMessage = "验证成功，获取到 \(models.count) 个模型"
        } catch {
            remoteMessage = error.localizedDescription
        }
        isFetchingRemoteModels = false
    }

    /// 设置页：保存云端配置（API Key + 模型 + 推理强度）并激活。
    public func applyRemoteProvider(model: String) async {
        let apiKey = await resolvedAPIKey(for: selectedProviderID)
        guard !apiKey.isEmpty else {
            remoteMessage = "请先填写 API Key"
            return
        }
        do {
            try await services.applyRemoteProvider(
                providerID: selectedProviderID,
                apiKey: apiKey,
                model: model,
                reasoningEffort: reasoningEffortDraft,
                kind: .llm
            )
            bootMessage = nil
            remoteMessage = "已启用云端模型 \(model)"
        } catch {
            remoteMessage = error.localizedDescription
        }
        await refreshStatus()
    }

    // MARK: - 主题

    public func setThemeMode(_ mode: ThemeMode) async {
        themeMode = mode
        product.themeMode = mode
        await persistProduct()
    }

    public func toggleDayNight() async {
        await setThemeMode(theme.isNight ? .day : .night)
    }

    // MARK: - 进度

    /// 通关一个关卡：累加星星、标记完成并解锁下一关，随后持久化。
    public func completeLevel(_ levelID: String, earnedStars: Int) async {
        guard let index = progress.levels.firstIndex(where: { $0.id == levelID }) else { return }
        progress.levels[index].earnedStars = max(progress.levels[index].earnedStars, earnedStars)
        progress.levels[index].state = .completed
        if let next = progress.levels.indices.first(where: { $0 > index && progress.levels[$0].state == .locked }) {
            progress.levels[next].state = .unlocked
        }
        progress.recalculateSummary()
        await services.saveProgress(progress)
    }

    // MARK: - 模型（UI 可填可选，代码零字面量）

    public func applyModel(_ name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await services.switchLLMModel(trimmed)
            modelDraft = trimmed
            bootMessage = nil
        } catch {
            bootMessage = error.localizedDescription
        }
        await refreshStatus()
    }

    // MARK: - 学习设置

    public func setPracticeMode(_ mode: PracticeMode) async {
        product.practiceMode = mode
        await persistProduct()
    }

    public func setLearningLanguage(_ language: String) async {
        product.learningLanguage = language
        chat.profile.learningLanguage = language
        await persistProduct()
    }

    public func setNativeLanguage(_ language: String) async {
        product.nativeLanguage = language
        chat.profile.nativeLanguage = language
        await persistProduct()
    }

    public func setTeacherVoice(_ voice: String) async {
        product.teacherVoice = voice
        await persistProduct()
    }

    // MARK: - 森林伙伴（气泡 / 活动开关，全部持久化）

    public func setTeacherBubbles(_ enabled: Bool) async {
        product.teacherBubbles = enabled
        await persistProduct()
    }

    public func setAnimalBubbles(_ enabled: Bool) async {
        product.animalBubbles = enabled
        await persistProduct()
    }

    public func setAnimalActivity(_ enabled: Bool) async {
        product.animalActivity = enabled
        await persistProduct()
    }

    public func setAnimalActivityFrequency(_ value: Double) async {
        product.animalActivityFrequency = min(max(value, 0), 1)
        await persistProduct()
    }

    public func setVoicePreview(_ enabled: Bool) async {
        product.voicePreview = enabled
        await persistProduct()
    }

    /// 教师朗读语速：落到最接近的可选档位（设置与对话区两处共用同一份配置）。
    public func setSpeechRate(_ value: Double) async {
        let rate = SpeechRate.nearest(to: value)
        guard rate.rawValue != product.speechRate else { return }
        product.speechRate = rate.rawValue
        await persistProduct()
    }

    // MARK: - 伙伴形象

    public func setTeacherAnimal(_ kind: AnimalKind) async {
        product.teacherAnimal = kind.rawValue
        await persistProduct()
    }

    public func setStudentAnimal(_ kind: AnimalKind) async {
        product.studentAnimal = kind.rawValue
        await persistProduct()
    }

    // MARK: - 学习记录

    public func openRecords() async {
        showingRecords = true
        await loadRecords()
    }

    public func openPractice() async {
        showingRecords = false
    }

    public func loadRecords() async {
        records = await services.recentSessions(limit: 20)
        mistakes = await services.recentCorrections(limit: 50)
        await loadReviews()
    }

    public func loadReviews() async {
        reviews = await services.recentReviews(limit: 10)
        if let first = reviews.first {
            latestReview = first
        } else {
            latestReview = await services.sessionReview(sessionID: chat.sessionID)
        }
    }

    /// 生成本次练习的复盘总结（本地模型完成，失败时自动给规则版总结）。
    public func generateSessionReview() async {
        guard !isGeneratingReview else { return }
        isGeneratingReview = true
        defer { isGeneratingReview = false }
        let duration = await services.sessionDuration(sessionID: chat.sessionID)
        let corrections = chat.correctionsByMessage.values.flatMap { $0 }
        let review = await services.makeSessionReview(
            sessionID: chat.sessionID,
            messages: chat.messages,
            corrections: corrections,
            duration: duration
        )
        latestReview = review
        reviews = await services.recentReviews(limit: 10)
    }

    // MARK: - 缓存管理

    public func refreshCacheInfo() async {
        cacheSnapshot = await services.cacheSnapshot()
    }

    /// 清理可再生的缓存（学习记忆与配置始终保留）。
    public func clearCache() async {
        let before = await services.clearCaches()
        let after = await services.cacheSnapshot()
        cacheSnapshot = after
        cacheFreedBytes = max(before.totalBytes - after.totalBytes, 0)
    }

    // MARK: - 高级（普通用户不需要）

    public func setLLMEndpoint(_ endpoint: String) async {
        do {
            try await services.setLLMProviderField(endpoint: endpoint)
            bootMessage = nil
        } catch {
            bootMessage = error.localizedDescription
        }
        await refreshStatus()
    }

    public func setLLMTemperature(_ temperature: Double) async {
        do {
            try await services.setLLMProviderField(temperature: temperature)
        } catch {
            bootMessage = error.localizedDescription
        }
    }

    private func persistProduct() async {
        try? await services.updateProduct(product)
    }
}
