import Foundation

/// 老师回话的**语言闸门**（纯函数，可脱机单测）。
///
/// 用户口径：学员可以用母语（中文）提问，但老师**必须且只能**用学习语言（英语）回话。
/// 这条规则首先由提示词承担（`teacher_system.txt` 第 1 条 + `scenario.txt` + 记忆块都写了），
/// 但提示词不是硬保证 —— 模型偶尔仍会整句用母语答（实测：「那真是太好了！…」）。
/// 这里给出一个**确定性判据**，让调用方能识别出来并兜一次。
public enum TeacherLanguageGuard {

    /// 正文里有没有母语（中文）字符 —— 包括中文标点与全角符号。
    ///
    /// ⚠️ 判据要**算上标点**：`「乐器」` 这种引用只要出现，整句就已经不是纯英文了；
    /// 只数汉字会让「Nice work! 「乐器」 is called…」漏过去。
    public static func containsNativeScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { isNativeScalar($0.value) }
    }

    /// 中文汉字（含扩展区 A / 兼容区）、中文标点、全角字符、假名。
    private static func isNativeScalar(_ value: UInt32) -> Bool {
        switch value {
        case 0x3400...0x4DBF,      // CJK 扩展 A
             0x4E00...0x9FFF,      // CJK 统一汉字
             0xF900...0xFAFF,      // CJK 兼容汉字
             0x3000...0x303F,      // 中文标点（「」、《》、。、！…）
             0xFF00...0xFFEF,      // 全角／半角形式（，．？：等）
             0x3040...0x30FF:      // 平假名 / 片假名
            return true
        default:
            return false
        }
    }

    /// 兜底重写的结果**可不可信**。
    ///
    /// ⚠️ 这道闸门是实测逼出来的：弱模型（agnes-3.0-flash）遇到「把你上一条重说一遍」这种指代，
    /// 会答非所问地把**历史里那句英文**（开场白）照抄回来 —— 用户看到的就是
    /// 「学员问了一句话，老师没有回答，反而又打了个招呼」。
    ///
    /// 判据只有一条、但足够准：重说的是**这一轮**的回复，它不可能与之前某条回复一字不差。
    /// 命中就判定这次重写不可信，调用方保留原文（宁可留着母语，也不给一句答非所问的复读）。
    ///
    /// 比较用归一化形式（小写 + 压空白），免得只差一个空格就漏过去。
    ///
    /// ⚠️ 只拿**够长**的回复来查重：`Nice work!` / `Try again.` 这类短语一节课里重复出现很正常，
    /// 拿它判「抄了历史」会误伤 —— 误伤的代价是原文（带母语）被留下，正好是这条规则要治的病。
    /// 会被抄错的永远是开场白那样的一整句，用它当判据足够准。
    public static func isCredibleRewrite(_ candidate: String, earlierReplies: [String]) -> Bool {
        let normalized = normalize(candidate)
        guard !normalized.isEmpty else { return false }
        guard normalized.count >= shortestReplyWorthComparing else { return true }
        return !earlierReplies.contains { normalize($0) == normalized }
    }

    /// 短于这个长度的回复不参与查重（见 `isCredibleRewrite` 的说明）。
    static let shortestReplyWorthComparing = 24

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
