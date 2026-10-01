import AIDomain
import AppCore
import Foundation

/// 每日推荐的雅思词库（`Resources/Vocabulary/ielts_words.json`）。
///
/// **只从数据文件读取**，代码零字面量——补词 / 调档位 / 改中文只改 JSON。
public enum VocabularyWordBank {

    /// 随包发布的词库。资源缺失 / 解析失败时返回空数组（UI 隐藏每日推荐板块）。
    public static func load() -> [DailyWord] {
        if let loaded = parse(resourceData()) { return loaded }
        AppLog.warning("未找到雅思词库资源（Resources/Vocabulary/ielts_words.json）", category: "vocabulary")
        return []
    }

    /// 读词库文件（两种打包布局都试一遍）。
    private static func resourceData() -> Data? {
        if let url = AppResourceBundle.url(forResource: "Vocabulary/ielts_words", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            return data
        }
        // 兜底：不同打包方式对子目录资源的处理略有差异。
        if let url = AppResourceBundle.url(forResource: "ielts_words", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            return data
        }
        return nil
    }

    /// 解析 `[{"word": "...", "difficulty": 1, "pos": "v.", "zh": "..."}]` 成 `DailyWord`。
    ///
    /// ⚠️ JSON 里的 `pos` / `zh` 只随数据存着（给以后的离线速查留一份），
    /// 选词与展示都不用它们——**详细释义一律按需问模型**。
    /// 空词 / 非法难度 / 重复词一律忽略；无法解析返回 nil。
    public static func parse(_ data: Data?) -> [DailyWord]? {
        guard let data,
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        var result: [DailyWord] = []
        var seen = Set<String>()
        for item in list {
            guard let raw = item["word"] as? String else { continue }
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, word.count <= 48, !seen.contains(word.lowercased()) else { continue }
            seen.insert(word.lowercased())
            result.append(DailyWord(word: word, difficulty: item["difficulty"] as? Int ?? 2))
        }
        return result
    }
}
