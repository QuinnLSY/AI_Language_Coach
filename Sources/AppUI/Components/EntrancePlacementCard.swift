import AIDomain
import SwiftUI

/// 入学定级卡（学习进度页）：回答「我该从哪一档开始」。
///
/// 与下面那张「能力定位」是**两把尺子**，所以两块卡分开放、各自标清来源：
/// - 这张：摸底自测（十来道选择题），**第 0 天就能给结果** —— 新用户需要的正是它；
/// - 能力定位：按真实练习数据估（要 25 轮对话 + 3 天 + 20 个词才肯开口）。
///
/// ⚠️ 两者不一致（自测 B2、练下来像 A2）恰恰是最有用的信息，所以这里只在
/// **两边都有且不一致**时补一句对照 —— 各自的值不重复展示（那是下面那张卡的事）。
struct EntrancePlacementCard: View {

    @Environment(\.forestTheme) private var theme

    /// 上一次摸底的结果（nil = 还没做过）。
    let result: PlacementResult?
    /// 按真实练习数据估出来的档位（nil = 样本不够，还在观察中）。
    let estimateLevel: CEFRLevel?
    /// 开始 / 重测。
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let result {
                taken(result)
            } else {
                notTaken
            }
        }
        .appPadding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.surface)
                .appElevation(.card)
        )
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "figure.walk.arrival")
                .appFont(12)
                .foregroundStyle(theme.accent)
            Text("入学定级")
                .appFont(13, weight: .semibold, design: .rounded)
                .foregroundStyle(theme.primaryText)
            Spacer(minLength: 8)
            Button(action: onStart) {
                Text(result == nil ? "开始摸底" : "重测")
                    .appFont(11, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 10)
                    .appPadding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous).strokeBorder(theme.accent.opacity(0.5), lineWidth: 1)
                    )
            }
            .buttonStyle(.appPressable)
            .help("\(EntrancePlacementRule.questionsPerLevel) 题一档、一共十来道选择题，几分钟能做完")
            .accessibilityLabel(result == nil ? "开始摸底" : "重新摸底")
        }
    }

    // MARK: - 还没做过

    private var notTaken: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("还没定级：先花几分钟摸个底，我按你的水平出题")
                .appFont(12, weight: .medium, design: .rounded)
                .foregroundStyle(theme.primaryText)
            Text("十来道选择题（认词 + 语法），从入门到自如四档各抽几道；全在本地判分，不联网。")
                .appFont(10, design: .rounded)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 做过之后

    private func taken(_ result: PlacementResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text(result.level.code)
                    .appFont(30, weight: .bold, design: .rounded)
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("起点 · \(result.level.displayName)（\(result.level.canDo)）")
                        .appFont(12, weight: .medium, design: .rounded)
                        .foregroundStyle(theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(result.headline) · 正确率 \(result.accuracyPercent)%")
                        .appFont(10, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }

            // 逐档明细：定级是「哪一档没过」那条阶梯，所以必须把每一档摆出来，
            // 否则用户只看到一个字母，没法核对这个结论是怎么来的。
            HStack(spacing: 6) {
                ForEach(result.perLevel, id: \.level) { score in
                    levelChip(score)
                }
                Spacer(minLength: 0)
            }

            Text(adviceText(result))
                .appFont(11, design: .rounded)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let comparison = comparisonText(result) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrow.left.arrow.right")
                        .appFont(9)
                        .foregroundStyle(theme.accentCool)
                    Text(comparison)
                        .appFont(10, design: .rounded)
                        .foregroundStyle(theme.accentCool)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// 自测与实际练习数据不一致时的对照（一致 / 缺一边 = 不出现）。
    ///
    /// ⚠️ 只在**两个都有**且**确实不同**时出现：同档时说一句「两边一致」是废话，
    /// 而样本不够时（estimateLevel == nil）说话就成了瞎猜。
    private func comparisonText(_ result: PlacementResult) -> String? {
        guard let estimateLevel, estimateLevel != result.level else { return nil }
        let direction = estimateLevel < result.level
            ? "练下来更像 \(estimateLevel.code)：自测偏乐观，出题我按实测的更稳"
            : "练下来已经有 \(estimateLevel.code) 了：起点可以往上挪一档"
        return "自测是 \(result.level.code)，但\(direction)"
    }

    private func levelChip(_ score: PlacementLevelScore) -> some View {
        HStack(spacing: 4) {
            Image(systemName: score.isPassed ? "checkmark.circle.fill" : "circle.dashed")
                .appFont(9)
            Text(score.text)
                .appFont(10, weight: .semibold, design: .rounded)
                .monospacedDigit()
        }
        .foregroundStyle(score.isPassed ? theme.success : theme.secondaryText)
        .padding(.horizontal, 7)
        .appPadding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(score.isPassed ? theme.success.opacity(0.14) : theme.hover)
        )
        .help(score.isPassed ? "这一档过了（答对 \(score.correct) / \(score.total)）" : "这一档没过 —— 定级就停在这里")
    }

    /// 说清「为什么定在这」，再给下一步。
    private func adviceText(_ result: PlacementResult) -> String {
        let advice = result.level.placementAdvice
        guard let failed = result.firstFailedLevel else {
            return "四档都过了，起点定在最高档。\(advice)"
        }
        return "\(failed.code) 这一档没过，所以起点定在 \(result.level.code)。\(advice)"
    }
}
