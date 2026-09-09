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
    public var progress: LearnerProgress = SampleProgress.make()

    public private(set) var availableModels: [DiscoveredModel] = []
    public private(set) var health: ProviderHealth = .configurationInvalid(reason: "尚未初始化")
    public private(set) var isBooting = true
    public private(set) var bootMessage: String?
    public var modelDraft: String = ""
    public var showingSettings = false

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

        isBooting = true
        do {
            try await services.bootstrapLLM()
            bootMessage = nil
        } catch {
            bootMessage = error.localizedDescription
        }
        await refreshStatus()
        isBooting = false
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
