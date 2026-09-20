import AIDomain
import SwiftUI

/// 跟读页（Shadowing，第 22 步）。
///
/// 一句一练：**听示范 → 跟读 → 听我的 → 看逐词反馈**。
/// 素材来自 `Resources/Shadowing/*.json`，页面里没有任何句子字面量。
/// 这里只做「展示 + 触发」，录音 / 识别 / 评测 / 落库全在 `ShadowingService`。
public struct ShadowingView: View {

    @Environment(\.forestTheme) private var theme
    let state: AppState

    public init(state: AppState) { self.state = state }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if state.hasShadowingMaterial {
                        modeSwitch
                        progressRow
                        // 两种粒度各有自己的「参考文本」与「结果卡」，但不共用一份：
                        // 段落要多渲染 N 行句子，混在一张卡里会让一句模式凭空长出空行。
                        if state.shadowingMode == .passage {
                            passageCard
                            actionRow
                            if let result = state.shadowingPassageResult {
                                passageResultCard(result)
                                if let pronunciation = state.shadowingPassagePronunciation {
                                    pronunciationCard(pronunciation)
                                }
                            }
                        } else {
                            drillCard
                            actionRow
                            if let comparison = state.shadowingComparison {
                                resultCard(comparison)
                                if let pronunciation = state.shadowingPronunciation {
                                    pronunciationCard(pronunciation)
                                }
                            }
                        }
                    } else {
                        emptyHint
                    }
                    if let notice = state.shadowingNotice {
                        noticeBanner(notice)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(theme.surfaceAlt.opacity(0.35))
        .task { await state.loadShadowing() }
    }

    // MARK: - 顶栏（与其他两栏 64pt 对齐）

    private var header: some View {
        HStack(spacing: 12) {
            CuteAnimalView(kind: state.studentAnimalKind, isSleeping: theme.isNight, size: 40, accessory: .student)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("跟读")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    if state.isShadowingLoading {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small)
                            Text("正在生成今天的句子…")
                                .font(.system(size: 10, design: .rounded))
                        }
                        .foregroundStyle(theme.secondaryText)
                    } else if state.shadowingIsDailyGenerated {
                        Text("今日 · \(state.shadowingDrills.count) 句")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(theme.accent.opacity(0.14)))
                            .help("每天按不同情景现生成，同一天内不会变")
                    } else {
                        Text("内置素材")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(theme.hover))
                            .help("今天现生成的句子没拿到，用的是安装包里的内置素材")
                    }
                }
                Text("跟着老师的节奏说一遍；句子里的词可以划过去单独看释义")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer(minLength: 0)
            if state.shadowingStats.attempts > 0 {
                HStack(spacing: 4) {
                    Text("练了 \(state.shadowingStats.attempts) 次 · 最佳 \(percent(state.shadowingStats.bestAccuracy))")
                    if let best = state.shadowingStats.bestPronunciation {
                        Text("· 发音最佳 \(Int(best.rounded())) 分")
                    }
                }
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .monospacedDigit()
            }
            // 换一批：今天的句子练腻了 / 觉得不合适，可以重新生成（覆盖当天缓存）。
            Button {
                Task { await state.loadTodayShadowingDrills(regenerate: true) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "wand.and.stars")
                    Text(state.isShadowingLoading ? "生成中…" : "换一批")
                }
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.accentCool)
            }
            .buttonStyle(.plain)
            .disabled(state.isShadowingLoading)
            .help("忽略今天的缓存，按情景重新生成 20 句")
            Button {
                Task { await state.loadShadowing() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("刷新统计")
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
    }

    // MARK: - 粒度切换（一句一练 / 整段跟读）

    /// ⚠️ 不用系统 `Picker`、也不用 SwiftUI `Menu`：macOS 不渲染 Menu 的 label，
    /// 且命中区会退化（项目里已为此留过记录）。两个**兄弟按钮** + 自绘边框最稳。
    private var modeSwitch: some View {
        HStack(spacing: 8) {
            ForEach(ShadowingMode.allCases) { mode in
                let isOn = state.shadowingMode == mode
                Button {
                    state.setShadowingMode(mode)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: mode.symbol).font(.system(size: 11, weight: .semibold))
                        Text(mode.displayName)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(isOn ? theme.accent : theme.secondaryText)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(isOn ? theme.accent.opacity(0.14) : theme.surfaceAlt.opacity(0.8))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(isOn ? theme.accent : theme.secondaryText.opacity(0.45), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(mode.help)
                .accessibilityLabel(mode.displayName)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 进度 / 主题 / 难度

    private var progressRow: some View {
        HStack(spacing: 8) {
            if state.shadowingMode == .passage {
                let passages = state.shadowingPassages
                Text("第 \(state.shadowingPassageIndex + 1) / \(passages.count) 段")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .monospacedDigit()
                if let passage = state.currentShadowingPassage {
                    if !passage.title.isEmpty { chip(passage.title, color: theme.accent) }
                    chip("\(passage.drills.count) 句", color: theme.accentCool)
                    difficultyDots(passage.difficulty)
                }
                Spacer(minLength: 0)
                Button {
                    state.nextShadowingPassage()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right.circle.fill")
                        Text("换一段")
                    }
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(theme.accent)
                }
                .buttonStyle(.plain)
            } else {
                Text("第 \(state.shadowingIndex + 1) / \(state.shadowingDrills.count) 句")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .monospacedDigit()

                if let drill = state.currentShadowingDrill, !drill.topic.isEmpty {
                    chip(drill.topic, color: theme.accent)
                }
                if let drill = state.currentShadowingDrill {
                    difficultyDots(drill.difficulty)
                }

                Spacer(minLength: 0)

                Button {
                    state.nextShadowingDrill()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right.circle.fill")
                        Text("换一句")
                    }
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func difficultyDots(_ value: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                Circle()
                    .fill(index < value ? theme.accent : theme.divider)
                    .frame(width: 5, height: 5)
            }
        }
        .help("难度 \(value)/5")
    }

    // MARK: - 参考句

    private var drillCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let drill = state.currentShadowingDrill {
                // 参考句可划词：跟读时遇到不认识的词，不用离开这一页就能看释义。
                LookupText(
                    text: drill.text,
                    fontSize: 22,
                    weight: .semibold,
                    color: theme.primaryText,
                    context: state.wordLookupContext
                )

                if !drill.translation.isEmpty {
                    Text(drill.translation)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !drill.focus.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "lightbulb.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.accent)
                        Text(drill.focus)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.surface)
                .shadow(color: theme.shadow, radius: 10, x: 0, y: 4)
        )
    }

    // MARK: - 整段参考（#232）

    /// 段落模式下把**整段**都摊开：跟读前看得见全貌，才知道句与句之间该怎么接。
    private var passageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let passage = state.currentShadowingPassage {
                ForEach(Array(passage.sentences.enumerated()), id: \.offset) { index, sentence in
                    HStack(alignment: .center, spacing: 8) {
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                            .monospacedDigit()
                            .frame(width: 14, alignment: .trailing)
                        // 整段里遇到不认识的词一样能划过去看释义。
                        LookupText(
                            text: sentence,
                            fontSize: 18,
                            weight: .semibold,
                            color: theme.primaryText,
                            context: state.wordLookupContext
                        )
                        Spacer(minLength: 0)
                    }
                }

                if !passage.translation.isEmpty {
                    Text(passage.translation)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !passage.focus.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "lightbulb.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.accent)
                        Text(passage.focus)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.surface)
                .shadow(color: theme.shadow, radius: 10, x: 0, y: 4)
        )
    }

    // MARK: - 三个动作：听示范 / 跟读 / 听我的

    private var actionRow: some View {
        HStack(spacing: 10) {
            // 正在放声音时这颗按钮变成「停止」：整段示范要读十几秒，等它读完才能跟读，
            // 没有停止就只有「把音量关掉」这一条路（`stopShadowingAudio` 原本无人调用）。
            actionButton(
                icon: state.isShadowingPlaying ? "stop.circle.fill" : "play.circle.fill",
                title: state.isShadowingPlaying ? "停止" : "听示范",
                tint: theme.accent,
                filled: false,
                isBusy: state.isShadowingBusy && !state.isShadowingPlaying && !state.isShadowingRecording
            ) {
                if state.isShadowingPlaying {
                    Task { await state.stopShadowingAudio() }
                } else {
                    Task { await state.playShadowingExample() }
                }
            }

            actionButton(
                icon: state.isShadowingRecording ? "stop.circle.fill" : "mic.circle.fill",
                title: state.isShadowingRecording ? "停止并评分" : "开始跟读",
                tint: state.isShadowingRecording ? .red : theme.accentAlt,
                filled: state.isShadowingRecording,
                isBusy: false
            ) {
                Task { await state.toggleShadowingRecording() }
            }

            actionButton(
                icon: state.isShadowingPlaying ? "stop.circle.fill" : "waveform.circle.fill",
                title: state.isShadowingPlaying ? "停止" : "听我的",
                tint: theme.accent,
                filled: false,
                isBusy: state.isShadowingBusy && !state.isShadowingPlaying && !state.isShadowingRecording
            ) {
                if state.isShadowingPlaying {
                    Task { await state.stopShadowingAudio() }
                } else {
                    Task { await state.replayShadowingRecording() }
                }
            }

            Spacer(minLength: 0)
        }
    }

    private func actionButton(
        icon: String,
        title: String,
        tint: Color,
        filled: Bool,
        isBusy: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(filled ? Color.white : tint)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(filled ? tint.opacity(0.92) : tint.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(tint.opacity(filled ? 0 : 0.35), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // VoiceOver：三颗按钮的可见内容全是图标，`title` 才是它们此刻**实际**要做的事
        // （「开始跟读」/「停止并评分」/「听示范」），必须显式读出来。
        .accessibilityLabel(title)
    }

    // MARK: - 评测结果

    private func resultCard(_ comparison: ShadowingComparison) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Text("\(comparison.accuracyPercent)%")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(verdictColor(comparison.verdict))
                    .monospacedDigit()

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Image(systemName: comparison.verdict.symbol)
                            .font(.system(size: 11))
                        Text(comparison.verdict.displayName)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(verdictColor(comparison.verdict))

                    Text("跟上 \(comparison.matched) / \(comparison.referenceCount) 个词")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }

            accuracyBar(accuracy: comparison.accuracy, verdict: comparison.verdict)

            // 逐词对齐：绿=跟上，红=漏了，橙=多说了
            FlowRow(spacing: 6, lineSpacing: 6) {
                ForEach(Array(comparison.tokens.enumerated()), id: \.offset) { _, token in
                    tokenChip(token)
                }
            }

            Text(comparison.hint)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "ear.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.secondaryText)
                Text("我听到的：\(comparison.recognizedText)")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.surface)
                .shadow(color: theme.shadow, radius: 10, x: 0, y: 4)
        )
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// 一句一练与整段跟读共用这根条（两种粒度都要画「进度 vs 阈值」）。
    private func accuracyBar(accuracy: Double, verdict: ShadowingVerdict) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.divider)
                Capsule()
                    .fill(verdictColor(verdict))
                    .frame(width: max(6, proxy.size.width * accuracy))
            }
        }
        .frame(height: 8)
    }

    // MARK: - 整段评测结果（#232）

    /// 整段结果：**整段总分在上，逐句明细在下**。
    /// 只给总分的话，用户看不出是卡在第几句 —— 那正是段落模式唯一的价值所在。
    private func passageResultCard(_ result: ShadowingPassageResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Text("\(result.accuracyPercent)%")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(verdictColor(result.verdict))
                    .monospacedDigit()

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Image(systemName: result.verdict.symbol)
                            .font(.system(size: 11))
                        Text(result.verdict.displayName)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(verdictColor(result.verdict))

                    Text("跟上 \(result.matched) / \(result.referenceCount) 个词")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }

            accuracyBar(accuracy: result.accuracy, verdict: result.verdict)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(result.sentences.enumerated()), id: \.offset) { index, comparison in
                    passageSentenceRow(
                        index: index,
                        comparison: comparison,
                        isWeakest: index == result.weakestIndex
                    )
                }
            }

            Text(result.hint)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "ear.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.secondaryText)
                Text("我听到的：\(result.recognizedText)")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.surface)
                .shadow(color: theme.shadow, radius: 10, x: 0, y: 4)
        )
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// 一句的明细行。完全跟上的句子只留一行结论 —— 四句全铺逐词 chip 会把页面撑成词云。
    private func passageSentenceRow(
        index: Int,
        comparison: ShadowingComparison,
        isWeakest: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("第 \(index + 1) 句")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Image(systemName: comparison.verdict.symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(verdictColor(comparison.verdict))
                Text("\(comparison.accuracyPercent)%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(verdictColor(comparison.verdict))
                    .monospacedDigit()
                if isWeakest { chip("最弱", color: theme.warning) }
                Spacer(minLength: 0)
            }
            if comparison.verdict != .perfect, !comparison.tokens.isEmpty {
                FlowRow(spacing: 5, lineSpacing: 5) {
                    ForEach(Array(comparison.tokens.enumerated()), id: \.offset) { _, token in
                        tokenChip(token)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.surfaceAlt.opacity(0.55))
        )
    }

    private func tokenChip(_ token: ShadowingToken) -> some View {
        let color: Color = switch token.status {
        case .matched: .green
        case .missing: .red
        case .extra: theme.warning
        }
        let prefix = token.status == .extra ? "+" : ""
        return Text(prefix + token.word)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(token.status == .matched ? theme.primaryText : color)
            .strikethrough(token.status == .missing, color: color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color.opacity(token.status == .matched ? 0.14 : 0.18))
            )
            .help(token.status == .extra ? "多说的词" : (token.status == .missing ? "漏掉的词" : "跟上了"))
    }

    private func verdictColor(_ verdict: ShadowingVerdict) -> Color {
        switch verdict {
        case .perfect: .green
        case .great: theme.accent
        case .keepGoing: theme.warning
        case .retry: .red
        }
    }

    // MARK: - 发音评测（第 23 步 Pronunciation）

    /// 发音评测卡：总分 + 各维度条 + 度量明细 + 针对性建议。
    /// 数据全部来自 `PronunciationReport`（录音里量出来的物理量），页面不做任何计算。
    private func pronunciationCard(_ report: PronunciationReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("发音评测")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                if !report.metrics.hasSpeech {
                    Text("这次没量到足够的语音，仅供参考")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Image(systemName: report.verdict.symbol)
                        .font(.system(size: 11))
                    Text(report.verdict.displayName)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(scoreColor(report.overall))
                Text("\(report.overallPercent)")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(scoreColor(report.overall))
                    .monospacedDigit()
            }

            VStack(spacing: 12) {
                ForEach(report.lines) { line in
                    dimensionRow(line)
                }
            }

            // 逐音素明细：单独成组件（见 `PhonemeBreakdownCard`），
            // 便于离屏渲染单独回归，也便于日后别的页面复用。
            if report.hasPhonemeBreakdown {
                PhonemeBreakdownCard(report: report, showsContainer: true)
            }

            ForEach(report.tips, id: \.self) { tip in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.accent)
                        .padding(.top, 2)
                    Text(tip)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(theme.surface)
                .shadow(color: theme.shadow, radius: 10, x: 0, y: 4)
        )
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func dimensionRow(_ line: PronunciationScoreLine) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(line.dimension.displayName)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Spacer(minLength: 8)
                Text(line.detail)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(Int(line.score.rounded()))")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(scoreColor(line.score))
                    .monospacedDigit()
                    .frame(width: 28, alignment: .trailing)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.divider.opacity(0.6))
                    Capsule()
                        .fill(scoreColor(line.score))
                        .frame(width: max(6, proxy.size.width * line.score / 100))
                }
            }
            .frame(height: 6)
        }
    }

    /// 分数配色：越高越绿，与逐词反馈的红/绿语义一致。
    private func scoreColor(_ score: Double) -> Color {
        if score >= 85 { return .green }
        if score >= 70 { return theme.accent }
        if score >= 55 { return theme.warning }
        return .red
    }

    // MARK: - 空态 / 提示

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "tray")
                    .foregroundStyle(theme.secondaryText)
                Text(state.shadowingNotice ?? "跟读素材还没加载出来")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(theme.primaryText)
            }
            Text("素材来自安装包内的 Resources/Shadowing/*.json。")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.secondaryText)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.surface)
        )
    }

    private func noticeBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.warning)
            Text(message)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                state.dismissShadowingNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.warning.opacity(0.14))
        )
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}

/// 简易自动换行布局（逐词 chip 用）。SwiftUI 的 `Layout` 协议实现，
/// 避免为了「一行放不下就换行」把文本塞进单个 `Text` 而丢掉逐词配色。
struct FlowRow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6
    /// 长条目是否允许在**词边界**折行：
    /// - `false`（默认）：只按自然宽度量，每个 chip 永远一行 —— 逐词 chip / 单词用；
    /// - `true`：拿可用宽做提案，整句过长时在空格处折行，
    ///   既保证短词 / 短词组一行放下，又不会在单词中间断开。
    var wrapsLongItems: Bool = false

    /// 量一个子视图：是否需要「约束到可用宽」。
    private func measure(_ subview: LayoutSubviews.Element, maxWidth: CGFloat) -> CGSize {
        guard wrapsLongItems, maxWidth.isFinite else {
            return subview.sizeThatFits(.unspecified)
        }
        return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = measure(subview, maxWidth: maxWidth)
            if x > 0, x + size.width > maxWidth {
                widest = max(widest, x - spacing)
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        widest = max(widest, x - spacing)
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = measure(subview, maxWidth: bounds.width)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
