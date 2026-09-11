import AIDomain
import AppCore
import Foundation

/// 每日推荐的雅思词库（`Resources/Vocabulary/ielts_words.json`）。
///
/// **只从数据文件读取**，代码零字面量——补词 / 调档位只改 JSON。
/// 词库只存词与难度档（1 简单 / 2 中等 / 3 困难），释义一律按需由 LLM 补。
public enum VocabularyWordBank {

    /// 随包发布的词库。资源缺失 / 解析失败时返回空数组（UI 隐藏每日推荐板块）。
    public static func load() -> [DailyWord] {
        if let url = AppResourceBundle.module.url(forResource: "Vocabulary/ielts_words", withExtension: "json"),
           let loaded = parse(try? Data(contentsOf: url)) {
            return loaded
        }
        // 兜底：不同打包方式对子目录资源的处理略有差异。
        if let url = AppResourceBundle.module.url(forResource: "ielts_words", withExtension: "json"),
           let loaded = parse(try? Data(contentsOf: url)) {
            return loaded
        }
        AppLog.warning("未找到雅思词库资源（Resources/Vocabulary/ielts_words.json）", category: "vocabulary")
        return []
    }

    /// 解析 `[{"word": "...", "difficulty": 1}]`。
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
