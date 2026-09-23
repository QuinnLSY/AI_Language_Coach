import Foundation

/// `[[FIX]]` 行的**内容**有效性判据。格式层（`GrammarCorrectionLine`）只管
/// 「这一行切不切得出三段」；这里管「切出来的这一条到底是不是一次真纠错」。
///
/// 起因是真实教学事故（库里有铁证）：学员发的原句本来就对 ——
/// `I like eating Portuguese egg tarts.`（首字母大写、老师也回了 You did it!），
/// 模型仍然输出 `[[FIX]] I like… => i like… => 句首字母要大写`——
/// 既无中生有，方向还反。同库还有 `长句 => 原句原样` 的空纠错。
/// 这类行若不拦，卡片、错题本、复盘、学习记忆一路全脏。
///
/// 刻意**窄**：只拦「确定是幻觉」的两种形状。拿不准的一律放行 ——
/// 错杀一条真纠错，学员少学一处；漏放一条幻觉，只是多一张怪卡。
public enum GrammarCorrectionSanity {

    /// 返回 true = 这条「纠错」不成立，解析层应整条丢弃。
    public static func isHallucinated(original: String, corrected: String) -> Bool {
        let lhs = collapsed(original)
        let rhs = collapsed(corrected)
        // ① 原句 => 同一句：什么都没改（把正文原样标成纠错也走这条）。
        if lhs == rhs { return true }
        // ② 只差大小写、且「改完反而把句首大写弄丢了」：原句本就大写，被改成小写。
        //    英语里没有「把句首改小写」这种课 —— 这是幻觉纠错的固定形状。
        //    唯一例外是原句通篇大写（喊叫体），改回正常大小写是正经纠错。
        if lhs.lowercased() == rhs.lowercased(),
           let lf = lhs.first, let rf = rhs.first,
           lf.isLetter, rf.isLetter,
           lf.isUppercase, rf.isLowercase,
           !isShouting(lhs) {
            return true
        }
        return false
    }

    /// 压空白：判据只关心字符本身，不关心排版差异。
    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// 通篇大写（喊叫体）：所有字母都大写、且不止一个字母。
    private static func isShouting(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter)
        return letters.count > 1 && letters.allSatisfy(\.isUppercase)
    }
}
