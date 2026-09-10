import AppCore
import Foundation

/// 输入框的预设学员提问（未输入内容时轮换展示，点击发送即发送当前这一条）。
///
/// **只从数据文件读取**（`Resources/Questions/starter_questions.json`），
/// 代码里不写死任何问题——改文案不必改代码，也不会污染 UI 层。
public enum StarterQuestionCatalog {

    /// 随包发布的提问列表。资源缺失时返回空数组（UI 退回普通占位文案）。
    public static func bundled() -> [String] {
        if let url = AppResourceBundle.module.url(forResource: "Questions/starter_questions", withExtension: "json"),
           let loaded = parse(try? Data(contentsOf: url)) {
            return loaded
        }
        // 兜底：不同打包方式对子目录资源的处理略有差异。
        if let url = AppResourceBundle.module.url(forResource: "starter_questions", withExtension: "json"),
           let loaded = parse(try? Data(contentsOf: url)) {
            return loaded
        }
        AppLog.warning("未找到预设提问资源（Resources/Questions/starter_questions.json）", category: "chat")
        return []
    }

    /// 解析 `{"questions": ["..."]}`（单测 / 未来自定义入口）。
    /// 非字符串、空串一律忽略；无法解析返回 nil（由调用方决定提示还是静默）。
    public static func parse(_ data: Data?) -> [String]? {
        guard let data else { return nil }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = raw["questions"] as? [Any]
        else { return nil }
        var result: [String] = []
        for item in list {
            guard let text = item as? String else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !result.contains(trimmed) else { continue }
            result.append(trimmed)
        }
        return result
    }
}
