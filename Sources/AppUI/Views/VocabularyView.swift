import AIDomain
import AIServices
import SwiftUI

/// 词汇本页（Vocabulary，第 24 步）。
///
/// 数据流：复盘 new_words / 手动添加 → `VocabularyService` → SQLite；
/// 复习调度与判分在 `AIDomain.ReviewScheduler`（纯函数），这里只做「展示 + 触发」。
/// 顶部还有「每日推荐」板块：**同一天恒定**的 12 个雅思词/词组
/// （种子由「日期 + 学习语言」派生，见 `DailySeed`；不落库、不自动进复习。
///  只有点「换一批」才真随机重抽。）
///
/// 排版约定（词汇本复习卡与每日推荐卡**共用**同一套）：
/// 中文义项一行（多义全列出）→ 中文解释另起一行 → 例句 + 例句翻译 → 近/反义词 →
/// （复习卡额外）重点单词。每部分之间留一点行间隔，绝不把翻译和解释连成一段。
public struct VocabularyView: View {

    @Environment(\.forestTheme) private var theme
    let state: AppState

    public init(state: AppState) { self.state = state }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.divider)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        dailySection
                        // 复习模式：整段换成复习卡（一张一张过），词表暂时让位。
                        // 不是「另开一个页面」——复习完就在原地回到词表，少一次跳转。
                        if state.vocabularyReview != nil {
                            reviewCard
                        } else {
                            reviewEntryCard
                            // 加词入口已经搬到词典页（查词结果页右上角「添加复习」）。
                            // 这里只留一句「去哪儿加」，不再放输入框 —— 两个入口各写一套联想逻辑，
                            // 匹配规则迟早会分叉，用户则会问「为什么这边搜不到那个词」。
                            addHint
                            if state.vocabularyEntries.isEmpty {
                                emptyHint
                            } else {
                                ForEach(state.vocabularyEntries) { entry in
                                    entryCard(entry)
                                }
                            }
                        }
                        if let notice = state.vocabularyNotice {
                            noticeBanner(notice)
                        }
                        // 末尾锚点：给 `--vocabulary-tail` 验证钩子用（滚到列表最后几条）。
                        Color.clear.frame(height: 1).id(Self.tailAnchor)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .task {
                    // 截图/验证辅助：--vocabulary-tail 启动后滚到词表末尾。
                    // 本机 UI 自动化点不动 SwiftUI，滚轮 / 翻页键也不生效，
                    // 要直接看末尾几条卡片（纯中文重点单词的历史数据）只能这样。
                    guard CommandLine.arguments.contains("--vocabulary-tail") else { return }
                    try? await Task.sleep(for: .seconds(2))
                    proxy.scrollTo(Self.tailAnchor, anchor: .bottom)
                }
            }
        }
        .background(theme.surfaceAlt.opacity(0.35))
        // 每次出现都补一次导入（按 word 去重，重复导入是零成本的幂等操作）；
        // 同时保证本次启动的每日推荐已抽好。
        .task {
            await state.openVocabulary()
            await state.loadDailyWordsIfNeeded()
            // 截图/验证辅助：--daily-flip 启动后自动翻到页面第二页。
            // 刻意放慢动画（1.8s），这样一张静态截图就能截到「整页滑动」的中间帧 ——
            // 本机 UI 自动化点不到 SwiftUI 按钮，这是唯一能验证翻页过渡的办法。
            guard CommandLine.arguments.contains("--daily-flip") else { return }
            try? await Task.sleep(for: .seconds(4))
            slowPageAnimation = true
            goToPage(dailyPage + 1)
        }
    }

    /// 词表末尾的滚动锚点（`--vocabulary-tail` 验证钩子用）。
    static let tailAnchor = "vocabulary-tail-anchor"

    // MARK: - 顶栏

    private var header: some View {
        HStack(spacing: 12) {
            CuteAnimalView(kind: state.studentAnimalKind, isSleeping: theme.isNight, size: 40, accessory: .student)
            VStack(alignment: .leading, spacing: 2) {
                Text("词汇本")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Text("复盘里出现的生词都会收进来，到期就来过一遍")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 0)
            if state.vocabularyStats.total > 0 {
                Text("\(state.vocabularyStats.total) 词 · 待复习 \(state.vocabularyStats.due) · 已掌握 \(state.vocabularyStats.mastered)")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(state.vocabularyStats.due > 0 ? theme.accent : theme.secondaryText)
                    .monospacedDigit()
            }
            Button {
                Task { await state.reloadVocabulary() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("刷新词表")
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
    }

    // MARK: - 每日推荐

    /// 推荐框默认**收起**（只露一整页 4 个卡片，紧凑）；点下框线中间的按钮展开 / 收起。
    @State private var dailyExpanded = false
    /// 收起态的页码：每页 4 个卡片（2 行 × 2 列），右侧上下按钮翻页。
    @State private var dailyPage = 0
    /// 收起态每页卡片数（2 行 × 2 列）。
    private static let dailyPageSize = DailyWordPager.pageSize

    @ViewBuilder
    private var dailySection: some View {
        if !state.dailyWords.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.accent)
                    Text("每日推荐")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Text("雅思标准 · 3 简单 / 5 中等 / 2 困难 / 2 词组")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                    Spacer(minLength: 0)
                    Button {
                        Task { await state.refreshDailyWords() }
                        dailyPage = 0
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("换一批")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.accent)
                    }
                    .buttonStyle(.plain)
                    .help("重新随机推荐 12 个不同的单词与词组")
                }

                dailyGrid
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(theme.accent.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(theme.accent.opacity(0.22), lineWidth: 1)
            )
            // 翻页按钮由 `dailyGrid` 与卡片区并排摆放（垂直居中于卡片区），
            // 不再挂在这个外框的 overlay 上 —— 那样是按「标题 + 卡片」整框居中，
            // 位置会偏上。
            // 展开 / 收起按钮骑在**下框线正中**（offset 半个胶囊高）。
            .overlay(alignment: .bottom) { dailyExpandToggle }
            .padding(.bottom, 10)
            // 换一批 / 重置后页码可能越界，收回第一页。
            .onChange(of: state.dailyWords) { _, _ in dailyPage = 0 }
        }
    }

    /// 推荐词区域：
    /// - 展开：全部平铺（自适应列宽）；
    /// - 收起：固定两列、只渲染当前页的 4 个卡片 —— 高度由内容决定，
    ///   **不再用固定高度裁切**（旧方案第二排只露一半），右侧上下按钮翻页。
    @ViewBuilder
    private var dailyGrid: some View {
        if dailyExpanded {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 230), spacing: 10)],
                spacing: 10
            ) {
                ForEach(state.dailyWords) { word in
                    dailyCard(word)
                }
            }
            // ⚠️ 必须显式撑满：LazyVGrid 在 VStack/HStack 里只按内容理想宽度排版，
            // 不写这行的话卡片会被压到 ~110pt（单词被拆成 recomm/end）。
            .frame(maxWidth: .infinity, alignment: .topLeading)
        } else {
            // 卡片区与翻页按钮并排、**垂直居中**对齐 —— 页码正好落在
            // 上下两行卡片的间隙中线上（用户口径：按钮整体再下移到框中线）。
            //
            // ⚠️ 收起态**绝不能用 LazyVGrid**：懒容器的子视图不参与过渡动画，
            // 卡片滑走了、里面的「查释义」按钮却留在原地（用户实测的 UI bug）。
            // 每页固定 4 个，用普通 VStack/HStack 排 2×2 —— 每张卡片是一个
            // 完整视图，卡内所有内容（含按钮）都跟着卡片一起移动。
            HStack(alignment: .center, spacing: 8) {
                ZStack(alignment: .top) {
                    VStack(spacing: 10) {
                        ForEach(Array(dailyPageRows.enumerated()), id: \.offset) { _, row in
                            HStack(alignment: .top, spacing: 10) {
                                ForEach(row) { word in
                                    dailyCard(word)
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                }
                                // 一行只剩一个卡片时右侧留空，两列始终等宽。
                                if row.count == 1 {
                                    Color.clear.frame(maxWidth: .infinity)
                                }
                            }
                        }
                    }
                    .id(dailyPage)
                    .transition(pageTransition)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                // 滑动过程中滑出框外的部分要裁掉，否则会盖住上面的标题行。
                .clipped()

                dailyPager
            }
        }
    }

    /// 收起态当前页按每行 2 个切分（2 行 × 2 列）。
    private var dailyPageRows: [[DailyWord]] {
        DailyWordPager.rows(pageWords, perRow: 2)
    }

    /// 翻页方向：`true` = 往下一页（新页从下方滑入、旧页向上滑出）。
    @State private var pageForward = true
    /// 验证钩子 `--daily-flip` 用的慢速动画开关（正常交互始终保持 0.26s）。
    @State private var slowPageAnimation = false

    /// 整页滑动过渡 —— 与「拖动下拉条」的观感一致。
    private var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: pageForward ? .bottom : .top).combined(with: .opacity),
            removal: .move(edge: pageForward ? .top : .bottom).combined(with: .opacity)
        )
    }

    /// 翻页（越界自动夹住；同页不重放动画）。
    private func goToPage(_ target: Int) {
        let clamped = min(max(target, 0), max(dailyPageCount - 1, 0))
        guard clamped != dailyPage else { return }
        pageForward = clamped > dailyPage
        withAnimation(.easeInOut(duration: slowPageAnimation ? 1.8 : 0.26)) { dailyPage = clamped }
    }

    /// 总页数（不足一页也算一页）。
    private var dailyPageCount: Int {
        DailyWordPager.pageCount(state.dailyWords, pageSize: Self.dailyPageSize)
    }

    /// 当前页的词。
    private var pageWords: [DailyWord] {
        DailyWordPager.page(state.dailyWords, index: dailyPage, pageSize: Self.dailyPageSize)
    }

    /// 右侧上下翻页按钮（取代原来的下拉条）。
    /// 与卡片区**垂直居中**对齐 → 页码正好落在上下两行卡片的**间隙中线**上。
    private var dailyPager: some View {
        VStack(spacing: 6) {
            pagerButton("chevron.up", enabled: dailyPage > 0) { goToPage(dailyPage - 1) }
            Text("\(dailyPage + 1)/\(dailyPageCount)")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .monospacedDigit()
            pagerButton("chevron.down", enabled: dailyPage < dailyPageCount - 1) { goToPage(dailyPage + 1) }
        }
    }

    private func pagerButton(_ systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(enabled ? theme.accent : theme.secondaryText.opacity(0.35))
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder((enabled ? theme.accent : theme.divider).opacity(0.4), lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(systemImage == "chevron.up" ? "上一页（上 4 个）" : "下一页（下 4 个）")
    }

    /// 下框线正中的下拉 / 收起按钮（互相切换）。
    private var dailyExpandToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { dailyExpanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: dailyExpanded ? "chevron.up" : "chevron.down")
                Text(dailyExpanded ? "收起" : "展开")
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 9)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.surface))
            .overlay(
                Capsule().strokeBorder(theme.accent.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .offset(y: 10)
        .help(dailyExpanded ? "收起为四个卡片" : "展开全部推荐词")
    }

    private func dailyCard(_ daily: DailyWord) -> some View {
        let definition = state.dailyDefinitions[daily.word]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(daily.word)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    // 单词优先占位：窄列时宁可整体缩小，也不要把单词拆成 technolog/y。
                    // 单个单词**只允许一行**（靠 minimumScaleFactor 收窄），
                    // 词组才允许按空格折成两行。
                    .layoutPriority(1)
                    .lineLimit(daily.isPhrase ? 2 : 1)
                    .minimumScaleFactor(daily.isPhrase ? 0.85 : 0.72)
                    .fixedSize(horizontal: false, vertical: true)
                difficultyTag(daily.difficulty)
                phoneticLabel(definition?.phonetic, word: daily.word)
                // 单词 / 词组单独一个喇叭（例句有它自己的喇叭，见 `definitionBody`）。
                speakButton(daily.word)
                Spacer(minLength: 0)
                // 三态按钮（查释义 / 看释义 / 收起）：**始终带文字**。
                // ⚠️ 这里绝不能包 `ViewThatFits` —— 它原来的第一个候选带
                // `if dailyExpanded` 条件，收起态下是个**空视图**，结果就是
                // 「查释义」文字消失、还留下一个不随卡片移动的残影（用户实测的 UI bug）。
                // `fixedSize` 保证按钮文字不被压缩，宽度让给单词侧缩。
                dailyToggleButton(
                    daily,
                    title: dailyToggleTitle(daily, definition: definition),
                    systemImage: dailyToggleIcon(daily)
                )
                .fixedSize()
            }

            if let definition, state.expandedDailyWords.contains(daily.word) {
                definitionBody(definition, showKeywords: false)
            }

            HStack(spacing: 8) {
                recognizeButton(daily)
                recognitionDots(state.dailyRecognitionCount(word: daily.word))
                Spacer(minLength: 0)
                if inVocabulary(daily.word) {
                    Label("已在词表", systemImage: "checkmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                } else {
                    Button {
                        Task { await state.addDailyToReview(word: daily.word) }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plus.rectangle.on.folder")
                            Text("加入复习")
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.accent)
                    }
                    .buttonStyle(.plain)
                    .help("加入词汇本复习列表")
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.divider, lineWidth: 1)
        )
    }

    // MARK: - 释义排版（复习卡 / 每日推荐卡共用）

    /// 统一释义排版：中文义项一行 → 解释另起一行 → 例句 + 翻译 → 近/反义词 →（可选）重点单词。
    /// 每个部分之间留一点行间隔，翻译与解释绝不连成一段。
    @ViewBuilder
    private func definitionBody(_ definition: VocabularyDefinition, showKeywords: Bool) -> some View {
        if !definition.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                if !definition.senses.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if !definition.pos.isEmpty { partOfSpeechTag(definition.pos) }
                        Text(definition.senses)
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(theme.primaryText.opacity(0.95))
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(2)
                    }
                } else if !definition.pos.isEmpty {
                    partOfSpeechTag(definition.pos)
                }

                // 解释另起一行 —— 与中文义项分开，方便义项一行多放几个多义。
                if !definition.explanation.isEmpty {
                    Text(definition.explanation)
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2)
                }

                // 旧数据：没结构的一段中文，原样展示（可点「重新释义」升级）。
                if !definition.legacyText.isEmpty {
                    Text(definition.legacyText)
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(theme.primaryText.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2)
                }

                if !definition.example.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            definitionLabel("例句")
                            Text(definition.example)
                                .font(.system(size: 11, design: .rounded).italic())
                                .foregroundStyle(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .lineSpacing(2)
                            // 例句有**自己**的喇叭：与单词的喇叭分开，可单独朗读。
                            speakButton(definition.example)
                            Spacer(minLength: 0)
                        }
                        if !definition.exampleTranslation.isEmpty {
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                // 用等宽的空标签占位，让译文与例句左对齐。
                                definitionLabel("例句").hidden()
                                Text(definition.exampleTranslation)
                                    .font(.system(size: 11, design: .rounded))
                                    .foregroundStyle(theme.secondaryText.opacity(0.85))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .lineSpacing(2)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                } else if !definition.exampleTranslation.isEmpty {
                    definitionLine("例句", definition.exampleTranslation)
                }

                if !definition.synonymTerms.isEmpty {
                    definitionLine("近义词", terms: definition.synonymTerms)
                }
                if !definition.antonymTerms.isEmpty {
                    definitionLine("反义词", terms: definition.antonymTerms)
                }
                // ⚠️ 传 `displayKeywordTerms`：重点单词**必须是英文**。
                // 模型偶尔把中文释义塞进 keywords（实测「你好、打招呼」），那种条目一律丢弃；
                // 一个英文词都没有时**整行不显示**（用户口径：没有重点单词就不显示这一项）。
                if showKeywords, !definition.displayKeywordTerms.isEmpty {
                    definitionLine("重点单词", terms: definition.displayKeywordTerms)
                }
            }
        }
    }

    /// 黄字小标签（例句 / 近义词 / 反义词 / 重点单词共用同一套样式）。
    private func definitionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(theme.accent.opacity(0.85))
    }

    private func definitionLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            definitionLabel(title)
            Text(value)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.primaryText.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
    }

    /// 词条行（**近义词 / 反义词 / 重点单词共用**）：黄字标签 + 一条条「英文 (词性) 中文」。
    ///
    /// 残缺词条只渲染存在的部分：模型只给英文（缺中文）时不会拼出半截括号，
    /// 只给中文（缺英文）时也不会凭空补一个空词性 —— 两种情况都是可读的。
    private func definitionLine(_ title: String, terms: [VocabularyTerm]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            definitionLabel(title)
            termText(terms)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
    }

    /// 词条正文：`considerable (adj.) 大量的、significant (adj.) 显著的`。
    private func termText(_ terms: [VocabularyTerm]) -> Text {
        var result = Text("")
        for (index, term) in terms.enumerated() {
            if index > 0 {
                result = result + Text("、").foregroundStyle(theme.secondaryText)
            }
            var part = Text("")
            var needsSeparator = false
            if !term.word.isEmpty {
                part = part + Text(term.word).foregroundStyle(theme.primaryText.opacity(0.92))
                needsSeparator = true
            }
            if !term.pos.isEmpty {
                if needsSeparator { part = part + Text(" ") }
                part = part + Text("(\(term.pos))").foregroundStyle(theme.accent.opacity(0.9))
                needsSeparator = true
            }
            if !term.translation.isEmpty {
                if needsSeparator { part = part + Text(" ") }
                part = part + Text(term.translation).foregroundStyle(theme.primaryText.opacity(0.8))
            }
            result = result + part
        }
        return result.font(.system(size: 11, design: .rounded))
    }

    /// 词性小标签（斜体、主题色）。
    private func partOfSpeechTag(_ pos: String) -> some View {
        Text(pos)
            .font(.system(size: 10, weight: .semibold, design: .rounded).italic())
            .foregroundStyle(theme.accent)
    }

    /// 音标：**只有单个单词才显示**（词组 / 短句不显示，模型也被要求填 `-`）。
    @ViewBuilder
    private func phoneticLabel(_ phonetic: String?, word: String) -> some View {
        if let phonetic, !phonetic.isEmpty, showsPhonetic(word) {
            Text(phonetic)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 该词条是否适合显示音标（含空格 = 词组 / 短句 → 不显示）。
    private func showsPhonetic(_ word: String) -> Bool {
        !word.contains(" ") && word.count <= 24
    }

    // MARK: - 小喇叭

    /// 黄色小喇叭：朗读卡片里的英文（单词 + 例句）。朗读中再点即停。
    /// 复用老师朗读链路（`AppState.speak` → VoiceService 分句流水线 + 相位回调）。
    /// 样式与行为都在 `SpeakButton`（词汇本 / 每日推荐 / 词典三处共用）。
    private func speakButton(_ text: String) -> some View {
        let isActive = state.speakingText == text && state.speechPhase != .idle
        let isPreparing = isActive && state.speechPhase == .preparing
        return SpeakButton(isActive: isActive, isPreparing: isPreparing) {
            if isActive {
                Task { await state.stopSpeaking() }
            } else {
                Task { await state.speak(text) }
            }
        }
    }

    // MARK: - 每日推荐按钮

    /// 每日推荐的「认识」按钮（与复习判分的认识同款绿色）：
    /// 点一下计数 +1 并变灰成「再想想」（再点撤销）；累计满 3 次的词不再推荐。
    private func recognizeButton(_ daily: DailyWord) -> some View {
        let acknowledged = state.dailyAcknowledged.contains(daily.word)
        return Button {
            Task { await state.toggleDailyRecognized(word: daily.word) }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: acknowledged ? "arrow.uturn.backward" : "checkmark.circle.fill")
                Text(acknowledged ? "再想想" : "认识")
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(acknowledged ? theme.secondaryText : Color.green)
        }
        .buttonStyle(.plain)
        .help(acknowledged ? "撤销：刚才点错了" : "我认识这个词（累计 3 次后不再推荐）")
    }

    /// 「认识」进度点：最多 3 个小绿点，亮几个 = 被认识几次。
    private func recognitionDots(_ count: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<AppState.dailyRecognitionRetireCount, id: \.self) { index in
                Circle()
                    .fill(index < count ? Color.green : theme.divider)
                    .frame(width: 6, height: 6)
            }
        }
        .help("累计认识 \(count) 次，满 \(AppState.dailyRecognitionRetireCount) 次不再推荐")
    }

    /// 每日推荐的「查释义 / 看释义 / 收起」按钮（一个按钮三态切换）。
    /// `showsTitle = false` 时只留图标（窄列降级），语义由悬停提示补足。
    private func dailyToggleButton(
        _ daily: DailyWord,
        title: String,
        systemImage: String,
        showsTitle: Bool = true
    ) -> some View {
        Button {
            Task { await state.toggleDailyDefinition(word: daily.word) }
        } label: {
            HStack(spacing: 4) {
                if state.isDefiningDaily.contains(daily.word) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .scaleEffect(0.6)
                } else {
                    Image(systemName: systemImage)
                }
                if showsTitle { Text(title) }
            }
            .font(.system(size: 10, weight: .medium))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.accent)
        .disabled(state.isDefiningDaily.contains(daily.word))
        .help(title)
    }

    /// 三态按钮的图标：展开后是「收起」，否则都是「查 / 看释义」。
    private func dailyToggleIcon(_ daily: DailyWord) -> String {
        state.expandedDailyWords.contains(daily.word) ? "chevron.up" : "character.book.closed"
    }

    /// 三态按钮的文案：没释义 = 查释义，有释义 = 看释义，已展开 = 收起释义。
    private func dailyToggleTitle(_ daily: DailyWord, definition: VocabularyDefinition?) -> String {
        if state.expandedDailyWords.contains(daily.word) { return "收起释义" }
        return definition == nil ? "查释义" : "看释义"
    }

    private func difficultyTag(_ difficulty: Int) -> some View {
        let color: Color = switch difficulty {
        case 1: .green
        case 2: theme.warning
        case 3: .red
        default: Color(hex: 0x8A7BF0)
        }
        return Text(DailyWord.difficultyLabel(for: difficulty))
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.85)))
    }

    /// 该词是否已在复习列表（大小写不敏感，与数据库去重规则一致）。
    private func inVocabulary(_ word: String) -> Bool {
        state.vocabularyEntries.contains { $0.word.caseInsensitiveCompare(word) == .orderedSame }
    }

    // MARK: - 复习闭环（P1-3）

    /// 复习入口：到期几个、一轮怎么走、什么时候开始。
    ///
    /// 「今天没有到期的词」也要显示（灰按钮）：不显示的话，用户会以为复习功能坏了。
    @ViewBuilder
    private var reviewEntryCard: some View {
        if state.vocabularyStats.total > 0 {
            let due = state.vocabularyStats.due
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: due > 0 ? "clock.badge.exclamationmark" : "checkmark.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(due > 0 ? theme.accent : Color.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(due > 0 ? "今天有 \(due) 个词到期" : "今天没有到期的词")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Text(due > 0
                         ? "一轮最多过 \(VocabularyReviewSession.maxCards) 个：先自己想，再翻面；忘了的今天还会再见一面。"
                         : "复习过的词会按掌握度排下一次见面的时间，掌握度满 \(ReviewScheduler.maxMastery) 就不再出现。")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    Task { await state.startVocabularyReview() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill")
                        Text("开始复习")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.onAccentFill)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        // 黄底上的字色跟着 `accentFill` 走（白档深墨、夜档白字）：
                        // 白档的黄已经提亮成金黄，再写死白字就整块读不出。
                        Capsule().fill(due > 0 ? theme.accentFill : theme.secondaryText.opacity(0.35))
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(due == 0)
                .help(due > 0 ? "开始一轮复习（最多 \(VocabularyReviewSession.maxCards) 个词）" : "今天没有到期的词")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(due > 0 ? theme.accent.opacity(0.3) : theme.divider, lineWidth: 1)
            )
        }
    }

    /// 复习模式：把状态摆进纯展示组件（组件本身不读 `AppState`，便于单独离屏渲染）。
    @ViewBuilder
    private var reviewCard: some View {
        if let session = state.vocabularyReview {
            VocabularyReviewCard(
                session: session,
                revealed: state.vocabularyReviewRevealed,
                report: state.vocabularyReviewReport,
                recognized: state.vocabularyReviewRecognized,
                notice: state.vocabularyReviewNotice,
                isRecording: state.isVocabularyReviewRecording,
                isBusy: state.isVocabularyReviewBusy,
                isSpeaking: state.speakingText == session.current?.word && state.speechPhase != .idle,
                isPreparingSpeech: state.speakingText == session.current?.word
                    && state.speechPhase == .preparing,
                hasRecording: state.vocabularyReviewRecognized != nil,
                isDefining: session.current.map { state.isDefiningVocabulary.contains($0.id) } ?? false,
                onReveal: { state.revealVocabularyReviewCard() },
                onGrade: { remembered in
                    Task { await state.gradeVocabularyReviewCard(remembered: remembered) }
                },
                onToggleRecording: { Task { await state.toggleVocabularyReviewRecording() } },
                onReplay: { Task { await state.replayVocabularyReviewRecording() } },
                onSpeak: { Task { await state.speakVocabularyReviewWord() } },
                onFinish: { Task { await state.finishVocabularyReview() } },
                onDefine: { Task { await state.defineVocabularyReviewWord() } },
                onDismissNotice: { state.dismissVocabularyReviewNotice() }
            )
        }
    }

    // MARK: - 加词入口（已搬到词典页）

    /// 加词指引条：词汇本的输入框已删除，加词统一从词典页走。
    ///
    /// 为什么删掉输入框而不是两个入口并存：词典页的搜索框要「模糊匹配 + 音标 + 翻译」，
    /// 与这里原来的联想是同一件事。两个入口各维护一套，匹配规则迟早分叉，
    /// 用户则会问「为什么词典里搜得到、这里搜不到」。
    private var addHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "character.book.closed.fill")
                .font(.system(size: 14))
                .foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("加词去词典里查")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Text("在词典页搜一个词，结果页右上角点「添加复习」，它就会出现在这里。")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button {
                Task { await state.openDictionary() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                    Text("去查词")
                }
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(theme.accent.opacity(0.12)))
                .overlay(Capsule().strokeBorder(theme.accent.opacity(0.3), lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("打开词典页查词")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.surfaceAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.divider, lineWidth: 1)
        )
    }

    // MARK: - 词条卡片

    private func entryCard(_ entry: VocabularyEntry) -> some View {
        let collapsed = state.collapsedVocabularyDefinitions.contains(entry.id)
        let definition = VocabularyDefinitionRule.decodeStored(entry.meaning)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.word)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                phoneticLabel(definition.phonetic, word: entry.word)
                // 只读单词；例句由例句行自己的喇叭读（两者互不影响）。
                speakButton(entry.word)
                if ReviewScheduler.isDue(entry) {
                    Text("待复习")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.onAccentFill)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(theme.accentFill))
                }
                if entry.isMastered {
                    Text("已掌握")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.green))
                }
                Spacer(minLength: 0)
                Text(sourceLabel(entry.source))
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                // 删除（红色线条，醒目一些）
                Button {
                    Task { await state.removeVocabulary(id: entry.id) }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.red.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("从词表删除")
            }

            if !collapsed {
                if entry.meaning.isEmpty {
                    Text("还没有释义")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(theme.secondaryText.opacity(0.7))
                } else {
                    // 与每日推荐卡完全同一套排版，额外多一行「重点单词」。
                    definitionBody(definition, showKeywords: true)
                }
            }

            HStack(spacing: 10) {
                masteryBar(entry.mastery)
                Text("复习 \(entry.reviewCount) 次")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .monospacedDigit()
                Spacer(minLength: 0)
                // 旧数据（早先只存了一段中文，没有音标 / 词性 / 例句翻译）：可重新释义升级。
                if definition.isLegacy {
                    Button {
                        Task { await state.redefineVocabulary(id: entry.id) }
                    } label: {
                        HStack(spacing: 4) {
                            if state.isDefiningVocabulary.contains(entry.id) {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .controlSize(.mini)
                                    .scaleEffect(0.6)
                            } else {
                                Image(systemName: "arrow.clockwise.circle")
                            }
                            Text("重新释义")
                        }
                        .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.secondaryText)
                    .disabled(state.isDefiningVocabulary.contains(entry.id))
                    .help("旧版数据没有音标 / 词性 / 例句翻译，重新查一次升级格式")
                }
                Button {
                    Task { await state.toggleVocabularyDefinition(id: entry.id) }
                } label: {
                    HStack(spacing: 4) {
                        if state.isDefiningVocabulary.contains(entry.id) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.mini)
                                .scaleEffect(0.6)
                        } else {
                            Image(systemName: collapsed ? "character.book.closed" : "eye.slash")
                        }
                        Text(collapsed ? "看释义" : (entry.meaning.isEmpty ? "查释义" : "收起释义"))
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accent)
                .disabled(state.isDefiningVocabulary.contains(entry.id))
                if ReviewScheduler.isDue(entry) {
                    gradeButton(entry.id, remembered: true, title: "认识", systemImage: "checkmark.circle.fill", color: .green)
                    gradeButton(entry.id, remembered: false, title: "忘了", systemImage: "xmark.circle.fill", color: theme.warning)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.divider, lineWidth: 1)
        )
    }

    private func gradeButton(_ id: UUID, remembered: Bool, title: String, systemImage: String, color: Color) -> some View {
        Button {
            Task { await state.gradeVocabulary(id: id, remembered: remembered) }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .help(remembered ? "记住了：掌握度 +1" : "忘了：掌握度 -1，今天再来一遍")
    }

    // MARK: - 小部件

    /// 掌握度条：5 格。
    private func masteryBar(_ mastery: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(index < mastery ? theme.accent : theme.divider)
                    .frame(width: 10, height: 4)
            }
        }
    }

    private func sourceLabel(_ source: VocabularyEntry.Source) -> String {
        switch source {
        case .review: "复盘"
        case .scenario: "情景"
        case .manual: "手动"
        case .material: "材料"
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 28))
                .foregroundStyle(theme.secondaryText.opacity(0.6))
            Text("词表还是空的")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.primaryText)
            Text("每次练习结束后，复盘里标记的生词会自动收进这里；也可以在词典页查词，从结果页右上角「添加复习」加进来。")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .foregroundStyle(theme.accent)
            Text(text)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.primaryText.opacity(0.85))
            Spacer(minLength: 0)
            Button {
                state.dismissVocabularyNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.accent.opacity(0.08))
        )
    }
}
