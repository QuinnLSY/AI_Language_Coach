import AIDomain
import AIServices
import SwiftUI

/// 词汇复习卡（P1-3 复习闭环的界面）。
///
/// **纯展示组件**：只收值 + 回调，不读 `AppState`、不碰服务 ——
/// 与 `AnnualRecapCard` 同款理由：这样它能被单独离屏渲染回归，
/// 也不必为了看一张卡的状态去搭一整套应用状态。
///
/// 三条界面上的硬规则（都是「不撒谎」的直接后果）：
/// 1. **正面只给词**。先自己想一遍再看释义，否则翻不翻面都没差别。
/// 2. **朗读分不预设等级**。读得再准，认识 / 忘了两个按钮也不替你按 ——
///    会读 ≠ 记得意思。分数旁边写明「仅供参考」。
/// 3. **通道来源如实显示**。规则推断的音素明细绝不说成声学实测
///    （标签由 `PhonemeSource.displayName` 决定，这里不自己编文案）。
struct VocabularyReviewCard: View {

    @Environment(\.forestTheme) private var theme

    let session: VocabularyReviewSession
    /// 当前卡是否已翻面。
    var revealed: Bool = false
    /// 当前卡的朗读评测报告（nil = 还没读 / 没拿到录音）。
    var report: PronunciationReport? = nil
    /// 本次朗读系统听成了什么。
    var recognized: String? = nil
    var notice: String? = nil
    var isRecording: Bool = false
    var isBusy: Bool = false
    /// 正在朗读这个词（含「还在合成」的那一段）。
    var isSpeaking: Bool = false
    /// 正在合成（第一句还没出声）—— 这时转圈，告诉用户「点了，在准备」。
    var isPreparingSpeech: Bool = false
    /// 有没有可回放的录音。
    var hasRecording: Bool = false
    /// 正在查这个词的释义（加载态）。
    var isDefining: Bool = false
    /// 键盘提示（当前绑定；nil = 不显示这一行）。
    ///
    /// 为什么由外面传进来：这张卡是纯展示组件，不读 `AppState`。
    /// 键面读的是**当前**绑定而不是写死的「空格 / 1 / 2 / R」——
    /// 用户在设置里改过键，卡上还写旧键，那就是界面在撒谎。
    var hints: ReviewShortcutHints? = nil

    var onReveal: () -> Void = {}
    var onGrade: (Bool) -> Void = { _ in }
    var onToggleRecording: () -> Void = {}
    var onReplay: () -> Void = {}
    var onSpeak: () -> Void = {}
    var onFinish: () -> Void = {}
    /// 就地查释义（查完直接显示在这张卡上，词表同步）。
    var onDefine: () -> Void = {}
    /// 跳去词典页查这个词（复习进度保留，回来接着过卡）。
    var onLookupInDictionary: () -> Void = {}
    var onDismissNotice: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if session.isFinished {
                summaryPanel
            } else {
                cardPanel
            }
            if let notice {
                noticeBanner(notice)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(theme.accent.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - 一张卡

    private var cardPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            progressHeader
            if let entry = session.current {
                front(entry)
                if revealed {
                    revealPanel(entry)
                }
                spokenPanel(entry)
                Divider().overlay(theme.divider)
                gradeRow
                if let hints {
                    shortcutHintRow(hints)
                }
            }
        }
    }

    /// 顶部：进度 + 结束这一轮。
    private var progressHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "book.closed.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.accent)
            Text("复习中")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(theme.primaryText)
            Text("第 \(min(session.reviewed + 1, session.total)) / \(session.total) 个")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .monospacedDigit()
            progressDots
            Spacer(minLength: 0)
            Text("还剩 \(session.remaining) 个")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .monospacedDigit()
            // ⚠️ 这里原来是「结束」两个灰字，用户实测反馈「进了复习回不去词表了」——
            // 那行字和进度、剩余数挤在一起，看不出是回词表的出口。
            // 换成有分量的胶囊按钮「退出复习」：出口必须一眼能找到。
            VocabularyReviewExitButton(onFinish: onFinish)
        }
    }

    /// 进度点：一个点一张卡（已走完的填成主题色，当前那张是冷紫）。
    ///
    /// 刻意不用 `GeometryReader` 画进度条：离屏渲染只跑一趟布局时，
    /// 依赖 `@State` 回填宽度的条会画成零宽（年度记录卡踩过同一个坑）。
    private var progressDots: some View {
        HStack(spacing: 2) {
            ForEach(0..<session.total, id: \.self) { index in
                Capsule()
                    .fill(dotColor(index))
                    .frame(width: 7, height: 4)
            }
        }
    }

    private func dotColor(_ index: Int) -> Color {
        if index < session.reviewed { return theme.accent }
        if index == session.reviewed { return theme.accentCool }
        return theme.divider
    }

    /// 正面：只有词（+ 音标 + 小喇叭）。
    private func front(_ entry: VocabularyEntry) -> some View {
        let definition = VocabularyDefinitionRule.decodeStored(entry.meaning)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.word)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if showsPhonetic(entry.word), !definition.phonetic.isEmpty {
                    Text(definition.phonetic)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }
                speakButton()
                Spacer(minLength: 0)
                // 词条行右端：去词典查这个词。放在 `Spacer` 之后 = 贴卡片右缘，
                // 与顶部的「退出复习」各占一行，不会互相挤。
                lookupButton()
            }
            if revealed {
                revealHint(entry)
            } else {
                HStack(spacing: 8) {
                    Text("先想一下它的意思")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                    Button(action: onReveal) {
                        HStack(spacing: 4) {
                            Image(systemName: "eye")
                            Text("看释义")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.accent)
                    }
                    .buttonStyle(.plain)
                    .help("翻开看释义（先自己想一遍再翻，效果差很多）")
                }
            }
        }
    }

    /// 词性 + 中文义项一行（翻面后的「第一眼」）。
    ///
    /// 没有释义时**就地**给一个「查释义」按钮：原来这里写的是一句
    /// 「（这个词还没有释义，可以回词表点「查释义」）」—— 用户实测反馈那样得退出去、
    /// 查完再翻回来，把一轮复习的连续性打断了。
    /// 历史数据（只有一整段非结构化释义）不算「没有释义」，照样把那一段摆出来。
    @ViewBuilder
    private func revealHint(_ entry: VocabularyEntry) -> some View {
        let definition = VocabularyDefinitionRule.decodeStored(entry.meaning)
        if !hasReadableMeaning(definition) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("这个词还没有释义")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                    VocabularyReviewDefineButton(isDefining: isDefining, onDefine: onDefine)
                    Spacer(minLength: 0)
                }
                Text("查完直接显示在这里，词表里也会同步 —— 不用退出复习。")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText.opacity(0.85))
            }
        } else if let headline = headline(for: definition) {
            HStack(spacing: 6) {
                if !definition.pos.isEmpty {
                    Text(definition.pos)
                        .font(.system(size: 11, weight: .semibold, design: .rounded).italic())
                        .foregroundStyle(theme.accent)
                }
                Text(headline)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 有没有「读得出意思」的内容：义项 / 老数据的整段原文 / 中文解释，三者皆空才算没有。
    ///
    /// ⚠️ 只看 `senses` 会把两种情况判错：历史数据（只有一整段非结构化释义）会被说成
    /// 「还没有释义」，只有解释没有义项的词也会。判错就会白白让人再花一次模型调用。
    private func hasReadableMeaning(_ definition: VocabularyDefinition) -> Bool {
        !definition.senses.isEmpty || !definition.legacyText.isEmpty || !definition.explanation.isEmpty
    }

    /// 翻面第一行给什么：优先中文义项；结构化不出来的老数据给那一整段原文；
    /// 两者都没有（只有解释）时不硬占一行 —— 下面那块释义里本来就有「解释」。
    private func headline(for definition: VocabularyDefinition) -> String? {
        if !definition.senses.isEmpty { return definition.senses }
        if !definition.legacyText.isEmpty { return definition.legacyText }
        return nil
    }

    // MARK: - 翻面后的完整释义

    @ViewBuilder
    private func revealPanel(_ entry: VocabularyEntry) -> some View {
        let definition = VocabularyDefinitionRule.decodeStored(entry.meaning)
        let rows = definitionRows(definition)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.title)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.accent)
                            .frame(width: 40, alignment: .leading)
                        Text(row.text)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(theme.primaryText.opacity(0.88))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.surfaceAlt.opacity(0.5))
            )
        }
    }

    private struct DefinitionRow {
        var title: String
        var text: String
    }

    /// 释义分区（中文解释、例句、例句翻译、近反义、重点单词）——空的部分直接不出行。
    private func definitionRows(_ definition: VocabularyDefinition) -> [DefinitionRow] {
        var rows: [DefinitionRow] = []
        if !definition.explanation.isEmpty {
            rows.append(DefinitionRow(title: "解释", text: definition.explanation))
        }
        if !definition.example.isEmpty {
            rows.append(DefinitionRow(title: "例句", text: definition.example))
        }
        if !definition.exampleTranslation.isEmpty {
            rows.append(DefinitionRow(title: "译文", text: definition.exampleTranslation))
        }
        let synonyms = definition.synonymTerms.map(\.displayText)
        if !synonyms.isEmpty {
            rows.append(DefinitionRow(title: "近义", text: synonyms.joined(separator: "、")))
        }
        let antonyms = definition.antonymTerms.map(\.displayText)
        if !antonyms.isEmpty {
            rows.append(DefinitionRow(title: "反义", text: antonyms.joined(separator: "、")))
        }
        let keywords = definition.displayKeywordTerms.map(\.displayText)
        if !keywords.isEmpty {
            rows.append(DefinitionRow(title: "重点", text: keywords.joined(separator: "、")))
        }
        return rows
    }

    // MARK: - 朗读检查

    /// 朗读区：读一遍 / 听我的 + 评测结果。
    ///
    /// 这一块复用的是**跟读页同一条链路**（录音 → 原始 ASR → 音素双通道），
    /// 所以卡片上的音素条与跟读页长得一模一样、来源标注口径也一致。
    private func spokenPanel(_ entry: VocabularyEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(action: onToggleRecording) {
                    HStack(spacing: 4) {
                        if isBusy {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .controlSize(.mini)
                                .scaleEffect(0.6)
                        } else {
                            Image(systemName: isRecording ? "stop.circle.fill" : "mic.fill")
                        }
                        Text(isRecording ? "停止并评分" : "读一遍")
                    }
                    .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(isRecording ? Color.red : theme.accentCool)
                .disabled(isBusy)
                .help("读出这个词，系统会把发音逐音素量给你看")

                if hasRecording {
                    Button(action: onReplay) {
                        HStack(spacing: 4) {
                            Image(systemName: "play.circle")
                            Text("听我的")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                    .help("回放刚才读的那一遍，和示范对着听")
                }
                Spacer(minLength: 0)
                Text("朗读分只作参考，等级由你自己定")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText.opacity(0.85))
            }

            if let report {
                spokenResult(report, word: entry.word)
            }
        }
    }

    private func spokenResult(_ report: PronunciationReport, word: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(report.overallPercent) 分")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(scoreColor(report.verdict))
                    .monospacedDigit()
                Text(report.verdict.displayName)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(scoreColor(report.verdict))
                if let label = report.phonemeSource.displayName {
                    Text(label)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(report.phonemeSource == .acoustic ? theme.accent : theme.secondaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(
                                (report.phonemeSource == .acoustic ? theme.accent : theme.secondaryText).opacity(0.14)
                            )
                        )
                        .help(report.phonemeSource.explanation ?? "")
                }
                Spacer(minLength: 0)
            }

            // 系统听成了别的词 —— 这多半是两件事之一：读串了词，或者读得太含糊。
            // 必须原样摆出来，否则用户只看到「分低」却不知道为什么。
            if let recognized, !recognized.isEmpty, !sameWord(recognized, word) {
                Text("系统听成：\(recognized)")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if report.hasPhonemeBreakdown {
                PhonemeBreakdownCard(report: report)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.accent.opacity(0.05))
        )
    }

    /// 识别结果是否就是这个词（只比字母与数字，大小写和标点不算差异）。
    private func sameWord(_ recognized: String, _ word: String) -> Bool {
        func key(_ text: String) -> String {
            text.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        return key(recognized) == key(word)
    }

    private func scoreColor(_ verdict: PronunciationVerdict) -> Color {
        switch verdict {
        case .excellent: .green
        case .good: .green
        case .fair: theme.accent
        case .needsWork: .red
        }
    }

    // MARK: - 判分

    private var gradeRow: some View {
        HStack(spacing: 10) {
            Text("刚才想对了吗")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.secondaryText)
            Spacer(minLength: 0)
            gradeButton(remembered: true, title: "认识", systemImage: "checkmark.circle.fill", color: .green)
            gradeButton(remembered: false, title: "忘了", systemImage: "xmark.circle.fill", color: theme.warning)
        }
    }

    /// 卡面上的按键提示：这一行是复习卡**唯一的**快捷键说明。
    ///
    /// 放在判分按钮下面而不是塞进按钮里：键面可能是 `⌘⇧R` 这么长，
    /// 挤进按钮会把「认识 / 忘了」两个字挤变形。
    private func shortcutHintRow(_ hints: ReviewShortcutHints) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard")
                .font(.system(size: 10))
                .foregroundStyle(theme.secondaryText)
            hintChip(hints.reveal, "翻面")
            hintChip(hints.remembered, "认识")
            hintChip(hints.forgotten, "忘了")
            hintChip(hints.speak, "朗读")
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("键盘快捷键：\(hints.reveal) 翻面，\(hints.remembered) 认识，\(hints.forgotten) 忘了，\(hints.speak) 朗读")
    }

    private func hintChip(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(theme.surfaceAlt)
                )
            Text(label)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(theme.secondaryText)
        }
    }

    private func gradeButton(
        remembered: Bool,
        title: String,
        systemImage: String,
        color: Color
    ) -> some View {
        Button {
            onGrade(remembered)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(color.opacity(0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(gradeHint(remembered))
        // VoiceOver：光读「认识 / 忘了」两个词说明不了后果（会不会当天再见到它、
        // 掌握度往哪边走），把 tooltip 那套话原样报出来 —— 两处同源，不会各自漂。
        .accessibilityLabel(title)
        .accessibilityHint(gradeHint(remembered))
    }

    /// 「认识 / 忘了」的后果说明：tooltip 与 VoiceOver 提示**同一份文案**。
    private func gradeHint(_ remembered: Bool) -> String {
        remembered ? "记住了：掌握度 +1，下次复习间隔变长" : "忘了：掌握度 −1，今天还会再见一面"
    }

    // MARK: - 结算

    private var summaryPanel: some View {
        let summary = session.summary
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.accent)
                Text("这一轮复习完了")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Spacer(minLength: 0)
                Button(action: onFinish) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 9, weight: .bold))
                        Text("回到词表")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(theme.onAccentFill)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(theme.accentFill))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("收起这一轮，回到词表")
            }

            Text(summary.headline)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 18) {
                statTile("复习", "\(summary.total)", theme.primaryText)
                statTile("认识", "\(summary.remembered)", .green)
                statTile("忘了", "\(summary.forgotten)", theme.warning)
                statTile("正确率", "\(summary.accuracyPercent)%", theme.accent)
                if let percent = summary.averagePronunciationPercent {
                    statTile("朗读均分", "\(percent)", theme.accentCool)
                }
                Spacer(minLength: 0)
            }

            if !summary.detail.isEmpty {
                Text(summary.detail)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statTile(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(theme.secondaryText)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
        }
    }

    // MARK: - 小部件

    /// 小喇叭：朗读这个词（与词表卡片上的同一个行为：朗读中再点即停）。
    ///
    /// 首句还在合成时转圈、出声后是声波逐层点亮 —— 与词表卡片、跟读页同一套相位语义，
    /// 不用 ⏸/🔇 之类的静音图标（那看着像「已经静音了」）。
    private func speakButton() -> some View {
        Button(action: onSpeak) {
            ZStack {
                if isPreparingSpeech {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: isSpeaking ? "speaker.wave.3.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 12))
                        // 与 `SpeakButton` 同一个黄：`Color.yellow` 在白天卡片上等于看不见。
                        .foregroundStyle(theme.accent)
                        .symbolEffect(.variableColor.iterative, isActive: isSpeaking)
                }
            }
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isSpeaking ? "停止朗读" : "听这个词怎么读")
    }

    /// 「去词典查这个词」：复习卡右侧的快捷出口。
    ///
    /// 为什么单独给一个按钮，而不是让用户退出复习再自己搜一遍：查一个词的意思
    /// 往往正是**复习到一半突然想确认**的事，退出去就断了这一轮的节奏
    /// （与下面 `revealHint` 里那个「就地查释义」是同一个诉求，只是那个查的是
    /// 当前词的释义写进卡里，这个去的是完整词典页）。
    ///
    /// ⚠️ 用 `accentCool`（冷紫）而不是喇叭那个 `accent`（橘）：同一行两个按钮
    /// 抢同一个颜色，用户分不出哪个是「读」哪个是「查」。冷紫正是主题里
    /// 留给「跳去别处」这类次要动作的那一支。
    private func lookupButton() -> some View {
        Button(action: onLookupInDictionary) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 12))
                .foregroundStyle(theme.accentCool)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("去词典查这个词（复习进度保留，回来接着过）")
        .accessibilityLabel("去词典查这个词")
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .foregroundStyle(theme.accent)
            Text(text)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.primaryText.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onDismissNotice) {
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

    /// 词组 / 短句不显示音标（与词表卡片同一判据）。
    private func showsPhonetic(_ word: String) -> Bool {
        VocabularyService.needsPhonetic(word)
    }
}

// MARK: - 复习卡上的两个出口

/// 「退出复习」：回到词表。
///
/// 抽成独立视图有两个原因：① 出口要**看得见** —— 用户实测反馈「进了复习回不去词表」，
/// 原来那行灰色「结束」藏在进度与剩余数之间，不像出口；② 能单独离屏渲染它自己，
/// 用墨迹尺寸证明画出来的是一个有分量的控件，而不是一行小字。
struct VocabularyReviewExitButton: View {

    @Environment(\.forestTheme) private var theme

    var onFinish: () -> Void = {}

    var body: some View {
        Button(action: onFinish) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .bold))
                Text("退出复习")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(theme.primaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(theme.surfaceAlt.opacity(0.85)))
            .overlay(Capsule().strokeBorder(theme.divider, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("退出复习，回到词表（已经判过的词都记下了）")
    }
}

/// 「查释义」（就地）：复习途中遇到没有释义的词，直接在这里查。
///
/// 与词表里那个「查释义」是**同一条链路**（同一次模型调用、同样落库），
/// 差别只是查完不必退出复习 —— 释义随后由 `AppState.reloadVocabulary` 带回这张卡上。
struct VocabularyReviewDefineButton: View {

    @Environment(\.forestTheme) private var theme

    var isDefining: Bool = false
    var onDefine: () -> Void = {}

    var body: some View {
        Button(action: onDefine) {
            HStack(spacing: 4) {
                if isDefining {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "character.book.closed")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(isDefining ? "正在查…" : "查释义")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(theme.accent.opacity(0.12)))
            .overlay(Capsule().strokeBorder(theme.accent.opacity(0.35), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isDefining)
        .help("就地查一次释义：查完直接显示在这张卡上，词表里也会同步（不用退出复习）")
    }
}
