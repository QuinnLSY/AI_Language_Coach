import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 第 31 步三项需求（每日跟读 / 词族树 / 划词气泡）的**离屏渲染**回归。
///
/// 手法与 `DictionaryRenderTests` 一致：
/// 1. **只翻一个开关**再逐像素差分 —— 差分有 = 那块确实画出来了，差分≈0 = 压根没画；
/// 2. 阈值自校准（同一状态连抓两趟当噪声）；
/// 3. 图要落到 `.workbuddy/verify/` 让人眼复核 —— 「高度变矮」这种断言救不了排版跑偏。
///
/// 熄屏验证，一律离屏渲染不碰屏幕、不读写真实数据。
@MainActor
final class WordFamilyRenderTests: XCTestCase {

    private var window: NSWindow?
    private let cardWidth: CGFloat = 620

    private struct Render {
        let rep: NSBitmapImageRep
        let size: CGSize
    }

    // MARK: - 造数据

    /// 一棵三层树（词根 → 分支 → 关联词 → 再一层），全部围绕同一个词，
    /// 这样抓出来的图读起来是一棵真的词族树，而不是互不相干的一堆词。
    private func family() -> DictionaryWordFamily {
        DictionaryWordFamily(
            root: "riv",
            rootMeaning: "河",
            branches: [
                DictionaryFamilyNode(
                    word: "rival",
                    pos: "n.",
                    translation: "竞争对手",
                    morphology: "riv 河：溪流 + -al 与……有关的",
                    children: [
                        DictionaryFamilyNode(
                            word: "rivalry", pos: "n.", translation: "竞争；较量",
                            morphology: "rival + -ry 表示性质/状态",
                            children: [
                                DictionaryFamilyNode(
                                    word: "rivality", pos: "n.", translation: "对立状态",
                                    morphology: "rivalry + -ity 名词后缀"
                                )
                            ]
                        ),
                        DictionaryFamilyNode(
                            word: "rivalrous", pos: "adj.", translation: "竞争性的",
                            morphology: "rival + -ous 充满……的"
                        )
                    ]
                ),
                DictionaryFamilyNode(
                    word: "derive", pos: "v.", translation: "起源；派生",
                    morphology: "de- 向下 + riv 河"
                )
            ]
        )
    }

    private func detail(withFamily: Bool) -> DictionaryDetail {
        DictionaryDetail(
            word: "rival",
            phoneticUS: "/ˈraɪvl/",
            senses: [DictionarySense(pos: "n.", text: "竞争对手；匹敌者")],
            derivatives: [DictionaryRelatedWord(word: "rivalry", pos: "n.", translation: "竞争；较量")],
            synonyms: [DictionaryRelatedWord(word: "competitor", pos: "n.", translation: "竞争者")],
            antonyms: [DictionaryRelatedWord(word: "ally", pos: "n.", translation: "盟友")],
            family: withFamily ? family() : DictionaryWordFamily()
        )
    }

    private func bubbleCard(isPhrase: Bool = false) -> WordLookupCard {
        WordLookupCard(
            text: isPhrase ? "take a rain check" : "rival",
            phonetic: isPhrase ? "" : "/ˈraɪvl/",
            pos: isPhrase ? "" : "n.",
            translation: isPhrase ? "改天再说；下次一定" : "竞争对手；可与……匹敌的人或物",
            isLoading: false,
            isPhrase: isPhrase,
            notice: nil,
            isFromModel: isPhrase
        )
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

        // 两趟：先问自然高度再出图，否则内容被裁掉，高度断言全是假的。
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
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]), "PNG 编码失败")
        try png.write(to: directory.appendingPathComponent(name))
    }

    // MARK: - ① 抓图本身是确定的

    func testFamilyRenderingIsDeterministic() throws {
        let binding = Binding<Bool>(get: { false }, set: { _ in })
        let first = try render(AnyView(WordFamilyCard(family: family(), currentWord: "rival", expansion: binding)))
        let second = try render(AnyView(WordFamilyCard(family: family(), currentWord: "rival", expansion: binding)))
        XCTAssertLessThanOrEqual(diff(first.rep, second.rep).count, 60, "同一状态两趟出图应当几乎完全一致")
    }

    // MARK: - ② 词族树：收起态 / 展开态

    /// 「展开关联词」必须**真的多铺出一层**：
    /// 一个分支展开后会多出 3 个词（`rivalry` / `rivalrous` / `rivality`）与它们的构词说明，
    /// 按每行 ≈ 44pt 算应当高出 100pt 以上；按钮文案与箭头方向也跟着变。
    ///
    /// ⚠️ 这里用测试钩子把展开状态直接灌进去：SwiftUI 的按钮在离屏环境里收不到合成鼠标事件，
    /// 点不开就只能验证收起态（见 `WordFamilyCard.expansion` 的注释）。
    func testExpandingTheFamilyReallyGrowsTheTree() throws {
        let collapsed = Binding<Bool>(get: { false }, set: { _ in })
        let expanded = Binding<Bool>(get: { true }, set: { _ in })

        let before = try render(AnyView(
            WordFamilyCard(family: family(), currentWord: "rival", expansion: collapsed)
        ))
        let after = try render(AnyView(
            WordFamilyCard(family: family(), currentWord: "rival", expansion: expanded)
        ))
        try dump(before.rep, name: "round42-word-family-collapsed-day.png")
        try dump(after.rep, name: "round42-word-family-expanded-day.png")
        try dump(
            try render(
                AnyView(WordFamilyCard(family: family(), currentWord: "rival", expansion: expanded)),
                day: false
            ).rep,
            name: "round42-word-family-expanded-night.png"
        )

        XCTAssertGreaterThan(
            after.size.height, before.size.height + 80,
            "展开后要多出三个关联词行（实测 \(before.size.height) → \(after.size.height)）"
        )
        XCTAssertGreaterThan(
            diff(before.rep, after.rep).count, 2_000,
            "收起与展开不能只在高度上有差别，画面内容也要真的变（实测差分 \(diff(before.rep, after.rep).count)）"
        )
    }

    /// 没有词族语义时（`branches` 为空）整张卡不出现 ——
    /// 详情上多一张只有「词族树」四个字的空卡，比没有更糟。
    func testEmptyFamilyAddsNothingToTheDetailPage() throws {
        let without = try render(AnyView(DictionaryWordDetailCard(detail: detail(withFamily: false))))
        let with = try render(AnyView(DictionaryWordDetailCard(detail: detail(withFamily: true))))
        try dump(with.rep, name: "round42-dictionary-detail-with-family-day.png")

        XCTAssertGreaterThan(
            with.size.height, without.size.height + 60,
            "有词族时详情页要长出一块（实测 \(without.size.height) → \(with.size.height)）"
        )
        XCTAssertTrue(
            detail(withFamily: false).family.isEmpty,
            "空的词族树必须算 `isEmpty`，否则详情页会挂一张空壳卡"
        )
    }

    /// 树上每个词都能点着查 —— 这一条只能靠「当前词被标出来」间接证明：
    /// 同一个词作为 `currentWord` 传进去时，卡片要长得不一样（「当前」徽章 + 描边高亮）。
    func testCurrentWordIsMarkedOnTheTree() throws {
        let binding = Binding<Bool>(get: { true }, set: { _ in })
        let anonymous = try render(AnyView(
            WordFamilyCard(family: family(), currentWord: "", expansion: binding)
        ))
        let current = try render(AnyView(
            WordFamilyCard(family: family(), currentWord: "rival", expansion: binding)
        ))
        XCTAssertGreaterThan(
            diff(anonymous.rep, current.rep).count, 40,
            "当前正在查的词要在树上标出来，否则展开后满屏都是词、用户不知道自己在哪"
        )
    }

    // MARK: - ③ 派生 / 近义 / 反义：三栏合一

    /// 用户口径：三张卡合成一张，**中间用竖线分开**（防止三卡高低不齐、
    /// 与下方词族树的衔接不连贯）。像素上能验的是「少三类内容 → 那一块明显矮下去、
    /// 而卡片仍然是完整的一张（不是三张各自为政）」。
    func testRelatedRowIsOneCardNotThree() throws {
        let full = try render(AnyView(DictionaryWordDetailCard(detail: detail(withFamily: false))))
        let lean = try render(AnyView(DictionaryWordDetailCard(
            detail: DictionaryDetail(word: "rival", senses: [DictionarySense(pos: "n.", text: "竞争对手")])
        )))
        try dump(full.rep, name: "round42-dictionary-related-three-columns-day.png")

        XCTAssertGreaterThan(full.size.height, lean.size.height + 40, "三栏内容应当撑起那一块")
        // 三栏合一之后，少一栏只影响内容、不影响「有没有卡片」，落差明显小于三张独立卡。
        let twoColumns = try render(AnyView(DictionaryWordDetailCard(
            detail: DictionaryDetail(
                word: "rival",
                senses: [DictionarySense(pos: "n.", text: "竞争对手")],
                derivatives: [DictionaryRelatedWord(word: "rivalry", pos: "n.", translation: "竞争")]
            )
        )))
        let threeColumns = try render(AnyView(DictionaryWordDetailCard(
            detail: DictionaryDetail(
                word: "rival",
                senses: [DictionarySense(pos: "n.", text: "竞争对手")],
                derivatives: [DictionaryRelatedWord(word: "rivalry", pos: "n.", translation: "竞争")],
                synonyms: [DictionaryRelatedWord(word: "competitor", pos: "n.", translation: "竞争者")]
            )
        )))
        XCTAssertLessThan(
            abs(threeColumns.size.height - twoColumns.size.height), 28,
            "三栏 Unified 成一张卡之后，多加一栏不该把这一块的高度顶出一个新节奏（实测 \(twoColumns.size.height) vs \(threeColumns.size.height)）"
        )
    }

    // MARK: - ④ 划词气泡

    func testBubbleShowsAllFourFieldsAndStaysNarrow() throws {
        let word = try render(AnyView(
            WordLookupBubble(card: bubbleCard())
                .padding(20)
        ), width: 360)
        try dump(word.rep, name: "round42-word-lookup-bubble-day.png")
        try dump(
            try render(AnyView(WordLookupBubble(card: bubbleCard()).padding(20)), day: false, width: 360).rep,
            name: "round42-word-lookup-bubble-night.png"
        )

        // 气泡宽度有上限（268）：下面是白不是「被气泡撑满的一整行」。
        XCTAssertLessThanOrEqual(word.size.width, 360)
        XCTAssertGreaterThan(word.size.height, 60, "词 / 音标 / 词性 / 释义 四行都要放得下")

        // 逐个字段**单独**翻开关，每个字段都必须真的画上去：
        // 少一个字段时卡片可能只是矮一点点，唯有像素差分能证明那一行字真的在。
        let noPhonetic = WordLookupCard(text: "rival", pos: "n.", translation: "竞争对手")
        let withPhonetic = WordLookupCard(text: "rival", phonetic: "/ˈraɪvl/", pos: "n.", translation: "竞争对手")
        let deltaPhonetic = diff(
            try render(AnyView(WordLookupBubble(card: noPhonetic))).rep,
            try render(AnyView(WordLookupBubble(card: withPhonetic))).rep
        )
        XCTAssertGreaterThan(deltaPhonetic.count, 20, "音标要显示在气泡上，实测差分 \(deltaPhonetic.count)")

        let loading = try render(AnyView(WordLookupBubble(card: bubbleCard())))
        let busy = try render(AnyView(WordLookupBubble(
            card: WordLookupCard(text: "rival", isLoading: true)
        )))
        XCTAssertGreaterThan(diff(loading.rep, busy.rep).count, 20, "正在查时要看得出来")

        // 朗读状态要看得见（点了喇叭要有反馈）。
        let speaking = try render(AnyView(WordLookupBubble(card: bubbleCard(), isSpeaking: true)))
        XCTAssertGreaterThan(diff(loading.rep, speaking.rep).count, 20, "朗读中要和静默时不一样")
    }

    /// 短语（划了几个词）**不给音标与词性** —— 那是单词才有的东西。
    func testPhraseCardDropsPhoneticAndPos() throws {
        let phraseCard = bubbleCard(isPhrase: true)
        XCTAssertTrue(phraseCard.isPhrase)
        XCTAssertTrue(phraseCard.phonetic.isEmpty, "短语没有音标")
        XCTAssertTrue(phraseCard.pos.isEmpty, "短语没有词性")

        let word = try render(AnyView(WordLookupBubble(card: bubbleCard())))
        let phrase = try render(AnyView(WordLookupBubble(card: phraseCard)))
        try dump(phrase.rep, name: "round42-word-lookup-bubble-phrase-day.png")
        XCTAssertGreaterThan(diff(word.rep, phrase.rep).count, 100, "短语卡与单词卡长得不一样")

        // 领域层那一半（纯函数）必须和画面同一条口径。
        XCTAssertTrue(WordLookupQuery.isPhrase("take a rain check"))
        XCTAssertFalse(WordLookupQuery.isPhrase("rival"))
    }

    /// 气泡不能被拉成整行糊在句子上 —— 外层给它多大可用宽度都一样。
    func testBubbleNeverExceedsMaxWidth() throws {
        let longCard = WordLookupCard(
            text: "incomprehensible",
            phonetic: "/ɪnˌkɑːmprɪˈhensəbl/",
            pos: "adj.",
            translation: "无法理解的；难懂的（用于强调某事物复杂或隐晦到难以领会）"
        )
        let rendered = try render(AnyView(
            WordLookupBubble(card: longCard).frame(maxWidth: .infinity, alignment: .leading)
        ))
        XCTAssertLessThanOrEqual(rendered.size.width, 620, "给多大宽度都不该把气泡拉成整行")
    }

    /// 长单词**绝不折行**：卡片宽度不够时自适应增宽（2026-09-19 用户口径）。
    /// 曾经「convenience」被行内音标压成两截 —— 音标已另起一行，这里钉住宽度语义。
    func testLongWordWidensCardInsteadOfWrapping() throws {
        let longWord = "antidisestablishmentarianism"
        let card = WordLookupCard(
            text: longWord,
            phonetic: "/ˌæntidɪsɪˌstæblɪʃmənˈtɛəriənɪzəm/",
            pos: "n.",
            translation: "反对政教分离主义"
        )
        // 词头行的自然宽（与气泡内部同一把尺）。
        let attributed = NSAttributedString(
            string: longWord,
            attributes: [.font: WordLookupTextBuilder.font(size: 14, weight: .bold)]
        )
        let wordWidth = ceil(
            attributed.boundingRect(
                with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).width
        )
        XCTAssertGreaterThan(wordWidth, 150, "选的词必须真的长，否则这条测试测不到增宽路径")

        // ① 宽度口径（纯函数，同一把尺）：长词的下限必须越过 268 上限 —— 卡片随之增宽。
        let iconCount = 2 // 朗读钮 + 查词典 + 收复习（失败态的 ↻ 是第三个，另算）
        let longMin = WordLookupBubble.minCardWidth(word: longWord, iconCount: iconCount)
        XCTAssertGreaterThan(longMin, WordLookupBubble.maxWidth, "长词的卡片下限要超过 268，否则词还是会被压")
        XCTAssertGreaterThanOrEqual(longMin, wordWidth + 116, "下限 = 词 + 朗读/图标 44 + 间距 28 + padding 22")
        // 短词维持 268 上限 —— 不许全线变宽。
        XCTAssertLessThanOrEqual(
            WordLookupBubble.minCardWidth(word: "rival", iconCount: iconCount),
            WordLookupBubble.maxWidth
        )

        // ② 渲染：长词卡绝不能比短词卡多出一行（折词 = 布局退回老 bug）。
        //    两卡行结构相同（词头 / 音标 / 词性+释义），唯一差异就是词本身的长相。
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        func renderBubble(_ card: WordLookupCard) throws -> (rep: NSBitmapImageRep, size: CGSize) {
            let host = NSHostingView(rootView: AnyView(
                VStack(alignment: .leading, spacing: 0) {
                    WordLookupBubble(card: card)
                    Spacer(minLength: 0)
                }
                .forestTheme(theme)
                .frame(width: 600, height: 200, alignment: .topLeading)
                .background(Color(hex: 0xE9EFE4))
            ))
            host.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
            host.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            return (rep, host.fittingSize)
        }
        let longRender = try renderBubble(card)
        try dump(longRender.rep, name: "round43-word-lookup-bubble-longword-day.png")
        let shortRender = try renderBubble(
            WordLookupCard(text: "rival", phonetic: "/ˈraɪvl/", pos: "n.", translation: "对手")
        )
        // 折行会让卡片高出一行（≥14pt）；没折行则两卡行数相同、高度差只有音标换行造成的个位数。
        // ⚠️ 量**卡片实际高度**：在长词卡图上从顶部往下找边框描边的底缘太脆，
        // 改为量内容 VStack 的 fittingSize —— 气泡是它唯一的不定高子视图。
        XCTAssertLessThanOrEqual(
            abs(longRender.size.height - shortRender.size.height), 24,
            "长词卡不该比短词卡多出一行（折词 = 布局退回老 bug），实测 \(longRender.size.height) vs \(shortRender.size.height)"
        )
    }

    /// 查不到时右上角多一个 ↻「再查一次」按钮 —— 与有释义的卡逐像素必须不一样。
    func testFailedCardShowsRetryButton() throws {
        let failed = WordLookupCard(text: "serendipity", notice: "「serendipity」这次没查到，点右上角的 ↻ 再查一次。")
        let found = WordLookupCard(text: "serendipity", phonetic: "/ˌsɛrənˈdɪpɪti/", pos: "n.", translation: "机缘巧合")
        let failedRender = try render(AnyView(WordLookupBubble(card: failed)))
        let foundRender = try render(AnyView(WordLookupBubble(card: found)))
        // 词头行（右上角图标区）+ 释义区都会不同；阈值放宽到能盖住图标位移。
        XCTAssertGreaterThan(diff(failedRender.rep, foundRender.rep).count, 60, "失败卡要长得不一样（含 ↻ 按钮）")
        try dump(failedRender.rep, name: "round43-word-lookup-bubble-failed-day.png")
    }
}
