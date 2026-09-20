import AIDomain
import SwiftUI

// MARK: - 交互小动物

/// 可点击的小动物：点击后头顶冒气泡展示一句个性语句；连点连续切换；
/// 停止点击 3 秒后气泡自动消失。`facing` 控制左右朝向，`phrases` 为空则纯展示不可交互。
public struct TalkingAnimal: View {

    @Environment(\.forestTheme) private var theme

    public let kind: AnimalKind
    public let isSleeping: Bool
    public let size: CGFloat
    public var accessory: AnimalAccessory = .none
    public var bobbing: Bool = true
    /// 1 = 朝右，-1 = 朝左（只翻转动物，不镜像气泡文字）。
    public var facing: CGFloat = 1
    public var phrases: [String] = []
    /// 气泡出现/消失时回调（父级据此把该个体抬到最上层，避免被相邻气泡遮挡）。
    public var onBubbleChange: ((Bool) -> Void)? = nil

    @State private var bubble: String?
    @State private var clickTick = 0

    public init(kind: AnimalKind, isSleeping: Bool = false, size: CGFloat = 64,
                accessory: AnimalAccessory = .none, bobbing: Bool = true,
                facing: CGFloat = 1, phrases: [String] = [],
                onBubbleChange: ((Bool) -> Void)? = nil) {
        self.kind = kind
        self.isSleeping = isSleeping
        self.size = size
        self.accessory = accessory
        self.bobbing = bobbing
        self.facing = facing
        self.phrases = phrases
        self.onBubbleChange = onBubbleChange
    }

    public var body: some View {
        ZStack(alignment: .top) {
            if let bubble {
                SpeechBubble(text: bubble, maxWidth: 176)
                    .offset(y: -(size * 0.86))
                    .transition(.opacity.combined(with: .scale(scale: 0.55, anchor: .bottom)))
                    .zIndex(3)
            }

            CuteAnimalView(kind: kind, isSleeping: isSleeping, size: size,
                           accessory: accessory, bobbing: bobbing)
                .scaleEffect(x: facing, y: 1, anchor: .center)
                .zIndex(2)
        }
        .frame(width: size, height: size)
        .contentShape(Circle().inset(by: -size * 0.08))
        .onTapGesture { showNext() }
        .task(id: clickTick) {
            guard bubble != nil else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            // 关键：被新的点击取消时（连点）必须直接返回，
            // 否则会立刻把气泡关掉——这正是「连点时气泡一闪就收」的根源。
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { bubble = nil }
            onBubbleChange?(false)
        }
        .accessibilityLabel("\(kind.displayName)（点击听它说话）")
        .accessibilityAddTraits(.isButton)
    }

    private func showNext() {
        guard !phrases.isEmpty else { return }
        let pool = phrases.filter { $0 != bubble }
        let next = pool.randomElement() ?? phrases[0]
        let isNewBubble = bubble == nil
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { bubble = next }
        if isNewBubble { onBubbleChange?(true) }
        clickTick += 1
    }
}

// MARK: - 气泡

/// 头顶冒出的对话气泡：圆角矩形 + 底部小三角指向说话者。
/// 宽度按文案长度估算（父容器是动物大小的正方形，不能用其提议宽度，否则会被压成细条）。
public struct SpeechBubble: View {

    @Environment(\.forestTheme) private var theme
    let text: String
    let maxWidth: CGFloat

    public init(text: String, maxWidth: CGFloat = 176) {
        self.text = text
        self.maxWidth = maxWidth
        self.segments = nil
    }

    /// 粗略估宽：中日韩字符 ≈ 字号宽，拉丁字符 ≈ 0.55 字号；夹在 [72, maxWidth]。
    private var estimatedWidth: CGFloat {
        var units: CGFloat = 0
        for ch in text {
            units += ch.unicodeScalars.allSatisfy { $0.properties.isEmojiPresentation || $0.value > 0x2E7F } ? 1.0 : 0.56
        }
        return min(maxWidth, max(72, units * 11.5 + 26))
    }

    /// 分段着色：哪几个字是红的、哪几个是绿的，由 `segments` 决定（今日进度的关键字）。
    ///
    /// 单独一个构造器而不是给 `init(text:)` 加参数 —— 整句一个色会变成「警告条 / 恭喜条」，
    /// 只有数字变色才读得出「进度」。传空数组等于不显示。
    public init(segments: [TodayPanel.Segment], maxWidth: CGFloat = 176) {
        self.text = segments.map(\.text).joined()
        self.segments = segments.isEmpty ? nil : segments
        self.maxWidth = maxWidth
    }

    private let segments: [TodayPanel.Segment]?

    public var body: some View {
        bubbleText
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(theme.primaryText)
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .frame(width: estimatedWidth)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(theme.panel)
                    .shadow(color: theme.shadow, radius: 5, x: 0, y: 2)
            )
            .overlay(alignment: .bottom) {
                Triangle()
                    .fill(theme.panel)
                    .frame(width: 12, height: 7)
                    .offset(y: 5.5)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(theme.divider, lineWidth: 1)
            )
            .fixedSize(horizontal: true, vertical: true)
    }

    /// 有分段就拼一段着色的 `Text`，没有就退回整句一个色。
    private var bubbleText: Text {
        guard let segments, !segments.isEmpty else { return Text(text) }
        return segments.reduce(Text("")) { partial, segment in
            partial + Text(segment.text).foregroundStyle(color(for: segment.tone))
        }
    }

    /// 绿/红都从主题取，**不写死 hex**（金四档那条规矩：加新色号前先问主题里有没有）。
    private func color(for tone: TodayPanel.Segment.Tone) -> Color {
        switch tone {
        case .plain: theme.primaryText
        case .good: theme.success
        case .alert: theme.danger
        }
    }
}
