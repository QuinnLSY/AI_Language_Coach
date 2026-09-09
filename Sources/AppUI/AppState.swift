import AIDomain
import AIInterfaces
import AIServices
import AppCore
import Foundation
import Observation
import SwiftUI

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
    /// 最近语音错误（nil = 正常）。
    public private(set) var voiceError: String?
    /// 语音服务健康状态。
    public private(set) var asrHealth: ProviderHealth = .configurationInvalid(reason: "尚未初始化")
    public private(set) var ttsHealth: ProviderHealth = .configurationInvalid(reason: "尚未初始化")
    /// 中栏切换：学习记录页（false = 练习对话）。
    public var showingRecords = false
    /// 学习记录数据（进入页面时加载）。
    public private(set) var records: [SessionSummary] = []
    public private(set) var mistakes: [GrammarCorrection] = []
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
        await bootstrapVoice()
        await refreshStatus()
        isBooting = false
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

    /// 朗读教师回复。
    public func speak(_ text: String) async {
        await services.voice.speak(text, voice: product.teacherVoice, language: "English")
        isSpeaking = await services.voice.isSpeaking
        voiceError = await services.voice.lastError
    }

    public func stopSpeaking() async {
        await services.voice.stopSpeaking()
        isSpeaking = false
    }

    /// 设置页：切换音色。
    public func setVoice(_ voice: String) async {
        product.teacherVoice = voice
        await persistProduct()
    }

    /// 设置页：切换自动朗读。
    public func setAutoSpeak(_ enabled: Bool) async {
        autoSpeak = enabled
        if !enabled { await stopSpeaking() }
    }

    public func refreshStatus() async {
        health = await services.llmHealth()
        let models = await services.availableLLMModels()
        availableModels = models.filter { !$0.isEmbeddingOnly }
        if let current = await services.currentLLMModel() {
            modelDraft = current
        } else {
            modelDraft = availableModels.first?.id ?? ""
        }
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
