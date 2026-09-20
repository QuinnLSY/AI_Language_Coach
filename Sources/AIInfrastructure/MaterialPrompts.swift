import AIDomain
import AppCore
import Foundation

/// 上传材料自动出题的 Prompt 组装（材料 → 情景 + 跟读句 + 生词表）。
///
/// ⚠️ 模板 `material_kit.txt` 与解析器 `MaterialKitRule.parse` 是**一对**：
/// 改任何一方的键名 / 字段顺序，另一方必须同步改（两边都有测试钉着）。
extension PromptBuilder {

    /// 材料出题请求体：一次请求产出三样东西（情景 / 生词 / 跟读句）。
    ///
    /// 「一次操作 = 一个模型请求」在这里的落点：拆解是一次性的整体动作，
    /// 拆成三次请求只会让用户等三趟、多花三份钱，且三样东西本就该同源。
    public static func materialKitPrompt(
        material: String,
        learningLanguage: String,
        nativeLanguage: String
    ) -> String {
        let template: String
        if let url = AppResourceBundle.module.url(forResource: "Prompts/material_kit", withExtension: "txt"),
           let loaded = try? String(contentsOf: url, encoding: .utf8) {
            template = loaded
        } else {
            template = """
            You will be given a study passage. Split it into practiceable material.
            Output key-value lines only:
            title: <title in {learning_language}> | <title in {native_language}>
            scenario: <AI role> | <learner role> | <objective> | <difficulty 1-5> | <opening line>
            vocabulary: <word> | <part of speech> | <meaning> | <example sentence>
            sentence: <sentence> | <translation> | <pronunciation focus>
            Rules: vocabulary at most {max_words} entries; about {max_drills} sentences; no markdown, no numbering.
            Material:
            {material}
            """
        }
        return template
            .replacingOccurrences(of: "{learning_language}", with: learningLanguage)
            .replacingOccurrences(of: "{native_language}", with: nativeLanguage)
            .replacingOccurrences(of: "{max_words}", with: "\(MaterialKitRule.maxWords)")
            .replacingOccurrences(of: "{max_drills}", with: "\(MaterialKitRule.maxDrills)")
            .replacingOccurrences(of: "{material}", with: material)
    }
}
