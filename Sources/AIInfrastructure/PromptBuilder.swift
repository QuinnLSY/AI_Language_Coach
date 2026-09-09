import AppCore
import Foundation

/// Prompt 隔离：长 Prompt 只放在 `Resources/Prompts/`，禁止出现在 View / 传输层 / Adapter 里。
public enum PromptBuilder {

    public static func teacherSystemPrompt(
        learningLanguage: String,
        nativeLanguage: String,
        proficiency: String,
        practiceMode: PracticeMode
    ) -> String {
        guard let url = Bundle.module.url(forResource: "Prompts/teacher_system", withExtension: "txt"),
              let template = try? String(contentsOf: url, encoding: .utf8)
        else {
            return fallbackSystemPrompt(learningLanguage: learningLanguage)
        }
        return template
            .replacingOccurrences(of: "{learning_language}", with: learningLanguage)
            .replacingOccurrences(of: "{native_language}", with: nativeLanguage)
            .replacingOccurrences(of: "{proficiency}", with: proficiency)
            .replacingOccurrences(of: "{practice_mode}", with: practiceMode.displayName)
    }

    private static func fallbackSystemPrompt(learningLanguage: String) -> String {
        "You are a friendly \(learningLanguage) conversation coach. Keep replies short and encouraging."
    }
}
