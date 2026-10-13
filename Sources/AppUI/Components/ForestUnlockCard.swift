import AIDomain
import SwiftUI

/// 森林解锁预告（⑦-C③）：林子里现有几位、下一位是谁、还差多少。
///
/// ⚠️ 这一行跟林子里**真的那几只**同源：`ForestUnlock` 给数、`AnimalKind.unlockOrder` 给顺序，
/// 地面带（`ForestGroundBand`）取的是同一个顺序的前 N 个 —— 两边不一致就会
/// 「写着小刺猬要来，来的却是小狐狸」。
struct ForestUnlockCard: View {

    @Environment(\.forestTheme) private var theme

    /// 已经在林子里的（顺序即 `AnimalKind.unlockOrder` 的前 N 位）。
    var companions: [AnimalKind]
    /// 下一位要来的（nil = 满员）。
    var next: AnimalKind?
    var headline: String
    var preview: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            lineup
            footer
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
        HStack(spacing: 7) {
            Image(systemName: "pawprint.fill")
                .appFont(12, weight: .semibold)
                .foregroundStyle(theme.accent)
            Text("林子里的伙伴")
                .appFont(13, weight: .bold, design: .rounded)
                .foregroundStyle(theme.primaryText)
            Spacer(minLength: 0)
            Text(headline)
                .appFont(11, design: .rounded)
                .foregroundStyle(theme.secondaryText)
                .monospacedDigit()
        }
    }

    /// 一排伙伴 + 一个还没到的位子。
    ///
    /// ⚠️ 没到的那只画成**半透明 + 虚线圈**，不画成一个灰团：看得见是谁，
    /// 才有「再练一会儿把它请来」的念头。
    private var lineup: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(companions, id: \.self) { kind in
                    CuteAnimalView(kind: kind, isSleeping: false, size: 34)
                        .accessibilityLabel(kind.displayName)
                }
                if let next {
                    VStack(spacing: 2) {
                        CuteAnimalView(kind: next, isSleeping: false, size: 34)
                            .opacity(0.35)
                        Text("下一位")
                            .appFont(9, weight: .medium, design: .rounded)
                            .foregroundStyle(theme.secondaryText)
                    }
                    .accessibilityLabel("下一位伙伴：\(next.displayName)")
                }
            }
            .appPadding(.vertical, 2)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: next == nil ? "checkmark.circle.fill" : "clock.badge.questionmark")
                .appFont(10, weight: .semibold)
                .foregroundStyle(next == nil ? theme.success : theme.accent)
            Text(preview)
                .appFont(11, design: .rounded)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
