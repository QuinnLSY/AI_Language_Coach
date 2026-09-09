import AIDomain
import AIInfrastructure
import AIInterfaces
import AppCore
import Foundation
import Observation

/// 面向 UI 的对话服务。**UI 只依赖本类型，禁止直连 Provider / HTTP。**
@MainActor
@Observable
public final class ChatService {

    public private(set) var messages: [ChatMessage] = []
    public private(set) var streamingText: String = ""
    public private(set) var isGenerating = false
    /// 模型正在「思考」：已有推理增量但还没有正文（推理模型常见）。
    public private(set) var isThinking = false
    public private(set) var errorMessage: String?

    public var profile: LearnerProfile = LearnerProfile()

    private let services: CoachServices
    private var generationTask: Task<Void, Never>?

    public init(services: CoachServices) {
        self.services = services
    }

    public func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isGenerating else { return }
        messages.append(ChatMessage(role: .user, content: trimmed))
        streamingText = ""
        errorMessage = nil
        isGenerating = true
        generationTask = Task { [weak self] in
            await self?.generate()
        }
    }

    public func cancel() {
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
    }

    public func clear() {
        cancel()
        messages.removeAll()
        streamingText = ""
        errorMessage = nil
    }

    // MARK: - 内部

    private func generate() async {
        defer { isGenerating = false }

        let configuration = await services.configuration
        let providerConfig = configuration.enabledProvider(for: .llm)
        let model = await services.currentLLMModel()

        let systemPrompt = PromptBuilder.teacherSystemPrompt(
            learningLanguage: profile.learningLanguage,
            nativeLanguage: profile.nativeLanguage,
            proficiency: profile.proficiency.displayName,
            practiceMode: configuration.product.practiceMode
        )

        var llmMessages = [LLMMessage(role: .system, content: systemPrompt)]
        llmMessages.append(contentsOf: messages.map { LLMMessage(role: $0.role, content: $0.content) })

        let request = LLMRequest(
            messages: llmMessages,
            model: model,
            temperature: providerConfig?.temperature,
            topP: providerConfig?.topP,
            maxTokens: providerConfig?.maxTokens,
            streaming: true
        )

        var accumulated = ""
        var reasoning = ""
        do {
            let stream = await services.llm.stream(request)
            for try await chunk in stream {
                if Task.isCancelled { break }
                if let delta = chunk.reasoningDelta, !delta.isEmpty { reasoning += delta }
                if !chunk.textDelta.isEmpty {
                    accumulated += chunk.textDelta
                    streamingText = accumulated
                }
                isThinking = accumulated.isEmpty && !reasoning.isEmpty
            }
        } catch let error as AIProviderError {
            errorMessage = error.localizedDescription
        } catch {
            if !(error is CancellationError) {
                errorMessage = error.localizedDescription
            }
        }

        streamingText = ""
        isThinking = false
        let finalText = Self.stripThinking(accumulated).trimmingCharacters(in: .whitespacesAndNewlines)
        // 用户主动叫停时保留已生成内容，不算错误。
        if !finalText.isEmpty {
            messages.append(ChatMessage(role: .assistant, content: finalText))
        }
    }

    /// deepseek-r1 会输出 `<think>...推理...</think>`，产品层不展示推理段。
    private static func stripThinking(_ text: String) -> String {
        guard let start = text.range(of: "<think>") else { return text }
        if let end = text.range(of: "</think>", range: start.upperBound..<text.endIndex) {
            return String(text[..<start.lowerBound]) + String(text[end.upperBound...])
        }
        return String(text[..<start.lowerBound])
    }
}
