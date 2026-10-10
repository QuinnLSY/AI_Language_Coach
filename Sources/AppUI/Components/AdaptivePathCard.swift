import AIDomain
import SwiftUI

/// 学习建议卡的内容（⑤ 自适应学习路径）。
///
/// 与「我的学习计划」卡的分工：那张说**阶段与今天**（我在哪 → 练什么 → 今天还差几项），
/// 这张说**最近的走向**（趋势在变，建议也跟着变）—— 两句话不重复，所以并排放在同一页。
///
/// ⚠️ 只拥有**内容**：卡壳（标题行 / 底 / 阴影）由调用方的 `card(…)` 提供，
/// 与计划卡共用同一份配方，这里长出第二份就一定会漂移。
///
/// ⚠️ 卡里**不做判断**：档位、理由、下一步都由 `AdaptivePathRule` 的纯函数算好，
/// 视图只负责画出来（判断挪进视图 = 离屏回归再也测不到）。
public struct AdaptivePathCard: View {

    @Environment(\.forestTheme) private var theme

    private let path: AdaptivePath
    private let onAction: (LearningPlanFocus.Action) -> Void

    public init(path: AdaptivePath, onAction: @escaping (LearningPlanFocus.Action) -> Void) {
        self.path = path
        self.onAction = onAction
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            reasonList
            actionRow
        }
    }

    // MARK: - 结论

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: path.stance.symbolName)
                .appFont(12)
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(tint.opacity(0.12)))
            Text(path.headline)
                .appFont(14, weight: .bold, design: .rounded)
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("学习建议：\(path.headline)")
    }

    /// 依据：每条都带可核对的量（数量 / 前后两个数），是判定自己给的不是视图编的。
    private var reasonList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(path.reasons.prefix(3).enumerated()), id: \.offset) { _, reason in
                HStack(alignment: .top, spacing: 6) {
                    Circle()
                        .fill(tint.opacity(0.7))
                        .frame(width: 4, height: 4)
                        .padding(.top, 5)
                    Text(reason)
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 下一步

    /// 第一个动作是主入口；其余并排成小胶囊（同样可点）。
    ///
    /// ⚠️ 主按钮与胶囊**共用** `performLearningPlanFocus` 的映射，不为同一件事开第二套动作。
    private var actionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let primary = path.nextActions.first {
                Button {
                    onAction(primary)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: Self.actionIcon(primary))
                            .appFont(11)
                            .foregroundStyle(tint)
                        Text("接着做：\(primary.title)")
                            .appFont(12, weight: .semibold, design: .rounded)
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .appFont(9, weight: .semibold)
                            .foregroundStyle(theme.secondaryText.opacity(0.8))
                    }
                    .appPadding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(theme.surfaceAlt.opacity(0.7))
                    )
                }
                .buttonStyle(.appPressable)
                .accessibilityLabel("接着做：\(primary.title)")
                .accessibilityHint("去练习")
            }

            if path.nextActions.count > 1 {
                HStack(spacing: 6) {
                    ForEach(Array(path.nextActions.dropFirst()), id: \.rawValue) { action in
                        Button {
                            onAction(action)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: Self.actionIcon(action))
                                    .appFont(9)
                                Text(action.title)
                                    .appFont(10, design: .rounded)
                                    .lineLimit(1)
                            }
                            .foregroundStyle(theme.secondaryText)
                            .appPadding(.horizontal, 8)
                            .appPadding(.vertical, 4)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(theme.surfaceAlt.opacity(0.7))
                            )
                        }
                        .buttonStyle(.appPressable)
                        .accessibilityLabel("也可以：\(action.title)")
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - 配色与图标

    /// 档位色：补短板 = 警示橘、稳住 = 主橘、往前推 = 绿、还在看 = 灰。
    ///
    /// ⚠️ 色相之外还有图标与文案三处差异，色弱用户与深浅两套主题下都分得出来。
    private var tint: Color {
        switch path.stance {
        case .observing: theme.secondaryText
        case .reinforce: theme.warning
        case .consolidate: theme.accent
        case .advance: theme.success
        }
    }

    /// 图标与计划卡共用一份映射（`LearningPlanFocus.Action.symbolName`），别为同一件事换第二套。
    private static func actionIcon(_ action: LearningPlanFocus.Action) -> String {
        action.symbolName
    }
}
