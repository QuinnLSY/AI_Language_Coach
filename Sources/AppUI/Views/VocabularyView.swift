import AIDomain
import AIServices
import AppCore
import SwiftUI

/// 词汇本页（Vocabulary，第 24 步）。
///
/// 数据流：复盘 new_words / 手动添加 → `VocabularyService` → SQLite；
/// 复习调度与判分在 `AIDomain.ReviewScheduler`（纯函数），这里只做「展示 + 触发」。
/// 顶部还有「每日推荐」板块：每次启动随机 10 个雅思词（不落库、不自动进复习）。
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
                    Text("雅思标准 · 3 简单 / 5 中等 / 2 困难")
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
                    .help("重新随机推荐 10 个不同的单词")
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(daily.word)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                difficultyTag(daily.difficulty)
                Spacer(minLength: 0)
                if state.expandedDailyWords.contains(daily.word) {
                    // 释义已展开 → 同一个按钮变成「收起」。
                    dailyToggleButton(daily, title: "收起", systemImage: "chevron.up")
                } else if state.dailyDefinitions[daily.word] != nil {
                    dailyToggleButton(daily, title: "看释义", systemImage: "character.book.closed")
                } else {
                    dailyToggleButton(daily, title: "查释义", systemImage: "character.book.closed")
                }
            }

            if let definition = state.dailyDefinitions[daily.word],
               state.expandedDailyWords.contains(daily.word) {
                dailyDefinitionBody(definition)
            }

            HStack(spacing: 6) {
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

    private func dailyDefinitionBody(_ definition: DailyDefinition) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if !definition.pos.isEmpty {
                    Text(definition.pos)
                        .font(.system(size: 10, weight: .semibold, design: .rounded).italic())
                        .foregroundStyle(theme.accent)
                }
                Text(definition.meaning)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(theme.primaryText.opacity(0.92))
            }
            .fixedSize(horizontal: false, vertical: true)
            if !definition.example.isEmpty {
                Text(definition.example)
                    .font(.system(size: 11, design: .rounded).italic())
                    .foregroundStyle(theme.secondaryText)
                if !definition.exampleTranslation.isEmpty {
                    Text(definition.exampleTranslation)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.secondaryText.opacity(0.85))
                }
            }
            if !definition.synonyms.isEmpty {
                dailyLine("近义词", definition.synonyms.joined(separator: "、"))
            }
            if !definition.antonyms.isEmpty {
                dailyLine("反义词", definition.antonyms.joined(separator: "、"))
            }
        }
    }

    private func dailyLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.accent.opacity(0.85))
            Text(value)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.primaryText.opacity(0.85))
        }
    }

    private func difficultyTag(_ difficulty: Int) -> some View {
        let color: Color = difficulty == 1 ? .green : (difficulty == 2 ? .orange : .red)
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
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.word)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
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

            // 「查释义 / 收起释义」是同一个按钮：没释义 → 请求；有释义 → 切换展开。
            if !collapsed {
                if entry.meaning.isEmpty {
                    Text("还没有释义")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(theme.secondaryText.opacity(0.7))
                } else {
                    Text(entry.meaning)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(theme.primaryText.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !entry.example.isEmpty {
                    Text(entry.example)
                        .font(.system(size: 11, design: .rounded).italic())
                        .foregroundStyle(theme.secondaryText)
                }
            }

            HStack(spacing: 10) {
                masteryBar(entry.mastery)
                Text("复习 \(entry.reviewCount) 次")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .monospacedDigit()
                Spacer(minLength: 0)
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
