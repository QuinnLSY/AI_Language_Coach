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

    @State private var bubble: String?
    @State private var clickTick = 0

    public init(kind: AnimalKind, isSleeping: Bool = false, size: CGFloat = 64,
                accessory: AnimalAccessory = .none, bobbing: Bool = true,
                facing: CGFloat = 1, phrases: [String] = []) {
        self.kind = kind
        self.isSleeping = isSleeping
        self.size = size
        self.accessory = accessory
        self.bobbing = bobbing
        self.facing = facing
        self.phrases = phrases
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
            withAnimation(.easeOut(duration: 0.25)) { bubble = nil }
        }
        .accessibilityLabel("\(kind.displayName)（点击听它说话）")
        .accessibilityAddTraits(.isButton)
    }

    private func showNext() {
        guard !phrases.isEmpty else { return }
        let pool = phrases.filter { $0 != bubble }
        let next = pool.randomElement() ?? phrases[0]
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { bubble = next }
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
    }

    /// 粗略估宽：中日韩字符 ≈ 字号宽，拉丁字符 ≈ 0.55 字号；夹在 [72, maxWidth]。
    private var estimatedWidth: CGFloat {
        var units: CGFloat = 0
        for ch in text {
            units += ch.unicodeScalars.allSatisfy { $0.properties.isEmojiPresentation || $0.value > 0x2E7F } ? 1.0 : 0.56
        }
        return min(maxWidth, max(72, units * 11.5 + 26))
    }

    public var body: some View {
        Text(text)
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
}
