import Foundation

// MARK: - 音素级发音评测（推断通道，纯函数）
//
// 设计依据：Implementation Plan §23「Pronunciation Engine」、PRD §12.1。
//
// 这条通道**不依赖任何发音模型**，也不假装自己听得见音素：
// 它拿「参考句」与「ASR 识别结果」各自的音素序列做**音素级加权对齐**，
// 用发音特征距离判断「某个音是彻底念错，还是只是发音部位差一点」。
//
// 因此它给出的分数是**推断**（`isEstimated`），绝不冒充声学实测；
// 真正的声学打分走 `PronunciationProvider`（云端 Azure 发音评估）。
// 两条通道在 `PronunciationService` 汇合，报告里标明来源。
//
// 本文件全是纯函数与纯数据：不碰模型、不碰 IO、不碰 UI，可脱机单测。

/// 音素词库：`word -> [ARPAbet]`。
///
/// 数据来自 `Resources/Pronunciation/lexicon.json`（由 CMUdict 派生，
/// 只收录本项目素材里出现的词），**加载由 AIInfrastructure 负责**，
/// 领域层只消费字典本身 —— 因此这里不依赖任何资源系统。
public struct PhonemeLexicon: Sendable, Equatable {

    /// 空词库：所有词都退化成规则 G2P。
    public static let empty = PhonemeLexicon(words: [:])

    private let words: [String: [String]]

    public init(words: [String: [String]]) {
        self.words = words
    }

    public var count: Int { words.count }

    /// 查一个词的音素序列；查不到返回 nil（由调用方决定是否走规则 G2P）。
    public func phonemes(for word: String) -> [String]? {
        let key = Self.normalized(word)
        guard !key.isEmpty else { return nil }
        if let hit = words[key] { return hit }
        // 所有格 / 缩写：`learner's` -> `learner`
        if key.hasSuffix("'s"), let hit = words[String(key.dropLast(2))] { return hit + ["Z"] }
        if key.hasSuffix("'"), let hit = words[String(key.dropLast())] { return hit }
        return nil
    }

    /// 查词键：小写、去掉首尾非字母（`"Hello,"` -> `hello`）。
    public static func normalized(_ word: String) -> String {
        var scalars = word.lowercased()
        while let first = scalars.first, !first.isLetter { scalars.removeFirst() }
        while let last = scalars.last, !last.isLetter { scalars.removeLast() }
        return scalars
    }
}

// MARK: - 规则 G2P（词库未收录时的兜底）

/// 英文拼写 → 音素的规则引擎。
///
/// **定位是兜底**：词库命中时一律以词库为准（那才是权威发音）。
/// 只有词库没有的词才走到这里，因此规则只求「大差不差」——
/// 目的是让对齐还能进行，而不是产出可以信以为真的发音。
public enum EnglishG2P {

    /// 不规则高频词（规则引擎最容易翻车的那些）。
    private static let irregulars: [String: [String]] = [
        "the": ["DH", "AH0"], "a": ["AH0"], "an": ["AE1", "N"],
        "one": ["W", "AH1", "N"], "two": ["T", "UW1"], "once": ["W", "AH1", "N", "S"],
        "who": ["HH", "UW1"], "what": ["W", "AH1", "T"], "where": ["W", "EH1", "R"],
        "there": ["DH", "EH1", "R"], "their": ["DH", "EH1", "R"], "here": ["HH", "IY1", "R"],
        "sure": ["SH", "UH1", "R"], "said": ["S", "EH1", "D"], "says": ["S", "EH1", "Z"],
        "have": ["HH", "AE1", "V"], "has": ["HH", "AE1", "Z"], "give": ["G", "IH1", "V"],
        "live": ["L", "IH1", "V"], "love": ["L", "AH1", "V"], "come": ["K", "AH1", "M"],
        "some": ["S", "AH1", "M"], "done": ["D", "AH1", "N"], "none": ["N", "AH1", "N"],
        "does": ["D", "AH1", "Z"], "go": ["G", "OW1"], "do": ["D", "UW1"],
        "to": ["T", "UW1"], "of": ["AH1", "V"], "off": ["AO1", "F"],
        "would": ["W", "UH1", "D"], "could": ["K", "UH1", "D"], "should": ["SH", "UH1", "D"],
        "you": ["Y", "UW1"], "your": ["Y", "AO1", "R"], "are": ["AA1", "R"],
        "was": ["W", "AH1", "Z"], "were": ["W", "ER1"], "is": ["IH1", "Z"],
        "as": ["AE1", "Z"], "his": ["HH", "IH1", "Z"], "this": ["DH", "IH1", "S"],
        "with": ["W", "IH1", "DH"], "from": ["F", "R", "AH1", "M"],
        "many": ["M", "EH1", "N", "IY0"], "any": ["EH1", "N", "IY0"],
        "again": ["AH0", "G", "EH1", "N"], "very": ["V", "EH1", "R", "IY0"],
        "water": ["W", "AO1", "T", "ER0"], "word": ["W", "ER1", "D"],
        "work": ["W", "ER1", "K"], "world": ["W", "ER1", "L", "D"],
        "beautiful": ["B", "Y", "UW1", "T", "AH0", "F", "AH0", "L"],
        "people": ["P", "IY1", "P", "AH0", "L"], "little": ["L", "IH1", "T", "AH0", "L"],
        "through": ["TH", "R", "UW1"], "though": ["DH", "OW1"], "thought": ["TH", "AO1", "T"],
        "enough": ["IH0", "N", "AH1", "F"], "laugh": ["L", "AE1", "F"],
        "food": ["F", "UW1", "D"], "good": ["G", "UH1", "D"], "blood": ["B", "L", "AH1", "D"],
        "break": ["B", "R", "EY1", "K"], "great": ["G", "R", "EY1", "T"],
        "friend": ["F", "R", "EH1", "N", "D"], "find": ["F", "AY1", "N", "D"],
        "climb": ["K", "L", "AY1", "M"], "listen": ["L", "IH1", "S", "AH0", "N"],
        "answer": ["AE1", "N", "S", "ER0"], "question": ["K", "W", "EH1", "S", "CH", "AH0", "N"],
        "photo": ["F", "OW1", "T", "OW0"], "phone": ["F", "OW1", "N"],
    ]

    /// 多字母组合 → 音素（按优先级从长到短尝试）。
    private static let clusters: [(pattern: String, phonemes: [String])] = [
        ("ough", ["AO1", "F"]),
        ("augh", ["AE1", "F"]),
        ("eigh", ["EY1"]),
        ("igh", ["AY1"]),
        ("tion", ["SH", "AH0", "N"]),
        ("sion", ["ZH", "AH0", "N"]),
        ("ture", ["CH", "ER0"]),
        ("cial", ["SH", "AH0", "L"]),
        ("tial", ["SH", "AH0", "L"]),
        ("cious", ["SH", "AH0", "S"]),
        ("ought", ["AO1", "T"]),
        ("ch", ["CH"]), ("sh", ["SH"]), ("th", ["TH"]), ("ph", ["F"]),
        ("wh", ["W"]), ("ck", ["K"]), ("kn", ["N"]), ("wr", ["R"]),
        ("gh", ["G"]), ("gn", ["N"]), ("mb", ["M"]), ("ng", ["NG"]),
        ("qu", ["K", "W"]), ("ck", ["K"]), ("ss", ["S"]), ("ll", ["L"]),
        ("ff", ["F"]), ("tt", ["T"]), ("pp", ["P"]), ("rr", ["R"]),
        ("ee", ["IY1"]), ("ea", ["IY1"]), ("ai", ["EY1"]), ("ay", ["EY1"]),
        ("oa", ["OW1"]), ("oo", ["UW1"]), ("ou", ["AW1"]), ("ow", ["OW1"]),
        ("oi", ["OY1"]), ("oy", ["OY1"]), ("au", ["AO1"]), ("aw", ["AO1"]),
        ("ie", ["IY1"]), ("ei", ["EY1"]), ("ue", ["UW1"]), ("ui", ["UW1"]),
        ("ar", ["AA1", "R"]), ("er", ["ER1"]), ("ir", ["ER1"]),
        ("or", ["AO1", "R"]), ("ur", ["ER1"]),
    ]

    private static let singleConsonants: [Character: [String]] = [
        "b": ["B"], "c": ["K"], "d": ["D"], "f": ["F"], "g": ["G"], "h": ["HH"],
        "j": ["JH"], "k": ["K"], "l": ["L"], "m": ["M"], "n": ["N"], "p": ["P"],
        "q": ["K"], "r": ["R"], "s": ["S"], "t": ["T"], "v": ["V"], "w": ["W"],
        "x": ["K", "S"], "z": ["Z"],
    ]

    private static let singleVowels: [Character: [String]] = [
        "a": ["AE1"], "e": ["EH1"], "i": ["IH1"], "o": ["AA1"], "u": ["AH1"], "y": ["IH1"],
    ]

    /// 一组词 → 全部音素（含词间无停顿标记；调用方按词分组）。
    public static func phonemes(for word: String) -> [String] {
        let key = PhonemeLexicon.normalized(word)
        guard !key.isEmpty else { return [] }
        if let hit = irregulars[key] { return hit }

        let letters = Array(key)
        var result: [String] = []
        var index = 0
        var vowelSeen = false

        while index < letters.count {
            let rest = String(letters[index...])

            // 1) 词首不发音组合：knife / write / phone-digraph 等
            if index == 0, let cluster = clusters.first(where: { rest.hasPrefix($0.pattern) && ["kn", "wr", "gn", "wh"].contains($0.pattern) }) {
                result.append(contentsOf: cluster.phonemes)
                index += cluster.pattern.count
                continue
            }
            // 2) 结尾的哑 `e`：make / time / hope（前面有元音且不是唯一字母）
            if rest == "e", letters.count > 2, vowelSeen {
                index += 1
                continue
            }
            // 3) 元音 + 辅音 + 哑 e：拉长音（name / bike / note / cute）
            if index + 2 < letters.count,
               let vowel = singleVowels[letters[index]],
               singleConsonants[letters[index + 1]] != nil,
               letters[index + 2] == "e",
               index + 3 == letters.count {
                result.append(contentsOf: lengthened(vowel))
                index += 3
                continue
            }
            // 4) 多字母组合（优先长的）
            if let cluster = clusters.first(where: { rest.hasPrefix($0.pattern) }) {
                result.append(contentsOf: cluster.phonemes)
                vowelSeen = vowelSeen || singleVowels[letters[index]] != nil
                index += cluster.pattern.count
                continue
            }
            // 5) 单字母
            let letter = letters[index]
            if let consonant = singleConsonants[letter] {
                // `c` 在 e/i/y 前读 /s/，在别处读 /k/
                if letter == "c", index + 1 < letters.count, "eiy".contains(letters[index + 1]) {
                    result.append("S")
                } else if letter == "g", index + 1 < letters.count, "eiy".contains(letters[index + 1]) {
                    result.append("JH")
                } else {
                    result.append(contentsOf: consonant)
                }
            } else if let vowel = singleVowels[letter] {
                // 词尾 `y` 常读 /i/
                if letter == "y", index == letters.count - 1, index > 0 { result.append("IY0") }
                else { result.append(contentsOf: vowel) }
                vowelSeen = true
            }
            index += 1
        }
        return result
    }

    /// 单字母元音在「辅音 + 哑 e」结构里的长音形式。
    ///
    /// ⚠️ 不看后面的辅音字母：ARPAbet 音标里长音已经由元音符号本身标出来了
    /// （`AE1 → EY1` 这类映射是固定的），拿它再判一次只会多一个用不上的入参。
    private static func lengthened(_ vowel: [String]) -> [String] {
        switch vowel.first {
        case "AE1": ["EY1"]
        case "EH1": ["IY1"]
        case "IH1": ["AY1"]
        case "AA1": ["OW1"]
        case "AH1": ["Y", "UW1"]
        default: vowel
        }
    }
}

// MARK: - 音素特征与距离

/// 音素的发音特征。用来回答「这个音是彻底不对，还是只差一点」。
enum PhonemeFeatures {

    struct Vowel {
        var height: Int   // 1（低）… 5（高）
        var backness: Int // 1（前）… 3（后）
        var rounded: Int  // 0 / 1
    }

    struct Consonant {
        var voiced: Int   // 0 / 1
        var manner: Int   // 1 塞音 2 塞擦 3 擦音 4 鼻音 5 近音
        var place: Int    // 1 双唇 … 8 喉
    }

    /// 去重音后的基音素（`ER1` -> `ER`）。
    static func base(_ phoneme: String) -> String {
        let trimmed = phoneme.trimmingCharacters(in: CharacterSet(charactersIn: "012"))
        return trimmed.isEmpty ? phoneme : trimmed
    }

    static func stress(_ phoneme: String) -> Int? {
        phoneme.last.flatMap { $0.wholeNumberValue }
    }

    static let vowels: [String: Vowel] = [
        "AA": Vowel(height: 1, backness: 3, rounded: 0),
        "AE": Vowel(height: 2, backness: 1, rounded: 0),
        "AH": Vowel(height: 3, backness: 2, rounded: 0),
        "AO": Vowel(height: 2, backness: 3, rounded: 1),
        "AW": Vowel(height: 2, backness: 3, rounded: 1),
        "AY": Vowel(height: 2, backness: 1, rounded: 0),
        "EH": Vowel(height: 3, backness: 1, rounded: 0),
        "ER": Vowel(height: 3, backness: 2, rounded: 1),
        "EY": Vowel(height: 3, backness: 1, rounded: 0),
        "IH": Vowel(height: 4, backness: 1, rounded: 0),
        "IY": Vowel(height: 5, backness: 1, rounded: 0),
        "OW": Vowel(height: 3, backness: 3, rounded: 1),
        "OY": Vowel(height: 2, backness: 3, rounded: 1),
        "UH": Vowel(height: 4, backness: 3, rounded: 1),
        "UW": Vowel(height: 5, backness: 3, rounded: 1),
    ]

    static let consonants: [String: Consonant] = [
        "P": Consonant(voiced: 0, manner: 1, place: 1),
        "B": Consonant(voiced: 1, manner: 1, place: 1),
        "F": Consonant(voiced: 0, manner: 3, place: 2),
        "V": Consonant(voiced: 1, manner: 3, place: 2),
        "TH": Consonant(voiced: 0, manner: 3, place: 3),
        "DH": Consonant(voiced: 1, manner: 3, place: 3),
        "T": Consonant(voiced: 0, manner: 1, place: 4),
        "D": Consonant(voiced: 1, manner: 1, place: 4),
        "S": Consonant(voiced: 0, manner: 3, place: 4),
        "Z": Consonant(voiced: 1, manner: 3, place: 4),
        "SH": Consonant(voiced: 0, manner: 3, place: 5),
        "ZH": Consonant(voiced: 1, manner: 3, place: 5),
        "CH": Consonant(voiced: 0, manner: 2, place: 5),
        "JH": Consonant(voiced: 1, manner: 2, place: 5),
        "K": Consonant(voiced: 0, manner: 1, place: 7),
        "G": Consonant(voiced: 1, manner: 1, place: 7),
        "M": Consonant(voiced: 1, manner: 4, place: 1),
        "N": Consonant(voiced: 1, manner: 4, place: 4),
        "NG": Consonant(voiced: 1, manner: 4, place: 7),
        "L": Consonant(voiced: 1, manner: 5, place: 4),
        "R": Consonant(voiced: 1, manner: 5, place: 4),
        "W": Consonant(voiced: 1, manner: 5, place: 1),
        "Y": Consonant(voiced: 1, manner: 5, place: 6),
        "HH": Consonant(voiced: 0, manner: 3, place: 8),
    ]

    /// 两个音素的发音距离 0...1（0 = 完全同一个音，1 = 毫不相干）。
    static func distance(_ lhs: String, _ rhs: String) -> Double {
        let a = base(lhs)
        let b = base(rhs)
        if a == b { return 0 }

        if let va = vowels[a], let vb = vowels[b] {
            let height = Double(abs(va.height - vb.height)) / 4
            let back = Double(abs(va.backness - vb.backness)) / 2
            let round = Double(abs(va.rounded - vb.rounded))
            return min(height * 0.5 + back * 0.35 + round * 0.15, 1)
        }
        if let ca = consonants[a], let cb = consonants[b] {
            let voiced = Double(abs(ca.voiced - cb.voiced))
            let manner = Double(abs(ca.manner - cb.manner)) / 4
            let place = Double(abs(ca.place - cb.place)) / 7
            return min(voiced * 0.30 + manner * 0.40 + place * 0.30, 1)
        }
        // 元音 vs 辅音：性质完全不同。
        return 1
    }
}

// MARK: - 展示层映射（领域给数据，UI 只渲染）

/// 单个音素的判定档位。
public enum PhonemeMark: String, Sendable, Equatable, CaseIterable {
    /// 准（✓）。
    case good
    /// 偏差（△）。
    case fair
    /// 不对（✗）。
    case poor

    public var symbol: String {
        switch self {
        case .good: "✓"
        case .fair: "△"
        case .poor: "✗"
        }
    }

    /// 由分数定档，阈值集中在这里，UI 不重复判断。
    public static func from(score: Double) -> PhonemeMark {
        if score >= 0.85 { return .good }
        if score >= 0.5 { return .fair }
        return .poor
    }
}

/// ARPAbet ↔ 展示用 IPA。
public enum PhonemeDisplay {

    private static let ipa: [String: String] = [
        "AA": "ɑ", "AE": "æ", "AH": "ʌ", "AO": "ɔ", "AW": "aʊ", "AY": "aɪ",
        "EH": "e", "ER": "ɝ", "EY": "eɪ", "IH": "ɪ", "IY": "i", "OW": "oʊ",
        "OY": "ɔɪ", "UH": "ʊ", "UW": "u",
        "B": "b", "CH": "tʃ", "D": "d", "DH": "ð", "F": "f", "G": "ɡ", "HH": "h",
        "JH": "dʒ", "K": "k", "L": "l", "M": "m", "N": "n", "NG": "ŋ", "P": "p",
        "R": "ɹ", "S": "s", "SH": "ʃ", "T": "t", "TH": "θ", "V": "v", "W": "w",
        "Y": "j", "Z": "z", "ZH": "ʒ",
    ]

    /// 音素 → IPA 符号（丢掉重音数字；重音另由 `showsStress` 提示）。
    public static func ipa(for phoneme: String) -> String {
        ipa[PhonemeFeatures.base(phoneme)] ?? phoneme
    }

    /// 是否主重音（ARPAbet 的 `1`）。
    public static func isStressed(_ phoneme: String) -> Bool {
        PhonemeFeatures.stress(phoneme) == 1
    }
}

// MARK: - 逐词评估结果

/// 一个词的音素级评估（UI 直接渲染成一行音素条）。
public struct PhonemeWordAssessment: Codable, Sendable, Equatable, Identifiable {

    public enum Status: String, Codable, Sendable, Equatable {
        /// 参考词与识别词配上对，逐音素比过。
        case aligned
        /// 这个词学员没读（整词丢失）。
        case missing
        /// 学员多说的词（参考句里没有），不产生音素条。
        case extra
    }

    public var word: String
    /// 逐音素得分（`PhonemeRating.phoneme` 为 ARPAbet）。
    public var phonemes: [PhonemeRating]
    /// 词级得分 0...1。
    public var score: Double
    public var status: Status

    public var id: String { "\(word)-\(status.rawValue)" }

    public init(word: String, phonemes: [PhonemeRating], score: Double, status: Status) {
        self.word = word
        self.phonemes = phonemes
        self.score = min(max(score, 0), 1)
        self.status = status
    }

    public var scorePercent: Int { Int((score * 100).rounded()) }
}

// MARK: - 评测主体

/// 推断式音素评测：参考句 vs 识别结果。
public enum PhonemeAssessment {

    /// 词级配对的最低相似度：低于它宁可当成「漏读 + 多说」两个独立事件，
    /// 也不要硬把两个无关的词配在一起（那会凭空造出一堆错音）。
    public static let minWordSimilarity = 0.35
    /// 词级对齐的空位罚分。
    public static let gapPenalty = -0.32
    /// 多出来的音素对词分的扣减（每个），以及封顶。
    public static let insertionPenalty = 0.03
    public static let maxInsertionPenalty = 0.15

    /// 一次评估：把参考句与识别结果都切成词，配对后逐音素打分。
    ///
    /// - Returns: 按参考句顺序排列的逐词结果（多说的词追加在末尾）。
    public static func assess(
        reference: String,
        recognized: String,
        lexicon: PhonemeLexicon = .empty
    ) -> [PhonemeWordAssessment] {
        let referenceWords = words(reference)
        guard !referenceWords.isEmpty else { return [] }
        let recognizedWords = words(recognized)

        let pairs = alignWords(
            reference: referenceWords.map { phonemes(of: $0, lexicon: lexicon) },
            hypothesis: recognizedWords.map { phonemes(of: $0, lexicon: lexicon) }
        )

        var results: [PhonemeWordAssessment] = []
        for pair in pairs {
            switch pair {
            case let .pair(refIndex, hypIndex):
                results.append(
                    paired(
                        word: referenceWords[refIndex],
                        reference: phonemes(of: referenceWords[refIndex], lexicon: lexicon),
                        recognized: phonemes(of: recognizedWords[hypIndex], lexicon: lexicon)
                    )
                )
            case let .referenceOnly(refIndex):
                let word = referenceWords[refIndex]
                results.append(
                    PhonemeWordAssessment(
                        word: word,
                        phonemes: phonemes(of: word, lexicon: lexicon).map {
                            PhonemeRating(phoneme: $0, score: 0)
                        },
                        score: 0,
                        status: .missing
                    )
                )
            case let .hypothesisOnly(hypIndex):
                results.append(
                    PhonemeWordAssessment(
                        word: recognizedWords[hypIndex], phonemes: [], score: 0, status: .extra
                    )
                )
            }
        }
        return results
    }

    /// 对齐后所有音素的扁平序列（喂给 `PronunciationScorer` 的「音准」维度）。
    public static func flatRatings(_ words: [PhonemeWordAssessment]) -> [PhonemeRating] {
        words.filter { $0.status != .extra }.flatMap(\.phonemes)
    }

    /// 音准平均分 0...1（没有可评音素时返回 nil）。
    public static func averageScore(_ words: [PhonemeWordAssessment]) -> Double? {
        let ratings = flatRatings(words)
        guard !ratings.isEmpty else { return nil }
        return ratings.map(\.score).reduce(0, +) / Double(ratings.count)
    }

    // MARK: - 内部

    /// 取一个词的音素序列：词库优先，规则兜底。
    static func phonemes(of word: String, lexicon: PhonemeLexicon) -> [String] {
        if let hit = lexicon.phonemes(for: word) { return hit }
        return EnglishG2P.phonemes(for: word)
    }

    /// 切词：只保留含字母的词（与跟读页同一口径）。
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map { token -> String in
                var scalars = String(token)
                while let first = scalars.first, !first.isLetter { scalars.removeFirst() }
                while let last = scalars.last, !last.isLetter { scalars.removeLast() }
                return scalars
            }
            .filter { !$0.isEmpty }
    }

    enum WordPair: Equatable {
        case pair(Int, Int)
        case referenceOnly(Int)
        case hypothesisOnly(Int)
    }

    /// 词级序列对齐（Needleman–Wunsch，按音素相似度给分）。
    ///
    /// 用相似度而不是「是否同一个词」：跟读场景里学员念错一个音时，
    /// 识别结果往往就是另一个词（world → word），那正是要打分的点。
    static func alignWords(reference: [[String]], hypothesis: [[String]]) -> [WordPair] {
        let n = reference.count
        let m = hypothesis.count
        guard n > 0 else { return (0..<m).map { .hypothesisOnly($0) } }
        guard m > 0 else { return (0..<n).map { .referenceOnly($0) } }

        var score = Array(repeating: Array(repeating: 0.0, count: m + 1), count: n + 1)
        for i in 1...n { score[i][0] = score[i - 1][0] + gapPenalty }
        for j in 1...m { score[0][j] = score[0][j - 1] + gapPenalty }

        for i in 1...n {
            for j in 1...m {
                let similarity = wordSimilarity(reference[i - 1], hypothesis[j - 1])
                let diagonal = score[i - 1][j - 1] + (similarity >= minWordSimilarity ? similarity : similarity + gapPenalty * 2)
                let up = score[i - 1][j] + gapPenalty
                let left = score[i][j - 1] + gapPenalty
                score[i][j] = max(diagonal, up, left)
            }
        }

        var pairs: [WordPair] = []
        var i = n
        var j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0 {
                let similarity = wordSimilarity(reference[i - 1], hypothesis[j - 1])
                let diagonal = score[i - 1][j - 1] + (similarity >= minWordSimilarity ? similarity : similarity + gapPenalty * 2)
                if abs(score[i][j] - diagonal) < 1e-9 {
                    pairs.append(.pair(i - 1, j - 1))
                    i -= 1
                    j -= 1
                    continue
                }
            }
            if i > 0, j == 0 || score[i][j] - (score[i - 1][j] + gapPenalty) < 1e-9 {
                pairs.append(.referenceOnly(i - 1))
                i -= 1
                continue
            }
            pairs.append(.hypothesisOnly(j - 1))
            j -= 1
        }
        return pairs.reversed()
    }

    /// 词与词的相似度 0...1 = 1 − 归一化音素编辑距离。
    static func wordSimilarity(_ lhs: [String], _ rhs: [String]) -> Double {
        if lhs.isEmpty || rhs.isEmpty { return 0 }
        let distance = phonemeDistance(lhs, rhs)
        return 1 - min(distance / Double(max(lhs.count, rhs.count)), 1)
    }

    /// 音素级加权编辑距离（替换代价 = 发音特征距离）。
    static func phonemeDistance(_ lhs: [String], _ rhs: [String]) -> Double {
        // 空序列早退：否则下面的双重循环会越界（`1...0` 不是合法区间，`current[0]` 也没处落）。
        if lhs.isEmpty { return Double(rhs.count) }
        if rhs.isEmpty { return Double(lhs.count) }

        var previous = (0...rhs.count).map { Double($0) }
        var current = Array(repeating: 0.0, count: rhs.count + 1)
        for i in 1...lhs.count {
            current[0] = Double(i)
            for j in 1...rhs.count {
                let substitution = previous[j - 1] + PhonemeFeatures.distance(lhs[i - 1], rhs[j - 1])
                let deletion = previous[j] + 1
                let insertion = current[j - 1] + 1
                current[j] = min(substitution, deletion, insertion)
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }

    /// 配上对的两个词的逐音素打分。
    ///
    /// ⚠️ 必须走**动态规划**而不是逐个位置贪心（2026-09-15 修正）：
    /// 贪心在 `world → word` 上会把「/l/ 被吞掉 + /d/ 读对」误判成
    /// 「/l/ 念错成 /d/ + 末尾 /d/ 没念」——既冤枉了读对的音，又指错了要复读的音。
    /// 全局最优的对齐会正确地判成「删 /l/、留 /d/」。
    static func paired(word: String, reference: [String], recognized: [String]) -> PhonemeWordAssessment {
        guard !reference.isEmpty else {
            return PhonemeWordAssessment(word: word, phonemes: [], score: 0, status: .aligned)
        }
        guard !recognized.isEmpty else {
            return PhonemeWordAssessment(
                word: word,
                phonemes: reference.map { PhonemeRating(phoneme: $0, score: 0) },
                score: 0, status: .aligned
            )
        }

        let n = reference.count
        let m = recognized.count
        var cost = Array(repeating: Array(repeating: 0.0, count: m + 1), count: n + 1)
        for i in 1...n { cost[i][0] = Double(i) }
        for j in 1...m { cost[0][j] = Double(j) }
        for i in 1...n {
            for j in 1...m {
                cost[i][j] = min(
                    cost[i - 1][j - 1] + PhonemeFeatures.distance(reference[i - 1], recognized[j - 1]),
                    cost[i - 1][j] + 1,
                    cost[i][j - 1] + 1
                )
            }
        }

        var ratings: [PhonemeRating] = []
        var insertions = 0
        var i = n
        var j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0 {
                let substitution = PhonemeFeatures.distance(reference[i - 1], recognized[j - 1])
                // 同分时优先「替换」：能对上就别判成漏读，否则会把读对的音记成 0 分。
                if abs(cost[i][j] - (cost[i - 1][j - 1] + substitution)) < 1e-9 {
                    let target = reference[i - 1]
                    let said = recognized[j - 1]
                    if substitution == 0 {
                        let sameStress = PhonemeFeatures.stress(target) == PhonemeFeatures.stress(said)
                        ratings.append(PhonemeRating(phoneme: target, score: sameStress ? 1 : 0.85))
                    } else {
                        // 替换：特征越远分越低，但不给 0（念错了 ≠ 没念）。
                        let substitutionScore = min(max(1 - substitution * 1.15, 0.1), 0.78)
                        ratings.append(PhonemeRating(phoneme: target, score: substitutionScore))
                    }
                    i -= 1
                    j -= 1
                    continue
                }
            }
            if i > 0, j == 0 || cost[i][j] - (cost[i - 1][j] + 1) < 1e-9 {
                // 参考里有、学员没发这个音：这一位就是 0 分。
                ratings.append(PhonemeRating(phoneme: reference[i - 1], score: 0))
                i -= 1
                continue
            }
            // 学员多发的音：不产生音素条，只轻微扣词分。
            insertions += 1
            j -= 1
        }

        ratings.reverse()
        let base = ratings.isEmpty ? 0 : ratings.map(\.score).reduce(0, +) / Double(ratings.count)
        let penalty = min(Double(insertions) * insertionPenalty, maxInsertionPenalty)
        return PhonemeWordAssessment(
            word: word, phonemes: ratings, score: max(base - penalty, 0), status: .aligned
        )
    }
}
