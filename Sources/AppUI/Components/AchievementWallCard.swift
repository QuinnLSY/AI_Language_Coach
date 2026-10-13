import AIDomain
import SwiftUI

/// 成就墙（⑦-C②）。
///
/// 两件事都交给 `AchievementWall` 的纯规则：墙上摆哪几格（已达成全部 + 最接近的三条）、
/// 墙头那一行怎么写。这里只画。
///
/// ⚠️ 所有数字都是插出来的真值，**没有一个写死的「3/9」**；
/// 未达成那几格必须写出「还差多少」，否则那面墙只是在数灰格子。
struct AchievementWallCard: View {

    @Environment(\.forestTheme) private var theme

    var headline: String
    var items: [Achievement]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            grid
        }
        .appPadding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.divider, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    // MARK: - 各块

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: "seal.fill")
                    .appFont(12, weight: .semibold)
                    .foregroundStyle(theme.accent)
                Text("成就墙")
                    .appFont(13, weight: .bold, design: .rounded)
                    .foregroundStyle(theme.primaryText)
            }
            Text(headline)
                .appFont(11, design: .rounded)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// ⚠️ 用 `LazyVGrid` 自适应列宽而不是写死列数：只有两格的时候写死三列会留一个空洞。
    private var grid: some View {
        let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(items) { item in
                tile(item)
            }
        }
    }

    private func tile(_ item: Achievement) -> some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: item.isUnlocked ? "checkmark.seal.fill" : "seal")
                .appFont(15, weight: .semibold)
                .foregroundStyle(item.isUnlocked ? theme.success : theme.secondaryText.opacity(0.55))
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .appFont(12, weight: .semibold, design: .rounded)
                    .foregroundStyle(item.isUnlocked ? theme.primaryText : theme.secondaryText)
                    .lineLimit(1)
                // 已达成那格写「已达成」，未达成那格写「还差 N」——
                // 反过来（未达成写 0/N）等于让用户自己去做除法。
                Text(item.remainingText ?? "已达成")
                    .appFont(10, design: .rounded)
                    .foregroundStyle(item.isUnlocked ? theme.success : theme.secondaryText)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .appPadding(9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(item.isUnlocked ? theme.success.opacity(0.10) : theme.surfaceAlt.opacity(0.7))
        )
        .overlay(alignment: .bottom) {
            // 进度条：只画在未达成那几格上（已达成就是满的，再画一条是在暗示还有一半路）。
            if !item.isUnlocked {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.divider)
                        Capsule()
                            .fill(theme.accent)
                            .frame(width: max(proxy.size.width * CGFloat(item.progress), 0))
                    }
                }
                .frame(height: 3)
            }
        }
        .accessibilityLabel("\(item.title)，\(item.remainingText ?? "已达成")")
    }
}
