import SwiftUI

/// 一条界面提示条（#283：**失败那几条自带「重试」**）。
///
/// 词典页、词汇本页、复习卡三处原来各写了一份一模一样的横条 —— 合成一个以后，
/// 「重试」这个按钮只需要写一次，也不会出现「某处漏挂、用户只能自己再点一遍原来的按钮」。
///
/// ⚠️ 带动作的提示用**警示图标 + 橘色**，告知类的用信息图标 + 强调色：
/// 一眼能分出「这条要我做点什么」和「这条只是说一声」。
struct NoticeBanner: View {

    @Environment(\.forestTheme) private var theme

    let notice: AppNotice
    var onDismiss: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: hasAction ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(hasAction ? theme.warning : theme.accent)
            Text(notice.text)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.primaryText.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action = notice.action {
                Button(action: action.run) {
                    Text(action.title)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.onAccentFill)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(theme.accentFill))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(action.title)：把刚才失败的这一步再做一次")
                .accessibilityLabel("\(action.title)：\(notice.text)")
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
            }
            .buttonStyle(.plain)
            .help("关掉这条提示")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.accent.opacity(0.08))
        )
    }

    private var hasAction: Bool { notice.action != nil }
}
