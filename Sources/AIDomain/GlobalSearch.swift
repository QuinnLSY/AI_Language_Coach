import Foundation

// MARK: - 跨页全局搜索（#414）

/// 一条命中来自哪儿。
///
/// 四个来源各自有独立的筛选入口（词汇本 / 词典 / 记录页），但「我上次练过那个词在哪」
/// 这类问题跨了页 —— 用户不知道该去哪一页找，于是根本不找。
public enum GlobalSearchKind: String, CaseIterable, Sendable, Identifiable {

    /// 词汇本（收过的生词）。
    case vocabulary
    /// 内置词典（六级 / 雅思 / 牛津 / 常用搭配）。
    case dictionary
    /// 历史对话的正文。
    case conversation
    /// 每日阅读短文。
    case reading

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .vocabulary: return "词汇本"
        case .dictionary: return "词典"
        case .conversation: return "对话"
        case .reading: return "阅读"
        }
    }

    /// 结果分组的次序：先找自己收过的词，再找词典，最后找练过的痕迹。
    public var order: Int {
        switch self {
        case .vocabulary: return 0
        case .dictionary: return 1
        case .conversation: return 2
        case .reading: return 3
        }
    }
}

/// 历史对话里命中的那一条消息（DB 查出来的最小形态）。
public struct GlobalSearchMessage: Sendable, Equatable, Identifiable {

    public let sessionID: UUID
    public let messageID: String
    /// `user` / `assistant`。
    public let role: String
    /// 命中位置附近的一小段原文（见 `GlobalSearch.snippet`）。
    public let snippet: String
    public let createdAt: Date

    public init(sessionID: UUID, messageID: String, role: String, snippet: String, createdAt: Date) {
        self.sessionID = sessionID
        self.messageID = messageID
        self.role = role
        self.snippet = snippet
        self.createdAt = createdAt
    }

    public var id: String { "\(sessionID.uuidString)|\(messageID)" }

    /// 这条是学员说的还是老师说的（结果行上要标一下，否则两条看着像同一段）。
    public var roleLabel: String { role == "user" ? "我" : "老师" }
}

/// 一条搜索结果。
///
/// ⚠️ `detail` 里**不留整段原文**：结果行只放得下一行，长文本一律走 `snippet`。
public struct GlobalSearchHit: Sendable, Equatable, Identifiable {

    public let id: String
    public let kind: GlobalSearchKind
    /// 主文本（词 / 短文标题 / 说话人）。
    public let title: String
    /// 副文本（释义 / 命中片段）。
    public let detail: String

    public init(id: String, kind: GlobalSearchKind, title: String, detail: String) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
    }

    /// id 的各段（`kind|...`），供下面几个定位属性解析。
    private var idParts: [Substring] {
        id.split(separator: "|", omittingEmptySubsequences: false)
    }

    /// 这条命中属于哪个**会话**（对话类；`message|<sessionID>|<messageID>`）。
    ///
    /// 为什么要有它（2026-10-01）：sessionID 一直在 id 里，可跳转时没用上 ——
    /// 点了结果落在学习记录页顶部，那条消息在哪全靠用户自己翻。
    public var sessionID: UUID? {
        let parts = idParts
        guard kind == .conversation, parts.count >= 3, parts[0] == "message" else { return nil }
        return UUID(uuidString: String(parts[1]))
    }

    /// 这条命中是哪一天的那批阅读（`reading|<dayKey>|<title>`）。
    public var readingDayKey: Int? {
        let parts = idParts
        guard kind == .reading, parts.count >= 3, parts[0] == "reading" else { return nil }
        return Int(parts[1])
    }

    /// 这条命中是哪一篇短文（标题，用于翻到它那一页）。
    public var readingTitle: String? {
        let parts = idParts
        guard kind == .reading, parts.count >= 3, parts[0] == "reading" else { return nil }
        return String(parts[2...].joined(separator: "|"))
    }
}

public enum GlobalSearch {

    /// 单个来源最多留几条。
    ///
    /// ⚠️ 有上限是刻意的：对话正文的命中可以成百上千条，不截断的话
    /// 「搜一个常见词」会把界面塞满，而真正想要的那个词被挤到看不见的地方。
    public static let defaultLimitPerKind = 5

    /// 归一化：去首尾空白 + 折叠内部连续空白（用户可能从别处粘进来带换行的词）。
    public static func normalize(_ query: String) -> String {
        query.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// 匹配打分（纯函数，越大越靠前，0 = 不命中）。
    ///
    /// 分档的意义：搜 "cat" 时 `category` 不该排到 `cat` 前面 —— 完全相等 > 前缀 > 词首 > 中间。
    public static func score(text: String, query: String) -> Int {
        guard !query.isEmpty else { return 0 }
        let haystack = text.lowercased()
        let needle = query.lowercased()
        guard let range = haystack.range(of: needle) else { return 0 }
        if range.lowerBound == haystack.startIndex && range.upperBound == haystack.endIndex { return 100 }
        if range.lowerBound == haystack.startIndex { return 60 }
        // 词首（空格 / 连字符 / 斜杠之后）：搜 "read" 命中 "re-read" 比命中 "spread" 更相关。
        let before = haystack[..<range.lowerBound].last
        if before == " " || before == "-" || before == "/" { return 40 }
        return 20
    }

    /// 命中片段：以命中位置为中心，左右各留一点上下文。
    ///
    /// 省略号只在**真的截掉了**时才加 —— 全文都装得下却挂个「…」会让人以为被截断。
    /// ⚠️ 用 `range(of:options: .caseInsensitive)` 在**原文**上取下标，不用 lowercased 的下标：
    /// 少数字符大写转小写会改变字符数，下标串了就是错位或越界。
    public static func snippet(text: String, query: String, radius: Int = 32) -> String {
        guard let range = text.range(of: query, options: .caseInsensitive) else {
            return String(text.prefix(radius * 3))
        }
        let from = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let to = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        let head = from > text.startIndex ? "…" : ""
        let tail = to < text.endIndex ? "…" : ""
        return head + String(text[from..<to]) + tail
    }

    /// 释义的第一行（落库的释义是结构化键值行，结果行只放得下一行）。
    public static func firstLine(of text: String) -> String {
        let line = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        return String(line.prefix(80))
    }

    /// 把四个来源的命中合成一份结果：组内按分数排序，组间按 `GlobalSearchKind.order`。
    ///
    /// 输入已经是各来源**自己筛过**的候选（词典走服务层、对话走 SQL），
    /// 这里只负责排序、截断与拼装 —— 排序口径只有这一处，改一次到处生效。
    public static func hits(
        query: String,
        vocabulary: [VocabularyEntry] = [],
        dictionary: [DictionaryWord] = [],
        messages: [GlobalSearchMessage] = [],
        readings: [ReadingPassage] = [],
        limitPerKind: Int = defaultLimitPerKind
    ) -> [GlobalSearchHit] {
        let needle = normalize(query)
        guard !needle.isEmpty else { return [] }

        var groups: [GlobalSearchHit] = []
        groups.append(contentsOf: top(
            candidates: vocabulary.map { entry in
                Candidate(
                    id: "vocabulary|\(entry.id.uuidString)",
                    kind: .vocabulary,
                    title: entry.word,
                    detail: firstLine(of: entry.meaning),
                    score: max(score(text: entry.word, query: needle),
                               score(text: entry.meaning, query: needle) / 2)
                )
            },
            limit: limitPerKind
        ))
        groups.append(contentsOf: top(
            candidates: dictionary.map { word in
                Candidate(
                    id: "dictionary|\(word.id)",
                    kind: .dictionary,
                    title: word.word,
                    detail: firstLine(of: word.translation),
                    score: score(text: word.word, query: needle)
                )
            },
            limit: limitPerKind
        ))
        // 对话最近的在前：同分时新的那次练习更有可能是「上次练过的」。
        groups.append(contentsOf: top(
            candidates: messages.map { message in
                Candidate(
                    id: "message|\(message.id)",
                    kind: .conversation,
                    title: message.roleLabel,
                    detail: message.snippet,
                    score: score(text: message.snippet, query: needle),
                    tiebreaker: message.createdAt.timeIntervalSince1970
                )
            },
            limit: limitPerKind
        ))
        groups.append(contentsOf: top(
            candidates: readings.map { passage in
                Candidate(
                    id: "reading|\(passage.dayKey)|\(passage.title)",
                    kind: .reading,
                    title: passage.title,
                    detail: snippet(text: passage.text, query: needle),
                    score: max(score(text: passage.title, query: needle),
                               score(text: passage.text, query: needle) / 2)
                )
            },
            limit: limitPerKind
        ))
        return groups
    }

    // MARK: - 内部

    private struct Candidate {
        let id: String
        let kind: GlobalSearchKind
        let title: String
        let detail: String
        let score: Int
        /// 同分时的决胜值（越大越靠前）：对话用时间，其余是 0。
        var tiebreaker: Double = 0
    }

    /// 去掉不命中的 → 按分数（同分用决胜值）排序 → 截断 → 收成 `GlobalSearchHit`。
    private static func top(candidates: [Candidate], limit: Int) -> [GlobalSearchHit] {
        candidates
            .filter { $0.score > 0 }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.tiebreaker > rhs.tiebreaker
            }
            .prefix(limit)
            .map { GlobalSearchHit(id: $0.id, kind: $0.kind, title: $0.title, detail: $0.detail) }
    }
}
