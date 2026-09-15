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

    var onReveal: () -> Void = {}
    var onGrade: (Bool) -> Void = { _ in }
    var onToggleRecording: () -> Void = {}
    var onReplay: () -> Void = {}
    var onSpeak: () -> Void = {}
    var onFinish: () -> Void = {}
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
            Button(action: onFinish) {
                Text("结束")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
            }
            .buttonStyle(.plain)
            .help("收起复习，随时可以再开一轮")
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
                speakButton(entry.word)
                Spacer(minLength: 0)
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
    @ViewBuilder
    private func revealHint(_ entry: VocabularyEntry) -> some View {
        let definition = VocabularyDefinitionRule.decodeStored(entry.meaning)
        HStack(spacing: 6) {
            if !definition.pos.isEmpty {
                Text(definition.pos)
                    .font(.system(size: 11, weight: .semibold, design: .rounded).italic())
                    .foregroundStyle(theme.accent)
            }
            Text(definition.senses.isEmpty ? "（这个词还没有释义，可以回词表点「查释义」）" : definition.senses)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(definition.senses.isEmpty ? theme.secondaryText : theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
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
            gradeButton(remembered: false, title: "忘了", systemImage: "xmark.circle.fill", color: .orange)
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
        .help(remembered ? "记住了：掌握度 +1，下次复习间隔变长" : "忘了：掌握度 −1，今天还会再见一面")
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
                    Text("完成")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(theme.accent))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            Text(summary.headline)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 18) {
                statTile("复习", "\(summary.total)", theme.primaryText)
                statTile("认识", "\(summary.remembered)", .green)
                statTile("忘了", "\(summary.forgotten)", .orange)
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
    private func speakButton(_ text: String) -> some View {
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
                        .foregroundStyle(Color.yellow)
                        .symbolEffect(.variableColor.iterative, isActive: isSpeaking)
                }
            }
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isSpeaking ? "停止朗读" : "听这个词怎么读")
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
