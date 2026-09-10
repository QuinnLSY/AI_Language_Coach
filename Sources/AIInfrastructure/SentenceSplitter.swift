import Foundation

/// 把一段教师回复切成适合**逐句合成、边播边合成**的片段。
///
/// 实测依据：本地 Qwen3-TTS 的合成耗时 ≈ 2.6 × 输出音频时长，且与文本长度近似线性。
/// 因此把 200~400 字符的整段一次性合成，用户要等 40~70 秒才听到第一个音；
/// 切成短句后「首句先合成先播、其余句在播放期间预取」，感知延迟降到首句的 3~5 秒。
public enum SentenceSplitter {

    /// 单句上限：超过则按次级标点（逗号/顿号）再切，仍超则硬切。
    public static let defaultMaxLength = 110
    /// 过短的片段会与相邻片段合并，避免碎片化朗读。
    public static let defaultMinLength = 14

    /// 一级断点：句末标点，遇到即断句。
    private static let terminators: Set<Character> = [".", "!", "?", ";", "…", "。", "！", "？", "；", "．"]
    /// 断句后仍需吸附到本句的收尾符号（引号、括号等）。
    private static let trailing: Set<Character> = ["\"", "'", "”", "’", ")", "）", "]", "】", "」", "』", "》"]
    /// 二级断点：仅在片段超长时使用。
    private static let softBreaks: Set<Character> = [",", "、", "，", "：", ":"]

    public static func split(
        _ text: String,
        maxLength: Int = defaultMaxLength,
        minLength: Int = defaultMinLength
    ) -> [String] {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return [] }

        let raw = hardBreaks(normalized)
        let merged = merge(raw, minLength: minLength)
        return merged.flatMap { limit($0, maxLength: maxLength) }
    }

    // MARK: - 步骤

    /// 压缩空白、清理 markdown 与 emoji，并去掉行首列表符号。
    ///
    /// 教师回复常带 markdown（`- item`、`**粗体**`、`[文字](链接)`）和 emoji，
    /// 这些符号直接送给 TTS 会读出杂音（"dash"、"open bracket"…），必须先清理。
    private static func normalize(_ text: String) -> String {
        // 行级：去掉行首列表符号
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { stripListMarker(String($0)) }
        let joined = stripLinks(lines.joined(separator: " "))

        var out = ""
        out.reserveCapacity(joined.count)
        var lastWasSpace = true
        for ch in joined {
            if ch == "\t" || ch == " " {
                if !lastWasSpace { out.append(" "); lastWasSpace = true }
                continue
            }
            if ch == "*" || ch == "`" || ch == "#" || ch == "_" || ch == "~" || ch == "|" {
                continue
            }
            if ch.unicodeScalars.allSatisfy({ isEmoji($0) }) { continue }
            out.append(ch)
            lastWasSpace = false
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 去掉行首的 `- `、`* `、`• `、`1. `、`) ` 等列表标记。
    private static func stripListMarker(_ line: String) -> String {
        var rest = Substring(line).drop { $0 == " " || $0 == "\t" || $0 == ">" }
        if let first = rest.first, "-*•+·".contains(first) {
            let after = rest.dropFirst()
            if after.isEmpty || after.first == " " || after.first == "\t" {
                rest = after.drop { $0 == " " || $0 == "\t" }
                return String(rest)
            }
        }
        // 有序列表：数字 / 字母 + "." 或 ")" + 空格
        let digits = rest.prefix { $0.isNumber }.count
        if digits > 0, digits <= 2 {
            let marker = rest.dropFirst(digits)
            if let sign = marker.first, sign == "." || sign == ")" {
                let after = marker.dropFirst()
                if after.isEmpty || after.first == " " || after.first == "\t" {
                    return String(after.drop { $0 == " " || $0 == "\t" })
                }
            }
        }
        return String(rest)
    }

    /// `[文字](链接)` → `文字`；孤立的 `](…)` 残留一并去掉。
    private static func stripLinks(_ text: String) -> String {
        guard text.contains("](") else { return text }
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "[", let close = text[index...].firstIndex(of: "]") {
                let after = text.index(after: close)
                if after < text.endIndex, text[after] == "(",
                   let paren = text[after...].firstIndex(of: ")") {
                    out += text[text.index(after: index)..<close]
                    index = text.index(after: paren)
                    continue
                }
            }
            out.append(text[index])
            index = text.index(after: index)
        }
        return out
    }

    /// emoji 与装饰符号：朗读时应剔除（否则会念出奇怪音节）。
    private static func isEmoji(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1F000...0x1FAFF,      // 各类 emoji
             0x2600...0x27BF,        // 杂项符号与装饰符（☀✓✈…）
             0x2B00...0x2BFF,        // 补充箭头
             0xFE0F, 0x200D,         // 变体选择符 / 零宽连接
             0x1F1E6...0x1F1FF:      // 区域指示符（国旗）
            return true
        default:
            return false
        }
    }

    /// 按句末标点切分（标点后的收尾引号一并吸附；括号内的句点不算句末）。
    private static func hardBreaks(_ text: String) -> [String] {
        let chars = Array(text)
        var pieces: [String] = []
        var start = 0
        var index = 0
        /// 括号深度：`(GitHub, Notion, etc.)` 里的句点不应断句
        var depth = 0
        while index < chars.count {
            let ch = chars[index]
            if ch == "(" || ch == "（" || ch == "[" || ch == "【" {
                depth += 1
                index += 1
                continue
            }
            if ch == ")" || ch == "）" || ch == "]" || ch == "】" {
                depth = max(0, depth - 1)
                index += 1
                continue
            }
            guard terminators.contains(ch), depth == 0 else {
                index += 1
                continue
            }
            var end = index + 1
            // 连续标点（如 "?!"）与收尾引号归入本句
            while end < chars.count, terminators.contains(chars[end]) || trailing.contains(chars[end]) {
                end += 1
            }
            let piece = String(chars[start..<end]).trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty { pieces.append(piece) }
            index = end
            start = end
        }
        if start < chars.count {
            let tail = String(chars[start...]).trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty { pieces.append(tail) }
        }
        return pieces
    }

    /// 合并过短片段（比如 "Yes." / "OK!"），使其达到可感知的朗读长度。
    private static func merge(_ pieces: [String], minLength: Int) -> [String] {
        var result: [String] = []
        var buffer = ""
        for piece in pieces {
            buffer = buffer.isEmpty ? piece : buffer + " " + piece
            if buffer.count >= minLength {
                result.append(buffer)
                buffer = ""
            }
        }
        if !buffer.isEmpty {
            if result.isEmpty {
                result.append(buffer)
            } else {
                result[result.count - 1] += " " + buffer
            }
        }
        return result
    }

    /// 把仍超长的片段按次级标点、最后按字符数切开。
    private static func limit(_ piece: String, maxLength: Int) -> [String] {
        guard piece.count > maxLength else { return [piece] }

        var result: [String] = []
        var buffer = ""
        for ch in piece {
            buffer.append(ch)
            let shouldBreak = softBreaks.contains(ch) && buffer.count >= maxLength / 2
            let tooLong = buffer.count >= maxLength
            if shouldBreak || tooLong {
                result.append(buffer.trimmingCharacters(in: .whitespaces))
                buffer = ""
            }
        }
        let tail = buffer.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty {
            if result.isEmpty {
                result.append(tail)
            } else if tail.count < maxLength / 3 {
                result[result.count - 1] += " " + tail
            } else {
                result.append(tail)
            }
        }
        return result.filter { !$0.isEmpty }
    }
}
