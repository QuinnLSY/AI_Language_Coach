import AIDomain
import AIInfrastructure
import AIInterfaces
import AppCore
import Foundation

/// 练习复盘（Session Review）：一次练习结束后，把会话流水 + 老师批注交给 LLM，
/// 产出结构化总结并落本地库 —— **学习记忆从"记流水"升级为"沉淀结论"**。
///
/// 依赖方向：本服务属 Application Services，只依赖 LLMManager / LearningDatabase，
/// 不接触任何具体模型、端点或 HTTP。Prompt 全部来自 `Resources/Prompts/`。
public actor SessionReviewService {

    private let llm: LLMManager
    private let learning: LearningDatabase?
    /// 学习事件总线（练习完成事件从这里发出）。CoachServices 装配时注入共享实例。
    private let events: LearningEventBus
    /// 落库失败记账（CoachServices 注入共享实例）。
    private let failures: PersistenceFailureRecorder

    public init(llm: LLMManager, learning: LearningDatabase?, events: LearningEventBus = LearningEventBus(),
            failures: PersistenceFailureRecorder) {
        self.llm = llm
        self.learning = learning
        self.events = events
        self.failures = failures
    }

    // MARK: - 生成

    /// 生成并保存一次复盘。
    /// - Parameters:
    ///   - sessionID: 归属会话。
    ///   - messages: 本次会话的完整流水。
    ///   - corrections: 老师在本次会话里标注的纠错。
    ///   - duration: 练习时长（秒）。
    ///   - options: 模型参数（来自配置，代码零字面量）。
    public func makeReview(
        sessionID: UUID,
        messages: [ChatMessage],
        corrections: [GrammarCorrection],
        duration: TimeInterval,
        options: ReviewOptions
    ) async -> SessionReview {
        let base = SessionReview(
            sessionID: sessionID,
            createdAt: Date(),
            duration: duration,
            messageCount: messages.filter { $0.role == .user }.count,
            correctionCount: corrections.count,
            source: .heuristic
        )
        guard !messages.isEmpty else {
            let fallback = Self.heuristic(from: base, corrections: corrections)
            await persist(fallback)
            return fallback
        }

        do {
            let request = LLMRequest(
                messages: [
                    LLMMessage(role: .system, content: PromptBuilder.sessionReviewPrompt(
                        learningLanguage: options.learningLanguage,
                        nativeLanguage: options.nativeLanguage,
                        proficiency: options.proficiency
                    )),
                    LLMMessage(role: .user, content: Self.userPayload(
                        messages: messages,
                        corrections: corrections,
                        duration: duration
                    )),
                ],
                model: options.model,
                temperature: options.temperature ?? 0.3,
                maxTokens: options.maxTokens,
                streaming: false,
                // 复盘是**确定性结构化输出**（固定字段的总结），与翻译/拼写/释义同为短任务：
                // 推理模型（qwen3 / deepseek-r1）默认会先把 max_tokens 花在思考段上，
                // 实测同一请求 12s 且正文为空，关思考后 0.8–5.8s 正常返回。
                reasoningEffort: LLMRequest.noThinkingEffort
            )
            let response = try await llm.generate(request)
            guard let parsed = Self.parse(response.text) else {
                AppLog.info("复盘返回不可解析，退化为规则总结", category: "review")
                let fallback = Self.heuristic(from: base, corrections: corrections)
                await persist(fallback)
                return fallback
            }
            var review = base
            review.source = .llm
            review.headline = parsed.headline
            review.newWords = parsed.newWords
            review.strengths = parsed.strengths
            review.improvements = parsed.improvements
            review.suggestion = parsed.suggestion
            await persist(review)
            return review
        } catch {
            AppLog.warning("复盘生成失败，退化为规则总结: \(error.localizedDescription)", category: "review")
            let fallback = Self.heuristic(from: base, corrections: corrections)
            await persist(fallback)
            return fallback
        }
    }

    /// 某会话最新一份复盘（没有则 nil）。
    public func review(sessionID: UUID) async -> SessionReview? {
        guard let learning else { return nil }
        return try? await learning.review(sessionID: sessionID)
    }

    /// 最近的复盘（学习记录页展示）。
    public func recentReviews(limit: Int = 10) async -> [SessionReview] {
        guard let learning else { return [] }
        return (try? await learning.recentReviews(limit: limit)) ?? []
    }

    // MARK: - 模型调用入参

    public struct ReviewOptions: Sendable {
        public var model: String?
        public var temperature: Double?
        public var maxTokens: Int?
        public var learningLanguage: String
        public var nativeLanguage: String
        public var proficiency: String

        public init(model: String? = nil, temperature: Double? = nil, maxTokens: Int? = nil,
                    learningLanguage: String = "en-US", nativeLanguage: String = "zh-CN",
                    proficiency: String = "beginner") {
            self.model = model
            self.temperature = temperature
            self.maxTokens = maxTokens
            self.learningLanguage = learningLanguage
            self.nativeLanguage = nativeLanguage
            self.proficiency = proficiency
        }
    }

    // MARK: - 入参拼装（纯函数，便于单测）

    /// 交给模型的用户消息：对话流水 + 纠错清单 + 时长。控制在合理长度内。
    public nonisolated static func userPayload(messages: [ChatMessage], corrections: [GrammarCorrection],
                                        duration: TimeInterval, limit: Int = 40) -> String {
        var lines: [String] = []
        lines.append("Practice length: \(Int(duration)) seconds.")
        lines.append("Transcript (learner / coach):")
        for message in messages.suffix(limit) {
            let who = message.role == .user ? "Learner" : "Coach"
            let text = message.content.replacingOccurrences(of: "\n", with: " ")
            lines.append("\(who): \(text)")
        }
        if corrections.isEmpty {
            lines.append("Teacher corrections: none recorded.")
        } else {
            lines.append("Teacher corrections:")
            for correction in corrections.prefix(12) {
                let reason = correction.explanation.isEmpty ? "" : " (\(correction.explanation))"
                lines.append("- \(correction.original) => \(correction.corrected)\(reason)")
            }
        }
        lines.append("Now output the JSON review.")
        return lines.joined(separator: "\n")
    }

    // MARK: - 解析 / 兜底

    private struct ReviewPayload: Decodable {
        let headline: String
        let newWords: [String]
        let strengths: [String]
        let improvements: [String]
        let suggestion: String

        enum CodingKeys: String, CodingKey {
            case headline
            case newWords = "new_words"
            case strengths
            case improvements
            case suggestion
        }

        /// 字段缺失/类型不符时逐个兜底，避免整段解析失败。
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            headline = (try? container.decode(String.self, forKey: .headline)) ?? ""
            newWords = (try? container.decode([String].self, forKey: .newWords)) ?? []
            strengths = (try? container.decode([String].self, forKey: .strengths)) ?? []
            improvements = (try? container.decode([String].self, forKey: .improvements)) ?? []
            suggestion = (try? container.decode(String.self, forKey: .suggestion)) ?? ""
        }
    }

    /// 从模型输出里抠出 JSON 对象：容忍 ```json 包壳、前后废话与 `<think>` 推理段。
    public nonisolated static func parse(_ raw: String) -> (headline: String, newWords: [String],
                                                     strengths: [String], improvements: [String],
                                                     suggestion: String)? {
        var text = raw
        if let start = text.range(of: "<think>"),
           let end = text.range(of: "</think>", range: start.upperBound..<text.endIndex) {
            text = String(text[..<start.lowerBound]) + String(text[end.upperBound...])
        }
        guard let object = firstJSONObject(in: text),
              let data = object.data(using: .utf8),
              let payload = try? JSONDecoder().decode(ReviewPayload.self, from: data)
        else { return nil }
        guard !payload.headline.isEmpty
                || !payload.newWords.isEmpty
                || !payload.strengths.isEmpty
                || !payload.improvements.isEmpty
                || !payload.suggestion.isEmpty
        else { return nil }
        return (payload.headline, payload.newWords, payload.strengths,
                payload.improvements, payload.suggestion)
    }

    /// 取首个花括号包裹的片段（按引号与转义粗略配对，够用于模型输出）。
    public nonisolated static func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        for index in text[start...].indices {
            let char = text[index]
            if inString {
                if escaped { escaped = false } else if char == "\\" { escaped = true } else if char == "\"" { inString = false }
                continue
            }
            switch char {
            case "\"": inString = true
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(text[start...index]) }
            default: break
            }
        }
        return nil
    }

    /// 规则兜底：模型不可用时也要给学员一份能看的复盘（只依据已记录的事实）。
    public nonisolated static func heuristic(from base: SessionReview, corrections: [GrammarCorrection]) -> SessionReview {
        var review = base
        review.source = .heuristic
        let turns = base.messageCount
        if turns == 0 {
            review.headline = "还没开始对话，去和老师打个招呼吧"
        } else if corrections.isEmpty {
            review.headline = "完成 \(turns) 轮对话，表达很稳"
            review.strengths = ["敢开口、愿意持续表达"]
        } else {
            review.headline = "完成 \(turns) 轮对话，\(corrections.count) 处可以更地道"
            review.strengths = ["坚持完成了整段练习"]
        }
        review.improvements = corrections.prefix(3).map { correction in
            correction.explanation.isEmpty
                ? "\(correction.original) → \(correction.corrected)"
                : "\(correction.explanation)（\(correction.corrected)）"
        }
        review.suggestion = corrections.isEmpty
            ? "下次挑战更长一点的句子，让老师带你往上爬一格。"
            : "先复习错题本里的 \(min(corrections.count, 3)) 条句子，再和老师聊同一个话题。"
        return review
    }

    // MARK: - 落库

    private func persist(_ review: SessionReview) async {
        guard let learning else {
            await failures.record("保存这次复盘", nil)
            return
        }
        do {
            try await learning.saveReview(review)
        } catch {
            // ⚠️ 落库失败就**不**发完成事件：森林飘叶是「练成了」的正反馈，
            // 复盘没存住时放这段动画，等于用视觉奖励掩盖一次静默丢失。
            await failures.record("保存这次复盘", error)
            return
        }
        // 森林地基：复盘落库了，树冠才飘叶（练完一段的「小回应」）。
        events.emit(.practiceCompleted(rounds: review.messageCount))
    }
}
