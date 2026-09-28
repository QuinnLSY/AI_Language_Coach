import AIDomain
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 词典页（新功能）。**一个页面两种模式**，靠顶栏那颗按钮来回切：
///
/// - 查单词（默认）：常驻搜索栏 + 结果页；
/// - 词典库：书架（封面网格 + 导入）。
///
/// 两者共用中间栏、共用一份状态：切走再切回来，查词会话（当前词 / 上一页 / 最初那个词）
/// 与输入框内容都还在（用户口径里明确要求）。
public struct DictionaryView: View {

    @Environment(\.forestTheme) private var theme
    let state: AppState

    public init(state: AppState) { self.state = state }

    /// 悬停中的书（nil = 没有）。
    @State private var hoveredBookID: String?
    /// 是否悬停在导入图标上。
    @State private var hoveringImport = false
    /// 搜索输入框是否持有焦点（用来「点回来就重新浮现联想」）。
    @FocusState private var queryFocused: Bool
    /// 鼠标正停在「最近查过」的哪一颗上。
    @State private var hoveredRecentWord: String?

    /// 中间栏内容的顶部锚点（换词 / 换模式之后把视口拉回开头）。
    private static let topAnchorID = "dictionary-scroll-top"

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.divider)
            if state.dictionaryMode == .search {
                searchBar
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                if !state.recentDictionaryWords.isEmpty {
                    recentWordsRow
                        .padding(.horizontal, 18)
                        .padding(.bottom, 10)
                }
                Divider().overlay(theme.divider)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if state.dictionaryMode == .search {
                            searchContent
                        } else {
                            libraryContent
                        }
                        if let notice = state.dictionaryNotice {
                            noticeBanner(notice)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(Self.topAnchorID)
                    // 失败提示的触觉反馈（#358）：挂在常驻容器上（挂在 if let 里
                    // 每次都是新装视图，trigger 永远等不到变化）。带「重试」动作的
                    // 才是失败 —— 纯告知（如「已在词汇本里」）不打扰。
                    .sensoryFeedback(.warning, trigger: state.dictionaryNotice?.text) { old, new in
                        new != nil && old != new
                    }
                }
                // ⚠️ 换一个词只是**换掉卡里的内容**，`ScrollView` 自己不会把偏移重置：
                // 从「派生词 / 近义词」那一块点进去，新词会带着同样的偏移开屏，
                // 看着就像「跳过去之后仍停在派生词那一栏」。所以每次换词显式滚回顶部。
                .onChange(of: state.dictionaryLookup.currentWord) { _, _ in
                    proxy.scrollTo(Self.topAnchorID, anchor: .top)
                }
                // 两种模式是两套内容、两套高度，偏移留着会停在别人的半截上。
                .onChange(of: state.dictionaryMode) { _, _ in
                    proxy.scrollTo(Self.topAnchorID, anchor: .top)
                }
            }
        }
        .background(theme.surfaceAlt.opacity(0.35))
        // 内容不足一屏时不硬弹（#360，同聊天区）。
        .scrollBounceBehavior(.basedOnSize)
        .task {
            await state.reloadDictionaryLibrary()
        }
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack(spacing: 12) {
            CuteAnimalView(kind: state.studentAnimalKind, isSleeping: theme.isNight, size: 40, accessory: state.studentAccessory)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.dictionaryMode == .search ? "查单词" : "词典库")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Text(headerSubtitle)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 0)
            if state.dictionaryUniqueWordCount > 0 {
                // 跨词典同名词只算一个（与查词 / 联想、设置页词汇本卡片同一个数）。
                Text("\(state.dictionaryBooks.count) 本 · 去重后共 \(state.dictionaryUniqueWordCount) 词")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .monospacedDigit()
            }
            modeSwitchButton
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
    }

    private var headerSubtitle: String {
        state.dictionaryMode == .search
            ? "输入单词或词组，回车查询；匹配到的词点一下就查"
            : "打勾的词典决定「每日推荐」从哪本取词，数字是优先级"
    }

    /// 模式切换按钮：文案写着**要去的地方**（不是当前所在的地方）。
    private var modeSwitchButton: some View {
        Button {
            Task { await state.toggleDictionaryMode() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: state.dictionaryMode.switchIcon)
                Text(state.dictionaryMode.switchTitle)
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(theme.accent.opacity(0.12)))
            .overlay(Capsule().strokeBorder(theme.accent.opacity(0.35), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.appPressable)
        .help(state.dictionaryMode.switchTitle)
    }

    // MARK: - 搜索栏（常驻）

    private var searchBar: some View {
        HStack(spacing: 0) {
            // 放大镜 + 输入框这一块单独包一层：**只有点这里才算「用户在找词」**。
            // ⚠️ 手势绝不能罩住右边的「清空 / 查询」两颗按钮 —— 点「查询」时它若也
            // 跟着把浮层重新武装起来，提交刚收起的浮层会被它顶回来。
            HStack(spacing: 0) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.leading, 10)

                TextField("查一个单词或词组，如 nominal", text: Bindable(state).dictionaryQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 8)
                    .focused($queryFocused)
                    .onSubmit { submit() }
                    .onChange(of: state.dictionaryQuery) { _, _ in
                        Task { await state.dictionaryQueryChanged() }
                    }
            }
            .contentShape(Rectangle())
            // 用户口径：查到词之后浮层自动收起，**鼠标再点一下输入框**才重新浮现。
            //
            // 两条路互为兜底，都指向同一个动作：
            // ① 焦点进来（点了别处再点回来，最常见的那条）；
            // ② 直接点在这块区域上（焦点本来就在框里时，焦点不会「变化」，① 不会响）。
            // ⚠️ 用 `simultaneousGesture` 而不是 `onTapGesture`：后者会把这次点击从
            // 输入框手里抢走（光标就点不进去了）。命中测试钉在
            // `DictionaryRenderTests.testClickingTheSearchFieldStillHitsTheTextField`。
            .onChange(of: queryFocused) { _, focused in
                guard focused else { return }
                Task { await state.rearmDictionaryMatches() }
            }
            .simultaneousGesture(TapGesture().onEnded {
                Task { await state.rearmDictionaryMatches() }
            })

            if !state.dictionaryQuery.isEmpty {
                Button {
                    state.dictionaryQuery = ""
                    state.dismissDictionaryMatches()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText.opacity(0.7))
                }
                .buttonStyle(.appPressable)
                .help("清空")
                .padding(.trailing, 6)
            }

            Rectangle()
                .fill(theme.divider)
                .frame(width: 1, height: 18)

            Button(action: submit) {
                Text("查询")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(canSubmit ? theme.accent : theme.secondaryText.opacity(0.45))
                    .padding(.horizontal, 16)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.appPressable)
            .disabled(!canSubmit)
            .help("查这个词（回车同样可以）")
        }
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(theme.divider, lineWidth: 1)
        )
        // 联想浮层用 overlay：**不占布局高度**，不会把结果区挤下去。
        .overlay(alignment: .topLeading) {
            if !state.dictionaryMatches.isEmpty {
                matchPopover.offset(y: 38)
            }
        }
        .zIndex(10)
    }

    /// 「最近查过」一排（#282）。
    ///
    /// 为什么放在搜索栏**下面**而不是只在空态页里：查完一个词之后最常见的下一步
    /// 是「刚才那个相关的词再看看 / 回到上一个词」，那时候空态页已经不在了。
    /// 点一下即回查 —— 与样例词共用同一颗胶囊，落点也同为 `lookUpDictionaryWord`。
    private var recentWordsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.secondaryText)
                Text("最近查过")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                Spacer(minLength: 0)
                Button {
                    state.clearRecentDictionaryWords()
                } label: {
                    Text("清空")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(.appPressable)
                .help("清掉这一排（只是这一排，词典与词汇本不受影响）")
            }
            JustifiedRow(spacing: 8) {
                ForEach(state.recentDictionaryWords, id: \.self) { word in
                    SampleWordChip(word: word, hovered: hoveredRecentWord == word) {
                        Task { await state.lookUpRecentDictionaryWord(word) }
                    }
                    .onHover { inside in
                        if inside {
                            hoveredRecentWord = word
                        } else if hoveredRecentWord == word {
                            hoveredRecentWord = nil
                        }
                    }
                    .help("再查一次「\(word)」")
                }
            }
        }
    }

    private var canSubmit: Bool {
        !state.dictionaryQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func submit() {
        Task { await state.submitDictionaryQuery() }
    }

    /// 匹配浮层：最多 10 条，每条「单词 / 音标 / 翻译」。
    private var matchPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(state.dictionaryMatches) { match in
                Button {
                    Task { await state.selectDictionaryMatch(match) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(match.word)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                        if !match.phonetic.isEmpty {
                            Text(match.phonetic)
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(theme.accent.opacity(0.9))
                        }
                        if !match.detailText.isEmpty {
                            Text(match.detailText)
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(theme.secondaryText)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.appPressable)
                .help("查「\(match.word)」")
                if match.id != state.dictionaryMatches.last?.id {
                    Divider().overlay(theme.divider)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(theme.accent.opacity(0.3), lineWidth: 1)
        )
        .appElevation(.card)
    }

    // MARK: - 查单词内容

    @ViewBuilder
    private var searchContent: some View {
        if let word = state.dictionaryLookup.currentWord {
            let detail = state.dictionaryLookup.current ?? DictionaryDetail(word: word)
            DictionaryWordDetailCard(
                detail: detail,
                isLoading: state.dictionaryLoadingWord == word,
                canGoBack: state.dictionaryLookup.canGoBack,
                canReturnToOrigin: state.dictionaryLookup.canReturnToOrigin,
                isInVocabulary: state.dictionaryWordIsInVocabulary(word),
                isSpeaking: { state.speakingText == $0 && state.speechPhase != .idle },
                isPreparing: { state.speakingText == $0 && state.speechPhase == .preparing },
                onSpeak: { text in Task { await state.speak(text) } },
                onStopSpeak: { Task { await state.stopSpeaking() } },
                onBack: { Task { await state.goBackDictionary() } },
                onReturnToOrigin: { Task { await state.returnToDictionaryOrigin() } },
                onAddToReview: { Task { await state.addDictionaryWordToReview() } },
                onOpenRelated: { related in Task { await state.openDictionaryRelated(related) } },
                onRelookUp: { Task { await state.relookUpDictionaryWord() } },
                lookup: state.wordLookupContext
            )
        } else {
            searchEmptyState
        }
    }

    private var searchEmptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "text.book.closed")
                    .font(.system(size: 22))
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("查一个词试试")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Text("在上面的搜索栏输入英文单词或词组，回车（或点「查询」）出结果。匹配到的词直接点一下也能查。")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if !state.dictionarySamplePool.isEmpty {
                // 铺满整行 + 每 10 秒错落翻牌换一批（词池在 `AppState` 里随机抽好）。
                // 点击的落点仍然是 `lookUpDictionaryWord`：输入框由 `AppState` 统一同步
                // （展示页出现哪个词，框里就是哪个词），这里不再自己写一遍。
                DictionarySampleWordsRow(words: state.dictionarySamplePool) { word in
                    Task { await state.lookUpDictionaryWord(word, pushing: false) }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.surface)
                .appElevation(.card)
        )
    }

    // MARK: - 词典库内容

    private var libraryContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 118, maximum: 168), spacing: 16)],
                alignment: .leading,
                spacing: 18
            ) {
                ForEach(state.dictionaryBooks) { book in
                    DictionaryBookCard(
                        book: book,
                        rank: state.dictionarySourceRanks[book.id],
                        isHovered: hoveredBookID == book.id,
                        isConfirmingDelete: state.dictionaryPendingDelete == book.id,
                        onHover: { hovering in
                            hoveredBookID = hovering ? book.id : (hoveredBookID == book.id ? nil : hoveredBookID)
                        },
                        onDelete: { handleDelete(book) },
                        onCancelDelete: { state.cancelRemoveDictionary() },
                        onToggleSource: { Task { await state.toggleDictionarySource(id: book.id) } }
                    )
                }
                // 导入按钮固定在**列表最后**，尺寸与封面一致。
                DictionaryImportTile(
                    isHovered: hoveringImport,
                    isBusy: state.isImportingDictionary,
                    onHover: { hoveringImport = $0 },
                    onTap: { pickDictionaryFile() }
                )
            }
            // ⚠️ LazyVGrid 在 VStack 里只按内容理想宽度排版，不撑满就会被压成一列窄条。
            .frame(maxWidth: .infinity, alignment: .leading)

            if hoveringImport { importFormatBubble }
            if !state.restorableDictionaries.isEmpty { restorableRow }
        }
    }

    /// 悬停导入图标时的格式气泡（原生 tooltip 之外的一份即时提示）。
    private var importFormatBubble: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("导入词典格式")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Text(DictionaryFileFormat.summary)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("只有 word 必填；phonetic / pos / zh 可省。点图标选择文件。")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText.opacity(0.9))
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.accent.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.accent.opacity(0.25), lineWidth: 1)
        )
    }

    /// 被取下的内置词典：内置的删了不丢，这里一条条放回来。
    private var restorableRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.uturn.backward.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.accent)
                Text("取下的内置词典")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                Spacer(minLength: 0)
                Button {
                    Task { await state.restoreBuiltInDictionaries() }
                } label: {
                    Text("全部放回")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.accent)
                }
                .buttonStyle(.appPressable)
                .help("把内置的三本词典都放回书架")
            }
            FlowRow(spacing: 8, lineSpacing: 8, wrapsLongItems: false) {
                ForEach(state.restorableDictionaries) { book in
                    Button {
                        Task { await state.restoreDictionary(id: book.id) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.uturn.backward")
                            Text(book.name)
                        }
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(theme.accent.opacity(0.12)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.appPressable)
                    .help("把「\(book.name)」放回书架")
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.divider, lineWidth: 1)
        )
    }

    // MARK: - 动作

    /// 删除是两段式：第一下只是变成「确认」（删除不可逆，导入的还会连文件一起删）。
    private func handleDelete(_ book: DictionaryBook) {
        if state.dictionaryPendingDelete == book.id {
            Task { await state.confirmRemoveDictionary(id: book.id) }
        } else {
            state.requestRemoveDictionary(id: book.id)
        }
    }

    /// 选一个 JSON 文件导入。非沙箱应用，直接开系统文件面板。
    private func pickDictionaryFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]
        panel.message = "选择一个词典 JSON 文件"
        panel.prompt = "导入"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await state.importDictionary(from: url) }
    }

    /// 提示条（查词失败那条自带「重试」—— 见 `NoticeBanner`）。
    private func noticeBanner(_ notice: AppNotice) -> some View {
        NoticeBanner(notice: notice) { state.dismissDictionaryNotice() }
    }
}
