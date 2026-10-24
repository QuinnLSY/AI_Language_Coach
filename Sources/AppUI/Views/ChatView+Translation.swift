import AIDomain
import AIInterfaces
import AIServices
import AppCore
import SwiftUI

// #663 自 ChatView.swift 拆出（2026-10-24）：原文件 2896 行、单结构体 + 5 个尾部类型，按主题分文件。
// 同模块移动，语义与拆分前完全一致；跨文件引用的成员已从 private 放宽到 internal
// （模块内可见，跨模块零影响，public API 不变）。
extension ChatView {

    // MARK: - 译文卡片装饰常量

    /// 译文卡片左右内边距。
    nonisolated static let translationPadding: CGFloat = 12
    /// 引号图标与文字之间的间距。
    nonisolated static let translationMarkGap: CGFloat = 6

    /// 翻译按钮：**按需翻译**的入口。
    ///
    /// 译文不是生成时就一起产出的 —— 那会让每条回复的 token 与延迟翻倍，
    /// 而绝大多数气泡学员根本不会点开。这里只负责「点一下才去要译文」，
    /// 结果有缓存，重复点开（含收起再展开）都是零成本。
    struct TranslateButton: View {
        @Environment(\.forestTheme) private var theme

        let isOn: Bool
        let isLoading: Bool
        let action: () -> Void

        var body: some View {
            Button {
                action()
            } label: {
                Group {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.mini)
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                            .tint(theme.accent)
                    } else {
                        Image(systemName: "translate")
                            .appFont(11, weight: .semibold)
                            .foregroundStyle(isOn ? theme.accent : theme.secondaryText.opacity(0.75))
                    }
                }
                .frame(width: 20, height: 20)
                .background(Circle().fill(isOn ? theme.accent.opacity(0.16) : Color.clear))
            }
            .buttonStyle(.appPressable)
            .disabled(isLoading)
            .help(isOn ? "收起翻译" : "翻译成中文")
            .accessibilityLabel(isOn ? "收起翻译" : "翻译成中文")
        }
    }

    /// 「改一改」纠错卡片：原句 → 改正 + 一句话说明。
    func correctionCard(_ correction: GrammarCorrection) -> some View {
        CorrectionCard(correction: correction, context: wordLookup) {
            // 「再练一次」：把**原句**放回输入框 —— 学员要练的是把这句重说对，
            // 而不是照抄改后句（改后句就在卡片上，划词即可细看）。
            input = correction.original
        }
    }

    /// 错题卡（「改一改」）。
    ///
    /// 独立成子视图的原因：展开状态是**每张卡自己的**（一个会话可能有多张卡），
    /// 放在 ChatView 根级就得维护「哪张卡展开了」的下标表。
    private struct CorrectionCard: View {
        @Environment(\.forestTheme) private var theme

        let correction: GrammarCorrection
        let context: WordLookupContext?
        let onPracticeAgain: () -> Void

        /// 解析说明默认收两行，点「展开」看全文（解释常比原句还长，全铺开会淹掉对话）。
        @State private var isExplanationExpanded = false

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: "pencil.and.list.clipboard")
                        .appFont(10, weight: .semibold)
                    Text("改一改")
                        .appFont(10, weight: .bold, design: .rounded)
                }
                .foregroundStyle(theme.accent)

                Text(correction.original)
                    .appFont(12, design: .rounded)
                    .strikethrough()
                    .foregroundStyle(theme.secondaryText)
                // 「改一改」里的改后句是最值得划词的：它就是要学员记住的那一句。
                LookupText(
                    text: correction.corrected,
                    fontSize: 12,
                    weight: .medium,
                    color: theme.primaryText,
                    context: context
                )
                if !correction.explanation.isEmpty {
                    explanation
                }

                HStack(spacing: 6) {
                    Button {
                        onPracticeAgain()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("再练一次")
                        }
                        .appFont(10, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 8)
                        .appPadding(.vertical, 4)
                        .background(Capsule().fill(theme.accent.opacity(0.1)))
                        .overlay(Capsule().strokeBorder(theme.accent.opacity(0.35), lineWidth: 1))
                    }
                    .buttonStyle(.appPressable)
                    .help("把原句放回输入框，重说一遍试试")
                    .accessibilityLabel("再练一次：\(correction.original)")

                    Spacer(minLength: 0)
                }
                .appPadding(.top, 2)
            }
            .padding(.horizontal, 12)
            .appPadding(.vertical, 8)
            .frame(maxWidth: 320, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(theme.accent.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(theme.accent.opacity(0.35), lineWidth: 1)
            )
        }

        /// 解析说明：默认两行，长解释给「展开 / 收起」。
        @ViewBuilder
        private var explanation: some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(correction.explanation)
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(isExplanationExpanded ? nil : 2)
                if isExplanationExpanded || isExplanationTruncated {
                    Button {
                        isExplanationExpanded.toggle()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: isExplanationExpanded ? "chevron.up" : "chevron.down")
                            Text(isExplanationExpanded ? "收起" : "展开")
                        }
                        .appFont(10, design: .rounded)
                        .foregroundStyle(theme.secondaryText.opacity(0.75))
                    }
                    .buttonStyle(.appPressable)
                    .accessibilityLabel(isExplanationExpanded ? "收起解析说明" : "展开解析说明")
                }
            }
        }

        /// 粗判「说明是不是被截断了」：超过约一行半的量（含标点）才值得给开关。
        /// SwiftUI 拿不到真实折行数，这里按字符数兜底 —— 太短的说明不给开关（免得点开没变化）。
        private var isExplanationTruncated: Bool { correction.explanation.count > 44 }
    }

    /// 朗读按钮：三态反馈（空闲 / 准备中 / 朗读中）。
    ///
    /// 本地 TTS 首句合成需要几秒，这段等待必须有可见反馈，否则用户会以为没点到；
    /// 有了「准备中」转圈 + 「朗读中」高亮，再点一次即可停止。
    struct SpeakButton: View {
        @Environment(\.forestTheme) private var theme

        let text: String
        let phase: SpeechPhase
        let action: (String) -> Void
        var onStop: (() -> Void)? = nil

        /// 按下中（按住不放）。
        @State private var isPressing = false
        /// 点中后的余辉：松开仍保持约 0.6 秒的高亮。
        @State private var didFlash = false

        private var isActive: Bool { phase != .idle }
        private var isHighlighted: Bool { isPressing || didFlash || isActive }

        private var labelText: String {
            switch phase {
            case .idle: "听老师读"
            case .preparing: "准备中…"
            case .speaking: "朗读中"
            }
        }

        var body: some View {
            Button {
                flash()
                if isActive { onStop?() } else { action(text) }
            } label: {
                HStack(spacing: 4) {
                    icon
                    Text(labelText)
                }
                .appFont(10, weight: .semibold, design: .rounded)
                .foregroundStyle(isHighlighted ? theme.onAccentFill : theme.secondaryText)
                .padding(.horizontal, 8)
                .appPadding(.vertical, 4)
                .background(
                    Capsule().fill(isHighlighted ? theme.accentFill : theme.surfaceAlt)
                )
                .overlay(
                    Capsule().strokeBorder(theme.accent, lineWidth: isHighlighted ? 2 : 0)
                )
                .scaleEffect(isPressing ? 0.94 : 1)
            }
            .buttonStyle(.appPressable)
            // 按住期间即高亮（simultaneous 不吞掉点击）
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in withAnimation(.app(.press)) { isPressing = true } }
                    .onEnded { _ in withAnimation(.app(.press)) { isPressing = false } }
            )
            .appAnimation(.reveal, value: isHighlighted)
            .help(isActive ? "点击停止朗读" : "听老师朗读这句")
        }

        @ViewBuilder
        private var icon: some View {
            switch phase {
            case .idle:
                Image(systemName: isHighlighted ? "speaker.wave.3.fill" : "speaker.wave.2.fill")
            case .preparing:
                // 首句正在合成：转圈表示「点了，正在准备」
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                    .scaleEffect(0.65)
                    .frame(width: 11, height: 11)
                    .tint(.white)
            case .speaking:
                Image(systemName: "speaker.wave.3.fill")
            }
        }

        private func flash() {
            withAnimation(.app(.press)) { didFlash = true }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.6))
                withAnimation(.app(.reveal)) { didFlash = false }
            }
        }
    }

    /// 语速选择：与设置页共用同一套下拉控件（形状/描边/箭头都由 `ForestSelect` 保证）。
    struct SpeechRateMenu: View {
        let rate: Double
        let onSelect: (Double) -> Void

        /// 控件宽度：按**最宽的档位标签**（`2.5×` / `0.5×`）实测得出。
        ///
        /// 2026-09-14 反馈「老师朗读的速率未正常显示」：原先写死 62pt，
        /// 而图标 + 内边距 + 间隙 + 箭头已占约 47pt，留给「2.5×」的不到 16pt，
        /// 值被压成「2…」。改成实测量宽后，字体或档位再变也不会重演。
        private static let chipWidth = ForestSelect<Double>.Metrics.compact
            .widthFitting(SpeechRate.allCases.map(\.label))

        var body: some View {
            ForestSelect(
                icon: "speedometer",
                selection: Binding(
                    get: { SpeechRate.nearest(to: rate).rawValue },
                    set: { onSelect($0) }
                ),
                options: SpeechRate.allCases.map {
                    ForestSelectOption(value: $0.rawValue, title: $0.label)
                },
                metrics: .compact,
                width: Self.chipWidth,
                help: "教师朗读语速（当前 \(SpeechRate.nearest(to: rate).label)）"
            )
        }
    }

}
