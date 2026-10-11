import AIDomain
import SwiftUI

/// 开屏话题卡：教区空态那句「今天聊什么」的**答案**。
///
/// 为什么单独成组件（与 `PronunciationComparisonCard` 同款理由）：
/// 空态那一屏里再叠三张卡，整页离屏看不出它到底画没画出来，
/// 单独组件才能做针对性回归。
///
/// ⚠️ 卡片**点一下就得有真反应**：这里不接任何「将来再说」的动作，
/// 每张卡要么发送一句话，要么打开一个确实存在的情景。
struct KickoffRow: View {

    @Environment(\.forestTheme) private var theme

    let suggestions: [KickoffSuggestion]
    /// 点某张卡（nil = 只读展示，跑渲染回归时用）。
    var onPick: ((KickoffSuggestion) -> Void)? = nil
    /// 离屏注入的悬停项（`CoreSimulator 不产生 hover`：真机才有 hover，
    /// 渲染回归只能靠参数喂，见 `forcedHoveredMessageID` 同款处理）。
    var forcedHoveredID: String? = nil

    @State private var hoveredID: String? = nil

    var body: some View {
        if suggestions.isEmpty {
            // 没有依据就不占地方：空态留白比留一排装饰好。
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                header
                ForEach(suggestions) { card in
                    kickoffButton(card)
                }
            }
            .frame(width: Self.width)
            .accessibilityElement(children: .contain)
        }
    }

    /// 卡片的宽度：**写死一个上限**。跟着父容器抻满一整行的话，
    /// 鼠标要横穿半个屏幕才能点到第一张卡 —— 推荐变成了负担。
    static let width: CGFloat = 360

    private var header: some View {
        Text("今天聊什么")
            .appFont(11, weight: .semibold, design: .rounded)
            .foregroundStyle(theme.secondaryText)
    }

    private func kickoffButton(_ card: KickoffSuggestion) -> some View {
        let isHovered = hoveredID == card.id || forcedHoveredID == card.id
        return Button {
            onPick?(card)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: Self.iconName(card.kind))
                    .appFont(12)
                    .foregroundStyle(theme.accent)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title)
                        .appFont(12, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                    if !card.detail.isEmpty {
                        Text(card.detail)
                            .appFont(11, design: .rounded)
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: 6)

                Image(systemName: "arrow.right")
                    .appFont(9)
                    .foregroundStyle(theme.secondaryText)
                    .opacity(isHovered ? 1 : 0.55)
            }
            .appPadding(.horizontal, 12)
            .appPadding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isHovered ? theme.selection.opacity(0.4) : theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(theme.divider, lineWidth: 0.5)
                    )
            )
        }
        // ⚠️ 不写 `.buttonStyle(.plain)`：按压反馈由 MainView 根上的
        // `.buttonStyle(.appPressable)` 统一注入，自己包一层 `.plain` 会把它盖掉
        // （症状是「卡片点了没反应」——`MotionTokenWiringTests` 钉着这条）。
        .onHover { inside in
            hoveredID = inside ? card.id : (hoveredID == card.id ? nil : hoveredID)
        }
        .accessibilityLabel(card.detail.isEmpty ? card.title : "\(card.title)，\(card.detail)")
    }

    private static func iconName(_ kind: KickoffSuggestion.Kind) -> String {
        switch kind {
        case .resume: return "arrow.uturn.forward"
        // ⚠️ 别用 `textformat.abc` / `character.bubble` 这类符号：
        // 它们是**本地化符号**，中文区域分别渲染成「甲乙丙」「字」——
        // 一个学英语的界面里冒出汉字图标，语义就偏了。
        case .todayWord: return "quote.bubble"
        case .smallTalk: return "bubble.left"
        }
    }
}
