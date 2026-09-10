import AIDomain
import AIServices
import AppCore
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
                    if state.currentShadowingDrill != nil {
                        progressRow
                        drillCard
                        actionRow
                    if let comparison = state.shadowingComparison {
                        resultCard(comparison)
                        if let pronunciation = state.shadowingPronunciation {
                            pronunciationCard(pronunciation)
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
                Text("跟读")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Text("跟着老师的节奏说一遍，再听听自己的")
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
            Button {
                Task { await state.loadShadowing() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("刷新素材与统计")
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
    }

    // MARK: - 进度 / 主题 / 难度

    private var progressRow: some View {
        HStack(spacing: 8) {
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
                Text(drill.text)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

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

    // MARK: - 三个动作：听示范 / 跟读 / 听我的

    private var actionRow: some View {
        HStack(spacing: 10) {
            actionButton(
                icon: "play.circle.fill",
                title: state.isShadowingBusy && !state.isShadowingRecording ? "朗读中…" : "听示范",
                tint: theme.accent,
                filled: false,
                isBusy: state.isShadowingBusy && !state.isShadowingRecording
            ) {
                Task { await state.playShadowingExample() }
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
                icon: "waveform.circle.fill",
                title: "听我的",
                tint: theme.accent,
                filled: false,
                isBusy: state.isShadowingBusy && !state.isShadowingRecording
            ) {
                Task { await state.replayShadowingRecording() }
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

            accuracyBar(comparison)

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

    private func accuracyBar(_ comparison: ShadowingComparison) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.divider)
                Capsule()
                    .fill(verdictColor(comparison.verdict))
                    .frame(width: max(6, proxy.size.width * comparison.accuracy))
            }
        }
        .frame(height: 8)
    }

    private func tokenChip(_ token: ShadowingToken) -> some View {
        let color: Color = switch token.status {
        case .matched: .green
        case .missing: .red
        case .extra: .orange
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
        case .keepGoing: .orange
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
        if score >= 55 { return .orange }
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
                .foregroundStyle(.orange)
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
                .fill(Color.orange.opacity(0.14))
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

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
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
            let size = subview.sizeThatFits(.unspecified)
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
