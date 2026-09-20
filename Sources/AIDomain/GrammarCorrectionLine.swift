import Foundation

/// 老师标在回复末尾的**纠错行**（`[[FIX]] 原句 => 改正 => 说明`）的识别规则。
///
/// 为什么要单独一层：这一行的存在感全在**格式**上 —— 写对了就变成错题卡，
/// 写歪了就什么都不是。而两处都要认它：
/// - `ChatService.extractCorrections` 要把它从正文里剥出来、解析成 `GrammarCorrection`；
/// - `VoiceService.cleanForSpeech` 要把它从朗读文本里去掉（念出来就穿帮了）。
/// 两处各写一份 `hasPrefix("[[FIX]]")` 的后果是：放宽标记写法时只改了一处，
/// 于是「卡片有了、朗读也跟着念了一遍 `[[FIX]]`」这种半修不修的 bug。
///
/// 容错口径来自实测：模型会写 `**[FIX]**`、`- [[FIX]]`、`[[FIX]]：`、
/// `【FIX】`、`[FIX]` —— 它们**都是**同一个标记，不该因为多了两个星号就丢掉一次纠错。
public enum GrammarCorrectionLine {

    /// 认得的标记（小写比较）。`[[fix]]` 必须排在 `[fix]` 前面。
    static let tags = ["[[fix]]", "[fix]", "【fix】", "[[修正]]", "【修正】"]

    /// 这一行是不是纠错行。
    public static func isTagged(_ line: String) -> Bool { body(of: line) != nil }

    /// 剥掉标记与装饰，返回标记**之后**的正文；不是纠错行 → nil。
    ///
    /// 剥掉的装饰：行首空白、列表符 / 引用符（`- * • # >`）、反引号与星号，
    /// 以及标记后紧跟的冒号 / 竖线 / 空白（`[[FIX]]：a => b`）。
    public static func body(of line: String) -> String? {
        var text = line.trimmingCharacters(in: .whitespaces)
        while let first = text.first, "-*•#>`~ \t".contains(first) {
            text = String(text.dropFirst())
        }
        let lowered = text.lowercased()
        guard let tag = tags.first(where: { lowered.hasPrefix($0) }) else { return nil }
        var rest = String(text.dropFirst(tag.count)).trimmingCharacters(in: .whitespaces)
        while let first = rest.first, first == ":" || first == "：" || first == "|" || first == "｜" {
            rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        // 行尾的装饰星号（`=> 说明 **`）也要去掉，否则说明里会多出两个星号。
        while let last = rest.last, last == "*" || last == "`" {
            rest = String(rest.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return rest
    }

    /// 分隔符：正文的三段怎么切。`=>` 是提示词里要求的写法，模型偶尔写箭头也要认。
    static let separators = ["=>", "⇒", "→", "＝>", "＝＞"]

    /// 把标记后的正文切成「原句 / 改正 / 说明」三段。切不出两段以上 → nil（这行作废）。
    public static func parts(of body: String) -> [String]? {
        var pieces = [body]
        for separator in separators {
            if pieces.count == 1, body.contains(separator) {
                pieces = body.components(separatedBy: separator)
            }
        }
        let fields = pieces
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "*`")) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count >= 2, !fields[0].isEmpty, !fields[1].isEmpty else { return nil }
        return fields
    }
}
