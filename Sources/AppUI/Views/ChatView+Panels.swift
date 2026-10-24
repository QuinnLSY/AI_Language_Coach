import SwiftUI

// #663 自 ChatView.swift 拆出（2026-10-24）：原文件 2896 行、单结构体 + 5 个尾部类型，按主题分文件。
// 同模块移动，语义与拆分前完全一致；跨文件引用的成员已从 private 放宽到 internal
// （模块内可见，跨模块零影响，public API 不变）。
// MARK: - 思考过程折叠面板

/// 推理模型的思考过程：卡片内嵌面板，箭头切换展开/收起（默认展开）。
/// 高度自适应：最多露出 6 行（超出可滚动回看全部），不足 6 行时按实际内容收窄。
/// 背景为半透明灰（比原先更透，避免遮挡底层内容）。
struct ThinkingPanel: View {

    @Environment(\.forestTheme) private var theme
    let reasoning: String
    /// 流式阶段为 true：内容持续增长，自动吸底显示最新思考。
    let isStreaming: Bool

    @State private var isExpanded = true
    /// 实测正文高度（含内边距）。
    @State private var contentHeight: CGFloat = 0
    /// 实测「6 行」参考高度（含内边距）；未测得前用兜底值。
    @State private var sixLineHeight: CGFloat = 0

    /// 最多显示的行数。
    private let maxLines = 6
    /// 字体与内边距（正文与参考测量必须一致）。
    private let bodyFontSize: CGFloat = 11
    private let horizontalPadding: CGFloat = 10
    private let bottomPadding: CGFloat = 8
    /// 参考高度尚未测得时的兜底（约 6 行）。
    private let fallbackPanelHeight: CGFloat = 96

    /// 面板高度：内容不足 6 行按实际高度，超出则封顶 6 行并可滚动。
    private var panelHeight: CGFloat {
        let cap = sixLineHeight > 0 ? sixLineHeight : fallbackPanelHeight
        guard contentHeight > 0 else { return cap }
        return min(contentHeight, cap)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.app(.reveal)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .appFont(9, weight: .bold)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(isStreaming ? "正在思考…" : "思考过程")
                        .appFont(10, weight: .semibold, design: .rounded)
                    Spacer()
                }
                .foregroundStyle(theme.secondaryText)
                .contentShape(Rectangle())
                .padding(.horizontal, 10)
                .appPadding(.vertical, 6)
            }
            .buttonStyle(.appPressable)

            if isExpanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(reasoning)
                            .appFont(bodyFontSize, design: .rounded)
                            .foregroundStyle(theme.primaryText.opacity(0.82))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, horizontalPadding)
                            .padding(.bottom, bottomPadding)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                            .id("thinking-bottom")
                    }
                    .frame(height: panelHeight)
                    .onChange(of: reasoning) { _, _ in
                        guard isStreaming else { return }
                        proxy.scrollTo("thinking-bottom", anchor: .bottom)
                    }
                    .onAppear {
                        proxy.scrollTo("thinking-bottom", anchor: .bottom)
                    }
                }
            }
        }
        .background(alignment: .topLeading) {
            // 隐藏的 6 行参考文本：仅用于实测「6 行」高度上限（不参与布局）。
            Text(String(repeating: "\n", count: maxLines - 1) + "M")
                .appFont(bodyFontSize, design: .rounded)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, bottomPadding)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sixLineHeight = $0 }
                .hidden()
                .accessibilityHidden(true)
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.gray.opacity(0.42))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.divider.opacity(0.6), lineWidth: 1)
        )
    }
}

// MARK: - 上下文占用圆环

/// 圆环仪表：淡灰整圈 = 模型上下文窗口，白色弧 = 已用占比；悬停显示文字气泡。
struct ContextGauge: View {

    let used: Int
    let limit: Int?
    let tooltip: String
    let track: Color

    @State private var isHovering = false

    private var fraction: Double {
        guard let limit, limit > 0 else { return 0 }
        return min(Double(used) / Double(limit), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(track, lineWidth: 3)
            if limit != nil {
                Circle()
                    .trim(from: 0, to: max(fraction, 0.02))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 13, height: 13)
        // 悬浮详情在圆环**上方**弹出：状态栏贴着窗口底边，向下弹会被裁出窗外（这就是之前看不到的原因）
        .overlay(alignment: .top) {
            if isHovering {
                SpeechBubble(text: tooltip, maxWidth: 220)
                    .fixedSize()
                    .offset(y: -34)
                    .zIndex(10)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Circle().inset(by: -8))
        .onHover { hovering in
            withAnimation(.app(.press)) { isHovering = hovering }
        }
        .help(tooltip)
    }
}

struct TypingDots: View {
    let color: Color
    @State private var phase = 0

    @Environment(\.appMotion) private var motion

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .offset(y: phase == index ? -4 : 0)
            }
        }
        .padding(.horizontal, 14)
        .appPadding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16).fill(color.opacity(0.10)))
        // ⚠️ 走 `Timer.publish(...).autoconnect()` + `onReceive`，不用 `Timer.scheduledTimer`：
        // 后者被 RunLoop 一直持有、闭包还捕获着视图，而这里既没保存引用也没在
        // `onDisappear` 里 invalidate —— 每出现一次「正在输入」就**永久多一个** 0.35 秒定时器，
        // 应用久开之后定时器越攒越多，闲着也在周期性叫醒主线程。
        // `autoconnect` 跟着视图生命周期自动断开，不需要谁记得去取消。
        .onReceive(Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()) { _ in
            // 「减弱动态效果」下三点**静止**：这一排点本身已经把「正在等待」说清楚了，
            // 反复跳动只是修饰 —— 而它偏偏是等待期间唯一一直动的东西（最刺眼的一个）。
            // 静止不等于没画出来，三个点仍在原位。
            guard !motion.reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.25)) { phase = (phase + 1) % 3 }
        }
    }
}

// MARK: - 预设提问轮换（状态下沉）

/// 预设提问的轮换状态（#440 优化）。
///
/// 轮换下标是**输入框占位提示**的私有状态 —— 以前放在 ChatView 根级 `@State`，
/// 每 3.4 秒一跳就把整个对话视图的 body 全部重算一遍（长会话里每一跳都是一次
/// 全量 diff）。`@Observable` 的细粒度订阅让**只有读下标的占位子视图**跟着刷新，
/// 父视图的 body 不再因为占位提示换了一句话而重算。
///
/// ⚠️ 父视图只有 `send()` 的 action 闭包读 `current`（闭包不订阅）；
/// `canSend` 用 `exam == nil && !starterQuestions.isEmpty` 的 index-free 判断，
/// 全程不给父级制造下标订阅。
@MainActor
@Observable
final class StarterQuestionRotator {
    private(set) var index: Int = 0
    private(set) var questions: [String] = []

    /// 当前轮换到的那条（没有预设时 nil）。
    var current: String? {
        guard !questions.isEmpty else { return nil }
        return questions[index % questions.count]
    }

    /// 换一批预设提问（内容没变就不动，避免把轮换归零）。
    func update(questions: [String]) {
        guard self.questions != questions else { return }
        self.questions = questions
        index = 0
    }

    /// 时钟一跳：换下一条。守卫与原根级 Timer 一致——
    /// 输入框空着、没在等回复、预设多于一条才动。
    func advance(isInputEmpty: Bool, isGenerating: Bool) {
        guard isInputEmpty, questions.count > 1, !isGenerating else { return }
        index = (index + 1) % questions.count
    }
}

/// 输入框里的轮换占位提示（浅灰那条）。
///
/// 自己持有轮换时钟：这个子视图只在「输入框为空且不在考试」时到场，
/// 时钟的生命周期天然跟着占位提示走 —— 输入框一旦有字，时钟随视图一起消失。
struct RollingStarterQuestionView: View {
    let rotator: StarterQuestionRotator
    let isGenerating: Bool

    /// 每条预设提问停留的秒数。
    private let rotationInterval: Double = 3.4

    @Environment(\.forestTheme) private var theme

    var body: some View {
        Group {
            if let hint = rotator.current {
                Text(hint)
                    .appFont(14, design: .rounded)
                    .foregroundStyle(theme.secondaryText.opacity(0.62))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .id(hint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 20)
                    .clipped()
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    ))
            }
        }
        // 轮换动画归子视图：父级不再把下标当 animation value（读了就会订阅）。
        .appAnimation(.panel, value: rotator.index)
        .onReceive(Timer.publish(every: rotationInterval, on: .main, in: .common).autoconnect()) { _ in
            rotator.advance(isInputEmpty: true, isGenerating: isGenerating)
        }
    }
}
