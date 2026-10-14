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
/// 第二种事故（用户 2026-10-14 报障）：老师**隔着两轮把之前的纠错又纠了一遍** ——
/// 学员说 "I am eating watermelon."，挂出来的卡片却是两轮前的
/// "I has no idea about what to chat. => I have no idea what to chat about."，
/// 与学员这一句毫无关系。根源在 `[[FIX]]` 行的契约是「learner's original
/// sentence」，却没有任何一层检查过**原句是不是学员本轮说过的话**；
/// 反复错误进了记忆后，老师（尤其是「集中练」档）会把旧纠错原样再吐一遍。
/// 由 `isUnrelatedToLatestMessage` 在解析层拦掉。
///
/// 刻意**窄**：只拦「确定不成立」的形状。拿不准的一律放行 ——
/// 错杀一条真纠错，学员少学一处；漏放一条，只是多一张怪卡。
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

    /// 原句内容词里必须有多少比例出现在学员本轮消息中，才算「这句是学员说的」。
    ///
    /// 真纠错的原句是**逐字引用**学员这一句，覆盖率接近 1.0；陈旧 / 编造的原句
    /// 与本轮消息用词几乎不重叠（实测样例：8 个内容词只重合 1 个 = 0.125）。
    /// 0.6 给「老师轻微改写引用」留足余量，又远高于任何换句重合度。
    static let relatednessThreshold = 0.6

    /// 这一条纠错的「原句」，是不是学员**本轮**说过的话。
    /// true = 对不上：老师把以前纠正过的句子又纠了一遍，或者编了一句学员没说过的话。
    ///
    /// 判据（刻意窄，拿不准一律放行）：
    /// - 原句是**单个词**时（`has => have` 这种片段级纠错）：这个词必须出现过。
    ///   用不过滤停用词的 token —— `has` 是助动词，剥了功能词这条判据就失效了。
    /// - 原句有多个词时：内容词（剥掉英文功能词）里**六成以上**必须出现在学员
    ///   本轮消息中。真纠错逐字引用本轮原话 → 覆盖率接近 1；陈旧纠错换了句子
    ///   → 覆盖率趋近 0。
    /// - 原句一个词都不剩 / 学员消息是空的 → 判不了，放行
    ///   （错杀一条真纠错比漏放一条陈旧纠错更糟）。
    public static func isUnrelatedToLatestMessage(original: String, learnerText: String) -> Bool {
        let originalTokens = comparableTokens(original)
        guard !originalTokens.isEmpty else { return false }
        let learnerTokens = Set(comparableTokens(learnerText))
        guard !learnerTokens.isEmpty else { return false }
        if originalTokens.count == 1 { return !learnerTokens.contains(originalTokens[0]) }
        let originalContent = originalTokens.filter { !stopWords.contains($0) }
        let learnerContent = learnerTokens.filter { !stopWords.contains($0) }
        guard !originalContent.isEmpty else { return false }
        let matched = originalContent.filter { learnerContent.contains($0) }
        return Double(matched.count) / Double(originalContent.count) < relatednessThreshold
    }

    /// 可比 token：小写；拉丁字母 / 数字按连续段切，CJK 逐字切（中文没有空格，
    /// 整句当一个词就没法比「引用了一句」还是「换了另一句」）。标点空白全是分隔符。
    private static func comparableTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var buffer = ""
        func flush() {
            if !buffer.isEmpty {
                tokens.append(buffer)
                buffer = ""
            }
        }
        for character in text.lowercased() {
            guard character.isLetter || character.isNumber else {
                flush()
                continue
            }
            if isCJK(character) {
                flush()
                tokens.append(String(character))
            } else {
                buffer.append(character)
            }
        }
        flush()
        return tokens
    }

    /// CJK / 假名 / 谚文字符：按字切，不当成一个整词。
    private static func isCJK(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF,   // 日文平假名 / 片假名
             0x31F0...0x31FF,   // 假名拼音扩展
             0x3400...0x4DBF,   // CJK 统一表意文字扩展 A
             0x4E00...0x9FFF,   // CJK 统一表意文字
             0xF900...0xFAFF,   // CJK 兼容表意
             0xAC00...0xD7AF,   // 韩文音节
             0x20000...0x2A6DF: // CJK 统一表意文字扩展 B
            return true
        default:
            return false
        }
    }

    /// 英文功能词。**只用于覆盖率判据**，不进任何别的口径。
    private static let stopWords: Set<String> = [
        // 冠词 / 连词 / 介词
        "a", "an", "the", "and", "or", "but", "so", "because", "if", "when", "while",
        "though", "although", "than", "as", "that", "this", "these", "those",
        "in", "on", "at", "to", "for", "with", "by", "from", "of", "about", "into",
        "onto", "over", "under", "between", "among", "during", "until", "before",
        "after", "through", "across", "against", "near", "up", "down", "out", "off",
        // 代词 / 疑问词
        "i", "me", "my", "mine", "myself", "you", "your", "yours", "he", "him", "his",
        "she", "her", "hers", "we", "us", "our", "ours", "they", "them", "their",
        "it", "its", "there", "here", "what", "how", "why", "where", "who", "which",
        // 助动词 / 情态动词
        "am", "is", "are", "was", "were", "be", "been", "being", "do", "does", "did",
        "have", "has", "had", "will", "would", "shall", "should", "can", "could",
        "may", "might", "must",
        // 高频虚词（任何句子里都可能出现，不承载「换了哪句」的信息）
        "no", "not", "very", "just", "too", "also", "now", "then",
        "today", "yesterday", "tomorrow",
    ]

    /// 通篇大写（喊叫体）：所有字母都大写、且不止一个字母。
    private static func isShouting(_ text: String) -> Bool {
        let letters = text.filter(\.isLetter)
        return letters.count > 1 && letters.allSatisfy(\.isUppercase)
    }
}
