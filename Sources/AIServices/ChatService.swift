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
    /// 流式思考过程（实时增长；UI 折叠面板展示最新若干行）。
    public private(set) var streamingReasoning: String = ""
    public private(set) var errorMessage: String?

    public var profile: LearnerProfile = LearnerProfile()
    /// 当前练习会话（持久化用）。
    public private(set) var sessionID: UUID
    /// 本会话按消息记录的纠错（UI 在气泡下方展示「改一改」卡片）。
    public private(set) var correctionsByMessage: [UUID: [GrammarCorrection]] = [:]
    /// 本会话累计纠错条数。
    public var correctionCount: Int { correctionsByMessage.values.reduce(0) { $0 + $1.count } }
    /// 上下文占用估算（token）：流式响应通常不回传 usage，用字符数近似
    /// （中英混合约 3 字符/token，每条消息附加 ~8 token 结构开销）。
    public var estimatedContextTokens: Int {
        var chars = 0
        for message in messages { chars += message.content.count + 24 }
        return (chars * 10 + 29) / 30
    }

    private let services: CoachServices
    private var generationTask: Task<Void, Never>?

    public init(services: CoachServices) {
        self.services = services
        let id = UUID()
        self.sessionID = id
        Task { [services, id] in
            await services.persistSession(ChatSession(id: id, mode: .conversation))
        }
    }

    public func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isGenerating else { return }
        let message = ChatMessage(role: .user, content: trimmed)
        messages.append(message)
        persist(message)
        streamingText = ""
        errorMessage = nil
        isGenerating = true
        generationTask = Task { [weak self] in
            await self?.generate()
        }
    }

    private func persist(_ message: ChatMessage) {
        let sessionID = sessionID
        let services = services
        Task {
            await services.persistMessage(message, sessionID: sessionID)
        }
    }

    public func cancel() {
        generationTask?.cancel()
        generationTask = nil
        isGenerating = false
    }

    /// 启动时恢复上次会话：消息回流 + 继续往同一会话里追加。
    public func restoreLastSessionIfNeeded() async {
        guard messages.isEmpty, !isGenerating else { return }
        guard let restored = await services.latestChatSession(), !restored.messages.isEmpty else { return }
        sessionID = restored.session.id
        messages = restored.messages
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
        let providerConfig = configuration.resolvedProvider(for: .llm)
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

        let tokensBefore = estimatedContextTokens
        var accumulated = ""
        var reasoning = ""
        do {
            let stream = await services.llm.stream(request)
            for try await chunk in stream {
                if Task.isCancelled { break }
                if let delta = chunk.reasoningDelta, !delta.isEmpty {
                    reasoning += delta
                    streamingReasoning = reasoning
                }
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
        streamingReasoning = ""
        isThinking = false
        let finalText = Self.stripThinking(accumulated).trimmingCharacters(in: .whitespacesAndNewlines)
        // 用户主动叫停时保留已生成内容，不算错误。
        if !finalText.isEmpty {
            // 抽取老师标注的纠错块（[[FIX]] ...），不进聊天正文。
            let parsed = Self.extractCorrections(finalText)
            let trimmedReasoning = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = ChatMessage(
                role: .assistant,
                content: parsed.cleanText,
                reasoning: trimmedReasoning.isEmpty ? nil : trimmedReasoning
            )
            messages.append(message)
            persist(message)
            if !parsed.corrections.isEmpty {
                correctionsByMessage[message.id] = parsed.corrections
                persistCorrections(parsed.corrections)
            }
            // 今日全局 token 用量（上下文增量估算，供黑板/督促气泡）。
            DailyTokenCounter.add(max(estimatedContextTokens - tokensBefore, 0))
        }
    }

    /// 解析并剥离 `[[FIX]] 原句 => 改正 => 简短说明` 行。
    /// 返回净化后的正文与纠错列表（纯函数，便于单测）。
    nonisolated static func extractCorrections(_ text: String) -> (cleanText: String, corrections: [GrammarCorrection]) {
        var corrections: [GrammarCorrection] = []
        var keptLines: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[[FIX]]") else {
                keptLines.append(line)
                continue
            }
            let body = trimmed.dropFirst("[[FIX]]".count).trimmingCharacters(in: .whitespaces)
            let parts = body.components(separatedBy: "=>").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { continue }
            let explanation = parts.count >= 3 ? parts[2] : ""
            corrections.append(GrammarCorrection(original: parts[0], corrected: parts[1], explanation: explanation))
        }
        let clean = keptLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (clean, corrections)
    }

    private func persistCorrections(_ corrections: [GrammarCorrection]) {
        let sessionID = sessionID
        let services = services
        Task {
            for correction in corrections {
                await services.persistCorrection(correction, sessionID: sessionID)
            }
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
