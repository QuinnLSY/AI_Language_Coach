import AIDomain
import AIServices
import AppCore
import SwiftUI

/// 词汇本页（Vocabulary，第 24 步）。
///
/// 数据流：复盘 new_words / 手动添加 → `VocabularyService` → SQLite；
/// 复习调度与判分在 `AIDomain.ReviewScheduler`（纯函数），这里只做「展示 + 触发」。
/// 顶部还有「每日推荐」板块：每次启动随机 12 个雅思词/词组（不落库、不自动进复习）。
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
                        // 添加框常驻：词表空了也要能随手加词。
                        addRow
                        if state.vocabularyEntries.isEmpty {
                            emptyHint
                        } else {
                            ForEach(state.vocabularyEntries) { entry in
                                entryCard(entry)
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
            // 翻页按钮骑在**整个框的垂直中线**上（右侧贴边）——
            // 不是顶在卡片上方（用户口径：位置往下移到框中线上）。
            .overlay(alignment: .trailing) {
                if !dailyExpanded {
                    dailyPager.padding(.trailing, 14)
                }
            }
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
            // 收敛在 ZStack 里：翻页时旧页与新页同时存在，各自上下滑出 / 滑入，
            // 才能看到「整页滑动」而不是直接闪现。
            ZStack(alignment: .top) {
                LazyVGrid(columns: Self.dailyColumns, spacing: 10) {
                    ForEach(pageWords) { word in
                        dailyCard(word)
                    }
                }
                .id(dailyPage)
                .transition(pageTransition)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // 滑动过程中滑出框外的部分要裁掉，否则会盖住上面的标题行。
            .clipped()
            // 给右侧翻页按钮让位（按钮由 dailySection 的 overlay 摆放）。
            .padding(.trailing, Self.pagerGutter)
        }
    }

    /// 收起态右侧翻页按钮占用的宽度（按钮 20pt + 与卡片的间距 8pt）。
    private static let pagerGutter: CGFloat = 28

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

    /// 收起态列宽：两列（每页 2 行 × 2 列 = 完整 4 个卡片）。
    /// 卡片标题行在窄列下靠 `ViewThatFits` 自动降级（见 `dailyCard`），
    /// 保证单词永远不会被拆成 desc/ribe。
    private static let dailyColumns = [
        GridItem(.flexible(), spacing: 10, alignment: .top),
        GridItem(.flexible(), spacing: 10, alignment: .top)
    ]

    /// 总页数（不足一页也算一页）。
    private var dailyPageCount: Int {
        DailyWordPager.pageCount(state.dailyWords, pageSize: Self.dailyPageSize)
    }

    /// 当前页的词。
    private var pageWords: [DailyWord] {
        DailyWordPager.page(state.dailyWords, index: dailyPage, pageSize: Self.dailyPageSize)
    }

    /// 右侧上下翻页按钮（取代原来的下拉条；垂直方向骑在框的中线上）。
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
                // 三态按钮（查释义 / 看释义 / 收起）：
                // 展开态列宽富余 → 带文字更好认；
                // 收起态是两列窄卡片 → 无条件降级成纯图标，把宽度让给单词
                // （否则 consequence 会被挤成「considera…」）。
                ViewThatFits(in: .horizontal) {
                    if dailyExpanded {
                        dailyToggleButton(daily, title: dailyToggleTitle(daily, definition: definition), systemImage: dailyToggleIcon(daily), showsTitle: true)
                    }
                    dailyToggleButton(daily, title: dailyToggleTitle(daily, definition: definition), systemImage: dailyToggleIcon(daily), showsTitle: false)
                }
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
    ///
    /// 朗读中是**声波逐层点亮的动效**（不再用静音图标 —— 那看着像「已经静音」）。
    /// 首句还在合成（preparing）时转圈，告诉用户「点了，正在准备」。
    private func speakButton(_ text: String) -> some View {
        let isActive = state.speakingText == text && state.speechPhase != .idle
        let isPreparing = isActive && state.speechPhase == .preparing
        return Button {
            if isActive {
                Task { await state.stopSpeaking() }
            } else {
                Task { await state.speak(text) }
            }
        } label: {
            ZStack {
                if isPreparing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: isActive ? "speaker.wave.3.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.yellow)
                        .symbolEffect(.variableColor.iterative, isActive: isActive)
                }
            }
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isActive ? "停止朗读" : "朗读")
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
        case 2: .orange
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

    // MARK: - 添加

    private var addRow: some View {
        // 输入框 + 「添加」按钮融成同一个圆角矩形（等高、共一条边框）。
        HStack(spacing: 0) {
            TextField("想记的单词或表达，如：How come…", text: Bindable(state).vocabularyDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .onSubmit { submitVocabularyDraft() }
                .onChange(of: state.vocabularyDraft) { _, _ in
                    state.vocabularyDraftChanged()
                }

            Rectangle()
                .fill(theme.divider)
                .frame(width: 1, height: 18)

            Button {
                submitVocabularyDraft()
            } label: {
                Text("添加")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(canSubmitVocabularyDraft ? theme.accent : theme.secondaryText.opacity(0.45))
                    .padding(.horizontal, 14)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSubmitVocabularyDraft)
            .help("加入词表")
        }
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.divider, lineWidth: 1)
        )
        // 联想浮层用 overlay：**不占布局高度**，因此不会把下方内容挤下去。
        .overlay(alignment: .topLeading) {
            if !state.vocabularyMatches.isEmpty {
                suggestionPopover
                    .offset(y: 36)
            }
        }
        // 抬高绘制层级，浮层才能盖在下面的词条卡片之上。
        .zIndex(10)
    }

    private var canSubmitVocabularyDraft: Bool {
        !state.vocabularyDraft.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 点「添加」（或回车）才真正入库；选中联想词只替换输入框内容。
    private func submitVocabularyDraft() {
        guard canSubmitVocabularyDraft else { return }
        state.dismissVocabularySuggestions()
        Task { await state.addVocabularyWord() }
    }

    /// 输入框下方的模糊匹配浮层：最多 10 条，不足按实际高度。
    /// 每条显示「英文（词性）中文翻译」；词库词还没有中文时退回难度档标签。
    private var suggestionPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(state.vocabularyMatches) { suggestion in
                Button {
                    state.applyVocabularySuggestion(suggestion)
                } label: {
                    HStack(spacing: 8) {
                        Text(suggestion.word)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                        if !suggestion.detailText.isEmpty {
                            Text(suggestion.detailText)
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(theme.secondaryText)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if suggestion.isInVocabulary {
                            Text("已在词表")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if suggestion.id != state.vocabularyMatches.last?.id {
                    Divider().overlay(theme.divider)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.accent.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
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
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(theme.accent))
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
                    gradeButton(entry.id, remembered: false, title: "忘了", systemImage: "xmark.circle.fill", color: .orange)
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
            Text("每次练习结束后，复盘里标记的生词会自动收进这里；也可以在上方手动添加，或把每日推荐的词「加入复习」。")
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
