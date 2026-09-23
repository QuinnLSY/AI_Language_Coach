import Foundation

/// 键值行的共用零件。
///
/// 用「`键: 值 | 值 | 值` 一行一个键」跟模型说话的地方不止一处（材料出题、情景生成…），
/// 尺子必须只有一把 —— 各写一份的话，「空段算不算一个字段」「子字段自带的标签剥不剥」
/// 这类细节迟早在两边分叉，而分叉的表现是**同一次输出在一处解析得出来、在另一处解析不出来**。
enum KeyValueLine {

    /// 子字段切分：`|` 分段、逐段去首尾空白、丢空段。
    ///
    /// 丢空段是刻意的：模型经常写成 `a | | b`，留着空段会让后面的字段整体错位一格。
    static func fields(_ value: String) -> [String] {
        value
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 剥掉模型在子字段里自带的标签（实测会写 `AI Role: xxx`、`Goal: xxx`）。
    ///
    /// 只剥「冒号前是已知字段标签」的情况 —— 正文里的冒号（`At 9:30 I ...`）不受影响。
    static func stripLabel(_ field: String) -> String {
        guard let separator = field.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return field }
        let head = field[..<separator]
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        guard labels.contains(head) else { return field }
        return String(field[field.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
    }

    /// 行首键名的归一化（去空白 / 下划线、小写）：`AI Role` 与 `ai_role` 是同一个键。
    static func normalizedKey(_ raw: Substring) -> String {
        raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }

    private static let labels: Set<String> = [
        "airole", "ai", "role", "learnerrole", "learner", "studentrole", "student",
        "goal", "objective", "角色", "学员角色", "学生角色", "目标", "学习目标",
    ]
}
