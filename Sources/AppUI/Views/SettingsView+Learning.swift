import AIDomain
import AppCore
import SwiftUI

// #662 自 SettingsView.swift 拆出（2026-10-24）：原文件 3227 行、单结构体 22 个 MARK 段，按主题分文件。
// 同模块移动，语义与拆分前完全一致；跨文件引用的成员已从 private 放宽到 internal
// （模块内可见，跨模块零影响，public API 不变）。

extension SettingsView {
    // MARK: - 语言候选（学习语言 / 母语的唯一下拉数据源）

    /// 学习语言下拉的选项。
    ///
    /// ⚠️ 走 `includingCurrent` 而不是直接用 `LanguageOptions.learning`：
    /// 老配置里可能存着清单外的标识，不补进候选就会显示「未选择」，
    /// 用户看着像设置丢了，一碰下拉还会被无声改掉。
    private var learningLanguageOptions: [ForestSelectOption<String>] {
        LanguageOptions.includingCurrent(state.learningLanguage, in: LanguageOptions.learning)
            .map { ForestSelectOption(value: $0.tag, title: $0.title) }
    }

    /// 母语下拉的选项，规则同学习语言。
    private var nativeLanguageOptions: [ForestSelectOption<String>] {
        LanguageOptions.includingCurrent(state.nativeLanguage, in: LanguageOptions.native)
            .map { ForestSelectOption(value: $0.tag, title: $0.title) }
    }

    /// 两个下拉共用同一个宽度：同排控件宽度不一致会显得没对齐。
    ///
    /// ⚠️ 宽度必须**量**出来（`widthFitting`），不能凭感觉写数字 ——
    /// 写小的表现是值被截成省略号，而几何空档上看不出来（2026-09-14 的「语速不显示」就是这样来的）。
    private var languageSelectWidth: CGFloat {
        ForestSelect<String>.Metrics.regular.widthFitting(
            (learningLanguageOptions + nativeLanguageOptions).map(\.title)
        )
    }

    /// 老师性格下拉的宽度：同样**量**出来（「温和鼓励」是四个字，拍数字最容易把它截掉）。
    private var personaSelectWidth: CGFloat {
        ForestSelect<TeacherPersona>.Metrics.regular.widthFitting(
            TeacherPersona.allCases.map(\.displayName)
        )
    }

    // MARK: - 学习

    var learningCard: some View {
        card(title: "学习设置", systemImage: "leaf.fill") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ForestSelect(
                        "练习模式",
                        icon: "leaf",
                        selection: Binding(
                            get: { state.productPracticeMode },
                            set: { mode in Task { await state.setPracticeMode(mode) } }
                        ),
                        options: PracticeMode.allCases.map {
                            ForestSelectOption(value: $0, title: $0.displayName)
                        },
                        width: 170
                    )
                    Spacer()
                }

                ForestSelect(
                    "学习语言",
                    icon: "globe",
                    selection: Binding(
                        get: { state.learningLanguage },
                        set: { value in Task { await state.setLearningLanguage(value) } }
                    ),
                    options: learningLanguageOptions,
                    width: languageSelectWidth,
                    help: "当前版本只支持英语；变体决定语音识别与发音评测用哪一套英语模型。"
                )

                ForestSelect(
                    "母        语",
                    icon: "character.bubble",
                    selection: Binding(
                        get: { state.nativeLanguage },
                        set: { value in Task { await state.setNativeLanguage(value) } }
                    ),
                    options: nativeLanguageOptions,
                    width: languageSelectWidth,
                    help: "释义、翻译与讲解使用的语言。"
                )

                ForestSelect(
                    "老师性格",
                    icon: "person.wave.2",
                    selection: Binding(
                        get: { state.teacherPersona },
                        set: { persona in Task { await state.setTeacherPersona(persona) } }
                    ),
                    options: TeacherPersona.allCases.map {
                        ForestSelectOption(value: $0, title: $0.displayName)
                    },
                    width: personaSelectWidth,
                    help: state.teacherPersona.summary
                )

                // 教师音色原来在这里还有一个手填框，与上方「模型管理中心 → 老师怎么读」里的下拉
                // 指向同一个值、却**绕过了** `setVoice`（不会停用克隆音色）——
                // 一个设置两处入口、行为还不一致。这里只留一条指路，避免两处各说各的。
                Text("教师音色已并入上方「模型管理中心 → 老师怎么读」，在那里切换会立即试听。")
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .lineSpacing(3)
            }
            .appFont(13, design: .rounded)
        }
    }

    // MARK: - 提醒我练习（#226 本地定时通知）

    var practiceReminderCard: some View {
        card(title: "提醒我练习", systemImage: "bell.badge.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("每天定时提醒我练一会儿", isOn: Binding(
                    get: { state.practiceReminderEnabled },
                    set: { enabled in Task { await state.setPracticeReminderEnabled(enabled) } }
                ))
                .appFont(13, design: .rounded)

                if state.practiceReminderEnabled {
                    HStack(spacing: 10) {
                        Text("提醒时刻")
                            .appFont(13, design: .rounded)
                            .foregroundStyle(theme.primaryText)

                        // 时刻用自绘步进（系统 DatePicker 样式与整体口径不符，且命中区退化）。
                        HStack(spacing: 4) {
                            reminderButton(systemImage: "minus") {
                                let total = state.practiceReminderHour * 60 + state.practiceReminderMinute
                                let shifted = (total - 30 + 24 * 60) % (24 * 60)
                                Task {
                                    await state.setPracticeReminderTime(hour: shifted / 60, minute: shifted % 60)
                                }
                            }
                            Text(String(format: "%02d:%02d", state.practiceReminderHour, state.practiceReminderMinute))
                                .appFont(13, weight: .semibold, design: .rounded)
                                .foregroundStyle(theme.primaryText)
                                .monospacedDigit()
                                .frame(width: 46)
                            reminderButton(systemImage: "plus") {
                                let total = state.practiceReminderHour * 60 + state.practiceReminderMinute
                                let shifted = (total + 30) % (24 * 60)
                                Task {
                                    await state.setPracticeReminderTime(hour: shifted / 60, minute: shifted % 60)
                                }
                            }
                        }
                        Text("每 30 分钟一档")
                            .appFont(10, design: .rounded)
                            .foregroundStyle(theme.secondaryText)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 20)
                }

                if state.reminderAuthorizationDenied {
                    Text("通知权限被系统拒绝了：请到「系统设置 → 通知 → 语林」里允许通知，之后开关一次提醒即可生效。")
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.warning)
                        .lineSpacing(3)
                } else if state.practiceReminderEnabled {
                    Text(TodayPanel.practiceReminderCopy(streakDays: 0).body)
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                        .lineSpacing(3)
                } else {
                    Text("到点小鹅子会来敲门 🐧 —— 应用没开着也能收到（走系统通知）。点击通知直接回到今天的作业。")
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                        .lineSpacing(3)
                }
            }
        }
    }

    private func reminderButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // ⚠️ 必须是 Image(systemName:) —— 写成 Image(systemImage) 会匹配到
            // Image(_ name:)（按资源名找图片），"minus"/"plus" 不是资源名 → 图标空白。
            Image(systemName: systemImage)
                .appFont(9, weight: .bold)
                .foregroundStyle(theme.primaryText)
                .frame(width: 20, height: 20)
                .background(Circle().fill(theme.hover))
        }
        .buttonStyle(.appPressable)
    }

    // MARK: - 词汇本（每日推荐学习进度）

    var vocabularyCard: some View {
        card(title: "词汇本", systemImage: "text.book.closed.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Text("每日推荐按「简单 → 中等 → 困难 → 词组」的节奏出词。某个等级全部认识后该等级不再出现，空缺由还没学完的最低等级补上。")
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                // 词库规模：**去重后**的词数（跨词典同名词只算一个），与词典页页头同一个数。
                // ⚠️ 不是「学员自己收录了几词」——那个在下面那行「本机已收录」里。
                if state.dictionaryUniqueWordCount > 0 {
                    Text("词库共 \(state.dictionaryUniqueWordCount) 词 · \(state.dictionaryBooks.count) 本")
                        .appFont(12, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.primaryText)
                        .monospacedDigit()
                }

                Button {
                    showVocabularyResetConfirm = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("词汇本每日推荐学习进度重置")
                    }
                    .appFont(12, weight: .semibold, design: .rounded)
                    .foregroundStyle(Color.red)
                    .padding(.horizontal, 12)
                    .appPadding(.vertical, 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.red.opacity(0.8), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.appPressable)
                .help("清空「认识」记录，每日推荐重新从简单档开始")

                Text(vocabularyResetSummary)
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .monospacedDigit()
            }
            // 卡片一出现就把两个数刷新到最新（幂等、便宜）：
            // 词库规模只在词典页被读过，本机收录数只在词汇本页被读过 ——
            // 这一轮启动若那两个页面都没进过，卡片会少一行 / 显示旧值。
            .task {
                await state.reloadDictionaryLibrary()
                await state.reloadVocabulary()
            }
        }
    }

    /// 「上次重置时间 + 上次已学词数」+「本机已收录（去重）词数」。
    ///
    /// ⚠️ 三个数各是各的，文案必须写清是谁的，否则一眼看去像自相矛盾：
    /// - 卡片上「词库共 N 词」= **去重后的词典规模**（`dictionaryUniqueWordCount`，与词典页同源，含全部可见词典）；
    /// - 本行分母 = `dailyBankTotal` = **每日推荐词源**去重后的词数 —— 只算被勾成词源的那几本，
    ///   勾得比可见词典少时它就是个小一点的数，所以这里必须标「推荐词源」；
    /// - 「本机已收录 M 词」= `vocabularyUniqueWordCount`，学员自己收进词汇本的词（按词去重）。
    private var vocabularyResetSummary: String {
        let collected = state.vocabularyUniqueWordCount
        let collectedText = collected > 0 ? "本机已收录 \(collected) 词" : "还没有收录单词"
        let total = state.dailyBankTotal
        guard let date = state.dailyProgressResetAt else {
            return "还没有重置过 · \(collectedText)"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let learned = total > 0
            ? "上次已学 \(state.dailyProgressResetLearned) / \(total) 词（推荐词源）"
            : "上次已学 \(state.dailyProgressResetLearned) 词"
        return "上次重置：\(formatter.string(from: date)) · \(learned) · \(collectedText)"
    }

    // MARK: - 情景对话（闯关进度）

    /// 情景对话卡：当前闯关概况 + 「重置闯关进度」入口。
    ///
    /// 为什么有重置入口：闯关进度随数据库永久保存，练歪了 / 想从头跟一遍课程时
    /// 没有任何出口能回到起点。与词汇本的重置同一口径 —— 红色描边按钮 + 确认弹窗。
    var scenarioCard: some View {
        card(title: "情景对话", systemImage: "theatermasks.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Text("情景任务与大树关卡记录你的闯关进度：每练完一轮情景任务收一颗星，星星攒够解锁下一关。")
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if state.progress.totalStars > 0 {
                    Text("已收集 \(state.progress.totalStars) 颗星 · 爬升 \(Int(state.progress.climbFraction * 100))%")
                        .appFont(12, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.primaryText)
                        .monospacedDigit()
                }

                Button {
                    showQuestResetConfirm = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("重置闯关进度（全新起点）")
                    }
                    .appFont(12, weight: .semibold, design: .rounded)
                    .foregroundStyle(Color.red)
                    .padding(.horizontal, 12)
                    .appPadding(.vertical, 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.red.opacity(0.8), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.appPressable)
                .disabled(state.progress.totalStars == 0)
                .opacity(state.progress.totalStars == 0 ? 0.45 : 1)
                .help("所有关卡归零、只开第一关，情景任务的完成记录一并清空（词汇本与对话记录不动）")
            }
        }
    }
}
