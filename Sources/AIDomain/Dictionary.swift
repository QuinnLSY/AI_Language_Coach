import Foundation

// MARK: - 一本词典

/// 词典库里的**一本书**（是元数据，不是词条）。
///
/// 词条本身留在资源文件 / 导入文件里，这里只描述「这本书是什么、封面长什么样」。
/// 封面配色用 `CoverStyle` 这种**令牌**表达，具体颜色由 UI 层从主题里取
/// —— 领域层不许出现颜色字面量，否则日夜切换必漏。
public struct DictionaryBook: Sendable, Equatable, Identifiable, Codable {

    /// 封面配色令牌（六选一，够三本内置 + 导入的书拉开差别）。
    public enum CoverStyle: String, Codable, Sendable, CaseIterable {
        case forest
        case ocean
        case sunset
        case plum
        case slate
        case sand
    }

    /// 稳定 id：内置的是固定串（`builtin.cet6` 等），导入的是 `imported.<uuid>`。
    public var id: String
    /// 封面下方显示的名字。
    public var name: String
    /// 封面上那个大字（书的「书脊字」：六级 / 牛津 / 雅思）。
    public var coverLabel: String
    /// 封面上那行小字（谁编的 / 多少词）。
    public var subtitle: String
    /// 词条数。
    public var entryCount: Int
    /// 是否随包内置（内置的删掉只是隐藏，可一键恢复；导入的删掉即删文件）。
    public var isBuiltIn: Bool
    public var coverStyle: CoverStyle
    /// 导入时间（内置为 nil）。
    public var importedAt: Date?

    public init(
        id: String,
        name: String,
        coverLabel: String = "",
        subtitle: String = "",
        entryCount: Int = 0,
        isBuiltIn: Bool = true,
        coverStyle: CoverStyle = .forest,
        importedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.coverLabel = coverLabel.isEmpty ? String(name.prefix(2)) : coverLabel
        self.subtitle = subtitle
        self.entryCount = entryCount
        self.isBuiltIn = isBuiltIn
        self.coverStyle = coverStyle
        self.importedAt = importedAt
    }
}

// MARK: - 词典里的一个词

/// 词典里的一个词条（搜索联想 / 选词 / 查词都用它）。
///
/// `phonetic` 可缺（内置词库的音标是离线补的，导入的词库可能没写），
/// UI 则该行不显示 —— 不拿一个空斜杠占位。
public struct DictionaryWord: Sendable, Equatable, Identifiable, Codable {
    public var word: String
    public var phonetic: String
    public var pos: String
    /// 中文义项（多义用「；」分隔）。
    public var translation: String
    /// 难度档：1 简单 / 2 中等 / 3 困难 / 4 词组（与每日推荐同一把尺）。
    public var difficulty: Int
    /// 来自哪本书（同名词可能出现在多本词典里，去重时保留优先级高的那本）。
    public var bookID: String

    public var id: String { "\(bookID)|\(word.lowercased())" }

    public init(
        word: String,
        phonetic: String = "",
        pos: String = "",
        translation: String = "",
        difficulty: Int = 2,
        bookID: String
    ) {
        self.word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        self.phonetic = phonetic.trimmingCharacters(in: .whitespaces)
        self.pos = pos.trimmingCharacters(in: .whitespaces)
        self.translation = translation.trimmingCharacters(in: .whitespaces)
        self.difficulty = min(max(difficulty, 1), DailyWord.maxDifficulty)
        self.bookID = bookID
    }

    /// 转成每日推荐的词（选词只看 word / difficulty）。
    public var dailyWord: DailyWord { DailyWord(word: word, difficulty: difficulty) }

    /// 联想 / 搜索结果里的副标题：「词性 中文」。
    public var detailText: String {
        translation.isEmpty ? "" : (pos.isEmpty ? translation : "\(pos) \(translation)")
    }
}

// MARK: - 词典库状态

/// 词典库的**用户状态**：哪几本被删了、哪几本是每日推荐词源、优先级各是几。
///
/// 刻意不含词条（词条在资源 / 导入文件里）：这份状态很小，可以直接进 `UserDefaults`，
/// 不必为它动 SQLite 或 config.json 的结构。
public struct DictionaryLibrary: Sendable, Equatable, Codable {

    /// 被用户删掉的词典 id（内置词典不删文件，记在这里，可一键恢复）。
    public var removedIDs: Set<String>
    /// 每日推荐词源：bookID → 名次（1 最小 = 最优先）。不在表里 = 不作为词源。
    public var priority: [String: Int]
    /// 用户导入的词典元数据。
    public var importedBooks: [DictionaryBook]

    public init(
        removedIDs: Set<String> = [],
        priority: [String: Int] = [:],
        importedBooks: [DictionaryBook] = []
    ) {
        self.removedIDs = removedIDs
        self.priority = priority
        self.importedBooks = importedBooks
    }

    public static let empty = DictionaryLibrary()

    // MARK: 可见性

    /// 库里的全部书（内置 + 导入），**不含**已删除的。
    public func visibleBooks(builtIns: [DictionaryBook]) -> [DictionaryBook] {
        (builtIns + importedBooks).filter { !removedIDs.contains($0.id) }
    }

    /// 全部书（含已删除的）—— 设置页 / 恢复内置用。
    public func allBooks(builtIns: [DictionaryBook]) -> [DictionaryBook] {
        builtIns + importedBooks
    }

    /// 被删掉且**是内置**的词典（可恢复）。
    public func restorableBuiltIns(builtIns: [DictionaryBook]) -> [DictionaryBook] {
        builtIns.filter { removedIDs.contains($0.id) }
    }

    // MARK: 删除 / 恢复

    /// 删掉一本书。只改状态：文件与词条的清理由服务层按 `isBuiltIn` 决定。
    public static func removing(_ id: String, from library: DictionaryLibrary) -> DictionaryLibrary {
        var next = library
        next.removedIDs.insert(id)
        next.priority.removeValue(forKey: id)
        next.renumber()
        return next
    }

    /// 恢复一本内置词典。
    public static func restoring(_ id: String, in library: DictionaryLibrary) -> DictionaryLibrary {
        var next = library
        next.removedIDs.remove(id)
        return next
    }

    /// 一键恢复全部内置词典。
    public static func restoringBuiltIns(_ library: DictionaryLibrary) -> DictionaryLibrary {
        var next = library
        next.removedIDs.removeAll()
        return next
    }

    /// 真正移除一本**导入**词典（元数据也要删）。
    public static func droppingImported(_ id: String, from library: DictionaryLibrary) -> DictionaryLibrary {
        var next = library
        next.importedBooks.removeAll { $0.id == id }
        next.removedIDs.remove(id)
        next.priority.removeValue(forKey: id)
        next.renumber()
        return next
    }

    // MARK: 优先级（每日推荐词源）

    /// 勾选 / 取消勾选「作为每日推荐词源」。
    ///
    /// 勾上时排到**最后一名**（新勾的不会抢掉已经在用那本的优先权），
    /// 取消时名次自动补位 —— 名次永远是 1,2,3… 连续，UI 直接显示这个数字。
    public static func togglingSource(_ id: String, in library: DictionaryLibrary) -> DictionaryLibrary {
        var next = library
        if next.priority[id] != nil {
            next.priority.removeValue(forKey: id)
            next.renumber()
        } else {
            next.priority[id] = (next.priority.values.max() ?? 0) + 1
        }
        return next
    }

    /// 把名次压成 1…n（删书 / 取消勾选后不留空洞）。
    private mutating func renumber() {
        let ordered = priority.sorted { ($0.value, $0.key) < ($1.value, $1.key) }
        var fresh: [String: Int] = [:]
        for (offset, entry) in ordered.enumerated() { fresh[entry.key] = offset + 1 }
        priority = fresh
    }

    /// 某本书的名次（没被选作词源 → nil）。
    public func rank(of id: String) -> Int? { priority[id] }

    /// 搜索用的书序：被选作词源的按名次在前，其余按名字排。
    /// 同名词优先归到排名靠前的那本，让「优先级」在搜索结果里也生效。
    public func searchOrder(builtIns: [DictionaryBook]) -> [DictionaryBook] {
        let books = visibleBooks(builtIns: builtIns)
        return books.sorted { lhs, rhs in
            let left = priority[lhs.id] ?? Int.max
            let right = priority[rhs.id] ?? Int.max
            if left != right { return left < right }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
    }

    /// 每日推荐的词源（按优先级排序的词典 id）。
    ///
    /// ⚠️ 一本都没勾选时**退化为全部可见词典**：否则「没勾 → 每日推荐空了」会被当成坏掉。
    public func sourceBookIDs(builtIns: [DictionaryBook]) -> [String] {
        let books = visibleBooks(builtIns: builtIns)
        let selected = books
            .filter { priority[$0.id] != nil }
            .sorted { (priority[$0.id] ?? 0, $0.name) < (priority[$1.id] ?? 0, $1.name) }
        if !selected.isEmpty { return selected.map(\.id) }
        return books.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }.map(\.id)
    }
}

// MARK: - 词典文件解析（导入 / 内置共用）

/// 词典 JSON 的解析（**一份格式，两处用**：内置资源与用户导入）。
///
/// 接受两种外形：
/// - 数组：`[{"word":"nominal","pos":"adj.","zh":"名义上的","phonetic":"/ˈnɒmɪnl/"}]`
/// - 对象：`{"name":"我的词表","words":[…]}`（顺带能读里面的名字）
///
/// 只有 `word` 必填；`pos` / `zh`（或 `translation` / `meaning`）/ `phonetic`（或 `ipa`）
/// / `difficulty` 都可省。空词、超长词、重复词一律丢掉，不报错。
public enum DictionaryFileParser {

    public struct Parsed: Sendable, Equatable {
        public var name: String?
        public var subtitle: String?
        public var words: [DictionaryWord]
    }

    /// 解析词典文件；完全读不出词条时返回 nil（调用方给「格式不对」提示）。
    public static func parse(_ data: Data?, bookID: String) -> Parsed? {
        guard let data else { return nil }
        let root = try? JSONSerialization.jsonObject(with: data)
        let list: [[String: Any]]
        var name: String?
        var subtitle: String?
        if let array = root as? [[String: Any]] {
            list = array
        } else if let object = root as? [String: Any],
                  let words = object["words"] as? [[String: Any]] {
            list = words
            name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            subtitle = (object["subtitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            return nil
        }
        let words = normalize(list, bookID: bookID)
        guard !words.isEmpty else { return nil }
        return Parsed(
            name: name?.isEmpty == true ? nil : name,
            subtitle: subtitle?.isEmpty == true ? nil : subtitle,
            words: words
        )
    }

    /// 逐条清洗：去重（不分大小写）、挡掉空词与超长词。
    static func normalize(_ list: [[String: Any]], bookID: String) -> [DictionaryWord] {
        var seen = Set<String>()
        var result: [DictionaryWord] = []
        for item in list {
            guard let raw = item["word"] as? String else { continue }
            let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, word.count <= 48, !seen.contains(word.lowercased()) else { continue }
            seen.insert(word.lowercased())
            result.append(
                DictionaryWord(
                    word: word,
                    phonetic: firstString(item, ["phonetic", "ipa", "pronunciation"]) ?? "",
                    pos: firstString(item, ["pos", "part_of_speech"]) ?? "",
                    translation: firstString(item, ["zh", "translation", "meaning", "中文"]) ?? "",
                    difficulty: item["difficulty"] as? Int ?? 2,
                    bookID: bookID
                )
            )
        }
        return result
    }

    private static func firstString(_ item: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = item[key] as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty {
                return value
            }
        }
        return nil
    }
}

// MARK: - 搜索打分

/// 模糊匹配打分：完全相等 0 < 前缀 1 < 子串 2 < 中文命中 3；没命中返回 nil。
///
/// ⚠️ 全应用**只有这一把尺**：词典搜索（`DictionaryMatcher`）与变体词还原都走它。
/// 谁要再做一个「搜词」入口，也必须复用这里的 `score` / `rank`，不许另写一套 ——
/// 否则同一串输入在两个入口给出不同顺序，用户会以为其中一个坏了。
public enum FuzzyWordMatch {

    public static func score(word: String, translation: String, needle: String) -> Int? {
        let target = word.lowercased()
        guard !target.isEmpty else { return nil }
        if target == needle { return 0 }
        if target.hasPrefix(needle) { return 1 }
        if target.contains(needle) { return 2 }
        if !translation.isEmpty, translation.lowercased().contains(needle) { return 3 }
        return nil
    }

    /// 归一化查询串（去首尾空白 + 小写）；空串 = 不搜。
    public static func needle(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 按「分数 → 词长 → 字母序」排序并去重（同词只留最靠前的那条）。
    public static func rank<T>(
        _ candidates: [(score: Int, length: Int, item: T)],
        limit: Int,
        key: (T) -> String
    ) -> [T] {
        var sorted = candidates
        sorted.sort {
            if $0.score != $1.score { return $0.score < $1.score }
            if $0.length != $1.length { return $0.length < $1.length }
            return key($0.item).lowercased() < key($1.item).lowercased()
        }
        var seen = Set<String>()
        var result: [T] = []
        for entry in sorted {
            let identity = key(entry.item).lowercased()
            guard !seen.contains(identity) else { continue }
            seen.insert(identity)
            result.append(entry.item)
            if result.count >= max(limit, 1) { break }
        }
        return result
    }
}

/// 词典搜索的模糊匹配（最多 10 条，打分走 `FuzzyWordMatch`）。
public enum DictionaryMatcher {

    /// 一次最多给几条。
    public static let limit = 10

    public static func match(
        _ query: String,
        in words: [DictionaryWord],
        limit: Int = limit
    ) -> [DictionaryWord] {
        let needle = FuzzyWordMatch.needle(query)
        guard !needle.isEmpty else { return [] }
        var ranked: [(score: Int, length: Int, item: DictionaryWord)] = []
        var exact = false
        for word in words {
            guard let score = FuzzyWordMatch.score(
                word: word.word, translation: word.translation, needle: needle
            ) else { continue }
            if score == 0 { exact = true }
            ranked.append((score, word.word.count, word))
        }
        // 变体兜底：`subtitles` 在词库里没有，但它的本体 `subtitle` 在 ——
        // 直接按「精确命中」把本体加进来，否则用户搜变体只会看到一串无关的模糊结果。
        if !exact {
            for candidate in WordForm.candidates(of: needle) {
                guard let hit = words.first(where: { $0.word.lowercased() == candidate.lemma }) else { continue }
                ranked.append((score: 0, length: hit.word.count, item: hit))
            }
        }
        return FuzzyWordMatch.rank(ranked, limit: limit) { $0.word }
    }
}

// MARK: - 查词结果

/// 一条义项：词性 + 中文 + （可选）用法说明。
public struct DictionarySense: Sendable, Equatable, Codable {
    public var pos: String
    public var text: String
    public var explanation: String

    public init(pos: String = "", text: String, explanation: String = "") {
        self.pos = pos
        self.text = text
        self.explanation = explanation
    }
}

/// 一条固定搭配：搭配本身 + 中文 + 例句及翻译。
public struct DictionaryCollocation: Sendable, Equatable, Codable, Identifiable {
    public var phrase: String
    public var translation: String
    public var example: String
    public var exampleTranslation: String

    public var id: String { "\(phrase)|\(translation)" }

    public init(
        phrase: String,
        translation: String = "",
        example: String = "",
        exampleTranslation: String = ""
    ) {
        self.phrase = phrase
        self.translation = translation
        self.example = example
        self.exampleTranslation = exampleTranslation
    }
}

/// 一条例句。
public struct DictionaryExample: Sendable, Equatable, Codable, Identifiable {
    public var text: String
    public var translation: String

    public var id: String { "\(text)|\(translation)" }

    public init(text: String, translation: String = "") {
        self.text = text
        self.translation = translation
    }
}

/// 构词拆分的一段（`nomin` = 「名字」）。
public struct DictionaryMorphPart: Sendable, Equatable, Codable {
    public var text: String
    public var label: String

    public init(text: String, label: String = "") {
        self.text = text
        self.label = label
    }
}

/// 构词拆分：几段拼起来 → 合成义。
public struct DictionaryMorphology: Sendable, Equatable, Codable {
    public var parts: [DictionaryMorphPart]
    public var result: String

    public init(parts: [DictionaryMorphPart] = [], result: String = "") {
        self.parts = parts
        self.result = result
    }

    public var isEmpty: Bool { parts.isEmpty && result.isEmpty }
}

/// 派生词 / 近义词 / 反义词里的一个词。
public struct DictionaryRelatedWord: Sendable, Equatable, Codable, Identifiable {
    public var word: String
    public var pos: String
    public var translation: String

    public var id: String { "\(word.lowercased())|\(pos)|\(translation)" }

    public init(word: String, pos: String = "", translation: String = "") {
        self.word = word.trimmingCharacters(in: .whitespaces)
        self.pos = pos.trimmingCharacters(in: .whitespaces)
        self.translation = translation.trimmingCharacters(in: .whitespaces)
    }

    /// 只有一个词、没有任何补充说明 —— 这种条目也算数（点击跳转仍可用）。
    public var isEmpty: Bool { word.isEmpty && pos.isEmpty && translation.isEmpty }
}

/// 词族树上的一个节点：一个词 + 它的构词说明 + 它的下挂词。
///
/// 词族树回答的是「同一个词根底下还长着哪些词」—— 与 `derivatives`（派生词）的区别：
/// 派生词只列**当前这个词**的直接派生，词族树是从**词根**出发、跨多个词的分支结构，
/// 用来成串地记词（`riv` → `rival` → `rivalry` / `rivalrous`）。
public struct DictionaryFamilyNode: Sendable, Equatable, Codable, Identifiable {
    public var word: String
    public var pos: String
    public var translation: String
    /// 构词说明（如「riv 河：溪流 + -al 与……有关的」）。可为空。
    public var morphology: String
    /// 下挂的词（分支 → 关联词；关联词自己也可以再有下挂）。
    public var children: [DictionaryFamilyNode]

    /// ⚠️ 同一棵树里 `word` 可能重复（不同分支共用同一个词），所以 id 必须带上**挂载点**，
    /// 不能只用词本身 —— 否则 `ForEach` 会把两个节点当成同一个，画出重复/错位的行。
    public var id: String { "\(parentKey)|\(word.lowercased())|\(pos)" }
    /// 挂载点（父词的小写）。由构建器赋值；根下的分支父词 = 词根。
    public var parentKey: String = ""

    public init(
        word: String,
        pos: String = "",
        translation: String = "",
        morphology: String = "",
        children: [DictionaryFamilyNode] = [],
        parentKey: String = ""
    ) {
        self.word = word.trimmingCharacters(in: .whitespaces)
        self.pos = pos.trimmingCharacters(in: .whitespaces)
        self.translation = translation.trimmingCharacters(in: .whitespaces)
        self.morphology = morphology.trimmingCharacters(in: .whitespaces)
        self.children = children
        self.parentKey = parentKey
    }

    public var isEmpty: Bool { word.isEmpty }

    /// 树上所有词（含自己与后代），按深度优先顺序，去重。
    public var allWords: [String] {
        var seen = Set<String>()
        var result: [String] = []
        func walk(_ node: DictionaryFamilyNode) {
            let key = node.word.lowercased()
            if !node.word.isEmpty, seen.insert(key).inserted { result.append(node.word) }
            for child in node.children { walk(child) }
        }
        walk(self)
        return result
    }

    /// 节点总数（含自己与后代）。
    public var count: Int { 1 + children.reduce(0) { $0 + $1.count } }
}

/// 词族树：一根词根 + 它底下的整棵树。
public struct DictionaryWordFamily: Sendable, Equatable, Codable {
    /// 词根（如 `riv`）。
    public var root: String
    /// 词根的意思（如「河」）。
    public var rootMeaning: String
    /// 词根下的分支。
    public var branches: [DictionaryFamilyNode]

    public init(root: String = "", rootMeaning: String = "", branches: [DictionaryFamilyNode] = []) {
        self.root = root.trimmingCharacters(in: .whitespaces)
        self.rootMeaning = rootMeaning.trimmingCharacters(in: .whitespaces)
        self.branches = branches
    }

    /// 没有分支 → 整张卡片不出现（用户口径：没有就整段不出现，不留空壳）。
    public var isEmpty: Bool { branches.isEmpty }

    /// 树上所有词（去重，保持深度优先顺序）—— 卡片收起时用来判断「当前词在不在树上」。
    public var allWords: [String] {
        var seen = Set<String>()
        var result: [String] = []
        func walk(_ node: DictionaryFamilyNode) {
            let key = node.word.lowercased()
            if !node.word.isEmpty, seen.insert(key).inserted { result.append(node.word) }
            for child in node.children { walk(child) }
        }
        for branch in branches { walk(branch) }
        return result
    }

    /// 出现过的词数（含所有层级）—— 收起态标题上的「N 个关联词」。
    public var wordCount: Int { allWords.count }

    /// 当前词在树里（决定要不要标「当前」）。
    public func contains(_ word: String) -> Bool {
        let needle = word.trimmingCharacters(in: .whitespaces).lowercased()
        return !needle.isEmpty && allWords.contains { $0.lowercased() == needle }
    }

    /// 按词找节点（第一个命中的，深度优先）。
    public func node(for word: String) -> DictionaryFamilyNode? {
        let needle = word.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return nil }
        func find(_ nodes: [DictionaryFamilyNode]) -> DictionaryFamilyNode? {
            for node in nodes {
                if node.word.lowercased() == needle { return node }
                if let hit = find(node.children) { return hit }
            }
            return nil
        }
        return find(branches)
    }
}

// MARK: - 词族树构建（纯函数）

/// 把模型给的「词根 / 分支 / 关联词」三组散行**组装成一棵树**（纯函数，可脱机单测）。
///
/// 为什么要单独一层：模型是一行一行给的（`family_branch` / `family_member`），
/// 而 UI 要的是嵌套结构。层级关系只由「关联词行的第一个字段 = 它挂在哪」表达，
/// 组装规则（挂不上就升为分支、防环、去重）全在这里，UI 不参与任何推断。
public enum DictionaryFamilyBuilder {

    /// - Parameters:
    ///   - root: 词根（如 `riv`）。
    ///   - kinds: 分支行，每行 `[word, pos, translation, morphology]`（后三段可省）。
    ///   - members: 关联词行，每行 `[parent, word, pos, translation, morphology]`。
    public static func build(
        root: String,
        rootMeaning: String,
        branches: [[String]],
        members: [[String]]
    ) -> DictionaryWordFamily {
        let rootKey = root.trimmingCharacters(in: .whitespaces).lowercased()

        /// 一条边：挂在 `parentKey` 下面的是 `node`。
        var edges: [(parentKey: String, node: DictionaryFamilyNode)] = []
        var nodeKeys: Set<String> = []

        for fields in branches {
            guard let node = node(from: fields) else { continue }
            nodeKeys.insert(node.word.lowercased())
            edges.append((rootKey, node))
        }
        // 关联词：第一个字段是**父词**，其余与分支行同构。
        for fields in members {
            guard fields.count >= 2 else { continue }
            let parentKey = fields[0].trimmingCharacters(in: .whitespaces).lowercased()
            guard let node = node(from: Array(fields.dropFirst())) else { continue }
            nodeKeys.insert(node.word.lowercased())
            edges.append((parentKey.isEmpty ? rootKey : parentKey, node))
        }

        // 挂不上的关联词**升为一级分支**，而不是丢掉 —— 模型给的父子关系偶尔会指名一个
        // 它自己没写出来的中间词，丢一行等于整棵树缺一块。
        for index in edges.indices where edges[index].parentKey != rootKey {
            if !nodeKeys.contains(edges[index].parentKey) {
                edges[index].parentKey = rootKey
            }
        }

        /// 深度优先展开：`seen` 防环（模型把 A 挂到 B、又把 B 挂到 A 时不能无限递归）。
        func assemble(parentKey: String, seen: Set<String>) -> [DictionaryFamilyNode] {
            var result: [DictionaryFamilyNode] = []
            var seenWords = Set<String>()
            for edge in edges where edge.parentKey == parentKey {
                let key = edge.node.word.lowercased()
                // 同一个词在同一个父节点下只出现一次（模型偶尔重复给同一行）。
                guard seenWords.insert(key).inserted else { continue }
                if seen.contains(key) {
                    // 成环：保留这个词，但不再往下展开。
                    result.append(edge.node)
                    continue
                }
                var node = edge.node
                node.parentKey = parentKey
                node.children = assemble(parentKey: key, seen: seen.union([key]))
                result.append(node)
            }
            return result
        }

        let tree = assemble(parentKey: rootKey, seen: [rootKey])
        return DictionaryWordFamily(root: root, rootMeaning: rootMeaning, branches: tree)
    }

    /// 一行 → 节点（`[word, pos, translation, morphology]`，后三段可省）。
    private static func node(from fields: [String]) -> DictionaryFamilyNode? {
        let word = fields.first?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !word.isEmpty else { return nil }
        return DictionaryFamilyNode(
            word: word,
            pos: fields.count > 1 ? fields[1] : "",
            translation: fields.count > 2 ? fields[2] : "",
            morphology: fields.count > 3 ? fields[3] : ""
        )
    }
}

/// 查一个词的**完整结果页**内容。
///
/// 每一项都是「有则展示、无则这行不出现」：模型没给构词拆分，页面就不该留个空标题。
public struct DictionaryDetail: Sendable, Equatable, Codable {
    public var word: String
    /// 美式 / 英式音标（都可缺）。
    public var phoneticUS: String
    public var phoneticUK: String
    public var senses: [DictionarySense]
    public var collocations: [DictionaryCollocation]
    public var examples: [DictionaryExample]
    public var morphology: DictionaryMorphology
    public var etymology: String
    public var derivatives: [DictionaryRelatedWord]
    public var synonyms: [DictionaryRelatedWord]
    public var antonyms: [DictionaryRelatedWord]
    /// 词族树（同一词根下的分支与关联词）。没有就整张卡片不出现。
    public var family: DictionaryWordFamily
    /// 变体说明：查的是变体时，模型写的那行「这是什么形式、在这里指什么」。
    ///
    /// ⚠️ 与「词源」不是一回事：词源讲词的来历，这一行只解释**被划到的那个写法**。
    public var formNote: String
    /// 变体的**本体**（`subtitles` → `subtitle`），来自 `form:` 那行的 `X = Y`。
    ///
    /// 单独存一份而不是复用 `word`：`word` 记的是「用户查的是哪个词」
    /// （`parse` 的兜底口径，模型写错时也不会带偏），本体另走一路更清楚。
    public var baseForm: String

    public init(
        word: String,
        phoneticUS: String = "",
        phoneticUK: String = "",
        senses: [DictionarySense] = [],
        collocations: [DictionaryCollocation] = [],
        examples: [DictionaryExample] = [],
        morphology: DictionaryMorphology = DictionaryMorphology(),
        etymology: String = "",
        derivatives: [DictionaryRelatedWord] = [],
        synonyms: [DictionaryRelatedWord] = [],
        antonyms: [DictionaryRelatedWord] = [],
        family: DictionaryWordFamily = DictionaryWordFamily(),
        formNote: String = "",
        baseForm: String = ""
    ) {
        self.word = word
        self.phoneticUS = phoneticUS
        self.phoneticUK = phoneticUK
        self.senses = senses
        self.collocations = collocations
        self.examples = examples
        self.morphology = morphology
        self.etymology = etymology
        self.derivatives = derivatives
        self.synonyms = synonyms
        self.antonyms = antonyms
        self.family = family
        self.formNote = formNote
        self.baseForm = baseForm
    }

    /// ⚠️ 手写 `init(from:)`：`family` 是后加的非可选字段，合成解码器要求 JSON 里必须有它，
    /// 旧数据（含测试里的手写 JSON）会整条解码失败。缺键时按空树处理。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        word = try container.decode(String.self, forKey: .word)
        phoneticUS = try container.decodeIfPresent(String.self, forKey: .phoneticUS) ?? ""
        phoneticUK = try container.decodeIfPresent(String.self, forKey: .phoneticUK) ?? ""
        senses = try container.decodeIfPresent([DictionarySense].self, forKey: .senses) ?? []
        collocations = try container.decodeIfPresent([DictionaryCollocation].self, forKey: .collocations) ?? []
        examples = try container.decodeIfPresent([DictionaryExample].self, forKey: .examples) ?? []
        morphology = try container.decodeIfPresent(DictionaryMorphology.self, forKey: .morphology)
            ?? DictionaryMorphology()
        etymology = try container.decodeIfPresent(String.self, forKey: .etymology) ?? ""
        derivatives = try container.decodeIfPresent([DictionaryRelatedWord].self, forKey: .derivatives) ?? []
        synonyms = try container.decodeIfPresent([DictionaryRelatedWord].self, forKey: .synonyms) ?? []
        antonyms = try container.decodeIfPresent([DictionaryRelatedWord].self, forKey: .antonyms) ?? []
        family = try container.decodeIfPresent(DictionaryWordFamily.self, forKey: .family)
            ?? DictionaryWordFamily()
        formNote = try container.decodeIfPresent(String.self, forKey: .formNote) ?? ""
        baseForm = try container.decodeIfPresent(String.self, forKey: .baseForm) ?? ""
    }

    /// 一条可用内容都没有（全是空）——UI 据此如实说「没查到」。
    public var isEmpty: Bool {
        senses.isEmpty && collocations.isEmpty && examples.isEmpty
            && morphology.isEmpty && etymology.isEmpty
            && derivatives.isEmpty && synonyms.isEmpty && antonyms.isEmpty
            && family.isEmpty
    }

    /// 「派生词 / 近义 / 反义」三栏里至少要有一栏才画那一行。
    public var hasRelated: Bool {
        !derivatives.isEmpty || !synonyms.isEmpty || !antonyms.isEmpty
    }

    /// 可点击跳转的词（派生词 + 近义词 + 反义词），按出现顺序去重。
    public var relatedWords: [DictionaryRelatedWord] {
        var seen = Set<String>()
        var result: [DictionaryRelatedWord] = []
        for list in [derivatives, synonyms, antonyms] {
            for item in list where !item.word.isEmpty {
                let key = item.word.lowercased()
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                result.append(item)
            }
        }
        return result
    }
}

// MARK: - 查词结果解析

/// 把模型输出解析成 `DictionaryDetail`（**纯函数**）。
///
/// 格式：一行一个键，**可重复的键重复写**，子字段用 `|` 分隔：
/// ```
/// word: nominal
/// phonetic_us: /ˈnɑːmɪnl/
/// phonetic_uk: /ˈnɒmɪnl/
/// sense: adj. | 名义上的；有名无实的
/// sense: n. | [语] 名词性词
/// collocation: nominal fee | 象征性费用 | They only charged a nominal fee. | 他们只收象征性服务费。
/// example: The settler got the house at a nominal price. | 移居者象征性地花点钱买下了这栋房子。
/// morphology: nomin=名字 + -al=……的 => 名义上的
/// etymology: 源自拉丁语 nominalis……
/// derivative: nominally | adv. | 名义上地
/// synonym: titular | adj. | 名义上的
/// antonym: actual | adj. | 实际的；真实的
/// ```
///
/// 为什么不用词汇本那套「一个键一个值」：这里的固定搭配、例句、派生词天生是**多条**，
/// 挤进一个键里就得再发明一层分隔符，反而更脆。重复键是最省事、也最不容易错位的写法。
///
/// 健壮性沿用词汇本那一套（都是实测踩过的坑）：剥围栏、容忍寒暄、键名归一化、
/// 字段名回显视为缺席；另外**单行解析失败只丢那一行**，不倒整份结果。
public enum DictionaryDetailRule {

    /// 子字段分隔符（全角半角都认）。
    static let subSeparators: [Character] = ["|", "｜"]

    /// 解析模型输出。认不出任何字段 → 空结果（`isEmpty == true`，UI 如实说没查到）。
    public static func parse(_ raw: String, fallbackWord: String = "") -> DictionaryDetail {
        var detail = DictionaryDetail(word: fallbackWord)
        var morphologyParts: [String] = []
        var morphologyResult = ""
        // 词族树：散行先收着，最后一次性组装成树（父子关系不能边读边定 —— 父词可能后出现）。
        var familyRoot = ""
        var familyRootMeaning = ""
        var familyBranches: [[String]] = []
        var familyMembers: [[String]] = []

        let lines = raw
            .replacingOccurrences(of: "```", with: "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        for line in lines {
            guard let (key, value) = splitKeyed(line) else { continue }
            let fields = splitFields(value)
            guard !fields.isEmpty else { continue }

            switch key {
            case "word", "headword", "单词", "词条":
                if detail.word.isEmpty { detail.word = fields[0] }
            case "phoneticus", "us", "phonetic", "ipa", "音标", "美":
                detail.phoneticUS = usablePhonetic(fields[0])
            case "phoneticuk", "uk", "英":
                detail.phoneticUK = usablePhonetic(fields[0])
            case "sense", "meaning", "meanings", "释义", "义项":
                if let sense = sense(fields) { detail.senses.append(sense) }
            case "collocation", "collocations", "phrase", "固定搭配", "搭配":
                if let item = collocation(fields) { detail.collocations.append(item) }
            case "example", "sentence", "例句":
                if let item = example(fields) { detail.examples.append(item) }
            case "morphology", "wordformation", "构词", "构词拆分":
                let (parts, result) = morphologyLine(fields)
                morphologyParts.append(contentsOf: parts)
                if !result.isEmpty { morphologyResult = result }
            case "etymology", "origin", "词源":
                if detail.etymology.isEmpty { detail.etymology = fields.joined(separator: " ") }
            case "derivative", "derivatives", "派生词":
                if let item = related(fields) { detail.derivatives.append(item) }
            case "synonym", "synonyms", "近义词", "同义词":
                if let item = related(fields) { detail.synonyms.append(item) }
            case "antonym", "antonyms", "反义词":
                if let item = related(fields) { detail.antonyms.append(item) }
            case "wordfamilyroot", "familyroot", "wordroot", "词根":
                let rootFields = splitFamilyFields(value)
                if !rootFields.isEmpty {
                    if familyRoot.isEmpty { familyRoot = rootFields[0] }
                    if rootFields.count > 1 { familyRootMeaning = rootFields[1] }
                }
            case "wordfamilybranch", "familybranch", "familybranches", "词族分支":
                familyBranches.append(splitFamilyFields(value))
            case "wordfamilymember", "familymember", "familymembers", "词族成员", "关联词":
                familyMembers.append(splitFamilyFields(value))
            case "form", "wordform", "variantform", "inflection", "inflectedform", "词形", "变体", "形式":
                let parsed = formLine(fields)
                if detail.baseForm.isEmpty { detail.baseForm = parsed.base }
                if detail.formNote.isEmpty { detail.formNote = parsed.note }
            default:
                break
            }
        }

        detail.morphology = DictionaryMorphology(
            parts: morphologyParts.map { part in
                let pieces = part.components(separatedBy: "=")
                return DictionaryMorphPart(
                    text: pieces[0].trimmingCharacters(in: .whitespaces),
                    label: pieces.count > 1 ? pieces[1].trimmingCharacters(in: .whitespaces) : ""
                )
            },
            result: morphologyResult
        )
        if detail.word.isEmpty { detail.word = fallbackWord }
        detail.family = DictionaryFamilyBuilder.build(
            root: familyRoot,
            rootMeaning: familyRootMeaning,
            branches: familyBranches,
            members: familyMembers
        )
        // ⚠️ 兜底：模型偶尔不按 `key: value` 回，而是**写一句话解释**。
        // 实测变体词最容易触发 —— 它想说「subtitles 是 subtitle 的复数」，
        // 于是整条回复变成散文，解析不出任何字段，页面就说「没查到」。
        // 只要那句话短、单行，就把它当释义收下：用户要的是「查到」，不是「格式漂亮」。
        if detail.isEmpty, let prose = unstructuredSummary(raw) {
            detail.senses = [DictionarySense(text: prose)]
        }
        return detail
    }

    /// 整份输出完全解析不出来时，从原文里抢救一句能当释义用的话。
    ///
    /// 边界（都很紧，宁可不收也别把一坨东西塞进释义）：
    /// - 单行、≤ 160 字（多行 = 它在列清单，不是一句解释）；
    /// - 真的是 `键: 值` 外形时，只取**陌生键**的值（已知键的值为空说明它没答上来）；
    /// - 值恰好是键名（`form` / `meaning` 这类回显）一律不算；
    /// - **推辞不算内容**：「抱歉，我不知道这个词」不是释义，收了就是拿假信息充数。
    static func unstructuredSummary(_ raw: String) -> String? {
        let text = raw
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("\n"), text.count <= 160 else { return nil }
        let candidate: String
        if let (key, value) = splitKeyed(text) {
            guard !knownKeys.contains(key), !value.isEmpty, value.count <= 160 else { return nil }
            candidate = value
        } else {
            guard !knownKeys.contains(normalizeKey(text)) else { return nil }
            candidate = text
        }
        guard !isRefusal(candidate) else { return nil }
        return candidate
    }

    /// 这句话是在**推辞**而不是在解释（中英都要认：模型两种都写过）。
    static func isRefusal(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let markers = [
            "抱歉", "不知道", "无法查", "无法确定", "没有查到", "查不到", "不是一个词", "拼写有误",
            "sorry", "i cannot", "i can't", "can not", "unable to", "don't know", "do not know",
            "no such word", "not a word", "no definition",
        ]
        return markers.contains { lowered.contains($0) }
    }

    /// `form:` 那一行 → (本体, 变体说明)。
    ///
    /// 认三种写法：
    /// - `subtitles = subtitle | 复数形式，指影片字幕` → 本体 `subtitle`，说明取最后一段；
    /// - `subtitles = subtitle` → 只给了对应关系，说明留空（气泡第一行已经写着是哪个词了）；
    /// - `复数形式，指影片字幕` → 没有对应关系，整条都当说明。
    static func formLine(_ fields: [String]) -> (base: String, note: String) {
        guard let first = fields.first else { return ("", "") }
        var base = ""
        let mapping = formMapping(first)
        if let mapping { base = mapping.base }
        if fields.count > 1 {
            return (base, fields.dropFirst().joined(separator: " "))
        }
        return (base, mapping == nil ? first : "")
    }

    /// `subtitles = subtitle` → (`subtitles`, `subtitle`)。不是「A = B」形状就返回 nil。
    ///
    /// 本体必须是**像个词的**一串字母：模型偶尔写成 `subtitles = subtitle 的复数`，
    /// 那种宁可不要，也不能把一整句话当成单词塞进「本体」。
    static func formMapping(_ text: String) -> (surface: String, base: String)? {
        let pieces = text.components(separatedBy: "=").map { $0.trimmingCharacters(in: .whitespaces) }
        guard pieces.count == 2, !pieces[0].isEmpty else { return nil }
        let base = pieces[1]
        guard !base.isEmpty, base.count <= 32,
              base.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" })
        else { return nil }
        return (pieces[0], base)
    }

    // MARK: - 键与字段

    /// 键名归一化：去装饰前缀 / 下划线 / 空格，统一小写。
    static func normalizeKey(_ raw: String) -> String {
        var key = raw.trimmingCharacters(in: .whitespaces)
        while let first = key.first, "-*•#·>".contains(first) {
            key = String(key.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return key
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }

    /// 拆「键：值」。键必须短且只由字母 / 中文组成，免得把例句里的冒号当分隔符。
    static func splitKeyed(_ line: String) -> (key: String, value: String)? {
        guard let index = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return nil }
        let rawKey = String(line[line.startIndex..<index]).trimmingCharacters(in: .whitespaces)
        guard !rawKey.isEmpty, rawKey.count <= 26 else { return nil }
        let key = normalizeKey(rawKey)
        guard !key.isEmpty, key.count <= 26,
              key.allSatisfy({ $0.isLetter || $0 == "_" })
        else { return nil }
        let value = String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    /// 值按 `|` 切成子字段（去掉空段与占位符 `-`）。
    static func splitFields(_ value: String) -> [String] {
        var fields: [String] = []
        var current = ""
        for character in value {
            if subSeparators.contains(character) {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        fields.append(current)
        return fields
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "-" && !isPlaceholder($0) }
    }

    /// 词族专用字段拆分：**不过滤占位符**（见 `isPlaceholder`）。
    ///
    /// ⚠️ 词族行的**第一个字段是父词**，而父词是英语单词 —— 「回显防御」会把恰好同名于键的
    /// 单词整个删掉（`derivative | rivulet | n. | 小溪` 里的 `derivative` 被当成回显），
    /// 后面每一列就整体错位一格：`rivulet` 被当成父词、`n.` 被当成词条、`小溪` 被当成释义
    /// （这条是加完守卫测试才发现的，肉眼 review 很难看出来）。
    /// `word → wording`、`sentence → sentential`、`origin → original` 这些真词族同样会翻车，
    /// 所以这一路宁可保留一个可能的回显值，也不能吞掉用户的词。
    static func splitFamilyFields(_ value: String) -> [String] {
        var fields: [String] = []
        var current = ""
        for character in value {
            if subSeparators.contains(character) {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        fields.append(current)
        return fields
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "-" }
    }

    /// 字段名回显防御（`meaning: MEANING` 这种）。**只对普通字段生效**。
    static func isPlaceholder(_ value: String) -> Bool {
        knownKeys.contains(normalizeKey(value))
    }

    static let knownKeys: Set<String> = [
        "word", "headword", "phonetic", "phoneticus", "phoneticuk", "us", "uk", "ipa",
        "sense", "meaning", "meanings", "collocation", "collocations", "phrase",
        "example", "sentence", "morphology", "wordformation", "etymology", "origin",
        "derivative", "derivatives", "synonym", "synonyms", "antonym", "antonyms",
        "wordfamilyroot", "familyroot", "wordroot", "wordfamilybranch", "familybranch",
        "familybranches", "wordfamilymember", "familymember", "familymembers",
        "form", "wordform", "variantform", "inflection", "inflectedform",
        "单词", "词条", "音标", "释义", "义项", "固定搭配", "搭配", "例句",
        "构词", "构词拆分", "词源", "派生词", "近义词", "同义词", "反义词", "美", "英",
        "词根", "词族分支", "词族成员", "关联词", "词形", "变体", "形式",
    ]

    /// 音标必须像音标（至少 3 个字符且含字母）——否则宁可空着，也不显示一个孤零零的斜杠。
    static func usablePhonetic(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard value.count >= 3, value.contains(where: { $0.isLetter }) else { return "" }
        return value
    }

    // MARK: - 各字段构造

    /// `adj. | 名义上的；有名无实的 | 说明` —— 词性可省（那就整条当义项）。
    static func sense(_ fields: [String]) -> DictionarySense? {
        guard !fields.isEmpty else { return nil }
        guard fields.count > 1 else { return DictionarySense(text: fields[0]) }
        return DictionarySense(pos: fields[0], text: fields[1], explanation: fields.count > 2 ? fields[2] : "")
    }

    /// `nominal fee | 象征性费用 | 例句 | 例句翻译`（后三段都可省）。
    static func collocation(_ fields: [String]) -> DictionaryCollocation? {
        guard let phrase = fields.first, !phrase.isEmpty else { return nil }
        return DictionaryCollocation(
            phrase: phrase,
            translation: fields.count > 1 ? fields[1] : "",
            example: fields.count > 2 ? fields[2] : "",
            exampleTranslation: fields.count > 3 ? fields[3] : ""
        )
    }

    /// `例句 | 翻译`。
    static func example(_ fields: [String]) -> DictionaryExample? {
        guard let text = fields.first, !text.isEmpty else { return nil }
        return DictionaryExample(text: text, translation: fields.count > 1 ? fields[1] : "")
    }

    /// `nomin=名字 + -al=……的 => 名义上的`
    ///
    /// 兼容两种写法：带 `=>` 的完整式，以及**只给几段拼接**的简式
    /// （`nomin + -al`）—— 简式下 `result` 留空，UI 只画拼接链。
    static func morphologyLine(_ fields: [String]) -> ([String], String) {
        let joined = fields.joined(separator: " | ")
        var result = ""
        var body = joined
        for marker in ["=>", "＝>", "→", "->"] {
            if let range = body.range(of: marker) {
                result = String(body[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                body = String(body[body.startIndex..<range.lowerBound])
                break
            }
        }
        let parts = body
            .components(separatedBy: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return (parts, result)
    }

    /// `nominally | adv. | 名义上地`（词性与中文都可省）。
    ///
    /// 也兼容模型把词性和中文都塞进同一个字段的两种写法：
    /// - `nominally (adv.) 名义上地`
    /// - `nominally (adv.) | 名义上地`
    /// 词性**必须**拆出来：否则「点击单词去查」会拿「nominally (adv.)」当查询词。
    static func related(_ fields: [String]) -> DictionaryRelatedWord? {
        guard let first = fields.first, !first.isEmpty else { return nil }
        let split = splitInlinePOS(first)
        let extras = fields.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }

        var pos = split.pos
        var translation = split.translation
        if let firstExtra = extras.first {
            if looksLikePartOfSpeech(firstExtra) {
                pos = firstExtra
                translation = extras.count > 1 ? extras[1] : split.translation
            } else {
                translation = firstExtra
            }
        }
        return DictionaryRelatedWord(word: split.word, pos: pos, translation: translation)
    }

    /// `nominally (adv.) 名义上地` → (`nominally`, `adv.`, `名义上地`)。
    ///
    /// 括号内不是词性（比如是一整句中文）就当没有括号，原样返回——
    /// 宁可少拆一次，也不能把释义误当成词。
    static func splitInlinePOS(_ raw: String) -> (word: String, pos: String, translation: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let open = trimmed.firstIndex(of: "("),
              let close = trimmed[trimmed.index(after: open)...].firstIndex(of: ")") else {
            return (trimmed, "", "")
        }
        let word = String(trimmed[trimmed.startIndex..<open]).trimmingCharacters(in: .whitespaces)
        let inside = String(trimmed[trimmed.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
        let tail = String(trimmed[trimmed.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty, looksLikePartOfSpeech(inside) else { return (trimmed, "", "") }
        return (word, inside, tail)
    }

    /// 一眼看去像词性标记：`n.` / `v. tr.` / `adj./adv.` 之类。
    ///
    /// 中文虽然也满足 `isLetter`，按 ASCII 收窄就自动排除了 —— 词性不该写成中文。
    static func looksLikePartOfSpeech(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 12 else { return false }
        return text.allSatisfy {
            guard $0.isASCII else { return false }
            return $0.isLetter || $0 == "." || $0 == "/" || $0.isWhitespace || $0 == "-"
        }
    }
}

// MARK: - 查词跳转历史

/// 查词页的**跳转历史**（纯值类型）。
///
/// 产品口径（用户原话）：「派生词 / 近义词 / 反义词点击后自动跳转搜索该词，
/// 页面左上角出现返回上一页图标；多层跳转时再加一个一键回到最初查找的词」。
/// 所以「最初那个词」= 历史的第一条，且它**只在多层跳转时**才有意义
/// （只是查了两个词就有两个返回目标，反而是噪音）。
public struct DictionaryLookupSession: Sendable, Equatable {

    /// 查过的词，**按查找顺序**（最后一个是当前页）。
    public private(set) var history: [String]
    /// 已取到的详情（键为小写词）——回退时**不重新请求**，来回点也不烧 token。
    public private(set) var details: [String: DictionaryDetail]

    public init(history: [String] = [], details: [String: DictionaryDetail] = [:]) {
        self.history = history
        self.details = details
    }

    /// 空会话（还没查过任何词）。
    public static let empty = DictionaryLookupSession()

    /// 当前展示的词。
    public var currentWord: String? { history.last }

    /// 当前展示的详情（还没拿到 → nil，UI 显示加载中）。
    public var current: DictionaryDetail? {
        guard let word = currentWord else { return nil }
        return details[word.lowercased()]
    }

    /// 最初查找的那个词。
    public var originWord: String? { history.first }

    /// 有没有「上一页」可回。
    public var canGoBack: Bool { history.count >= 2 }

    /// 要不要显示「回到最初」：**至少三层**才显示（两层时它和「上一页」是同一个目标）。
    public var canReturnToOrigin: Bool { history.count >= 3 }

    /// 查一个**新**词：历史从它重新开始（旧历史不再可回）。
    public mutating func present(_ detail: DictionaryDetail) {
        let word = detail.word.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return }
        let key = word.lowercased()
        history = [word]
        details[key] = detail
    }

    /// 开始查一个**新**词，详情还没到（UI 显示加载中）。
    ///
    /// 与 `present` 分开是因为「先切页面、后落详情」：等模型回完再切页面，
    /// 用户会盯着上一页发呆十几秒，还以为自己没点中。
    public mutating func begin(_ word: String) {
        let clean = word.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        history = [clean]
    }

    /// 记下「查过了但要继续往后跳」的一页（如从详情点进派生词）。
    public mutating func remember(_ detail: DictionaryDetail) {
        let word = detail.word.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return }
        details[word.lowercased()] = detail
        if history.last?.lowercased() != word.lowercased() {
            history.append(word)
        }
    }

    /// 从当前详情**点击一个词跳转**。已经在历史里也照样入栈（用户要看的是「我点过」）。
    public mutating func push(_ word: String) {
        let clean = word.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, history.last?.lowercased() != clean.lowercased() else { return }
        history.append(clean)
    }

    /// 回到上一页；返回要展示的词（历史不足时不动，返回 nil）。
    @discardableResult
    public mutating func goBack() -> String? {
        guard canGoBack else { return nil }
        history.removeLast()
        return history.last
    }

    /// 撤掉「页面已经切过去、结果还没回来」的那一页（用户取消了这次查询）。
    ///
    /// ⚠️ 只撤**没有详情**的那一页：已经查到的词留在历史与缓存里
    /// （来回点不重新烧 token），撤掉的是那个空壳 —— 不撤的话页面会一直
    /// 停在「正在查…」上，因为那次请求已经不会再回来了。
    ///
    /// - Returns: 撤掉了没有（撤不动 = 当前页已经有详情，或者压根没有当前页）。
    @discardableResult
    public mutating func discardPendingCurrent() -> Bool {
        guard currentWord != nil, current == nil else { return false }
        history.removeLast()
        return true
    }

    /// 一键回到最初查的词：历史只剩它一个。
    @discardableResult
    public mutating func returnToOrigin() -> String? {
        guard canReturnToOrigin, let origin = history.first else { return nil }
        history = [origin]
        return origin
    }

    /// 某词的详情（已缓存才有）。
    public func detail(for word: String) -> DictionaryDetail? {
        details[word.lowercased()]
    }

    /// 记下某词的详情（按需查完回填）。词不在历史里也照存（便于复用）。
    public mutating func cache(_ detail: DictionaryDetail) {
        let word = detail.word.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty else { return }
        details[word.lowercased()] = detail
    }
}
