import AIDomain
import AppCore
import Foundation

// MARK: - 内置词典目录

/// 随包内置的四本书（牛津核心 / 六级核心 / 雅思标准 / 常用搭配）。
///
/// 词条**只从资源文件读**，代码零字面量：补词 / 改中文只改
/// `Resources/Dictionaries/*.json`。生成脚本见 `Scripts/build_dictionaries.py`
/// （词书，音标由离线 IPA 词典统一生成，不手写）与 `Scripts/build_phrase_book.py`
/// （词组书，多词短语不生成音标）。
public enum DictionaryCatalog {

    /// 一本书是**词书**还是**词组书**。
    ///
    /// ⚠️ 词组书不是「多了一本词书」：它只收多词搭配（`difficulty` 全是 4），
    /// 每日推荐的字组档靠它供货、查词组也优先归它。UI 文案与测试都要能分辨这两类，
    /// 所以做成**数据**而不是散落各处的字符串比较（那种写法会在改名时静默失效）。
    /// 注意 `Spec` 不进 `UserDefaults`（只有 `DictionaryBook` 进），所以加字段零兼容风险。
    public enum BookKind: Sendable, Equatable {
        case words
        case phrases
    }

    /// 一本书的固定信息（词条数在加载后才知道）。
    public struct Spec: Sendable, Equatable {
        public var id: String
        public var file: String
        public var name: String
        public var coverLabel: String
        public var subtitle: String
        public var coverStyle: DictionaryBook.CoverStyle
        public var kind: BookKind = .words
    }

    /// 词组书的 id（推荐兜底排序与查找去重都要用它，别再写字面量）。
    public static let phraseBookID = "builtin.phrases"

    public static let specs: [Spec] = [
        Spec(
            id: phraseBookID,
            file: "phrases",
            name: "常用搭配",
            coverLabel: "搭配",
            subtitle: "固定搭配与词组",
            coverStyle: .plum,
            kind: .phrases
        ),
        Spec(
            id: "builtin.ielts",
            file: "ielts",
            name: "雅思标准词",
            coverLabel: "雅思",
            subtitle: "雅思听说写常用",
            coverStyle: .forest
        ),
        Spec(
            id: "builtin.cet6",
            file: "cet6",
            name: "六级核心词汇",
            coverLabel: "六级",
            subtitle: "大学英语六级",
            coverStyle: .ocean
        ),
        Spec(
            id: "builtin.oxford",
            file: "oxford",
            name: "牛津核心词",
            coverLabel: "牛津",
            subtitle: "常用词与基础搭配",
            coverStyle: .sunset
        ),
    ]

    /// 词组书（`kind == .phrases` 的那本）。
    public static var phraseBook: Spec? {
        specs.first { $0.kind == .phrases }
    }

    /// 内置词典的元数据（词条数来自实际加载结果）。
    public static var builtInBooks: [DictionaryBook] {
        specs.map { spec in
            let count = words(bookID: spec.id).count
            return DictionaryBook(
                id: spec.id,
                name: spec.name,
                coverLabel: spec.coverLabel,
                subtitle: spec.subtitle,
                entryCount: count,
                isBuiltIn: true,
                coverStyle: spec.coverStyle
            )
        }
    }

    /// 某本内置词典的词条（非内置 id 返回空）。
    public static func words(bookID: String) -> [DictionaryWord] {
        guard let spec = specs.first(where: { $0.id == bookID }) else { return [] }
        return cache.value(for: spec)
    }

    /// 内置词典的全部词条（按 specs 顺序拼接）。
    public static var allWords: [DictionaryWord] {
        specs.flatMap { cache.value(for: $0) }
    }

    /// 资源文件读一次就够（三本合计数千条、约 1 MB，每次搜索都重读纯属浪费）。
    private static let cache = ResourceCache()

    private final class ResourceCache: @unchecked Sendable {
        private var storage: [String: [DictionaryWord]] = [:]
        private let lock = NSLock()

        func value(for spec: Spec) -> [DictionaryWord] {
            lock.lock()
            defer { lock.unlock() }
            if let cached = storage[spec.file] { return cached }
            let loaded = Self.load(spec)
            storage[spec.file] = loaded
            return loaded
        }

        private static func load(_ spec: Spec) -> [DictionaryWord] {
            guard let data = resourceData(file: spec.file) else {
                AppLog.warning("未找到内置词典资源（Resources/Dictionaries/\(spec.file).json）", category: "dictionary")
                return []
            }
            guard let parsed = DictionaryFileParser.parse(data, bookID: spec.id) else {
                AppLog.warning("内置词典解析失败（\(spec.file).json）", category: "dictionary")
                return []
            }
            return parsed.words
        }

        /// 两种打包布局都试一遍（与词汇本词库同一套兜底）。
        private static func resourceData(file: String) -> Data? {
            if let url = AppResourceBundle.module.url(forResource: "Dictionaries/\(file)", withExtension: "json"),
               let data = try? Data(contentsOf: url) {
                return data
            }
            if let url = AppResourceBundle.module.url(forResource: file, withExtension: "json"),
               let data = try? Data(contentsOf: url) {
                return data
            }
            return nil
        }
    }
}

// MARK: - 词典库（用户状态 + 导入的词典）

/// 词典库仓库：内置词典读资源、导入词典落 `.workbuddy/app-config/dictionaries/`，
/// 用户状态（删了哪本、哪几本是每日推荐词源）落 `.workbuddy/app-config/dictionaries.json`。
///
/// 与 `VoiceProfileStore` 同构：一个 actor 管一份 JSON，写入只有一条路，没有内存副本漂移。
public actor DictionaryBookStore {

    public static let shared = DictionaryBookStore()

    private var library: DictionaryLibrary
    private let fileURL: URL
    private let booksDirectory: URL
    /// 导入词典的词条缓存（导入时读一次）。
    private var importedWords: [String: [DictionaryWord]] = [:]
    /// 搜索词表的缓存（`searchableWords()` 的结果）。
    private var searchableCache: [DictionaryWord]?

    public init(fileURL: URL? = nil, booksDirectory: URL? = nil) {
        let base = AppPaths.userDataDirectory()
        self.fileURL = fileURL ?? base.appendingPathComponent("dictionaries.json")
        self.booksDirectory = booksDirectory ?? base.appendingPathComponent("dictionaries", isDirectory: true)
        // 读不出来（文件不存在 / 写坏）时按「一本没删、没有导入」处理，
        // **不删也不改名**：宁可重新开始，也不能把用户导入的书悄悄丢掉。
        self.library = Self.read(from: self.fileURL) ?? .empty
    }

    // MARK: 读

    public var state: DictionaryLibrary { library }

    /// 内置词典元数据（词条数取自资源）。
    public var builtInBooks: [DictionaryBook] { DictionaryCatalog.builtInBooks }

    /// 当前可见的书（内置去掉已删的 + 导入的）。
    public var visibleBooks: [DictionaryBook] {
        library.visibleBooks(builtIns: builtInBooks)
    }

    /// 全部书（含已删的内置，恢复入口用）。
    public var allBooks: [DictionaryBook] {
        library.allBooks(builtIns: builtInBooks)
    }

    /// 搜索用的书序（优先级高的在前，词组书在同优先级里排最前）。
    public var searchOrder: [DictionaryBook] {
        library.searchOrder(builtIns: builtInBooks, phraseBookID: DictionaryCatalog.phraseBookID)
    }

    /// 某本书的词条（内置查资源 / 导入查文件，都走缓存）。
    public func words(bookID: String) -> [DictionaryWord] {
        if DictionaryCatalog.specs.contains(where: { $0.id == bookID }) {
            return DictionaryCatalog.words(bookID: bookID)
        }
        if let cached = importedWords[bookID] { return cached }
        let loaded = Self.readImportedWords(bookID: bookID, in: booksDirectory)
        importedWords[bookID] = loaded
        return loaded
    }

    /// 可见词典的全部词条，按搜索顺序拼接（同名词先出现的是优先级高的那本）。
    ///
    /// ⚠️ **这里是「查词组优先从词组书匹配」真正生效的地方**：词组书在 `searchOrder`
    /// 的同优先级里排最前，而这里按该顺序**逐本去重**，于是同一个词条只会留下词组书
    /// 那一份（内嵌在词书里的 `give up` 这类会被挡掉），查找与每日推荐就都落在词组书上。
    /// 所以不需要在匹配打分里再加一条「词组优先」—— 池子里根本没有第二份可争。
    ///
    /// 结果缓存：词库是上万条的规模，而搜索框**每敲一个键**都会走这里。
    /// 缓存失效只有一条路 —— `persist()`（所有会改变可见书 / 优先级的写操作都经过它）。
    public func searchableWords() -> [DictionaryWord] {
        if let cached = searchableCache { return cached }
        var seen = Set<String>()
        var result: [DictionaryWord] = []
        for book in searchOrder {
            for word in words(bookID: book.id) where !seen.contains(word.word.lowercased()) {
                seen.insert(word.word.lowercased())
                result.append(word)
            }
        }
        searchableCache = result
        return result
    }

    /// 每日推荐的选词池（按优先级排序，一本一个池子；词组书默认排最前）。
    public func recommendationPools() -> [[DailyWord]] {
        let books = visibleBooks
        let ids = library.sourceBookIDs(builtIns: builtInBooks, phraseBookID: DictionaryCatalog.phraseBookID)
        return ids.compactMap { id in
            guard books.contains(where: { $0.id == id }) else { return nil }
            return words(bookID: id).map(\.dailyWord)
        }
    }

    // MARK: 写

    /// 删掉一本书：内置只隐藏（可恢复），导入的连文件一起删。
    /// 返回被删的那本书（给 UI 提示用）。
    @discardableResult
    public func removeBook(id: String) throws -> DictionaryBook? {
        guard let book = allBooks.first(where: { $0.id == id }) else { return nil }
        if book.isBuiltIn {
            library = DictionaryLibrary.removing(id, from: library)
        } else {
            library = DictionaryLibrary.droppingImported(id, from: library)
            importedWords.removeValue(forKey: id)
            try? FileManager.default.removeItem(at: booksDirectory.appendingPathComponent("\(id).json"))
        }
        try persist()
        return book
    }

    /// 恢复一本内置词典。
    public func restoreBook(id: String) throws {
        library = DictionaryLibrary.restoring(id, in: library)
        try persist()
    }

    /// 一键恢复全部内置词典。
    public func restoreBuiltIns() throws {
        library = DictionaryLibrary.restoringBuiltIns(library)
        try persist()
    }

    /// 勾选 / 取消「作为每日推荐词源」。
    @discardableResult
    public func toggleSource(id: String) throws -> Bool {
        library = DictionaryLibrary.togglingSource(id, in: library)
        try persist()
        return library.rank(of: id) != nil
    }

    /// 导入一本词典。文件格式见 `DictionaryFileParser`（只有 `word` 必填）。
    /// 解析不出任何词条 → 抛错（由 UI 提示格式）。
    @discardableResult
    public func importBook(from url: URL, name: String? = nil) throws -> DictionaryBook {
        let data = try Data(contentsOf: url)
        let id = "imported.\(UUID().uuidString.lowercased())"
        guard let parsed = DictionaryFileParser.parse(data, bookID: id) else {
            throw AppError.storage("这个文件里没有读到任何词条。词典是 JSON 数组，每条至少要有 word 字段。")
        }
        // 落一份到自己的目录：用户之后把原文件删了 / 挪了，词典也还在。
        try? FileManager.default.createDirectory(at: booksDirectory, withIntermediateDirectories: true)
        try? data.write(to: booksDirectory.appendingPathComponent("\(id).json"), options: .atomic)
        importedWords[id] = parsed.words

        let fallbackName = url.deletingPathExtension().lastPathComponent
        let book = DictionaryBook(
            id: id,
            name: (name ?? parsed.name) ?? (fallbackName.isEmpty ? "导入的词典" : fallbackName),
            coverLabel: String(((name ?? parsed.name) ?? fallbackName).prefix(2)),
            subtitle: parsed.subtitle ?? "\(parsed.words.count) 词 · 导入",
            entryCount: parsed.words.count,
            isBuiltIn: false,
            coverStyle: Self.coverStyle(for: id),
            importedAt: Date()
        )
        library.importedBooks.append(book)
        try persist()
        return book
    }

    // MARK: 持久化

    private func persist() throws {
        // 唯一的写入口 = 唯一的失效点：删书 / 恢复 / 改优先级 / 导入都会经过这里，
        // 而它们每一个都可能改变可见书集合或搜索顺序。
        searchableCache = nil
        do {
            try Self.write(library, to: fileURL)
        } catch {
            throw AppError.storage("保存词典库失败：\(error.localizedDescription)")
        }
    }

    private static func read(from url: URL) -> DictionaryLibrary? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(DictionaryLibrary.self, from: data)
    }

    private static func readImportedWords(bookID: String, in directory: URL) -> [DictionaryWord] {
        // 文件名就是 id（导入时写下的），不认 id 里的路径分隔符以外的东西。
        let url = directory.appendingPathComponent("\(bookID).json")
        guard let data = try? Data(contentsOf: url),
              let parsed = DictionaryFileParser.parse(data, bookID: bookID)
        else { return [] }
        return parsed.words
    }

    private static func write(_ library: DictionaryLibrary, to url: URL) throws {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(library).write(to: url, options: .atomic)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// 导入的书也要有封面：按 id 的哈希分配一档，同一本书每次进来颜色都一样。
    static func coverStyle(for id: String) -> DictionaryBook.CoverStyle {
        var hash = 5381
        for scalar in id.unicodeScalars {
            hash = (hash &* 33) &+ Int(scalar.value)
        }
        let all = DictionaryBook.CoverStyle.allCases
        return all[abs(hash) % all.count]
    }
}
