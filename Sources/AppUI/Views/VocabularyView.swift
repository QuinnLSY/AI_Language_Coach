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
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(theme.surfaceAlt.opacity(0.35))
        // 每次出现都补一次导入（按 word 去重，重复导入是零成本的幂等操作）；
        // 同时保证本次启动的每日推荐已抽好。
        .task {
            await state.openVocabulary()
            await state.loadDailyWordsIfNeeded()
        }
    }

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

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 230), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(state.dailyWords) { word in
                        dailyCard(word)
                    }
                }
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
        }
    }

    private func dailyCard(_ daily: DailyWord) -> some View {
        let definition = state.dailyDefinitions[daily.word]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(daily.word)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                difficultyTag(daily.difficulty)
                phoneticLabel(definition?.phonetic, word: daily.word)
                speakButton(dailySpokenText(daily))
                Spacer(minLength: 0)
                if state.expandedDailyWords.contains(daily.word) {
                    // 释义已展开 → 同一个按钮变成「收起」。
                    dailyToggleButton(daily, title: "收起", systemImage: "chevron.up")
                } else if definition != nil {
                    dailyToggleButton(daily, title: "看释义", systemImage: "character.book.closed")
                } else {
                    dailyToggleButton(daily, title: "查释义", systemImage: "character.book.closed")
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

    /// 每日推荐卡朗读内容：**单词 + 例句**（例句要等「查释义」拿到后才一起读）。
    private func dailySpokenText(_ daily: DailyWord) -> String {
        guard let definition = state.dailyDefinitions[daily.word], !definition.example.isEmpty else {
            return daily.word
        }
        return "\(daily.word). \(definition.example)"
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

                if !definition.example.isEmpty || !definition.exampleTranslation.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        if !definition.example.isEmpty {
                            Text(definition.example)
                                .font(.system(size: 11, design: .rounded).italic())
                                .foregroundStyle(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .lineSpacing(2)
                        }
                        if !definition.exampleTranslation.isEmpty {
                            Text(definition.exampleTranslation)
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(theme.secondaryText.opacity(0.85))
                                .fixedSize(horizontal: false, vertical: true)
                                .lineSpacing(2)
                        }
                    }
                }

                if !definition.synonyms.isEmpty {
                    definitionLine("近义词", definition.synonyms.joined(separator: "、"))
                }
                if !definition.antonyms.isEmpty {
                    definitionLine("反义词", definition.antonyms.joined(separator: "、"))
                }
                if showKeywords, let keywords = definition.keywordsLine {
                    definitionLine("重点单词", keywords)
                }
            }
        }
    }

    private func definitionLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.accent.opacity(0.85))
            Text(value)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.primaryText.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
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
    private func dailyToggleButton(_ daily: DailyWord, title: String, systemImage: String) -> some View {
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
                Text(title)
            }
            .font(.system(size: 10, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.accent)
        .disabled(state.isDefiningDaily.contains(daily.word))
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
        HStack(spacing: 8) {
            TextField("想记的单词或表达，如：How come…", text: Bindable(state).vocabularyDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.divider, lineWidth: 1)
                )
                .onSubmit { Task { await state.addVocabularyWord() } }
            Button {
                Task { await state.addVocabularyWord() }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(state.vocabularyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            .help("加入词表")
        }
    }

    // MARK: - 词条卡片

    private func entryCard(_ entry: VocabularyEntry) -> some View {
        let collapsed = state.collapsedVocabularyDefinitions.contains(entry.id)
        let definition = VocabularyDefinitionRule.decodeStored(entry.meaning)
        // 小喇叭朗读内容：单词 + 例句（有例句就连起来读，一个按钮读完卡片所有英文）。
        let spokenText = definition.example.isEmpty
            ? entry.word
            : "\(entry.word). \(definition.example)"
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.word)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                phoneticLabel(definition.phonetic, word: entry.word)
                speakButton(spokenText)
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
                // 删除（悬停才显眼，平时低调）
                Button {
                    Task { await state.removeVocabulary(id: entry.id) }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.secondaryText.opacity(0.7))
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
