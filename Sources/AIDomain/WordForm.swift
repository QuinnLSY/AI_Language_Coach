import Foundation

/// 词形还原：**变体 → 本体**（划词查词要用它）。
///
/// 为什么要单独一层：用户口径是「划到的词是变体（复数 / -ing / -ed…）时，
/// 要查出本体，并解释当前变体相对本体的含义 —— 每一个单词都要能查到」。
/// 现实是模型面对 `subtitles` / `listening` 这类变体会**不按格式回**（它想解释
/// 「这是 subtitle 的复数」，于是写成一句话，解析不出词条 → 页面说「没查到」）。
/// 所以第一步先在本地把变体还原成原形，用原形去查 / 去问。
///
/// 这一层是**纯函数**：只做字符串判断与候选排序，不碰词库、不碰网络。
/// 「哪个候选真的存在」由调用方拿去问词库（`dictionaryBaseForm`）。
///
/// ⚠️ 宁可多给几个候选，也别漏：候选只当**提示**用（本地查不到就交给模型判断），
/// 多一个错候选的代价是模型忽略它，少一个对的候选的代价是用户查不到。
public enum WordForm {

    /// 一个候选原形 + 它对应的语法名称（用来向用户解释「这是它的什么形式」）。
    public struct Candidate: Sendable, Equatable {
        /// 本体（原形）。
        public var lemma: String
        /// 「复数形式」「现在分词」这类中文名称。
        public var label: String

        public init(lemma: String, label: String) {
            self.lemma = lemma
            self.label = label
        }
    }

    // MARK: - 语法名称

    public enum Label {
        public static let plural = "复数形式"
        public static let thirdPerson = "第三人称单数形式"
        public static let progressive = "现在分词（-ing 形式）"
        public static let past = "过去式 / 过去分词（-ed 形式）"
        public static let comparative = "比较级"
        public static let superlative = "最高级"
    }

    // MARK: - 不规则变化表
    //
    // 只收**高频且规则推不出来**的那些（`went` / `children` / `better`…）。
    // 规则能推出来的一律不进表：表越长越容易和规则打架，也越难维护。

    /// surface（小写）→ (本体, 名称)。
    private static let irregulars: [String: (lemma: String, label: String)] = [
        // be
        "am": ("be", Label.thirdPerson), "is": ("be", Label.thirdPerson),
        "are": ("be", Label.thirdPerson), "was": ("be", Label.past),
        "were": ("be", Label.past), "been": ("be", Label.past),
        "being": ("be", Label.progressive),
        // have / do / go
        "has": ("have", Label.thirdPerson), "had": ("have", Label.past),
        "having": ("have", Label.progressive),
        "does": ("do", Label.thirdPerson), "did": ("do", Label.past),
        "done": ("do", Label.past), "doing": ("do", Label.progressive),
        "goes": ("go", Label.thirdPerson), "went": ("go", Label.past),
        "gone": ("go", Label.past), "going": ("go", Label.progressive),
        // say / make / take / come / get / give / see / know
        "said": ("say", Label.past), "made": ("make", Label.past),
        "took": ("take", Label.past), "taken": ("take", Label.past),
        "came": ("come", Label.past), "got": ("get", Label.past),
        "gotten": ("get", Label.past), "gave": ("give", Label.past),
        "given": ("give", Label.past), "saw": ("see", Label.past),
        "seen": ("see", Label.past), "knew": ("know", Label.past),
        "known": ("know", Label.past),
        // 高频不规则动词
        "found": ("find", Label.past), "told": ("tell", Label.past),
        "thought": ("think", Label.past), "bought": ("buy", Label.past),
        "brought": ("bring", Label.past), "caught": ("catch", Label.past),
        "taught": ("teach", Label.past), "left": ("leave", Label.past),
        "felt": ("feel", Label.past), "kept": ("keep", Label.past),
        "slept": ("sleep", Label.past), "spent": ("spend", Label.past),
        "stood": ("stand", Label.past), "understood": ("understand", Label.past),
        "met": ("meet", Label.past), "paid": ("pay", Label.past),
        "ran": ("run", Label.past), "sat": ("sit", Label.past),
        "spoke": ("speak", Label.past), "spoken": ("speak", Label.past),
        "wrote": ("write", Label.past), "written": ("write", Label.past),
        "read": ("read", Label.past), "put": ("put", Label.past),
        "meant": ("mean", Label.past), "lost": ("lose", Label.past),
        "held": ("hold", Label.past), "heard": ("hear", Label.past),
        "built": ("build", Label.past), "sent": ("send", Label.past),
        "grew": ("grow", Label.past), "grown": ("grow", Label.past),
        "drew": ("draw", Label.past), "drawn": ("draw", Label.past),
        "fell": ("fall", Label.past), "fallen": ("fall", Label.past),
        "wore": ("wear", Label.past), "worn": ("wear", Label.past),
        "chose": ("choose", Label.past), "chosen": ("choose", Label.past),
        "began": ("begin", Label.past), "begun": ("begin", Label.past),
        "drank": ("drink", Label.past), "drunk": ("drink", Label.past),
        "ate": ("eat", Label.past), "eaten": ("eat", Label.past),
        "flew": ("fly", Label.past), "flown": ("fly", Label.past),
        "forgot": ("forget", Label.past), "forgotten": ("forget", Label.past),
        "rode": ("ride", Label.past), "ridden": ("ride", Label.past),
        "rose": ("rise", Label.past), "risen": ("rise", Label.past),
        "threw": ("throw", Label.past), "thrown": ("throw", Label.past),
        "woke": ("wake", Label.past), "woken": ("wake", Label.past),
        // 不规则复数
        "children": ("child", Label.plural), "men": ("man", Label.plural),
        "women": ("woman", Label.plural), "people": ("person", Label.plural),
        "feet": ("foot", Label.plural), "teeth": ("tooth", Label.plural),
        "geese": ("goose", Label.plural), "mice": ("mouse", Label.plural),
        "oxen": ("ox", Label.plural), "indices": ("index", Label.plural),
        "analyses": ("analysis", Label.plural), "crises": ("crisis", Label.plural),
        "criteria": ("criterion", Label.plural), "phenomena": ("phenomenon", Label.plural),
        "data": ("datum", Label.plural), "media": ("medium", Label.plural),
        // 不规则比较级 / 最高级
        "better": ("good", Label.comparative), "best": ("good", Label.superlative),
        "worse": ("bad", Label.comparative), "worst": ("bad", Label.superlative),
        "more": ("many", Label.comparative), "most": ("many", Label.superlative),
        "less": ("little", Label.comparative), "least": ("little", Label.superlative),
        "further": ("far", Label.comparative), "furthest": ("far", Label.superlative),
        "farther": ("far", Label.comparative), "farthest": ("far", Label.superlative),
    ]

    // MARK: - 规则表

    /// 一条后缀规则：把 surface 变回原形的几种可能写法。
    private struct Rule {
        var suffix: String
        var label: String
        /// 去掉后缀之后要拼回去的尾巴（按可能性排序）。
        var tails: [String]
        /// 结尾是「辅音 + 辅音 + 元音 + 辅音」这种双写情形时，再试一次去掉重复字母的写法。
        var undouble = false
    }

    /// ⚠️ 顺序 = 优先级：更长的后缀排在前面（`-ies` 必须在 `-es` / `-s` 之前，
    /// 否则 `studies` 会先被 `-s` 吃成 `studie`）。
    private static let rules: [Rule] = [
        // 复数 / 第三人称
        Rule(suffix: "ies", label: Label.plural, tails: ["y"]),          // studies → study
        Rule(suffix: "ves", label: Label.plural, tails: ["f", "fe", "ve"]), // leaves → leaf/life
        Rule(suffix: "oes", label: Label.plural, tails: ["o", "oe"]),     // potatoes → potato, shoes → shoe
        Rule(suffix: "es", label: Label.plural, tails: ["", "e"]),        // boxes → box, houses → house
        Rule(suffix: "s", label: Label.plural, tails: ["", "e"]),         // arms → arm
        // 现在分词
        Rule(suffix: "ying", label: Label.progressive, tails: ["ie", ""]), // lying → lie, buying → buy
        Rule(suffix: "ing", label: Label.progressive, tails: ["", "e"], undouble: true),
        // 过去式 / 过去分词
        Rule(suffix: "ied", label: Label.past, tails: ["y"]),             // studied → study
        Rule(suffix: "ed", label: Label.past, tails: ["", "e"], undouble: true),
        // 比较级 / 最高级
        Rule(suffix: "iest", label: Label.superlative, tails: ["y"]),     // happiest → happy
        Rule(suffix: "ier", label: Label.comparative, tails: ["y"]),      // happier → happy
        Rule(suffix: "est", label: Label.superlative, tails: ["", "e"], undouble: true),
        Rule(suffix: "er", label: Label.comparative, tails: ["", "e"], undouble: true),
    ]

    /// 一个词至少要留这么长才可能是本体（`is` → `i` 这类明显是误推）。
    ///
    /// ⚠️ 不能设太大：`running → run` 只有 3 个字母，是**对**的候选；
    /// 所以只挡到 2 个字（`s` → 空、`ing` → 空），再长的都放行。
    private static let minimumLemmaLength = 2

    // MARK: - 对外

    /// 一个表面词形可能的原形，按可能性排序（不规则表在前，规则候选在后）。
    ///
    /// 返回的候选**不保证是真实单词** —— 调用方要么拿去问词库，要么当提示交给模型。
    public static func candidates(of surface: String) -> [Candidate] {
        let word = surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !word.isEmpty else { return [] }
        // 已经带空白 = 短语，不还原（`look after` 没有「原形」这回事）。
        guard !word.contains(where: { $0.isWhitespace }) else { return [] }
        // 连字符词（`state-of-the-art`）只还原最后一段，前缀原样拼回去。
        if let last = word.split(separator: "-").last.map(String.init), last != word,
           let range = word.range(of: last, options: .backwards) {
            let prefix = String(word[word.startIndex..<range.lowerBound])
            return candidates(of: last).map {
                Candidate(lemma: prefix + $0.lemma, label: $0.label)
            }
        }

        var result: [Candidate] = []
        var seen = Set<String>([word])
        func push(_ lemma: String, _ label: String) {
            let clean = lemma.trimmingCharacters(in: .whitespaces)
            guard clean.count >= minimumLemmaLength, seen.insert(clean).inserted else { return }
            result.append(Candidate(lemma: clean, label: label))
        }

        // ① 不规则：权威，排最前。**放在长度门槛之前** —— `is` / `am` 只有两个字母，
        //    先过长度判断的话它们会被直接丢掉。
        if let entry = irregulars[word] { push(entry.lemma, entry.label) }

        // ② 规则（两个字母的词不套规则：「as」减掉 s 只剩「a」，纯属噪音）。
        guard word.count >= 3 else { return result }

        for rule in rules where word.hasSuffix(rule.suffix) && word.count > rule.suffix.count {
            let stem = String(word.dropLast(rule.suffix.count))
            for tail in rule.tails { push(stem + tail, rule.label) }
            // 双写：`running` → `runn` → `run`。判据是「末尾两个相同的辅音 + 它前面是元音」，
            // 少了元音那一问，`session` 这种词干会被误还原成 `ses`。
            if rule.undouble, stem.count >= 3 {
                let characters = Array(stem)
                let last = characters[characters.count - 1]
                let previous = characters[characters.count - 2]
                let beforePrevious = characters[characters.count - 3]
                if last == previous, !isVowel(last), isVowel(beforePrevious) {
                    push(String(characters.dropLast()), rule.label)
                }
            }
        }
        return result
    }

    /// 已知 surface 与它的本体，倒推语法名称（拿不到就 nil）。
    ///
    /// 模型回的原形有时不在我们的规则里（它自己判断的），这时照实说「是这个的另一种形式」
    /// 就行，不硬编一个名称 —— 编错了比不说更糟。
    public static func label(surface: String, lemma: String) -> String? {
        let target = lemma.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return nil }
        return candidates(of: surface).first { $0.lemma == target }?.label
    }

    private static func isVowel(_ character: Character) -> Bool {
        "aeiou".contains(character)
    }
}
