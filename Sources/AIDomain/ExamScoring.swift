import Foundation

/// 分数刻度：0–9，半步（与雅思 band 同量纲）。
///
/// ⚠️ **同量纲不等于官方评分**。这一套是我们按「流利 / 词汇 / 语法 / 任务完成」的
/// 可量化指标折出来的**参考分**，用于让学员看到自己的相对位置与改进方向。
public struct ExamBand: Codable, Sendable, Equatable, Comparable {
    public let value: Double

    public init(_ raw: Double) {
        let clamped = min(max(raw, 0), 9)
        value = (clamped * 2).rounded() / 2
    }

    public static func < (lhs: ExamBand, rhs: ExamBand) -> Bool { lhs.value < rhs.value }

    /// `6.5` / `7`（整数不显示小数点）。
    public var displayName: String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// 评分维度。顺序即展示顺序。
public enum ExamDimension: String, Codable, Sendable, Equatable, CaseIterable, Identifiable {
    /// 流利与连贯：语速、填充词。
    case fluency
    /// 词汇：内容词多样性。
    case lexical
    /// 语法：句长、从句比例、错误密度。
    case grammar
    /// 任务完成：答没答完、答够没有。
    case taskCompletion
    /// 发音：**只在拿到真实评测结果时才出现**（见 `ExamScoring.report`）。
    case pronunciation

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fluency: "流利与连贯"
        case .lexical: "词汇"
        case .grammar: "语法"
        case .taskCompletion: "任务完成"
        case .pronunciation: "发音"
        }
    }

    /// 该维度的依据来自「测量」还是「文本代理指标」。
    ///
    /// 这条信息必须能透出：语速与填充词是从真实时长/文本里量出来的，
    /// 而词汇多样性只是文本代理指标 —— 两者混在一起展示，用户会以为都同等可信。
    public var isMeasured: Bool {
        switch self {
        case .pronunciation, .fluency: true
        case .lexical, .grammar, .taskCompletion: false
        }
    }
}

// MARK: - 原始指标

/// 全场的原始指标。**报告里必须带上它们** —— 分数是这些数的结论，结论不给依据没法核对。
public struct ExamMetrics: Sendable, Equatable {
    public struct QuestionLength: Sendable, Equatable {
        public let questionNumber: Int
        public let words: Int
    }

    public let answeredCount: Int
    public let questionCount: Int
    public let totalWords: Int
    public let speakingSeconds: Int
    /// 每分钟词数（总词数 / 总时长）。总时长为 0 时为 0。
    public let wordsPerMinute: Double
    /// 填充词（um / uh / you know…）占**全部词**的比例。
    public let fillerRatio: Double
    /// 内容词去重比例（unique content words / content words）。
    public let contentTypeTokenRatio: Double
    public let averageSentenceWords: Double
    /// 含从句标记的句子比例。
    public let clauseSentenceRatio: Double
    /// 每个作答平均错误数。**nil = 没有这一路数据**（不是零错误）。
    public let errorsPerAnswer: Double?
    /// 最短的一次作答。
    public let shortestAnswer: QuestionLength?
    /// 少于环节期望词数的那些问题编号。
    public let undersizedQuestions: [Int]

    public var hasAnyData: Bool { answeredCount > 0 }
}

/// 一个维度的得分 + 依据。
public struct ExamScore: Sendable, Equatable {
    public let dimension: ExamDimension
    public let band: ExamBand
    /// 一句话依据，**由真实数字生成**（不允许写没有依据的评语）。
    public let evidence: String
}

/// 考后报告。与课程体系的星星 / 判定卡完全无关。
public struct ExamReport: Sendable, Equatable {
    public let title: String
    public let metrics: ExamMetrics
    /// 只在有分数的维度上出现；顺序按 `ExamDimension.allCases`。
    public let scores: [ExamScore]
    /// 各维度均值。没有任何维度时为 nil（没考就没分，不编一个 0）。
    public let overall: ExamBand?
    /// 做得好的地方（每条都带数字）。
    public let highlights: [String]
    /// 可以改进的地方（每条都带数字）。
    public let improvements: [String]
    /// 是否每一问都答了。
    public let isComplete: Bool

    public func score(for dimension: ExamDimension) -> ExamScore? {
        scores.first { $0.dimension == dimension }
    }
}

// MARK: - 指标与评分（纯函数）

/// 考试评分：**全部是确定性纯函数**，不调模型、不发请求。
///
/// 分数曲线一律写成「锚点 + 线性插值」而不是散落的 `if`：
/// 锚点能一眼看出「什么算 6 分」，也能被单测逐点钉住；散落的 `if` 改一处错一处。
///
/// ⚠️ 三个维度（词汇 / 语法 / 任务完成）是**文本代理指标**，不是实测能力。
/// 报告里每一项都带 `evidence` 与 `ExamDimension.isMeasured`，就是为了不把
/// 代理指标说成实测。
public enum ExamScoring {

    // MARK: 文本工具

    /// 词数：按空白切分。中英混排时英文词数照旧可用（中文会各算一个「词」，
    /// 这是刻意的粗略处理 —— 考试模式的目标语言是英语）。
    public static func wordCount(of text: String) -> Int {
        tokens(text).count
    }

    /// 切词：小写、只留字母与词内撇号（`don't` 算一个词）。
    public static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0 == "'") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    /// 拆句：按 `.` `?` `!` 与换行切，丢掉空句。
    public static func sentences(_ text: String) -> [String] {
        text.split { "。．.?!\n".contains($0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 内容词 = 去掉虚词后的词。
    ///
    /// ⚠️ 这张虚词表**只为指标服务**（算用词多样性时把 always/the/of 这类噪声去掉），
    /// 不是词典的词表真源 —— 那份真源在词典构建脚本里，两者用途不同，别互相覆盖。
    public static func contentWords(_ text: String) -> [String] {
        tokens(text).filter { !functionWords.contains($0) }
    }

    /// 填充词（只收「一定是填充」的：`like` 不收 —— 它是正经单词，收了会冤枉人）。
    static let fillerWords: Set<String> = ["um", "uh", "er", "erm", "ah", "hmm", "mm", "mmm"]
    static let fillerPhrases = ["you know", "i mean", "kind of", "sort of"]

    static let clauseMarkers: Set<String> = [
        "because", "although", "though", "while", "whereas", "which", "who", "whom", "whose",
        "that", "if", "unless", "when", "whenever", "since", "until", "before", "after",
        "however", "therefore", "despite", "whereby", "whilst",
    ]

    static let functionWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "so", "if", "of", "to", "in", "on", "at", "by",
        "for", "with", "from", "into", "onto", "about", "as", "than", "then", "that", "this",
        "these", "those", "there", "here", "it", "its", "is", "am", "are", "was", "were", "be",
        "been", "being", "do", "does", "did", "done", "have", "has", "had", "will", "would",
        "shall", "should", "can", "could", "may", "might", "must", "not", "no", "yes", "i",
        "you", "he", "she", "we", "they", "me", "him", "her", "us", "them", "my", "your", "his",
        "our", "their", "very", "just", "also", "too", "more", "most", "some", "any", "all",
        "one", "two", "get", "got", "go", "going", "well", "how", "what", "when", "where",
        "why", "who", "which", "up", "out", "off", "over", "again", "still", "now",
    ]

    // MARK: 指标

    public static func metrics(for session: ExamSession) -> ExamMetrics {
        let answers = session.answers
        let joined = answers.map(\.text).joined(separator: "\n")
        let allTokens = tokens(joined)
        let totalWords = allTokens.count
        let seconds = answers.reduce(0) { $0 + $1.seconds }
        let contentTokens = allTokens.filter { !functionWords.contains($0) }
        let uniqueContent = Set(contentTokens)
        let allSentences = answers.flatMap { sentences($0.text) }

        let errors = answers.compactMap(\.errorCount)

        var undersized: [Int] = []
        var shortest: ExamMetrics.QuestionLength?
        for answer in answers {
            if answer.wordCount < (minimumWords(for: answer, in: session) ?? 0) {
                undersized.append(answer.questionNumber)
            }
            if shortest == nil || answer.wordCount < shortest!.words {
                shortest = ExamMetrics.QuestionLength(
                    questionNumber: answer.questionNumber,
                    words: answer.wordCount
                )
            }
        }

        return ExamMetrics(
            answeredCount: answers.count,
            questionCount: session.totalQuestions,
            totalWords: totalWords,
            speakingSeconds: seconds,
            wordsPerMinute: seconds > 0 ? Double(totalWords) / Double(seconds) * 60 : 0,
            fillerRatio: totalWords > 0
                ? Double(fillerCount(joined)) / Double(totalWords)
                : 0,
            contentTypeTokenRatio: contentTokens.isEmpty
                ? 0
                : Double(uniqueContent.count) / Double(contentTokens.count),
            averageSentenceWords: allSentences.isEmpty
                ? 0
                : Double(allSentences.reduce(0) { $0 + tokens($1).count }) / Double(allSentences.count),
            clauseSentenceRatio: allSentences.isEmpty
                ? 0
                : Double(allSentences.filter(hasClauseMarker).count) / Double(allSentences.count),
            errorsPerAnswer: errors.isEmpty ? nil : Double(errors.reduce(0, +)) / Double(errors.count),
            shortestAnswer: shortest,
            undersizedQuestions: undersized
        )
    }

    static func minimumWords(for answer: ExamAnswer, in session: ExamSession) -> Int? {
        session.blueprint.stages.first { $0.id == answer.stageID }?.minimumWords
    }

    /// 填充词出现次数（单词 + 多词短语都算）。`public` 是为了让报告的依据可被单测核对。
    public static func fillerCount(_ text: String) -> Int {
        let lower = text.lowercased()
        var count = tokens(lower).filter { fillerWords.contains($0) }.count
        for phrase in fillerPhrases {
            count += lower.components(separatedBy: phrase).count - 1
        }
        return count
    }

    static func hasClauseMarker(_ sentence: String) -> Bool {
        let lower = sentence.lowercased()
        if lower.contains("so that") || lower.contains("in order to") { return true }
        return tokens(lower).contains { clauseMarkers.contains($0) }
    }

    // MARK: 报告

    /// 出报告。
    ///
    /// - Parameter pronunciation: 真实的发音评测结果（来自音素级评测）。
    ///   **`nil` = 这一路没有数据 → 报告里不出现「发音」这一项**，
    ///   而不是给一个拍出来的平均分。没有就是没有。
    public static func report(
        for session: ExamSession,
        pronunciation: ExamBand? = nil
    ) -> ExamReport {
        let metrics = metrics(for: session)
        guard metrics.hasAnyData else {
            return ExamReport(
                title: session.blueprint.title,
                metrics: metrics,
                scores: [],
                overall: nil,
                highlights: [],
                improvements: ["这次没有记录到任何作答，先完整答完一题再来看报告。"],
                isComplete: false
            )
        }

        var scores: [ExamScore] = [
            score(.fluency, metrics: metrics),
            score(.lexical, metrics: metrics),
            score(.grammar, metrics: metrics),
            score(.taskCompletion, metrics: metrics),
        ]
        if let pronunciation {
            scores.append(
                ExamScore(
                    dimension: .pronunciation,
                    band: pronunciation,
                    evidence: "来自本场录音的音素级评测结果。"
                )
            )
        }
        scores.sort { order(of: $0.dimension) < order(of: $1.dimension) }

        let overall = ExamBand(
            scores.map(\.band.value).reduce(0, +) / Double(scores.count)
        )
        return ExamReport(
            title: session.blueprint.title,
            metrics: metrics,
            scores: scores,
            overall: overall,
            highlights: highlights(metrics: metrics, scores: scores),
            improvements: improvements(metrics: metrics, scores: scores, session: session),
            isComplete: metrics.answeredCount == metrics.questionCount
        )
    }

    static func order(of dimension: ExamDimension) -> Int {
        ExamDimension.allCases.firstIndex(of: dimension) ?? 0
    }

    static func score(_ dimension: ExamDimension, metrics: ExamMetrics) -> ExamScore {
        switch dimension {
        case .fluency:
            // 语速：150 词/分以下明显偏慢，190–240 是自然交流节奏（与跟读同一条尺，
            // 2026-09-19 用户定稿），再快不再加分。
            var band = ramp(metrics.wordsPerMinute, [
                (100, 3.0), (120, 4.5), (135, 5.5), (150, 6.5), (170, 7.5), (190, 8.5), (210, 9.0),
            ])
            // 填充词：2% 以内不扣，之后每 1% 扣 0.25，最多扣 1.5。
            let fillerPercent = metrics.fillerRatio * 100
            band -= min(max(fillerPercent - 2, 0) * 0.25, 1.5)
            return ExamScore(
                dimension: dimension,
                band: ExamBand(band),
                evidence: String(
                    format: "语速 %.0f 词/分（%@），填充词占 %.1f%%。",
                    metrics.wordsPerMinute,
                    paceLabel(metrics.wordsPerMinute),
                    fillerPercent
                )
            )

        case .lexical:
            let band = ramp(metrics.contentTypeTokenRatio, [
                (0.40, 3.5), (0.50, 5.0), (0.60, 6.5), (0.70, 7.5), (0.80, 8.5),
            ])
            return ExamScore(
                dimension: dimension,
                band: ExamBand(band),
                evidence: String(
                    format: "用词去重比例 %.0f%%（同为 %.0f 词的作答里越高越不重复）。",
                    metrics.contentTypeTokenRatio * 100,
                    metrics.totalWords
                )
            )

        case .grammar:
            let lengthBand = ramp(metrics.averageSentenceWords, [
                (4, 3.5), (7, 5.0), (11, 6.5), (15, 7.5), (20, 8.0),
            ])
            let clauseBand = ramp(metrics.clauseSentenceRatio, [
                (0.05, 4.0), (0.20, 5.5), (0.35, 6.5), (0.50, 7.5), (0.70, 8.5),
            ])
            var band = (lengthBand + clauseBand) / 2
            // ⚠️ 没有纠错数据时**封顶 7 分**：句长与从句比例只能说明句子够复杂，
            //    说明不了它是对的。缺了这一半依据还给 8–9 分，就等于把「没测到」
            //    当成了「没问题」—— 那正是本项目一直在防的那种谎。
            if let errorsPerAnswer = metrics.errorsPerAnswer {
                band -= ramp(errorsPerAnswer, [(0, 0), (1, 0.75), (2, 1.5), (3, 2.5)])
            } else {
                band = min(band, 7.0)
            }
            let errorNote = metrics.errorsPerAnswer.map {
                String(format: "，平均每答 %.1f 处错误", $0)
            } ?? "，这一场没有取到纠错数据（语法分据此封顶 7）"
            return ExamScore(
                dimension: dimension,
                band: ExamBand(band),
                evidence: String(
                    format: "平均句长 %.1f 词，%@ 的句子带从句标记%@。",
                    metrics.averageSentenceWords,
                    percent(metrics.clauseSentenceRatio),
                    errorNote
                )
            )

        case .taskCompletion:
            let coverageBand = ramp(
                Double(metrics.answeredCount) / Double(max(metrics.questionCount, 1)),
                [(0.5, 3.0), (0.75, 5.0), (1.0, 8.0)]
            )
            let fit = metrics.answeredCount == 0
                ? 0
                : Double(metrics.answeredCount - metrics.undersizedQuestions.count)
                    / Double(metrics.answeredCount)
            let fitBand = ramp(fit, [(0.3, 4.0), (0.6, 6.0), (0.9, 8.0)])
            return ExamScore(
                dimension: dimension,
                band: ExamBand((coverageBand + fitBand) / 2),
                evidence: String(
                    format: "答了 %d/%d 问，其中 %d 问没达到期望长度。",
                    metrics.answeredCount,
                    metrics.questionCount,
                    metrics.undersizedQuestions.count
                )
            )

        case .pronunciation:
            // 走到这里说明没传发音数据；上面已按下标处理，这里给一个不可能的兜底。
            return ExamScore(dimension: dimension, band: ExamBand(0), evidence: "缺少发音评测数据。")
        }
    }

    static func highlights(metrics: ExamMetrics, scores: [ExamScore]) -> [String] {
        var lines: [String] = []
        if metrics.wordsPerMinute >= 190 {
            lines.append(String(format: "语速 %.0f 词/分，接近自然的交流节奏。", metrics.wordsPerMinute))
        }
        if metrics.answeredCount == metrics.questionCount, metrics.questionCount > 0 {
            lines.append("全场 \(metrics.questionCount) 问一题没落。")
        }
        if metrics.fillerRatio <= 0.02, metrics.totalWords >= 30 {
            lines.append(String(format: "填充词只占 %.1f%%，几乎没有「嗯…啊…」。", metrics.fillerRatio * 100))
        }
        if metrics.errorsPerAnswer == 0 {
            lines.append("这一场没有出现被标出的语言错误。")
        }
        if let best = scores.max(by: { $0.band < $1.band }), lines.count < 3 {
            lines.append("最稳的一项是「\(best.dimension.displayName)」：\(best.evidence)")
        }
        // 一条都没达标时不硬夸 —— 报告宁可短，也不要凑数的表扬。
        return Array(lines.prefix(3))
    }

    static func improvements(metrics: ExamMetrics, scores: [ExamScore], session: ExamSession) -> [String] {
        var lines: [String] = []
        if metrics.fillerRatio > 0.05 {
            lines.append(String(format: "填充词占了 %.1f%%，卡壳时把「um」换成一秒停顿会更利落。", metrics.fillerRatio * 100))
        }
        if let shortest = metrics.shortestAnswer, metrics.answeredCount > 1 {
            lines.append("第 \(shortest.questionNumber) 题只说了 \(shortest.words) 词，是全场最短的一次。")
        }
        if metrics.wordsPerMinute > 0, metrics.wordsPerMinute < 150 {
            lines.append(String(format: "语速 %.0f 词/分偏慢，先追求说完整句、再提速。", metrics.wordsPerMinute))
        }
        if metrics.clauseSentenceRatio < 0.2, metrics.answeredCount > 0 {
            lines.append("几乎没有用到从句，试着用 because / although 把两句并成一句。")
        }
        if !metrics.undersizedQuestions.isEmpty {
            let numbers = metrics.undersizedQuestions.map(String.init).joined(separator: "、")
            lines.append("第 \(numbers) 问答得偏短 —— 考官会据此判定「不愿展开」。")
        }
        if let worst = scores.min(by: { $0.band < $1.band }), lines.count < 3 {
            lines.append("当前最弱的一项是「\(worst.dimension.displayName)」：\(worst.evidence)")
        }
        if !session.isFinished, lines.count < 3 {
            lines.append("这一场没有考完，分数只反映已经答过的部分。")
        }
        return Array(lines.prefix(3))
    }

    // MARK: 曲线

    /// 锚点线性插值：`anchors` 必须按 `value` 升序。
    ///
    /// 低于第一个锚点取第一个 band，高于最后一个取最后一个 —— 不 extrapolate，
    /// 否则 200 词/分会算出 12 分。
    public static func ramp(_ value: Double, _ anchors: [(value: Double, band: Double)]) -> Double {
        guard let first = anchors.first, let last = anchors.last else { return 0 }
        if value <= first.value { return first.band }
        if value >= last.value { return last.band }
        for index in 1..<anchors.count where value <= anchors[index].value {
            let low = anchors[index - 1], high = anchors[index]
            let span = high.value - low.value
            guard span > 0 else { return high.band }
            let t = (value - low.value) / span
            return low.band + (high.band - low.band) * t
        }
        return last.band
    }

    static func paceLabel(_ wordsPerMinute: Double) -> String {
        switch wordsPerMinute {
        case ..<150: "偏慢"
        case 150..<190: "适中"
        case 190..<240: "接近自然节奏"
        default: "偏快"
        }
    }

    static func percent(_ ratio: Double) -> String {
        String(format: "%.0f%%", ratio * 100)
    }
}
