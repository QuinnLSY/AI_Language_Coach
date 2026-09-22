import AIDomain
import SwiftUI

/// 听力页（#308 #309）。
///
/// 单独成页而不是塞在跟读页里：这条练习练的是「只听不看」，与跟读页
/// 「把句子摊在最显眼处让你跟着念」是互相打架的两套界面。以前它寄在跟读页上
/// （`isListeningDrill` 接管正文区），结果是两种形式都只能各让一步 ——
/// 跟读页多一个模式分叉，听力也只能有「精听默写」一种形式。
///
/// 现在三种形式共用**一批句子**（今天跟读的那批）、一条播放链路、一本当天账本，
/// 差别只在「问什么」：整句默写 / 只抓关键词 / 四个释义挑一个。
/// 页面上没有任何句子字面量，素材全部来自 `AppState.listeningRound`。
public struct ListeningView: View {

    @Environment(\.forestTheme) private var theme
    let state: AppState

    public init(state: AppState) { self.state = state }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                    if let notice = state.listeningNotice {
                        noticeBanner(notice)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(theme.surfaceAlt.opacity(0.35))
        .task { await state.openListening() }
    }

    // MARK: - 正文（结算 → 练习 → 空态）

    /// 正在练的那一句（没有 = 该给结算卡或空态）。
    ///
    /// 页头与正文都读它：**有练习卡的时候，页头就不再重复「这一形式练什么」** ——
    /// 卡片自己会说一遍，页头再说一遍就是同一句话在屏幕上出现两次。
    private var practiceDrill: ShadowingDrill? {
        guard state.listeningSummary == nil, state.isListeningDrill else { return nil }
        return state.currentListeningDrill
    }

    @ViewBuilder
    private var content: some View {
        if let summary = state.listeningSummary {
            ListeningSummaryCard(
                summary: summary
            ) {
                Task { await state.collectListeningMissedWords() }
            } onRestart: {
                Task { await state.startListeningDrill() }
            } onClose: {
                state.exitListeningDrill()
            }
        } else if let drill = practiceDrill {
            modeSwitch
            practiceCard(drill)
        } else {
            emptyHint
        }
    }

    private var modeSwitch: some View {
        ListeningModeSwitch(current: state.listeningMode) { mode in
            state.switchListeningMode(mode)
        }
    }

    /// 页头那枚小标（与跟读页同一套写法：胶囊 + 悬浮解释）。
    private func badge(_ text: String, color: Color, help: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
            .help(help)
    }

    /// 页头第二行：说的是一整页的事（**三种形式共用一批句子**），
    /// 不是「现在选中了哪一种」—— 那个由切换条自己高亮、由卡片自己报名字。
    private var headerSubtitle: String {
        "同一批句子，三种问法：默写整句 / 只抓关键词 / 挑释义 —— 换问法不会丢进度。"
    }

    @ViewBuilder
    private func practiceCard(_ drill: ShadowingDrill) -> some View {
        let isLast = state.listeningIndex + 1 >= state.listeningRound.count
        switch state.listeningMode {
        case .dictation, .keyword:
            ListeningDrillCard(
                mode: state.listeningMode,
                index: state.listeningIndex,
                total: state.listeningRound.count,
                attempt: state.listeningResult,
                keyword: state.listeningKeywordResult,
                playCount: state.listeningPlayCount,
                isPlaying: state.listeningIsPlaying,
                isSlow: state.listeningSlowPlayback,
                isLast: isLast,
                typed: draftBinding
            ) {
                Task { await togglePlayback() }
            } onToggleSlow: {
                state.toggleListeningSlowPlayback()
            } onSubmit: {
                if state.listeningMode == .keyword {
                    state.submitListeningKeywords()
                } else {
                    state.submitListeningDraft()
                }
            } onAdvance: {
                state.advanceListening()
            } onCancel: {
                Task {
                    await state.stopListeningAudio()
                    state.exitListeningDrill()
                }
            }
            // ⚠️ 卡里读不到 `drill.text` 的任何界面元素 —— 传进去的只有句数、遍数与状态；
            // 原文由 `ListeningAttempt` / `KeywordCapture` 在提交后带出来。
            .id("\(state.listeningMode.rawValue)-\(drill.id)")
        case .meaning:
            if let question = state.listeningMeaningQuestion {
                ListeningMeaningCard(
                    index: state.listeningIndex,
                    total: state.listeningRound.count,
                    question: question,
                    selection: state.listeningMeaningSelection,
                    reference: drill.text,
                    playCount: state.listeningPlayCount,
                    isPlaying: state.listeningIsPlaying,
                    isSlow: state.listeningSlowPlayback,
                    isLast: isLast
                ) {
                    Task { await togglePlayback() }
                } onToggleSlow: {
                    state.toggleListeningSlowPlayback()
                } onChoose: { index in
                    state.chooseListeningMeaning(index)
                } onAdvance: {
                    state.advanceListening()
                } onCancel: {
                    Task {
                        await state.stopListeningAudio()
                        state.exitListeningDrill()
                    }
                }
                .id(question.drillID)
            } else {
                // 走在「找下一句能出题的句子」那条路上才会短暂看到它。
                Text("这一句出不了选择题（缺释义或选项不够），正在找下一句…")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    /// 两种写作答的形式共用一份草稿 —— 精听写整句、关键词写词，
    /// 换形式时草稿已经由 `switchListeningMode` 清过了。
    private var draftBinding: Binding<String> {
        Binding(
            get: {
                state.listeningMode == .keyword
                    ? state.listeningKeywordDraft
                    : state.listeningDraft
            },
            set: { value in
                if state.listeningMode == .keyword {
                    state.listeningKeywordDraft = value
                } else {
                    state.listeningDraft = value
                }
            }
        )
    }

    private func togglePlayback() async {
        if state.listeningIsPlaying {
            await state.stopListeningAudio()
        } else {
            await state.playListeningPrompt()
        }
    }

    // MARK: - 空态

    /// ⚠️ 这里有两种「没有正在练的句子」，说错话会让人以为素材丢了：
    /// ① 素材还没拿到（跟读页也还没拿到今天的句子）→ 指路去跟读页；
    /// ② 素材就在手上，只是刚点过「先不练了」/结算卡收尾了 → 直接给一颗「再开一轮」。
    private var emptyHint: some View {
        let hasMaterial = !state.shadowingDrills.isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "ear.badge.waveform")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.accent)
                Text(hasMaterial ? "这一轮结束了" : "还没有可练的句子")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
            }
            Text(hasMaterial
                ? "今天的素材已经就位（\(state.shadowingDrills.count) 句）。点下面的按钮就能再开一轮，三种形式随便挑。"
                : "听力的素材与跟读是同一批（今天那几个情景里的句子）。先去跟读页拿到今日素材，回来就能开始。")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                if hasMaterial {
                    Task { await state.startListeningDrill() }
                } else {
                    Task { await state.go(to: .shadowing) }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: hasMaterial ? "play.fill" : "waveform.badge.mic")
                        .font(.system(size: 11, weight: .semibold))
                    Text(hasMaterial ? "再开一轮" : "去跟读页")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(theme.accentCool)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(
                    Capsule(style: .continuous)
                        .strokeBorder(theme.accentCool.opacity(0.5), lineWidth: 1)
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(hasMaterial ? "重新开一轮（今天的成绩已经记在账本里）" : "听力与跟读共用今天的素材")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.surface.opacity(0.7))
        )
    }

    // MARK: - 顶栏（与其他页的 64pt 对齐）

    private var header: some View {
        HStack(spacing: 12) {
            CuteAnimalView(
                kind: state.studentAnimalKind,
                isSleeping: theme.isNight,
                size: 40,
                accessory: .student
            )
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("听力")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    // 这枚小标说的是**素材是哪来的**（与跟读页同一套说法），
                    // ⚠️ 不是「现在练哪种形式」：形式由下面的切换条与卡片标题说，
                    // 页头再说一遍就是同一句话在屏幕上出现三次。
                    if state.shadowingIsDailyGenerated {
                        badge(
                            "今日 · \(state.shadowingDrills.count) 句", color: theme.accent,
                            help: "与跟读页同一批句子：每天按不同情景现生成，同一天内不会变"
                        )
                    } else {
                        badge(
                            "内置素材", color: theme.secondaryText,
                            help: "今天现生成的句子没拿到，用的是安装包里的内置素材"
                        )
                    }
                }
                // ⚠️ 这里**不写**「这一形式练什么」：有练习卡时卡片自己说，
                // 没有卡时（空态 / 结算）那两张卡也都把话说完了。
                Text(headerSubtitle)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 0)
            if state.listeningLog.resolvedCount > 0 {
                Text(todayText)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .monospacedDigit()
                    .help("今天练过的句数（三种形式记在同一本账上）")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
    }

    private var todayText: String {
        let done = state.listeningLog.resolvedCount
        guard let average = state.listeningLog.averageAccuracy else { return "今天练了 \(done) 句" }
        return "今天练了 \(done) 句 · 平均 \(Int((average * 100).rounded()))%"
    }

    // MARK: - 提示条

    /// ⚠️ 文案与动作**绑成一个值**：拆成两个属性一定会出现
    /// 「上一条失败留下的『重试』挂在下一条不相干的文案上」。
    private func noticeBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(theme.accent)
            Text(text)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                state.dismissListeningNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("知道了")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.accent.opacity(0.12))
        )
    }
}
