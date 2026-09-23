@testable import AIDomain
import AIInfrastructure
import AIServices
import XCTest

/// 词典（新功能）领域层与数据层的单元测试。
///
/// 覆盖四块：解析（模型输出 → 条目）、词典库状态（删 / 恢复 / 优先级）、
/// 搜索匹配（与词汇本联想同一把尺）、查词跳转历史（上一页 / 回到最初）。
/// 都是纯函数，跑得快 —— 词典最复杂的逻辑全在这里，UI 只负责画。
final class DictionaryTests: XCTestCase {

    // MARK: - 详情解析

    /// 与 `Resources/Prompts/dictionary_lookup.txt` 里那段「标准答案」同构的一例。
    private let modelReply = """
    word: nominal
    phonetic_us: /ˈnɑːmɪnl/
    phonetic_uk: /ˈnɒmɪnl/
    sense: adj. | 名义上的；有名无实的；[会计] 票面上的
    sense: n. | [语] 名词性词
    collocation: nominal fee | 象征性费用 | They only charged a nominal fee for the service. | 他们只收取了象征性的服务费。
    collocation: nominal value | 票面价值 | The nominal value of the share is $10. | 该股票的票面价值为 10 美元。
    example: The settler got the house at a nominal price. | 移居者象征性地花点钱买下了这栋房子。
    example: He is the nominal head of the company. | 他是公司名义上的负责人。
    morphology: nomin=名字 + -al=……的 => 名义上的
    etymology: 源自拉丁语 nominalis，本义「名字的」。
    derivative: nominally | adv. | 名义上地
    derivative: nominalize | v. | 使具名
    synonym: titular | adj. | 名义上的
    antonym: actual | adj. | 实际的；真实的
    """

    func testParsesFullEntry() {
        let detail = DictionaryDetailRule.parse(modelReply, fallbackWord: "nominal")
        XCTAssertEqual(detail.word, "nominal")
        XCTAssertEqual(detail.phoneticUS, "/ˈnɑːmɪnl/")
        XCTAssertEqual(detail.phoneticUK, "/ˈnɒmɪnl/")
        XCTAssertEqual(detail.senses.count, 2, "重复的 sense 键要各占一条，不能互相覆盖")
        XCTAssertEqual(detail.senses[0].pos, "adj.")
        XCTAssertEqual(detail.senses[0].text, "名义上的；有名无实的；[会计] 票面上的")
        XCTAssertEqual(detail.senses[1].pos, "n.")
        XCTAssertEqual(detail.collocations.count, 2)
        XCTAssertEqual(detail.collocations[0].phrase, "nominal fee")
        XCTAssertEqual(detail.collocations[0].translation, "象征性费用")
        XCTAssertEqual(detail.collocations[0].exampleTranslation, "他们只收取了象征性的服务费。")
        XCTAssertEqual(detail.examples.count, 2)
        XCTAssertEqual(detail.examples[1].translation, "他是公司名义上的负责人。")
        XCTAssertEqual(detail.morphology.parts.map(\.text), ["nomin", "-al"])
        XCTAssertEqual(detail.morphology.parts.map(\.label), ["名字", "……的"])
        XCTAssertEqual(detail.morphology.result, "名义上的")
        XCTAssertFalse(detail.etymology.isEmpty)
        XCTAssertEqual(detail.derivatives.map(\.word), ["nominally", "nominalize"])
        XCTAssertEqual(detail.derivatives[0].pos, "adv.")
        XCTAssertEqual(detail.synonyms.map(\.word), ["titular"])
        XCTAssertEqual(detail.antonyms.map(\.word), ["actual"])
        XCTAssertFalse(detail.isEmpty)
        XCTAssertTrue(detail.hasRelated)
        XCTAssertEqual(detail.relatedWords.map(\.word), ["nominally", "nominalize", "titular", "actual"])
    }

    func testMissingSectionsStayEmptyInsteadOfFake() {
        // 只有释义与例句的条目：其余段落必须**真的空**，UI 才会整段不画。
        let detail = DictionaryDetailRule.parse("""
        word: diesel
        sense: n. | 柴油；柴油机
        example: But there is no more diesel trains running in HK now. | 但已经没有更多的柴油列车运行了。
        """, fallbackWord: "diesel")
        XCTAssertEqual(detail.senses.count, 1)
        XCTAssertTrue(detail.phoneticUS.isEmpty)
        XCTAssertTrue(detail.collocations.isEmpty)
        XCTAssertTrue(detail.morphology.isEmpty)
        XCTAssertTrue(detail.etymology.isEmpty)
        XCTAssertFalse(detail.hasRelated)
        XCTAssertFalse(detail.isEmpty, "有义项就不是空条目")
    }

    func testUnparsableReplyIsHonestlyEmpty() {
        let detail = DictionaryDetailRule.parse("抱歉，我不知道这个词。")
        XCTAssertTrue(detail.isEmpty, "认不出任何字段时必须如实为空，由 UI 说「没查到」")
        XCTAssertTrue(
            DictionaryDetailRule.parse("Sorry, I don't know this word.").isEmpty,
            "推辞不是释义 —— 收下来就是拿假信息充数"
        )
        let echoed = DictionaryDetailRule.parse("word: MEANING\nsense: sense")
        XCTAssertTrue(echoed.senses.isEmpty, "字段名回显不是内容")
    }

    // MARK: - 变体词（用户实测：`subtitles` / `listening` 一直查不到）

    /// 模型面对变体时常**不按格式回**，而是写一句话解释「这是谁的什么形式」。
    /// 这句话就是用户要的答案，不能因为格式不对就丢掉。
    func testProseReplyAboutAnInflectedFormIsRescued() {
        let detail = DictionaryDetailRule.parse("「listening」是 listen 的现在分词形式，表示正在听。")
        XCTAssertFalse(detail.isEmpty, "一句解释也是内容：用户在气泡上要的是查到，不是格式")
        XCTAssertEqual(detail.senses.count, 1)
        XCTAssertTrue(detail.senses[0].text.contains("listen"))
    }

    func testFormLineIsParsedForInflectedHeadwords() {
        let detail = DictionaryDetailRule.parse("""
        word: subtitle
        phonetic_us: /ˈsʌbtaɪtl/
        sense: n. | 字幕；（书的）副标题
        form: subtitles = subtitle | 复数形式，指影片的字幕
        """, fallbackWord: "subtitles")
        // ⚠️ `word` 仍是**用户查的那个写法**：`parse` 的兜底口径优先于模型回显的 `word`
        // （模型写错词时不能带偏），本体单独从 `form:` 那行取。
        XCTAssertEqual(detail.word, "subtitles")
        XCTAssertEqual(detail.baseForm, "subtitle", "本体来自 `A = B` 的右边")
        XCTAssertEqual(detail.formNote, "复数形式，指影片的字幕", "变体说明要单独拿到，气泡多显示一行")
        XCTAssertFalse(detail.isEmpty)
    }

    func testFormLineOnlyAcceptsARealWordAsBase() {
        // `subtitles = subtitle 的复数`：右边不是个词，宁可不要本体，也不能把一句话塞进去。
        let detail = DictionaryDetailRule.parse("""
        word: subtitles
        sense: n. | 字幕
        form: subtitles = subtitle 的复数 | 复数形式
        """)
        XCTAssertTrue(detail.baseForm.isEmpty, "拿到的是「\(detail.baseForm)」")
        XCTAssertEqual(detail.formNote, "复数形式")
    }

    func testFormLineWithOnlyTheMappingLeavesTheNoteEmpty() {
        // `subtitles = subtitle` 只给了对应关系：本体我们另存一份，说明位不该重复展示它。
        let detail = DictionaryDetailRule.parse("word: subtitle\nsense: n. | 字幕\nform: subtitles = subtitle")
        XCTAssertTrue(detail.formNote.isEmpty, "拿到的是「\(detail.formNote)」")
    }

    func testMissingFormNoteStaysEmpty() {
        let detail = DictionaryDetailRule.parse(modelReply, fallbackWord: "nominal")
        XCTAssertTrue(detail.formNote.isEmpty, "原形词没有变体说明")
    }

    /// 搜变体要能搜到本体：词典页搜索框里打 `subtitles` 也得给出 `subtitle` 这一条。
    func testMatcherFallsBackToTheBaseFormOfAnInflection() {
        let matched = DictionaryMatcher.match("nominations", in: words())
        XCTAssertEqual(matched.first?.word, "nomination", "\(matched.map(\.word))")
        // 原形自己搜得动的时候不许被兜底搅乱顺序。
        XCTAssertEqual(DictionaryMatcher.match("nomination", in: words()).first?.word, "nomination")
    }

    func testDashAndEmptyValuesAreDropped() {
        let detail = DictionaryDetailRule.parse("""
        word: hobby
        phonetic_us: -
        sense: -
        collocation: -
        example: I collect stamps as a hobby. | 我集邮作为爱好。
        etymology:
        """, fallbackWord: "hobby")
        XCTAssertTrue(detail.phoneticUS.isEmpty)
        XCTAssertTrue(detail.senses.isEmpty)
        XCTAssertTrue(detail.collocations.isEmpty)
        XCTAssertEqual(detail.examples.count, 1)
        XCTAssertTrue(detail.etymology.isEmpty)
    }

    func testCollocationWithoutExampleStillParses() {
        let detail = DictionaryDetailRule.parse("collocation: run out of | 用完；耗尽")
        XCTAssertEqual(detail.collocations.count, 1)
        XCTAssertEqual(detail.collocations[0].phrase, "run out of")
        XCTAssertEqual(detail.collocations[0].translation, "用完；耗尽")
        XCTAssertTrue(detail.collocations[0].example.isEmpty)
    }

    func testInlinePartOfSpeechInRelatedWords() {
        // 有些模型把词性塞进同一个字段：`nominally (adv.) 名义上地`。
        let detail = DictionaryDetailRule.parse("derivative: nominally (adv.) 名义上地")
        XCTAssertEqual(detail.derivatives.count, 1)
        XCTAssertEqual(detail.derivatives[0].word, "nominally", "词性必须从词里拆出来，否则点击跳转会查「nominally (adv.)」")
        XCTAssertEqual(detail.derivatives[0].pos, "adv.")
        XCTAssertEqual(detail.derivatives[0].translation, "名义上地")
    }

    func testFullWidthSeparatorsAndBarePhoneticAreTolerated() {
        let detail = DictionaryDetailRule.parse("""
        word：nominal
        phonetic_us：/ˈnɑːmɪnl/
        sense：adj. ｜ 名义上的
        """, fallbackWord: "nominal")
        XCTAssertEqual(detail.phoneticUS, "/ˈnɑːmɪnl/", "全角冒号 / 全角竖线都要认")
        XCTAssertEqual(detail.senses.first?.text, "名义上的")
        XCTAssertEqual(detail.senses.first?.pos, "adj.")
    }

    func testBareSlashPhoneticIsRejected() {
        let detail = DictionaryDetailRule.parse("word: hobby\nphonetic_us: /")
        XCTAssertTrue(detail.phoneticUS.isEmpty, "只回一个斜杠等于没给，不能把它画出来")
    }

    /// **模板与解析器必须成对**：提示词里让模型写的每个键，解析器都得认识。
    ///
    /// 这一条是防「改了提示词忘了改解析器」的：那种 bug 不报错，只是字段悄悄消失，
    /// 表现是「固定搭配怎么老是空的」——查起来极其费劲。
    func testPromptKeysAreAllUnderstoodByTheParser() throws {
        let url = try XCTUnwrap(
            AppResourceBundle.module.url(forResource: "Prompts/dictionary_lookup", withExtension: "txt")
                ?? AppResourceBundle.module.url(forResource: "dictionary_lookup", withExtension: "txt"),
            "查词提示词模板必须随包发布"
        )
        let template = try String(contentsOf: url, encoding: .utf8)

        var keys: Set<String> = []
        for line in template.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let colon = text.firstIndex(of: ":") else { continue }
            let key = String(text[text.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            // 只收「纯小写字母/下划线」的键（排除 JSON 示例、散文里的冒号）。
            guard !key.isEmpty, key.count <= 20,
                  key.allSatisfy({ $0.isLowercase || $0 == "_" })
            else { continue }
            keys.insert(key)
        }
        XCTAssertFalse(keys.isEmpty, "模板里应当能读出键名")
        for key in keys {
            XCTAssertTrue(
                DictionaryDetailRule.knownKeys.contains(DictionaryDetailRule.normalizeKey(key)),
                "提示词要求模型写「\(key)」，但解析器不认识这个键 —— 该字段会被静默丢掉"
            )
        }
        // 反向也要成立：解析器认识的键，模板里至少得提一个（防止两边彻底走散）。
        for required in ["word", "phonetic_us", "sense", "collocation", "example", "derivative"] {
            XCTAssertTrue(keys.contains(required), "模板必须要求模型写「\(required)」")
        }
    }

    // MARK: - 词典文件解析（导入 / 内置共用）

    func testFileParserAcceptsArrayAndObjectForms() throws {
        let array = try XCTUnwrap(DictionaryFileParser.parse(
            Data("""
            [{"word": "nominal", "phonetic": "/ˈnɒmɪnl/", "pos": "adj.", "zh": "名义上的", "difficulty": 3},
             {"word": "diesel", "ipa": "/ˈdiːzl/", "translation": "柴油"}]
            """.utf8),
            bookID: "test"
        ))
        XCTAssertEqual(array.words.count, 2)
        XCTAssertEqual(array.words[0].phonetic, "/ˈnɒmɪnl/")
        XCTAssertEqual(array.words[0].difficulty, 3)
        XCTAssertEqual(array.words[1].phonetic, "/ˈdiːzl/", "ipa / translation 这些别名也要认")
        XCTAssertEqual(array.words[1].difficulty, 2, "没写 difficulty 时默认中等")
        XCTAssertEqual(array.words[0].bookID, "test")
        XCTAssertNil(array.name)

        let object = try XCTUnwrap(DictionaryFileParser.parse(
            Data(#"{"name": "我的词表", "subtitle": "自用", "words": [{"word": "hobby"}]}"#.utf8),
            bookID: "imported.x"
        ))
        XCTAssertEqual(object.name, "我的词表")
        XCTAssertEqual(object.subtitle, "自用")
        XCTAssertEqual(object.words.count, 1)
    }

    func testFileParserDropsInvalidAndDuplicateWords() throws {
        let parsed = try XCTUnwrap(DictionaryFileParser.parse(
            Data("""
            [{"word": "hobby"}, {"word": "HOBBY"}, {"word": ""}, {"pos": "n."},
             {"word": "\(String(repeating: "a", count: 60))"}, {"word": "diesel"}]
            """.utf8),
            bookID: "test"
        ))
        XCTAssertEqual(parsed.words.map(\.word), ["hobby", "diesel"], "重复 / 空 / 超长的条目一律丢掉")
    }

    func testFileParserRejectsNonDictionaryJSON() {
        XCTAssertNil(DictionaryFileParser.parse(Data(#"{"hello": "world"}"#.utf8), bookID: "x"))
        XCTAssertNil(DictionaryFileParser.parse(Data("not json".utf8), bookID: "x"))
        XCTAssertNil(DictionaryFileParser.parse(Data("[]".utf8), bookID: "x"), "一个词都没有 = 导入失败")
        XCTAssertNil(DictionaryFileParser.parse(nil, bookID: "x"))
    }

    func testDifficultyIsClampedIntoRange() {
        let word = DictionaryWord(word: "x", difficulty: 99, bookID: "b")
        XCTAssertEqual(word.difficulty, DailyWord.maxDifficulty)
        XCTAssertEqual(DictionaryWord(word: "x", difficulty: 0, bookID: "b").difficulty, 1)
    }

    // MARK: - 词典库（删 / 恢复 / 优先级）

    /// 造四本书（含词组书）—— 顺序刻意打乱，好让「排序」这条逻辑真的被考到。
    private func books() -> [DictionaryBook] {
        [
            DictionaryBook(id: "builtin.ielts", name: "雅思标准词", entryCount: 145, coverStyle: .forest),
            DictionaryBook(id: "builtin.cet6", name: "六级核心词汇", entryCount: 297, coverStyle: .ocean),
            DictionaryBook(id: "builtin.oxford", name: "牛津核心词", entryCount: 248, coverStyle: .sunset),
            DictionaryBook(id: DictionaryCatalog.phraseBookID, name: "常用搭配", entryCount: 1032, coverStyle: .plum),
        ]
    }

    /// 词组书 id 的便捷写法（测试里到处要传它）。
    private var phraseBookID: String { DictionaryCatalog.phraseBookID }

    func testTogglingSourceAssignsAndRenumbersRanks() {
        var library = DictionaryLibrary.empty
        library = DictionaryLibrary.togglingSource("builtin.oxford", in: library)
        XCTAssertEqual(library.rank(of: "builtin.oxford"), 1)
        library = DictionaryLibrary.togglingSource("builtin.ielts", in: library)
        XCTAssertEqual(library.rank(of: "builtin.ielts"), 2, "新勾的排在最后，不抢已经在用那本的优先权")

        // 取消第 1 名 → 后面的自动补位，不留空洞。
        library = DictionaryLibrary.togglingSource("builtin.oxford", in: library)
        XCTAssertNil(library.rank(of: "builtin.oxford"))
        XCTAssertEqual(library.rank(of: "builtin.ielts"), 1, "名次必须连续，UI 直接显示这个数字")
    }

    func testRemovingABookAlsoDropsItsRankAndRenumbers() {
        var library = DictionaryLibrary.empty
        library = DictionaryLibrary.togglingSource("builtin.ielts", in: library)
        library = DictionaryLibrary.togglingSource("builtin.cet6", in: library)
        library = DictionaryLibrary.removing("builtin.ielts", from: library)
        XCTAssertNil(library.rank(of: "builtin.ielts"))
        XCTAssertEqual(library.rank(of: "builtin.cet6"), 1)
        XCTAssertEqual(library.visibleBooks(builtIns: books()).count, 3)
        XCTAssertEqual(library.restorableBuiltIns(builtIns: books()).map(\.id), ["builtin.ielts"])
    }

    func testRestoringBuiltInsPutsEverythingBack() {
        var library = DictionaryLibrary.empty
        library = DictionaryLibrary.removing("builtin.ielts", from: library)
        library = DictionaryLibrary.removing("builtin.cet6", from: library)
        XCTAssertEqual(library.visibleBooks(builtIns: books()).count, 2)
        library = DictionaryLibrary.restoringBuiltIns(library)
        XCTAssertEqual(library.visibleBooks(builtIns: books()).count, 4)
        XCTAssertTrue(library.restorableBuiltIns(builtIns: books()).isEmpty)
    }

    func testSourceBookIDsFollowsPriorityThenFallsBackToAll() {
        var library = DictionaryLibrary.empty
        // 一本都没勾：全部可见词典都参与（否则「没勾 → 每日推荐空了」会被当成坏掉），
        // 但**词组书排最前** —— 它只含词组档词条，排最前就等于「词组档由它供货」。
        XCTAssertEqual(
            library.sourceBookIDs(builtIns: books(), phraseBookID: phraseBookID),
            [phraseBookID, "builtin.cet6", "builtin.oxford", "builtin.ielts"],
            "词组书排最前；其余兜底顺序按 localizedCompare 按名字排：六(liu) < 牛(niu) < 雅(ya)"
        )
        // 显式勾选仍然压过那条兜底规则（用户的排序是他的意思表示）。
        library = DictionaryLibrary.togglingSource("builtin.oxford", in: library)
        XCTAssertEqual(
            library.sourceBookIDs(builtIns: books(), phraseBookID: phraseBookID),
            ["builtin.oxford"]
        )
        library = DictionaryLibrary.togglingSource("builtin.cet6", in: library)
        XCTAssertEqual(
            library.sourceBookIDs(builtIns: books(), phraseBookID: phraseBookID),
            ["builtin.oxford", "builtin.cet6"]
        )
    }

    func testSearchOrderPutsPriorityBooksFirstAndPhraseBookNext() {
        var library = DictionaryLibrary.empty
        library = DictionaryLibrary.togglingSource("builtin.cet6", in: library)
        let ordered = library.searchOrder(builtIns: books(), phraseBookID: phraseBookID).map(\.id)
        XCTAssertEqual(ordered.first, "builtin.cet6", "被选作词源的词典排在最前，同名词优先归它")
        XCTAssertEqual(ordered.dropFirst().first, phraseBookID, "其次才是词组书")
        XCTAssertEqual(Set(ordered), Set(books().map(\.id)))
        // ⚠️ 「同优先级里词组书排最前」这条**不在这里**断言：真实书名「常用搭配」(chang)
        // 本来就排在六/牛/雅前面，撤掉规则这条也会绿 —— 那是假绿。
        // 规则本身由 `testPhraseBookHoistIsIndependentOfItsName` 用名字排最后的书单来钉。
    }

    /// 「词组书排最前」是一条**显式规则**，不是碰巧它的名字排在前面。
    ///
    /// 真实书名「常用搭配」（拼音 chang）恰好排在「六级」「牛津」「雅思」前面 ——
    /// 光靠名字就分不清规则有没有生效，改个名更会静默失效。这条用一个
    /// **名字排在最后**的假书单把规则单独钉住：给 id 就提上来，不给 id 就按名字沉底。
    func testPhraseBookHoistIsIndependentOfItsName() {
        let phraseBookSortsLast = [
            DictionaryBook(id: "builtin.phrases", name: "自用词表", entryCount: 1),
            DictionaryBook(id: "builtin.other", name: "常用词", entryCount: 1),
        ]
        let library = DictionaryLibrary.empty
        XCTAssertEqual(
            library.sourceBookIDs(builtIns: phraseBookSortsLast, phraseBookID: nil),
            ["builtin.other", "builtin.phrases"],
            "没有词组书概念时纯按名字排，它落在最后"
        )
        XCTAssertEqual(
            library.sourceBookIDs(builtIns: phraseBookSortsLast, phraseBookID: "builtin.phrases"),
            ["builtin.phrases", "builtin.other"],
            "给了 id 就该把它提上来 —— 与名字无关"
        )
        XCTAssertEqual(
            library.searchOrder(builtIns: phraseBookSortsLast, phraseBookID: "builtin.phrases").map(\.id),
            ["builtin.phrases", "builtin.other"]
        )
    }

    func testDroppingImportedBookRemovesItEntirely() {
        let imported = DictionaryBook(
            id: "imported.1", name: "自用词表", entryCount: 3, isBuiltIn: false, coverStyle: .plum
        )
        var library = DictionaryLibrary(importedBooks: [imported])
        library = DictionaryLibrary.togglingSource("imported.1", in: library)
        library = DictionaryLibrary.droppingImported("imported.1", from: library)
        XCTAssertTrue(library.importedBooks.isEmpty)
        XCTAssertNil(library.rank(of: "imported.1"))
        XCTAssertFalse(library.removedIDs.contains("imported.1"), "导入的删了就是删了，不该进「可恢复」名单")
    }

    // MARK: - 模糊匹配

    private func words() -> [DictionaryWord] {
        [
            DictionaryWord(word: "nominal", phonetic: "/ˈnɒmɪnl/", pos: "adj.", translation: "名义上的", bookID: "a"),
            DictionaryWord(word: "nominate", phonetic: "/ˈnɒmɪneɪt/", pos: "v.", translation: "提名", bookID: "a"),
            DictionaryWord(word: "nomination", phonetic: "/ˌnɒmɪˈneɪʃn/", pos: "n.", translation: "提名", bookID: "a"),
            DictionaryWord(word: "abnormal", pos: "adj.", translation: "异常的", bookID: "a"),
            DictionaryWord(word: "diesel", pos: "n.", translation: "名义上的柴油机", bookID: "b"),
        ]
    }

    func testMatcherRanksExactThenPrefixThenSubstringThenChinese() {
        let matched = DictionaryMatcher.match("normal", in: words())
        XCTAssertEqual(matched.first?.word, "abnormal", "子串命中排在中文化命中之前")
        // 中文命中：学员在中文输入法下直接打意思也要能找到（此时 needle 是中文）。
        let byChinese = DictionaryMatcher.match("提名", in: words())
        XCTAssertEqual(
            Set(byChinese.map(\.word)), ["nominate", "nomination"],
            "搜中文要命中所有对得上意思的词"
        )
        XCTAssertNil(
            DictionaryMatcher.match("normal", in: words()).first { $0.word == "diesel" },
            "英文查询不该因为某个中文释义里碰巧有这几个字母就被拉进来"
        )
    }

    func testMatcherLimitsAndDeduplicatesByWord() {
        var many: [DictionaryWord] = []
        for index in 0..<30 {
            many.append(DictionaryWord(word: "word\(index)", bookID: "a"))
        }
        many.append(DictionaryWord(word: "WORD0", bookID: "b"))
        let matched = DictionaryMatcher.match("word", in: many)
        XCTAssertEqual(matched.count, DictionaryMatcher.limit, "最多 10 条")
        XCTAssertEqual(Set(matched.map { $0.word.lowercased() }).count, matched.count, "同名词只留一条")
    }

    func testMatcherAgreesWithSharedFuzzyRuler() {
        // 同一把尺：词典搜索的排序必须与 `FuzzyWordMatch` 逐条一致。
        // 这条一旦红了，说明有人改了打分规则却只改了一边。
        let query = "nomin"
        let dictionary = DictionaryMatcher.match(query, in: words()).map { $0.word.lowercased() }
        let needle = FuzzyWordMatch.needle(query)
        var ranked: [(score: Int, length: Int, item: String)] = []
        for word in words() {
            guard let score = FuzzyWordMatch.score(
                word: word.word, translation: word.translation, needle: needle
            ) else { continue }
            ranked.append((score, word.word.count, word.word))
        }
        let shared = FuzzyWordMatch.rank(ranked, limit: DictionaryMatcher.limit) { $0 }
            .map { $0.lowercased() }
        XCTAssertEqual(dictionary, shared)
    }

    func testMatcherIgnoresEmptyQuery() {
        XCTAssertTrue(DictionaryMatcher.match("   ", in: words()).isEmpty)
    }

    /// 多词查询里**单词词条连候选都进不来** —— 这是匹配尺的结构性结果，不是排名里的一条规则。
    ///
    /// `FuzzyWordMatch.score` 比的是「词条的 word 是否全等 / 前缀 / 包含查询串」：
    /// 查询串自身带空格时，不含空格的词条既不可能全等，也不可能前缀或子串命中 ——
    /// 0/1/2 三档全都够不到，只剩「中文释义里含这串」那一档（3），天然排在词组后面。
    /// 所以「多词查询优先多词词条」**不需要在 `rank` 里再加一条规则**（`DictionaryMatcher`
    /// 的注释也是这么写的，这里把它变成可执行的证据）。
    ///
    /// 这条测试钉住的是这个结构：一旦有人把匹配尺改成「任一词元命中」
    /// （听起来很合理的一次「优化」，例如让 `get` 也能搜到 `get up`），
    /// `give` / `up` 会立刻作为候选冒出来，下面的断言变红。
    func testMultiWordQueryKeepsPhrasesAheadOfSingleWords() {
        let pool = [
            DictionaryWord(word: "give", translation: "给", bookID: "w"),
            DictionaryWord(word: "up", translation: "向上", bookID: "w"),
            DictionaryWord(word: "give up", translation: "放弃；停止", difficulty: 4, bookID: phraseBookID),
            DictionaryWord(word: "give up on", translation: "对…不再抱希望", difficulty: 4, bookID: phraseBookID),
        ]
        let matched = DictionaryMatcher.match("give up", in: pool)

        XCTAssertEqual(matched.first?.word, "give up", "全等命中的词组必须排第一")
        XCTAssertEqual(matched.map(\.word), ["give up", "give up on"], "同分数里短的在前")
        XCTAssertFalse(
            matched.contains { !$0.word.contains(" ") },
            "多词查询不该把单词词条拉进候选：\(matched.map(\.word))"
        )
    }

    // MARK: - 跳转历史

    private func detail(_ word: String) -> DictionaryDetail {
        DictionaryDetail(word: word, senses: [DictionarySense(pos: "n.", text: "\(word) 的释义")])
    }

    func testLookupSessionBackAndOrigin() {
        var session = DictionaryLookupSession.empty
        XCTAssertNil(session.currentWord)
        XCTAssertFalse(session.canGoBack)
        XCTAssertFalse(session.canReturnToOrigin)

        session.begin("nominal")
        session.cache(detail("nominal"))
        XCTAssertEqual(session.currentWord, "nominal")
        XCTAssertFalse(session.canGoBack, "只查了一个词就没有「上一页」")

        // 从详情里点进派生词 → 压栈。
        session.push("nominally")
        session.cache(detail("nominally"))
        XCTAssertEqual(session.currentWord, "nominally")
        XCTAssertTrue(session.canGoBack)
        XCTAssertFalse(session.canReturnToOrigin, "只有两层时「回到最初」和「上一页」是同一个目标，不该出现")

        session.push("nominalize")
        session.cache(detail("nominalize"))
        XCTAssertTrue(session.canReturnToOrigin, "三层起才给「一键回到最初」")

        XCTAssertEqual(session.goBack(), "nominally")
        XCTAssertEqual(session.currentWord, "nominally")
        XCTAssertEqual(session.originWord, "nominal")
        // 退到只剩两层时，「回到最初」的目标和「上一页」重合了 —— 这时它该消失，
        // 而不是留两个颜色不同、点下去却去同一个地方的按钮。
        XCTAssertFalse(session.canReturnToOrigin, "两层时这两个按钮等价，只留「上一页」")
        XCTAssertEqual(session.goBack(), "nominal")
        XCTAssertEqual(session.history, ["nominal"])
        XCTAssertFalse(session.canGoBack, "回到最初之后就不再需要「上一页」")
    }

    /// 三层时「回到最初」要能一步跨回去（不用连按两次「上一页」）。
    func testReturnToOriginCollapsesThreeLayersAtOnce() {
        var session = DictionaryLookupSession.empty
        session.begin("nominal")
        session.cache(detail("nominal"))
        session.push("nominally")
        session.cache(detail("nominally"))
        session.push("nominalize")
        session.cache(detail("nominalize"))

        XCTAssertEqual(session.returnToOrigin(), "nominal")
        XCTAssertEqual(session.history, ["nominal"])
        XCTAssertFalse(session.canGoBack)
        XCTAssertFalse(session.canReturnToOrigin)
        XCTAssertEqual(session.current?.word, "nominal", "详情留在缓存里，回去不用重新请求")
    }

    func testLookupSessionKeepsDetailsWhenGoingBack() {
        var session = DictionaryLookupSession.empty
        session.present(detail("nominal"))
        session.push("actual")
        XCTAssertNil(session.current, "跳过去还没查到 → 当前页是加载中（nil）")
        session.cache(detail("actual"))
        XCTAssertEqual(session.current?.word, "actual")
        session.goBack()
        XCTAssertEqual(session.current?.word, "nominal", "回退不重新请求：详情已经在会话缓存里")
    }

    func testPresentResetsHistoryButPushDoesNot() {
        var session = DictionaryLookupSession.empty
        session.present(detail("nominal"))
        session.push("actual")
        session.cache(detail("actual"))
        session.present(detail("diesel"))
        XCTAssertEqual(session.history, ["diesel"], "重新查一个词 = 历史从头开始")
    }

    func testPushingTheSameWordTwiceDoesNotStack() {
        var session = DictionaryLookupSession.empty
        session.begin("nominal")
        session.push("nominal")
        XCTAssertEqual(session.history, ["nominal"], "点了自己不该多一层")
    }

    // MARK: - 多词典选词（优先级）

    private func pool(_ prefix: String, difficulty: Int, count: Int) -> [DailyWord] {
        (0..<count).map { DailyWord(word: "\(prefix)\($0)", difficulty: difficulty) }
    }

    private struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    func testMultiSourcePickerFillsFromTheTopPriorityBookFirst() {
        // 第一本词典**只有简单档**：中等 / 困难 / 词组的配额只能由第二本补。
        var rng = SeededRNG(state: 2026)
        let first = pool("a", difficulty: 1, count: 10)
        let second = pool("b", difficulty: 2, count: 10)
            + pool("b2", difficulty: 3, count: 10)
            + pool("b3", difficulty: 4, count: 10)
        let picked = DailyWordPicker.pick(fromSources: [first, second], excluding: [], using: &rng)

        XCTAssertEqual(picked.count, DailyWordPicker.total)
        XCTAssertEqual(
            picked.filter { $0.difficulty == 1 }.count, 3,
            "简单档的 3 个名额必须来自优先级最高的那本"
        )
        XCTAssertTrue(
            picked.filter { $0.difficulty == 1 }.allSatisfy { $0.word.hasPrefix("a") },
            "第一本够用的档位，第二本不该插进来"
        )
        XCTAssertTrue(
            picked.filter { $0.difficulty == 2 }.allSatisfy { $0.word.hasPrefix("b") },
            "第一本没有的档位，由下一本补上"
        )
        // 同批不重复。
        XCTAssertEqual(Set(picked.map(\.word)).count, picked.count)
    }

    func testMultiSourcePickerDeduplicatesTheSameWordAcrossBooks() {
        var rng = SeededRNG(state: 99)
        let first = [DailyWord(word: "same", difficulty: 1)] + pool("a", difficulty: 1, count: 5)
        let second = [DailyWord(word: "same", difficulty: 1)] + pool("b", difficulty: 2, count: 8)
        let picked = DailyWordPicker.pick(fromSources: [first, second], excluding: [], using: &rng)
        XCTAssertEqual(picked.filter { $0.word == "same" }.count, 1, "同名词不能占两个名额")
    }

    func testMultiSourcePickerWithOneSourceMatchesTheOldBehaviour() {
        // 单本词典必须与改动前逐字一致（老入口 `pick(from:)` 仍然走同一条路）。
        var rngA = SeededRNG(state: 5)
        var rngB = SeededRNG(state: 5)
        let bank = pool("a", difficulty: 1, count: 10) + pool("b", difficulty: 2, count: 10)
            + pool("c", difficulty: 3, count: 10) + pool("d", difficulty: 4, count: 10)
        XCTAssertEqual(
            DailyWordPicker.pick(from: bank, using: &rngA).map(\.word),
            DailyWordPicker.pick(fromSources: [bank], using: &rngB).map(\.word)
        )
    }

    // MARK: - 内置词典资源

    func testBuiltInDictionariesArePresentAndFilled() {
        let books = DictionaryCatalog.builtInBooks
        XCTAssertEqual(books.count, 4, "搭配 / 雅思 / 六级 / 牛津四本内置词典")
        for book in books {
            XCTAssertGreaterThan(book.entryCount, 100, "「\(book.name)」词条太少了")
            XCTAssertFalse(book.coverLabel.isEmpty, "封面上的书脊字不能空")
        }
        XCTAssertEqual(Set(books.map(\.id)).count, 4, "id 必须唯一")

        let words = DictionaryCatalog.allWords
        XCTAssertGreaterThan(words.count, 500)
        // 单字词必须有音标（词组没有音标是正常的）。
        let singleWords = words.filter { !$0.word.contains(" ") }
        let missing = singleWords.filter { $0.phonetic.isEmpty }
        XCTAssertLessThan(
            Double(missing.count) / Double(max(singleWords.count, 1)), 0.05,
            "音标是用离线 IPA 词典批量生成的，缺的比例不该超过 5%；实际缺 \(missing.count)/\(singleWords.count)"
        )
        XCTAssertTrue(words.allSatisfy { $0.word.count <= 48 })
        XCTAssertTrue(words.contains { $0.difficulty == 4 }, "词库里要有词组档")
    }

    /// 词组书：**独立成册**，且里面只放词组。
    ///
    /// 这本书有两个身份：查词组时它是首选词源（`searchOrder` 排最前），
    /// 每日推荐的字组档由它供货。所以它必须能被认出来（`kind == .phrases`），
    /// 且不接受任何单字词条混进来 —— 混进来的单字会去挤别的档位的配额。
    func testPhraseBookIsRegisteredAndHoldsOnlyPhrases() throws {
        let specs = DictionaryCatalog.specs
        let phraseSpecs = specs.filter { $0.kind == .phrases }
        XCTAssertEqual(phraseSpecs.count, 1, "词组书只能有一本，否则排序规则会打架")
        let spec = try XCTUnwrap(phraseSpecs.first)
        XCTAssertEqual(spec.id, DictionaryCatalog.phraseBookID)
        XCTAssertEqual(DictionaryCatalog.phraseBook?.id, spec.id)
        XCTAssertEqual(Set(specs.map(\.id)).count, specs.count, "四本书的 id 不能重")

        let words = DictionaryCatalog.words(bookID: spec.id)
        XCTAssertGreaterThan(words.count, 800, "词组书只有 \(words.count) 条，撑不住每天 2 个的配额")
        XCTAssertTrue(words.allSatisfy { $0.word.contains(" ") }, "词组书里混进了单字词条")
        XCTAssertTrue(words.allSatisfy { $0.difficulty == 4 }, "词组书里混进了非词组档")
        XCTAssertTrue(words.allSatisfy { !$0.translation.isEmpty }, "有条目没释义")
        XCTAssertEqual(Set(words.map { $0.word.lowercased() }).count, words.count, "有重复词条")
        XCTAssertTrue(
            words.contains { $0.word == "give up" },
            "最基础的短语动词都缺，说明资源没打进包里"
        )
        XCTAssertTrue(words.contains { $0.word == "of course" })
    }

    /// 词组档能撑多久：**每天 2 个**的配额不该在可见范围内见底。
    ///
    /// 这条是这次做词组书的**起因**：以前三本词书里 `difficulty == 4` 的去重后只有
    /// 49 条，24 天见底，之后口径悄悄变成「说好每天 2 个词组，怎么变成别的词了」。
    func testPhraseQuotaIsCoveredForAYear() {
        let phrases = Set(
            DictionaryCatalog.allWords
                .filter { $0.difficulty == DailyWordPicker.phraseDifficulty }
                .map { $0.word.lowercased() }
        )
        let days = phrases.count / (DailyWordPicker.quota[DailyWordPicker.phraseDifficulty] ?? 1)
        XCTAssertGreaterThan(days, 365, "词组档只有 \(phrases.count) 条 ≈ \(days) 天，配额会见底")
    }

    func testBuiltInWordsCarryPartOfSpeechAndChinese() throws {
        let entry = try XCTUnwrap(
            DictionaryCatalog.allWords.first { $0.word == "abandon" },
            "抽查的词应当在词库里"
        )
        XCTAssertFalse(entry.pos.isEmpty)
        XCTAssertFalse(entry.translation.isEmpty)
        XCTAssertEqual(entry.detailText, "\(entry.pos) \(entry.translation)")
    }

    /// 词书要**真够大**：它是「每日推荐」的选词池，几百个示例词撑不起每天抽一组。
    ///
    /// ⚠️ 只对**词书**（`.words`）要求这个规模：词组书另有一套判据
    /// （见 `testPhraseBookIsRegisteredAndHoldsOnlyPhrases`），它的 1000 条
    /// 是「固定搭配全集的规模」，与「词书该有多少词」不是同一把尺。
    func testBuiltInWordBanksAreRealWordBanks() {
        let wordBooks = DictionaryCatalog.specs.filter { $0.kind == .words }
        XCTAssertEqual(wordBooks.count, 3)
        for spec in wordBooks {
            let count = DictionaryCatalog.words(bookID: spec.id).count
            XCTAssertGreaterThan(count, 1000, "「\(spec.name)」只有 \(count) 条，达不到词典的规模")
        }
        let total = DictionaryCatalog.allWords.count
        XCTAssertGreaterThan(total, 5000, "四本合计只有 \(total) 条")
    }

    /// 词库里不收**虚词**（冠词 / 代词 / 助动词 / 基本介词 / 基本连词 / 数词）。
    ///
    /// 判据是「这个词有没有自己的意思」：`the` / `of` / `is` 没有，学员早就认识，
    /// 收进来只会让「每日推荐」抽出没有练习价值的词；而 `however` / `although`
    /// **有**意思（中高级学员真要学怎么用它组织句子），必须留着 ——
    /// 这条断言守的就是这条分界线，别哪天把有实义的连词也一起清掉。
    func testBuiltInDictionariesExcludeFunctionWords() {
        let words = Set(DictionaryCatalog.allWords.map { $0.word.lowercased() })
        for function in ["the", "of", "and", "in", "is", "he", "very", "one"] {
            XCTAssertFalse(words.contains(function), "虚词「\(function)」不该进词库")
        }
        for meaningful in ["however", "although", "because", "perhaps"] {
            XCTAssertTrue(words.contains(meaningful), "有实义的「\(meaningful)」必须留着")
        }
    }

    /// 难度轴是**词频名次**（越常用越简单），不是柯林斯星级。
    ///
    /// 星级在 ECDICT 里对高频虚词明显不靠谱（`the` 五星、`in` 两星、`common` 一星），
    /// 拿它当难度轴会得出自相矛盾的分档。抽查两个词把这条轴钉住。
    func testDifficultyFollowsWordFrequency() throws {
        let government = try XCTUnwrap(
            DictionaryCatalog.allWords.first { $0.word == "government" }
        )
        XCTAssertEqual(government.difficulty, 1, "高频词（词频百名内）应当是最简单档")

        let nominal = try XCTUnwrap(
            DictionaryCatalog.allWords.first { $0.word == "nominal" }
        )
        XCTAssertEqual(nominal.difficulty, 3, "词频六千开外的词属于困难档")

        // 词组自成一档：每日推荐有「词组」这一档，词库里必须有货。
        let phrase = try XCTUnwrap(DictionaryCatalog.allWords.first { $0.word.contains(" ") })
        XCTAssertEqual(phrase.difficulty, 4)
    }

    // MARK: - 词组书接线（推荐 / 查找都优先）

    /// 造一个用临时目录的词典库仓库（不碰用户真实数据）。
    private func makeStore(_ label: String) throws -> (DictionaryBookStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dict-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = DictionaryBookStore(
            fileURL: directory.appendingPathComponent("dictionaries.json"),
            booksDirectory: directory.appendingPathComponent("books", isDirectory: true)
        )
        return (store, directory)
    }

    /// 每日推荐的字组档**必须由词组书供货**。
    ///
    /// 走的是真实的 `DictionaryBookStore.recommendationPools()`（不是直接调领域层函数），
    /// 所以链路上任何一环把词组书 id 漏传出去，这条都会红 —— 这正是要守的地方：
    /// 漏传不会报错，只会让「词组」那一档悄悄回到词书里那几十条上。
    func testPhraseQuotaIsSuppliedByThePhraseBook() async throws {
        let (store, directory) = try makeStore("phrase-quota")
        defer { try? FileManager.default.removeItem(at: directory) }

        let phraseBookWords = Set(
            DictionaryCatalog.words(bookID: DictionaryCatalog.phraseBookID).map(\.word)
        )
        XCTAssertFalse(phraseBookWords.isEmpty, "词组书资源没读出来")

        let pools = await store.recommendationPools()
        let first = try XCTUnwrap(pools.first, "第一本词源应当是词组书")
        XCTAssertFalse(first.isEmpty)
        XCTAssertTrue(
            first.allSatisfy { $0.difficulty == DailyWordPicker.phraseDifficulty },
            "排在最前的是词组书，它里面只能有词组档词条"
        )
        XCTAssertTrue(first.allSatisfy { phraseBookWords.contains($0.word) })

        // 真抽一组：词组那 2 个名额必须落在词组书上。
        let picked = DailyWordPicker.pick(fromSources: pools, seed: 42)
        let want = try XCTUnwrap(DailyWordPicker.quota[DailyWordPicker.phraseDifficulty])
        let phrasePicks = picked.filter { $0.difficulty == DailyWordPicker.phraseDifficulty }
        XCTAssertEqual(phrasePicks.count, want)
        XCTAssertTrue(
            phrasePicks.allSatisfy { phraseBookWords.contains($0.word) },
            "词组名额被词书里的旧词组占走了：\(phrasePicks.map(\.word))"
        )
    }

    /// 查词组**优先命中词组书**：同一个词条同时长在导入词典与词组书里时，归词组书。
    ///
    /// 机制说明：`searchableWords()` 按 `searchOrder` 逐本去重，词组书排最前 ⇒
    /// 搜索池里根本不会有第二份，所以不需要在匹配打分里再加一条「词组优先」。
    ///
    /// ⚠️ 这本对手词典**故意起名为「阿萨词典」**（拼音 a，排在「常用搭配」chang 之前）：
    /// 若拿「对手词典」(dui) 这种排在后面的名字，就算词组书那条规则没生效，
    /// 它也会因为名字靠前而恰好胜出 —— 测试会**假绿**（反证时实测过）。
    func testLookupPrefersThePhraseBookForTheSamePhrase() async throws {
        let (store, directory) = try makeStore("phrase-lookup")
        defer { try? FileManager.default.removeItem(at: directory) }

        // 造一本「对手词典」，故意也收 `give up`，释义与词组书不同。
        let rival = directory.appendingPathComponent("rival.json")
        try Data(#"[{"word":"give up","pos":"v.","zh":"对手词典的释义"}]"#.utf8).write(to: rival)
        let imported = try await store.importBook(from: rival, name: "阿萨词典")

        let found = await store.searchableWords()
        let hits = found.filter { $0.word.lowercased() == "give up" }
        XCTAssertEqual(hits.count, 1, "同一个词条在搜索池里只该有一份")
        XCTAssertEqual(
            hits.first?.bookID, DictionaryCatalog.phraseBookID,
            "同名词条要归词组书 —— 这就是「查词组优先从词组书匹配」"
        )
        XCTAssertNotEqual(hits.first?.bookID, imported.id)

        // 再走一遍真正的搜索入口（不只看池子）。
        let phraseBookGiveUp = DictionaryCatalog.words(bookID: DictionaryCatalog.phraseBookID)
            .first { $0.word.lowercased() == "give up" }
        let matched = DictionaryMatcher.match("give up", in: found)
        XCTAssertEqual(matched.first?.word.lowercased(), "give up")
        XCTAssertEqual(matched.first?.bookID, DictionaryCatalog.phraseBookID)
        XCTAssertEqual(matched.first?.translation, phraseBookGiveUp?.translation)

        // 反过来：把词组书删掉，这段结论就不成立了 —— 证明归一确实是词组书带来的，
        // 不是碰巧排到了前面。
        _ = try await store.removeBook(id: DictionaryCatalog.phraseBookID)
        let withoutPhraseBook = await store.searchableWords()
        let fallback = withoutPhraseBook.first { $0.word.lowercased() == "give up" }
        XCTAssertEqual(fallback?.bookID, imported.id, "没有词组书时才会轮到导入的那本")
    }

    // MARK: - 词典库仓库（落盘）

    func testBookStorePersistsLibraryStateAndImportedWords() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dict-store-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("dictionaries.json")
        let booksDirectory = directory.appendingPathComponent("books", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // 造一个导入用的 JSON 文件。
        let source = directory.appendingPathComponent("my-words.json")
        try Data("""
        {"name": "我的词表", "words": [{"word": "nominal", "pos": "adj.", "zh": "名义上的"},
                                      {"word": "diesel", "pos": "n.", "zh": "柴油"}]}
        """.utf8).write(to: source)

        let store = DictionaryBookStore(fileURL: fileURL, booksDirectory: booksDirectory)
        let imported = try await store.importBook(from: source)
        XCTAssertEqual(imported.name, "我的词表")
        XCTAssertEqual(imported.entryCount, 2)
        XCTAssertFalse(imported.isBuiltIn)
        let importedWords = await store.words(bookID: imported.id)
        XCTAssertEqual(importedWords.count, 2)

        // 勾选词源 + 删一本内置。
        _ = try await store.toggleSource(id: imported.id)
        _ = try await store.removeBook(id: "builtin.cet6")

        // 重新开一个仓库（模拟重启）：状态与词条都要还在。
        let reopened = DictionaryBookStore(fileURL: fileURL, booksDirectory: booksDirectory)
        let state = await reopened.state
        XCTAssertEqual(state.rank(of: imported.id), 1)
        XCTAssertTrue(state.removedIDs.contains("builtin.cet6"))
        let reopenedWords = await reopened.words(bookID: imported.id).map(\.word)
        let visibleCount = await reopened.visibleBooks.count
        XCTAssertEqual(reopenedWords, ["nominal", "diesel"])
        XCTAssertEqual(visibleCount, 4, "四本内置去掉一本 + 一本导入")

        // 搜索能同时搜到内置与导入的词（且按优先级排序：导入那本被勾成词源，排最前）。
        let found = await reopened.searchableWords()
        XCTAssertTrue(found.contains { $0.word == "nominal" && $0.bookID == imported.id })
        let orderFirst = await reopened.searchOrder.first?.id
        XCTAssertEqual(orderFirst, imported.id)

        // 删掉导入的：文件也要清干净。
        _ = try await reopened.removeBook(id: imported.id)
        let stored = booksDirectory.appendingPathComponent("\(imported.id).json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.path), "删书要连文件一起删")
        let finalState = await reopened.state
        XCTAssertTrue(finalState.importedBooks.isEmpty)
        XCTAssertNil(finalState.rank(of: imported.id))

        try? FileManager.default.removeItem(at: directory)
    }

    func testBookStoreRejectsBadFileAndStaysUsable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dict-bad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = DictionaryBookStore(
            fileURL: directory.appendingPathComponent("dictionaries.json"),
            booksDirectory: directory.appendingPathComponent("books", isDirectory: true)
        )
        let bad = directory.appendingPathComponent("bad.json")
        try Data(#"{"nope": 1}"#.utf8).write(to: bad)

        do {
            _ = try await store.importBook(from: bad)
            XCTFail("没有词条的文件必须导入失败，而不是静默生成一本空词典")
        } catch {
            // 期望路径：如实报错，由 UI 提示格式。
        }
        let importedCount = await store.state.importedBooks.count
        let visibleCount = await store.visibleBooks.count
        XCTAssertEqual(importedCount, 0)
        XCTAssertEqual(visibleCount, 4, "导入失败不该影响已有词典")
        try? FileManager.default.removeItem(at: directory)
    }

    func testRecommendationPoolsFollowTheSelectedBooks() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dict-pool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = DictionaryBookStore(
            fileURL: directory.appendingPathComponent("dictionaries.json"),
            booksDirectory: directory.appendingPathComponent("books", isDirectory: true)
        )

        // 默认（一本都没勾）→ 四本都参与，且**词组书排最前**。
        let defaultPools = await store.recommendationPools()
        XCTAssertEqual(defaultPools.count, 4)
        let firstBookID = await store.searchOrder.first?.id
        XCTAssertEqual(firstBookID, DictionaryCatalog.phraseBookID, "默认词源第一本是词组书")
        _ = try await store.toggleSource(id: "builtin.oxford")
        let pools = await store.recommendationPools()
        let oxfordWords = await store.words(bookID: "builtin.oxford")
        XCTAssertEqual(pools.count, 1)
        XCTAssertEqual(pools[0].count, oxfordWords.count)
        try? FileManager.default.removeItem(at: directory)
    }

    func testSampleWordsAreStableAndNonEmpty() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dict-sample-\(UUID().uuidString)", isDirectory: true)
        let store = DictionaryBookStore(
            fileURL: directory.appendingPathComponent("dictionaries.json"),
            booksDirectory: directory.appendingPathComponent("books", isDirectory: true)
        )
        let service = DictionaryService(llm: LLMManager(), store: store)
        let searchable = await store.searchableWords()
        XCTAssertFalse(searchable.isEmpty)
        // 固定间隔取样：同一份数据取两次结果一致（不随机 → 用户不会觉得页面自己在变）。
        let sample = await service.sampleWords(limit: 6)
        XCTAssertEqual(sample.count, 6)
        XCTAssertEqual(Set(sample.map(\.word)).count, 6)
        let again = await service.sampleWords(limit: 6).map(\.word)
        XCTAssertEqual(sample.map(\.word), again)
        let reported = await service.totalWordCount()
        let visible = await store.visibleBooks
        XCTAssertEqual(reported, visible.reduce(0) { $0 + $1.entryCount })
        // 去重口径：跨词典同名词只算一个，必须严格小于「各书相加」，
        // 并且与查词 / 联想用的那份词表完全一致（界面上的「词库共 N 词」用它）。
        let unique = await service.uniqueWordCount()
        XCTAssertEqual(unique, searchable.count)
        XCTAssertLessThan(unique, reported, "三本词典大量常用词重合，去重后必然少于相加值")
        try? FileManager.default.removeItem(at: directory)
    }

    /// 每日推荐词库（设置页「已学 x / y 词」的分母）也要按词去重：
    /// 几本书一个池子，直接相加会把 `say`/`go` 这类词算好几遍，分母虚高。
    func testDailyWordBankDeduplicatesAcrossBooks() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dict-bank-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = DictionaryBookStore(
            fileURL: directory.appendingPathComponent("dictionaries.json"),
            booksDirectory: directory.appendingPathComponent("books", isDirectory: true)
        )
        let services = CoachServices(
            config: ConfigStore(fileURL: directory.appendingPathComponent("config.json")),
            databasePath: ":memory:",
            dictionaryStore: store
        )
        let bank = await services.dailyWordBank()
        XCTAssertFalse(bank.isEmpty)
        XCTAssertEqual(bank.count, Set(bank.map { $0.word.lowercased() }).count, "词库分母不许有重复词")
        let unique = await services.dictionaryUniqueWordCount()
        XCTAssertEqual(bank.count, unique, "分母要与「词库共 N 词」是同一个数")
        try? FileManager.default.removeItem(at: directory)
    }
}
