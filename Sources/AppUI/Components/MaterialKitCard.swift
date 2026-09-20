import AIDomain
import AppCore
import SwiftUI

/// 「我的材料」单张卡（情景选择面板内）。
///
/// 一份材料拆出三样东西，卡上把三样都报数并各给一个去处：
/// 开始情景（对话链路）/ 练跟读句（跟读页）/ 删除（生词已进词汇本，不回收）。
struct MaterialKitCard: View {

    let kit: MaterialKit
    @Bindable var state: AppState
    @Environment(\.forestTheme) private var theme
    @State private var confirmingDelete = false

    private var title: String { kit.scenario?.titleZh ?? kit.title }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.accent)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.surfaceAlt)
                    )

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    HStack(spacing: 8) {
                        chip("\(kit.drills.count) 句跟读")
                        chip("\(kit.words.count) 个生词")
                        if kit.scenario != nil {
                            chip("情景可练")
                        }
                    }
                }

                Spacer(minLength: 0)

                Text(Self.dateText(kit.createdAt))
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText.opacity(0.8))
            }

            if !kit.excerpt.isEmpty {
                Text(kit.excerpt)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText.opacity(0.9))
                    .lineLimit(2)
            }

            HStack(spacing: 10) {
                Text("生词已自动收进词汇本。")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText.opacity(0.85))
                Spacer(minLength: 0)
                if confirmingDelete {
                    Button {
                        Task {
                            await state.deleteMaterialKit(id: kit.id)
                        }
                    } label: {
                        Text("确认删除")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.warning)
                    }
                    .buttonStyle(.plain)
                    .help("删除这份材料（已加入词汇本的词不受影响）")
                    Button {
                        confirmingDelete = false
                    } label: {
                        Text("取消")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        confirmingDelete = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .help("删除这份材料")
                    .accessibilityLabel("删除材料 \(title)")
                }
                if kit.scenario != nil {
                    Button {
                        Task { await state.startMaterialScenario(kit) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                            Text("开始情景")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(theme.onAccentFill)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(theme.accentFill))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("用这个情景和老师对练")
                }
                Button {
                    state.useMaterialDrills(kit)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "waveform").font(.system(size: 9, weight: .bold))
                        Text("练跟读句")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().strokeBorder(theme.accent.opacity(0.5), lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("去跟读页逐句磨这 \(kit.drills.count) 句")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.surfaceAlt.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.divider, lineWidth: 1)
        )
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, design: .rounded))
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(theme.hover))
    }

    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }
}
