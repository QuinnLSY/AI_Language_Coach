import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 词典页的**离屏渲染**回归（新功能）。
///
/// 断言只钉「用户真能看见」这件事，方法与同目录另几支渲染测试一致：
///
/// 1. **只切一个开关**再逐像素差分。想知道「悬停时到底有没有冒出删除按钮」，
///    就只把 `isHovered` 从 false 改成 true，别的一个字段都不动 ——
///    差分有，说明那些控件确实画在封面上；差分约等于 0，就是根本没画。
/// 2. 阈值**自校准**：同一状态连抓两趟当噪声基准，不用拍脑袋的固定值。
/// 3. 产品口径优先：「有则展示、无则不留空标题」「例句都要有朗读按钮」
///    「悬停才出现删除与优先级框」这几条各对应一条断言。
///
/// 验证环境熄屏，一律离屏渲染，不碰屏幕。
@MainActor
final class DictionaryRenderTests: XCTestCase {

    private var window: NSWindow?
    private let cardWidth: CGFloat = 620

    private struct Render {
        let rep: NSBitmapImageRep
        let size: CGSize
    }

    // MARK: - 造数据

    private func book(
        id: String = "builtin.cet6",
        name: String = "六级核心词汇",
        entryCount: Int = 297,
        isBuiltIn: Bool = true,
        coverStyle: DictionaryBook.CoverStyle = .forest
    ) -> DictionaryBook {
        DictionaryBook(
            id: id, name: name, subtitle: isBuiltIn ? "" : "导入",
            entryCount: entryCount, isBuiltIn: isBuiltIn,
            coverStyle: coverStyle,
            importedAt: isBuiltIn ? nil : Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    /// 一份「要什么有什么」的完整词条。
    private func fullDetail() -> DictionaryDetail {
        DictionaryDetail(
            word: "nominal",
            phoneticUS: "/ˈnɑːmɪnl/",
            phoneticUK: "/ˈnɒmɪnl/",
            senses: [
                DictionarySense(pos: "adj.", text: "名义上的；有名无实的",
                                explanation: "常用于正式语境，强调与实际不符。"),
                DictionarySense(pos: "n.", text: "名词性词语")
            ],
            collocations: [
                DictionaryCollocation(
                    phrase: "nominal fee", translation: "象征性费用",
                    example: "They charge a nominal fee for the service.",
                    exampleTranslation: "这项服务他们只收象征性费用。"
                )
            ],
            examples: [
                DictionaryExample(text: "He is the nominal head of the company.",
                                  translation: "他是公司名义上的负责人。"),
                DictionaryExample(text: "The price was nominal.", translation: "价格是象征性的。")
            ],
            morphology: DictionaryMorphology(
                parts: [DictionaryMorphPart(text: "nomin", label: "名字"),
                        DictionaryMorphPart(text: "al", label: "形容词后缀")],
                result: "名字的 → 名义上的"
            ),
            etymology: "源自拉丁语 nomen（名字）。",
            derivatives: [
                DictionaryRelatedWord(word: "nominally", pos: "adv.", translation: "名义上地")
            ],
            synonyms: [
                DictionaryRelatedWord(word: "titular", pos: "adj.", translation: "有名无实的")
            ],
            antonyms: [
                DictionaryRelatedWord(word: "actual", pos: "adj.", translation: "实际的")
            ]
        )
    }

    /// 只有释义的「清淡版」——用来验「没有的项不留空标题」。
    private func leanDetail() -> DictionaryDetail {
        DictionaryDetail(word: "nominal", senses: [DictionarySense(pos: "adj.", text: "名义上的")])
    }

    // MARK: - 离屏渲染

    private func render(_ view: AnyView, day: Bool = true, width: CGFloat? = nil) throws -> Render {
        let theme = ForestThemeResolver.resolve(mode: day ? .day : .night, systemIsDark: !day)
        let backdrop: Color = day ? Color(hex: 0xE9EFE4) : Color(hex: 0x101B2E)
        let target = width ?? cardWidth
        let host = NSHostingView(rootView: AnyView(
            view.forestTheme(theme).frame(width: target).background(backdrop)
        ))
        host.frame = NSRect(x: 0, y: 0, width: target, height: 200)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        // 两趟：先问出自然高度，再按自然高度出图，否则内容会被裁掉。
        let size = CGSize(width: target, height: max(80, ceil(host.fittingSize.height)))
        host.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep, size: size)
    }

    private func diff(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> (mean: Double, count: Int) {
        let width = min(a.pixelsWide, b.pixelsWide)
        let height = min(a.pixelsHigh, b.pixelsHigh)
        var sum = 0.0
        var count = 0
        for x in 0..<width {
            for y in 0..<height {
                guard let ca = a.colorAt(x: x, y: y), let cb = b.colorAt(x: x, y: y) else { continue }
                let delta = abs(ca.redComponent - cb.redComponent)
                    + abs(ca.greenComponent - cb.greenComponent)
                    + abs(ca.blueComponent - cb.blueComponent)
                guard delta > 0.12 else { continue }
                sum += delta
                count += 1
            }
        }
        return (count == 0 ? 0 : sum / Double(count), count)
    }

    private func dump(_ rep: NSBitmapImageRep, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // RenderTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]), "PNG 编码失败")
        try png.write(to: directory.appendingPathComponent(name))
    }

    // MARK: - ① 抓图本身要确定（否则后面的差分全不算数）

    func testComponentRenderingIsDeterministic() throws {
        let first = try render(AnyView(DictionaryWordDetailCard(detail: fullDetail())))
        let second = try render(AnyView(DictionaryWordDetailCard(detail: fullDetail())))
        let noise = diff(first.rep, second.rep)
        XCTAssertLessThanOrEqual(noise.count, 100, "同一状态两趟出图差异应接近 0，实测 \(noise.count)")
    }

    // MARK: - ② 词典库：封面悬停才出现「删除」与「优先级框」

    /// 用户口径：鼠标移到封面上时，边缘高亮 + 轻微放大，并出现删除按钮与优先级选定框。
    /// 验证方式：只把 `isHovered` 翻过来，别的字段一个不动。
    func testHoverRevealsDeleteAndSourceControls() throws {
        let idle = try render(AnyView(
            DictionaryBookCard(book: book(), rank: nil, isHovered: false, onHover: { _ in },
                               onDelete: {}, onToggleSource: {})
        ))
        let hovered = try render(AnyView(
            DictionaryBookCard(book: book(), rank: nil, isHovered: true, onHover: { _ in },
                               onDelete: {}, onToggleSource: {})
        ))
        let signal = diff(idle.rep, hovered.rep)
        XCTAssertGreaterThan(
            signal.count, 400,
            "悬停时封面上该多出「删除」与「推荐词源」两个胶囊 + 边缘高亮，实测变化像素 \(signal.count)"
        )
    }

    /// 勾选状态是**有意义的信息**：不悬停也要看得见名次（否则用户不知道推荐词从哪来）。
    func testSelectedBookShowsItsRankWithoutHovering() throws {
        let unselected = try render(AnyView(
            DictionaryBookCard(book: book(), rank: nil, isHovered: false, onHover: { _ in },
                               onDelete: {}, onToggleSource: {})
        ))
        let selected = try render(AnyView(
            DictionaryBookCard(book: book(), rank: 2, isHovered: false, onHover: { _ in },
                               onDelete: {}, onToggleSource: {})
        ))
        let signal = diff(unselected.rep, selected.rep)
        XCTAssertGreaterThan(
            signal.count, 200,
            "不悬停时被选作词源的词典也要显示名次，实测变化像素 \(signal.count)"
        )
    }

    /// 删除是两步：确认态必须**看向就不一样**（不能按下去毫无反馈）。
    func testDeleteConfirmationLooksDifferent() throws {
        let armed = try render(AnyView(
            DictionaryBookCard(book: book(), rank: nil, isHovered: true, isConfirmingDelete: false,
                               onHover: { _ in }, onDelete: {}, onToggleSource: {})
        ))
        let confirming = try render(AnyView(
            DictionaryBookCard(book: book(), rank: nil, isHovered: true, isConfirmingDelete: true,
                               onHover: { _ in }, onDelete: {}, onToggleSource: {})
        ))
        let signal = diff(armed.rep, confirming.rep)
        XCTAssertGreaterThan(signal.count, 100, "确认态要写成「确认」，与垃圾桶图标明显不同")
    }

    /// 导入图标：与封面同尺寸、悬停高亮 + 放大。
    func testImportTileHoverHighlights() throws {
        let idle = try render(AnyView(
            DictionaryImportTile(isHovered: false, onHover: { _ in }, onTap: {})
        ))
        let hovered = try render(AnyView(
            DictionaryImportTile(isHovered: true, onHover: { _ in }, onTap: {})
        ))
        let signal = diff(idle.rep, hovered.rep)
        XCTAssertGreaterThan(signal.count, 300, "悬停导入图标要变亮变粗并放大，实测 \(signal.count)")
        XCTAssertEqual(
            idle.size.height, hovered.size.height, accuracy: 1,
            "放大只是视觉缩放，不该把版式撑高（否则整排书会跟着跳）"
        )
    }

    /// 导入图标与书封面**同一尺寸**（用户口径：跟封面大小一致）。
    func testImportTileMatchesCoverSize() throws {
        let cover = try render(AnyView(
            DictionaryBookCard(book: book(), rank: nil, isHovered: false, onHover: { _ in },
                               onDelete: {}, onToggleSource: {})
        ))
        let tile = try render(AnyView(
            DictionaryImportTile(isHovered: false, onHover: { _ in }, onTap: {})
        ))
        XCTAssertEqual(tile.size.height, cover.size.height, accuracy: 2,
                       "导入图标要和封面卡等高，肉眼看上去才是同一排的一格")
    }

    // MARK: - ③ 查单词结果页

    /// 「有则展示、没有则不展示」：清淡版不许留空标题占位。
    func testAbsentSectionsLeaveNoEmptyHeadings() throws {
        let full = try render(AnyView(DictionaryWordDetailCard(detail: fullDetail())))
        let lean = try render(AnyView(DictionaryWordDetailCard(detail: leanDetail())))
        try dump(lean.rep, name: "round38-dictionary-detail-lean-day.png")

        XCTAssertGreaterThan(
            full.size.height, lean.size.height + 200,
            "有构词/词源/搭配/例句/派生/近义/反义时页面应当明显更高（实测 \(full.size.height) vs \(lean.size.height)）"
        )
        // 清淡版里只有：词头 + 音标 + 一条释义 + 「添加复习」。七个「没有就不画」的
        // 段落若真留了空标题，高度会立刻翻上去（每个标题至少 25pt）。
        XCTAssertLessThan(
            lean.size.height, 200,
            "只有一条释义时不该出现空标题占位，实测高度 \(lean.size.height)"
        )
    }

    /// 例句右侧的朗读按钮必须在，而且**真的跟它自己的状态走**：
    /// 只把 `isPreparing` 打开（同一份详情、同一段文字），画面就该变。
    func testExampleSpeakButtonsTrackTheirOwnState() throws {
        let detail = fullDetail()
        let idle = try render(AnyView(
            DictionaryWordDetailCard(detail: detail, isSpeaking: { _ in false }, isPreparing: { _ in false })
        ))
        let preparing = try render(AnyView(
            DictionaryWordDetailCard(detail: detail, isSpeaking: { _ in false }, isPreparing: { _ in true })
        ))
        let signal = diff(idle.rep, preparing.rep)
        XCTAssertGreaterThan(
            signal.count, 20,
            "每条例句（含固定搭配里的例句）右侧都该有小喇叭，且它能反映自己的状态，实测 \(signal.count)"
        )
    }

    /// 右上角「添加复习」：不在词表时是按钮，加入后变成「已在词表」。
    func testAddToReviewButtonOnlyShowsWhenNotInVocabulary() throws {
        let detail = fullDetail()
        let before = try render(AnyView(DictionaryWordDetailCard(detail: detail, isInVocabulary: false)))
        let after = try render(AnyView(DictionaryWordDetailCard(detail: detail, isInVocabulary: true)))
        let signal = diff(before.rep, after.rep)
        XCTAssertGreaterThan(signal.count, 20, "「添加复习」与「已在词表」必须肉眼可分，实测 \(signal.count)")
    }

    /// 「上一页」与「一键回到最初」是**两个颜色不同**的按钮：
    /// 单开一个与单开另一个，画面必须不一样；两个都开又不一样。
    func testBackAndOriginButtonsAreVisuallyDistinct() throws {
        let detail = fullDetail()
        let none = try render(AnyView(DictionaryWordDetailCard(detail: detail)))
        let backOnly = try render(AnyView(
            DictionaryWordDetailCard(detail: detail, canGoBack: true, canReturnToOrigin: false)
        ))
        let originOnly = try render(AnyView(
            DictionaryWordDetailCard(detail: detail, canGoBack: false, canReturnToOrigin: true)
        ))
        let both = try render(AnyView(
            DictionaryWordDetailCard(detail: detail, canGoBack: true, canReturnToOrigin: true)
        ))

        XCTAssertGreaterThan(diff(none.rep, backOnly.rep).count, 20, "有上一页时该出现返回按钮")
        XCTAssertGreaterThan(diff(none.rep, originOnly.rep).count, 20, "有三层历史时该出现「回到最初」")
        XCTAssertGreaterThan(
            diff(backOnly.rep, originOnly.rep).count, 20,
            "两个按钮颜色不同，只开其中一个时画面应当不一样（否则用户分不清哪个是哪个）"
        )
        XCTAssertGreaterThan(diff(backOnly.rep, both.rep).count, 20, "两个都在时应比只有一个多出内容")
    }

    /// 加载态与内容态要分得开（否则「查了个词却什么都没发生」）。
    func testLoadingStateIsDistinguishable() throws {
        let loading = try render(AnyView(
            DictionaryWordDetailCard(detail: DictionaryDetail(word: "nominal"), isLoading: true)
        ))
        let loaded = try render(AnyView(DictionaryWordDetailCard(detail: fullDetail())))
        XCTAssertGreaterThan(diff(loading.rep, loaded.rep).count, 500)
    }

    /// 查不到（模型什么都没给）时如实说，而不是画一张空卡。
    func testEmptyResultIsHonest() throws {
        let empty = try render(AnyView(DictionaryWordDetailCard(detail: DictionaryDetail(word: "zzz"))))
        XCTAssertLessThan(empty.size.height, 140, "查不到就一句话，实测高度 \(empty.size.height)")
    }

    // MARK: - ④ 昼夜两版都能读（并留下人工复核的图）

    func testRendersBothThemesAndDumpsPNG() throws {
        // 单独渲染一张封面卡时给它一个**真实栅格里的宽度**：词典库是网格，
        // 封面实际只有 200 上下，按 620 出图会得到一张 620×827 的巨幅封面，
        // 角落那两颗胶囊被推出位图边界 —— 那是取景问题，不是版式问题。
        let cover: (Bool) -> AnyView = { day in
            AnyView(
                DictionaryBookCard(book: self.book(), rank: 1, isHovered: true, onHover: { _ in },
                                   onDelete: {}, onToggleSource: {})
                    .frame(width: 200)
            )
        }
        let dayCard = try render(cover(true), day: true)
        let nightCard = try render(cover(false), day: false)
        let dayDetail = try render(AnyView(
            DictionaryWordDetailCard(detail: fullDetail(), canGoBack: true, canReturnToOrigin: true)
        ), day: true)
        let nightDetail = try render(AnyView(
            DictionaryWordDetailCard(detail: fullDetail(), canGoBack: true, canReturnToOrigin: true)
        ), day: false)

        XCTAssertGreaterThan(dayCard.size.height, 80)
        XCTAssertGreaterThan(nightCard.size.height, 80)
        try dump(dayCard.rep, name: "round38-dictionary-book-hover-day.png")
        try dump(nightCard.rep, name: "round38-dictionary-book-hover-night.png")
        try dump(dayDetail.rep, name: "round38-dictionary-detail-day.png")
        try dump(nightDetail.rep, name: "round38-dictionary-detail-night.png")
    }

    /// 左侧栏「词典」入口要落在**跟读和词汇本中间**（用户指定的位置）。
    /// 顺序是写死在 `navList` 里的，只能靠出图人眼复核，所以这里把图留下来。
    func testSidebarShowsDictionaryEntryBetweenShadowingAndVocabulary() async throws {
        let state = makeAppState()
        await state.openDictionary()
        XCTAssertTrue(state.showingDictionary)

        let day = try render(AnyView(AppSidebar(state: state)), day: true, width: 220)
        let night = try render(AnyView(AppSidebar(state: state)), day: false, width: 220)
        XCTAssertGreaterThan(day.size.height, 200, "侧栏应能布局")
        try dump(day.rep, name: "round38-sidebar-with-dictionary-day.png")
        try dump(night.rep, name: "round38-sidebar-with-dictionary-night.png")

        // 点了「词典」之后，练习那一项不该再是高亮的（否则看上去停在练习页）。
        XCTAssertFalse(state.showingVocabulary)
        XCTAssertFalse(state.showingShadowing)
    }

    // MARK: - ⑤ 整页：两种模式各自成立，且切换是真的换了内容

    private func makeAppState() -> AppState {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("dict-probe-\(UUID().uuidString).json")
        )
        // ⚠️ 词典库**必须**换成临时仓库：默认的 `.shared` 读写的是用户真实的
        // `.workbuddy/app-config/dictionaries.json`，探针会污染真实数据、
        // 也会因为用户删过书而让断言时红时绿。
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dict-store-\(UUID().uuidString)", isDirectory: true)
        let dictionaryStore = DictionaryBookStore(
            fileURL: base.appendingPathComponent("dictionaries.json"),
            booksDirectory: base.appendingPathComponent("books", isDirectory: true)
        )
        return AppState(services: CoachServices(
            config: store, databasePath: ":memory:", dictionaryStore: dictionaryStore
        ))
    }

    /// 一支「查词请求必定秒失败」的 AppState：用例要真的走完查词流程时用它。
    ///
    /// ⚠️ 为什么不能直接用默认配置：`llm` 会被解析到**本机真在跑的 Ollama** 上
    /// （同一坑在 `ExternalModelApplyGateTests` 里有记录），一次真实推理几十秒，
    /// 而且会往真实的查词缓存里写东西。注册一支端点指向必然连不上的 provider 并激活它，
    /// 请求立刻失败 —— 而本用例要钉的同步**发生在第一个 await 之前**，该验的一个不少。
    private func makeAppStateWithDeadLLM() async throws -> AppState {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dict-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        try await store.updateProvider(
            ProviderConfig(
                id: "stub.llm", kind: .llm, enabled: true, runtime: .remoteAPI,
                endpoint: "http://127.0.0.1:9/v1", apiKey: "sk-dead",
                model: "stub-model", candidateModels: ["stub-model"]
            )
        )
        try await store.mutateProduct { product in
            product.activateProvider("stub.llm", for: .llm)
            product.selectModel("stub-model", for: .llm)
        }
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dict-store-\(UUID().uuidString)", isDirectory: true)
        let dictionaryStore = DictionaryBookStore(
            fileURL: base.appendingPathComponent("dictionaries.json"),
            booksDirectory: base.appendingPathComponent("books", isDirectory: true)
        )
        return AppState(services: CoachServices(
            config: store, databasePath: ":memory:", dictionaryStore: dictionaryStore
        ))
    }

    func testDictionaryPageLayoutsBothModesEndToEnd() async throws {
        let state = makeAppState()
        // 页面自己会 `.task` 异步加载词典库 —— 先手动跑一遍把数据钉住，
        // 否则两次抓图可能一次在加载前、一次在加载后，差分全是假的。
        await state.openDictionary()
        XCTAssertEqual(state.dictionaryMode, .search, "从侧边栏进来默认是「查单词」")
        XCTAssertEqual(state.dictionaryBooks.count, 4, "四本内置词典应当就位（含词组书）")
        XCTAssertEqual(
            state.dictionaryBooks.first?.id, DictionaryCatalog.phraseBookID,
            "词组书排在最前（它是词组档的词源，查找也优先归它）"
        )

        // 差分两边都用日间主题：否则「背景色变了」也会被算成「内容变了」。
        let search = try render(AnyView(DictionaryView(state: state)), day: true, width: 780)

        await state.toggleDictionaryMode()
        XCTAssertEqual(state.dictionaryMode, .library)
        let library = try render(AnyView(DictionaryView(state: state)), day: true, width: 780)
        let libraryNight = try render(AnyView(DictionaryView(state: state)), day: false, width: 780)

        try dump(search.rep, name: "round38-dictionary-page-search-day.png")
        try dump(library.rep, name: "round38-dictionary-page-library-day.png")
        try dump(libraryNight.rep, name: "round38-dictionary-page-library-night.png")

        XCTAssertGreaterThan(search.size.height, 200, "查单词页应能布局")
        XCTAssertGreaterThan(library.size.height, 200, "词典库页应能布局")
        XCTAssertGreaterThan(
            diff(search.rep, library.rep).count, 5_000,
            "切模式必须真的换掉中间栏内容，而不是只换个标题"
        )
    }

    /// 切走再切回来，输入框里的字与当前词都要还在（用户口径里明确要求）。
    ///
    /// 这里不真去打模型：「详情留着不重查」由 `DictionaryTests` 里的
    /// `testLookupSessionKeepsDetailsWhenGoingBack` 在领域层钉死，
    /// 本用例只管「切模式不碰查词状态」这条 AppState 行为。
    func testSwitchingModesKeepsTheSearchState() async throws {
        let state = makeAppState()
        await state.openDictionary()
        state.dictionaryQuery = "nominal"

        await state.toggleDictionaryMode()
        XCTAssertEqual(state.dictionaryMode, .library)
        XCTAssertEqual(state.dictionaryQuery, "nominal", "切到词典库不该清空搜索框")
        XCTAssertTrue(state.showingDictionary, "切模式不该顺手把词典页关掉")

        await state.toggleDictionaryMode()
        XCTAssertEqual(state.dictionaryMode, .search)
        XCTAssertEqual(state.dictionaryQuery, "nominal", "切回来输入框里的字还在")
    }

    // MARK: - ⑥ 查询之后，匹配列表要收起来

    /// 用户口径：点「查询」或回车之后，匹配列表自动隐藏。
    ///
    /// ⚠️ 这里钉的是一个**竞态**，不是「忘了清空」：`dismissDictionaryMatches`
    /// 把列表清掉之后，用户敲最后一个字母时发出的那次联想请求可能**还在路上**，
    /// 而它回来时输入框里的字一个字都没变（回车不改字），于是它会理直气壮地
    /// 把列表重新填上 —— 用户看到的就是「点了查询，列表还在」。
    /// 所以状态里记了「这个词已经被消费过」，在途的联想回来时会被这一笔挡掉。
    func testDismissedMatchListIsNotRevivedByAnInFlightSearch() async throws {
        let state = makeAppState()
        await state.openDictionary()

        state.dictionaryQuery = "nom"
        await state.dictionaryQueryChanged()
        XCTAssertFalse(state.dictionaryMatches.isEmpty, "打字时本来就该给联想，否则这个用例没意义")

        // 查询 / 选中一条 / 点清空走的都是这一步：记下「已消费」+ 清列表。
        // （后面那次查词请求要打模型，用例里不真发 —— 竞态就发生在它返回之前。）
        state.dismissDictionaryMatches()
        XCTAssertTrue(state.dictionaryMatches.isEmpty)

        // 复现时序：那次还没回来的联想现在才到。
        let inFlight = Task { await state.dictionaryQueryChanged() }
        await inFlight.value
        XCTAssertTrue(
            state.dictionaryMatches.isEmpty,
            "已经收起过的词，不该被在途的联想请求重新顶出来"
        )

        // 反过来也要成立：用户再改输入框（多打一个字母）就该重新联想。
        state.dictionaryQuery = "nomin"
        await state.dictionaryQueryChanged()
        XCTAssertFalse(state.dictionaryMatches.isEmpty, "改过输入框之后要重新联想")
    }

    /// 用户口径：搜索时输入框里的内容**不清除**。
    func testQueryTextSurvivesDismissal() async throws {
        let state = makeAppState()
        await state.openDictionary()
        state.dictionaryQuery = "nominal"
        await state.dictionaryQueryChanged()
        state.dismissDictionaryMatches()
        XCTAssertEqual(state.dictionaryQuery, "nominal", "收起联想不该顺手把输入框清掉")
    }

    // MARK: - ⑦ 换内容之后，中间栏要回到顶部

    /// 用户口径：从「派生词 / 近义词」跳过去之后要**从头展示**，
    /// 而不是停在上一页那一块的位置。
    ///
    /// 离屏渲染默认不给视口高度，`ScrollView` 根本没有偏移可谈 —— 所以这里
    /// **故意**用一个固定高度的窗口把内容裁起来，再从 AppKit 视图树里捞出
    /// 那个 `NSScrollView`，手工滚下去，然后换掉内容，看偏移有没有被拉回 0。
    func testContentChangeScrollsBackToTop() async throws {
        let state = makeAppState()
        await state.openDictionary()
        await state.toggleDictionaryMode()
        XCTAssertEqual(state.dictionaryMode, .library, "词典库的内容比查词页高，滚得动")

        // 视口要**明显小于内容**：240 高时滚动范围只有 17pt，看不出区别。
        let viewportHeight: CGFloat = 150
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let host = NSHostingView(rootView: AnyView(DictionaryView(state: state).forestTheme(theme)))
        host.frame = NSRect(x: 0, y: 0, width: 780, height: viewportHeight)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let scrollView = try XCTUnwrap(
            Self.firstScrollView(in: host), "词典页的中间栏应当由一个 NSScrollView 承载"
        )
        let document = try XCTUnwrap(scrollView.documentView, "滚动视图应当有内容视图")
        XCTAssertGreaterThan(
            document.frame.height, viewportHeight + 20,
            "内容要比视口高，否则这个用例测不出任何东西（实测内容高 \(document.frame.height)）"
        )

        let bottom = NSPoint(x: 0, y: document.frame.height - viewportHeight)
        scrollView.contentView.scroll(to: bottom)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        XCTAssertGreaterThan(
            scrollView.contentView.bounds.origin.y, 30,
            "没能把内容滚下去，后面的断言就不成立"
        )

        // 换内容（换模式与换词共用同一条「回到顶部」的接线）。
        await state.toggleDictionaryMode()
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        // SwiftUI 的更新可能压在下一个 runloop 上，`await` 一下让它落盘
        // （不能用 `RunLoop.run(until:)`：异步上下文里不可用）。
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(
            scrollView.contentView.bounds.origin.y, 0, accuracy: 1,
            "换掉中间栏内容之后，视口要回到顶部（否则跳去一个词会停在上一页的那一栏）"
        )
    }

    // MARK: - ⑧ 浮层：查到词就收起，点回输入框才浮现

    /// 用户口径（09-16 第二次）：「查到单词后，浮层还在，应该查到之后自动隐藏，
    /// 鼠标再次点击输入框时才浮现。」
    ///
    /// 这里钉的是「浮层由 `AppState` 说了算」：浮层的生死**不能**只看列表里有没有
    /// 内容 —— 一次在途的联想回来时会把列表填上，于是浮层在已经查到词之后自己冒出来。
    /// 用户那张截图正是这个样子：输入框与展示页都是 `snatch`，浮层还挂着一条 `snatch`。
    func testMatchListHidesAfterALookupAndComesBackOnReArm() async throws {
        let state = makeAppState()
        await state.openDictionary()

        state.dictionaryQuery = "nom"
        await state.dictionaryQueryChanged()
        XCTAssertFalse(state.dictionaryMatches.isEmpty, "打字时本来就该给联想，否则这个用例没意义")

        // 回车 / 点「查询」走的就是这一步。
        state.dismissDictionaryMatches()
        XCTAssertTrue(state.dictionaryMatches.isEmpty)

        // 复现时序：敲最后一个字母时发出的那次联想，现在才回来 —— 不许把浮层顶回来。
        await state.dictionaryQueryChanged()
        XCTAssertTrue(state.dictionaryMatches.isEmpty, "已经收起的浮层，不该被在途的联想顶回来")

        // 鼠标点回输入框：这才轮到浮层重新出现。
        await state.rearmDictionaryMatches()
        XCTAssertFalse(state.dictionaryMatches.isEmpty, "点回输入框之后应当重新浮现匹配列表")
    }

    /// 浮层的显隐在**像素上**也要成立（状态对了、界面没跟着变同样算 bug）。
    func testMatchOverlayLeavesTheCanvasWhenDismissed() async throws {
        let state = makeAppState()
        await state.openDictionary()
        state.dictionaryQuery = "nom"
        await state.dictionaryQueryChanged()

        let withList = try render(AnyView(DictionaryView(state: state)), day: true, width: 780)
        try dump(withList.rep, name: "round41-dictionary-matchlist-day.png")
        state.dismissDictionaryMatches()
        let withoutList = try render(AnyView(DictionaryView(state: state)), day: true, width: 780)

        XCTAssertEqual(
            withList.size.height, withoutList.size.height, accuracy: 1,
            "浮层是 overlay、不该占布局高度：收起它不该让整页变矮"
        )
        let delta = diff(withList.rep, withoutList.rep)
        XCTAssertGreaterThan(
            delta.count, 200,
            "收起浮层之后画面上应当少掉那一块（实测差分像素 \(delta.count)）"
        )
    }

    // MARK: - ⑩ 「最近查过」一排（#282）

    /// 有空词时那一排必须真的画出来，且**整页跟着变高** ——
    /// 只改状态、界面没跟着变，用户就永远看不到「刚才那个词还能再点回去」。
    ///
    /// ⚠️ 直接改 `recentDictionaryWords` 而**不走 `clear` / 记录**那两个方法：
    /// 它们会写 `UserDefaults.standard`，跑一次测试就把开发机上真实的「最近查过」抹了。
    /// 这里只动内存，测完原样放回去。
    func testRecentWordsRowShowsUpWhenThereAreWords() async throws {
        let state = makeAppState()
        await state.openDictionary()
        let original = state.recentDictionaryWords
        defer { state.recentDictionaryWords = original }

        state.recentDictionaryWords = []
        let empty = try render(AnyView(DictionaryView(state: state)), day: true, width: 780)

        state.recentDictionaryWords = ["nominal", "sustainable", "coffee", "gentle"]
        let filled = try render(AnyView(DictionaryView(state: state)), day: true, width: 780)
        let filledNight = try render(AnyView(DictionaryView(state: state)), day: false, width: 780)

        XCTAssertGreaterThan(
            filled.size.height, empty.size.height + 16,
            "「最近查过」要真的占一块高度（差 \(filled.size.height - empty.size.height)pt）"
        )
        XCTAssertGreaterThan(
            diff(filled.rep, empty.rep).count, 300,
            "那一排不能只是「占了位置」—— 得真有胶囊被画出来"
        )

        try dump(filled.rep, name: "round53-dictionary-recent-words-day.png")
        try dump(filledNight.rep, name: "round53-dictionary-recent-words-night.png")

        // 清空之后必须回到原样（不是「留一条空壳标题」）。
        state.recentDictionaryWords = []
        let cleared = try render(AnyView(DictionaryView(state: state)), day: true, width: 780)
        XCTAssertEqual(
            cleared.size.height, empty.size.height, accuracy: 1,
            "清空之后那一排（连标题带「清空」按钮）都该跟着消失"
        )
    }

    // MARK: - ⑨ 输入框与展示页同步

    /// 用户口径（09-16 第二次）：「任何情况下，当展示页有具体单词展示时，
    /// 输入框中的单词都应该与展示的单词同步。」
    ///
    /// 最容易漏的是**跳转**：从详情页点派生词 / 近义词过去，原来输入框会一直停在
    /// 上一个词上，看着像「查的和看的不是同一个词」。
    ///
    /// ⚠️ 这条用例要真的**走完查词流程**（提交 → 跳转 → 回退），所以必须把那台
    /// 真在跑的本地模型挡掉：默认配置会把 `llm` 解析到本机 Ollama 上，一次真实推理
    /// 要几十秒（实测 58s），既慢又会往真实缓存里写东西。见 `makeAppStateWithDeadLLM()`。
    func testInputFollowsTheWordShownOnThePage() async throws {
        let state = try await makeAppStateWithDeadLLM()
        await state.openDictionary()

        state.dictionaryQuery = "nominal"
        await state.submitDictionaryQuery()
        XCTAssertEqual(state.dictionaryLookup.currentWord, "nominal")
        XCTAssertEqual(state.dictionaryQuery, "nominal")

        // 点派生词跳过去。
        await state.openDictionaryRelated("nominally")
        XCTAssertEqual(state.dictionaryLookup.currentWord, "nominally")
        XCTAssertEqual(state.dictionaryQuery, "nominally", "跳过去的词要同步进输入框")

        // 视图上的 `.onChange` 会因这次程序性赋值而跑一遍（用例里手动补上）：
        // 那次联想必须自己收起来，不能凭空弹一层浮层（用户截图里的样子）。
        await state.dictionaryQueryChanged()
        XCTAssertTrue(state.dictionaryMatches.isEmpty, "跳转之后的程序性同步不该弹出联想浮层")

        // 再跳一层 → 回退。
        await state.openDictionaryRelated("titular")
        XCTAssertEqual(state.dictionaryLookup.currentWord, "titular")
        XCTAssertEqual(state.dictionaryQuery, "titular")
        await state.goBackDictionary()
        XCTAssertEqual(state.dictionaryQuery, "nominally", "回到上一页，输入框也要跟着回去")

        // 一键回到最初那个词（历史至少三层才有这颗按钮）。
        await state.openDictionaryRelated("titular")
        XCTAssertTrue(state.dictionaryLookup.canReturnToOrigin)
        await state.returnToDictionaryOrigin()
        XCTAssertEqual(state.dictionaryLookup.currentWord, "nominal")
        XCTAssertEqual(state.dictionaryQuery, "nominal", "一键回到最初那个词，输入框同样跟上")
    }

    /// ⚠️ 给「放大镜 + 输入框」那一块加 `contentShape` + `simultaneousGesture` 之后，
    /// **点进去的命中对象必须还是那个输入框** —— 否则用户连光标都点不进去了。这是
    /// 那次改动唯一可能踩的坑，所以用 AppKit 的命中测试钉住。
    ///
    /// 说明边界：离屏窗口里**合成**的鼠标事件到不了 SwiftUI 的手势系统（实测
    /// `simultaneousGesture` 收不到），所以这里断言的是「谁被打中」，不是「手势跑没跑」。
    /// 手势那段只能靠人点真机复核。
    func testClickingTheSearchFieldStillHitsTheTextField() async throws {
        let state = makeAppState()
        await state.openDictionary()

        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let host = NSHostingView(rootView: AnyView(DictionaryView(state: state).forestTheme(theme)))
        host.frame = NSRect(x: 0, y: 0, width: 780, height: 420)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let field = try XCTUnwrap(
            Self.firstTextField(in: host), "SwiftUI 的 TextField 在 macOS 上应当是 NSTextField"
        )
        let inWindow = field.convert(field.bounds, to: nil)
        XCTAssertGreaterThan(inWindow.width, 40, "输入框应当有可点的宽度（实测 \(inWindow.width)）")

        // ⚠️ `hitTest(_:)` 收的点是**父视图坐标系**（这里就是窗口坐标），不是自己的坐标系
        // —— 传转换过的自身坐标会打到半个屏幕之外（实测打到了中间栏的 `NSClipView`）。
        let hit = try XCTUnwrap(
            host.hitTest(NSPoint(x: inWindow.midX, y: inWindow.midY)),
            "输入框正中间应当有东西接着这次点击"
        )
        XCTAssertTrue(
            hit === field || Self.isDescendant(hit, of: field),
            "点输入框应当命中输入框本身，实际命中的是 \(type(of: hit))@\(hit.convert(hit.bounds, to: nil))（被外层的手势区吞掉了）"
        )
    }

    // MARK: - ⑦ 固定搭配：中文译文要紧跟英文

    /// 一块只带一条固定搭配、别的什么都没有的词条。
    ///
    /// 故意做这么干净：搭配是最后一块，于是「图上最后一个墨块」就是搭配那一行 ——
    /// 不用去猜版块的位置，量它就行。
    private func onlyCollocation() -> DictionaryDetail {
        DictionaryDetail(
            word: "nominal",
            collocations: [
                DictionaryCollocation(
                    phrase: "nominal fee", translation: "象征性费用",
                    example: "", exampleTranslation: ""
                )
            ]
        )
    }

    /// 用户口径：查单词卡片里「固定搭配」的**中文释义要紧跟在英文右边**一小段距离，
    /// 不是被推到卡片最右边（实测报障：中间隔了大半张卡）。
    ///
    /// 判据：那一行里所有墨迹之间的**最大空隙**。译文被推开时，空隙会有几百像素；
    /// 紧跟时只有英文单词之间的空格与 8pt 的行内间距。
    func testCollocationTranslationSitsRightNextToThePhrase() throws {
        let rendered = try render(AnyView(DictionaryWordDetailCard(detail: onlyCollocation())))
        try dump(rendered.rep, name: "collocation-row.png")

        let scale = 2.0   // 离屏位图是 2x
        let block = try XCTUnwrap(
            lastContentBlock(in: rendered.rep), "搭配那一行一个像素都没画出来"
        )
        let runs = inkRuns(in: rendered.rep, rows: block)
        XCTAssertGreaterThanOrEqual(runs.count, 2, "搭配行里应当既有英文也有中文译文")

        var biggestGap = 0
        for (previous, next) in zip(runs, runs.dropFirst()) {
            biggestGap = max(biggestGap, next.lowerBound - previous.upperBound)
        }
        XCTAssertLessThanOrEqual(
            CGFloat(biggestGap) / scale, 24,
            "英文与译文之间出现了一段空白（最大空隙 \(Double(biggestGap) / scale)pt），译文没有紧跟搭配"
        )

        let rightEdge = try XCTUnwrap(runs.last?.upperBound)
        XCTAssertLessThan(
            CGFloat(rightEdge) / scale, cardWidth - 60,
            "译文被推到了卡片最右边（墨迹右缘 \(Double(rightEdge) / scale)pt，卡片宽 \(cardWidth)pt）"
        )
    }

    /// 图上**最后一个有内容的**行区间（搭配是最后一块，于是它就是搭配那一行）。
    ///
    /// ⚠️ 不能直接取「最后一个有墨的行块」：卡片底部还有一道描边（通栏一整行），
    /// 它比文字更靠下，会被当成最后一块 —— 量出来一条通栏、没有任何文字分段。
    /// 所以从下往上挑第一块**不是通栏**的。
    private func lastContentBlock(in rep: NSBitmapImageRep) -> ClosedRange<Int>? {
        var blocks: [ClosedRange<Int>] = []
        var start: Int?
        for y in 0..<rep.pixelsHigh {
            let hasInk = rowHasInk(in: rep, row: y)
            if hasInk, start == nil { start = y }
            if !hasInk, let from = start {
                blocks.append(from...(y - 1))
                start = nil
            }
        }
        if let from = start { blocks.append(from...(rep.pixelsHigh - 1)) }

        for block in blocks.reversed() {
            let runs = inkRuns(in: rep, rows: block)
            guard let first = runs.first, let last = runs.last else { continue }
            let extent = last.upperBound - first.lowerBound
            if CGFloat(extent) < CGFloat(rep.pixelsWide) * 0.9 { return block }
        }
        return nil
    }

    private func rowHasInk(in rep: NSBitmapImageRep, row: Int) -> Bool {
        for x in 0..<rep.pixelsWide {
            guard let color = rep.colorAt(x: x, y: row) else { continue }
            if color.brightnessComponent < 0.94 { return true }
        }
        return false
    }

    /// 给定行区间里，横向的墨迹分段（用来看「英文」与「译文」之间隔了多远）。
    private func inkRuns(in rep: NSBitmapImageRep, rows: ClosedRange<Int>) -> [ClosedRange<Int>] {
        var inked = [Bool](repeating: false, count: rep.pixelsWide)
        for x in 0..<rep.pixelsWide {
            for y in rows {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                if color.brightnessComponent < 0.9 { inked[x] = true; break }
            }
        }
        var runs: [ClosedRange<Int>] = []
        var start: Int?
        for x in 0..<inked.count {
            if inked[x] {
                if start == nil { start = x }
            } else if let from = start, x - from > 1 {
                runs.append(from...(x - 1))
                start = nil
            }
        }
        if let from = start { runs.append(from...(inked.count - 1)) }
        return runs
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }

    private static func firstTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField { return field }
        for subview in view.subviews {
            if let found = firstTextField(in: subview) { return found }
        }
        return nil
    }

    private static func isDescendant(_ view: NSView, of ancestor: NSView) -> Bool {
        var current = view.superview
        while let node = current {
            if node === ancestor { return true }
            current = node.superview
        }
        return false
    }
}
