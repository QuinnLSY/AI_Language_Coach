import AIDomain
import SwiftUI

/// 复习的限时连击条（⑦-C①）。
///
/// 一张只有两副脸的小条：**跑着**（倒计时 + 连击）/ **到点了**（这一轮的成绩 + 再来一轮）。
///
/// ⚠️ 本视图**不抓 `Date()`**：倒计时那几个字由状态源每秒写进来（`reviewBlitzRemaining`），
/// 这里只把它摆出来。视图自己读时钟的结果是「同一时刻两个数」—— 状态源判词用的是那一秒，
/// 界面画的是这一秒，两边对不上就会出现「判完还剩 1 秒，下一拍变回 2 秒」。
/// ⚠️ 不写 `.buttonStyle(.plain)`：按压反馈由所在页面的根注入（见 `MotionTokenWiringTests`）。
struct BlitzBar: View {

    @Environment(\.forestTheme) private var theme

    /// 连击本体（只用来取「连对几个 / 最高几个 / 这一轮的成绩」这些不随时间变的量）。
    var blitz: ReviewBlitz
    /// 倒计时还剩几秒（0 = 到点）。
    var remaining: Int
    /// 历史纪录。
    var record: Int
    /// 这一轮是不是破了纪录。
    var isNewRecord: Bool
    var onRestart: () -> Void

    private var expired: Bool { remaining <= 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            titleRow
            if expired {
                settledRow
            } else {
                timeBar
                comboRow
            }
        }
        .appPadding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(theme.accent.opacity(expired ? 0.18 : 0.45), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    // MARK: - 各块

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "flame.fill")
                .appFont(12, weight: .semibold)
                .foregroundStyle(theme.accent)
            Text("限时连击")
                .appFont(12, weight: .bold, design: .rounded)
                .foregroundStyle(theme.primaryText)
            Spacer(minLength: 0)
            Text(ReviewBlitz.countdownText(remaining: remaining))
                .appFont(12, weight: .semibold, design: .rounded)
                .foregroundStyle(expired ? theme.secondaryText : theme.accent)
                .monospacedDigit()
        }
    }

    /// 时间条：越走越短。**看得见的时间**才是这一件好玩的地方。
    private var timeBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.surfaceAlt)
                Capsule()
                    .fill(theme.accent)
                    .frame(width: max(proxy.size.width * fraction, 0))
            }
        }
        .frame(height: 6)
        .accessibilityLabel("这一轮还剩 \(remaining) 秒")
    }

    private var fraction: CGFloat {
        let window = Double(max(ReviewBlitz.windowSeconds, 1))
        return CGFloat(min(max(Double(remaining) / window, 0), 1))
    }

    private var comboRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(blitz.comboText)
                .appFont(17, weight: .bold, design: .rounded)
                .foregroundStyle(theme.primaryText)
                .monospacedDigit()
            if blitz.bestCombo > 0 {
                Text("最高 \(blitz.bestCombo)")
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            if record > 0 {
                Text("纪录 \(record)")
                    .appFont(11, weight: .medium, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .monospacedDigit()
            }
        }
    }

    /// 到点了：给一句成绩 + 一颗「再来一轮」。
    ///
    /// ⚠️ 破纪录才挂那枚徽章 —— 见 `ReviewBlitzRecord.badgeTitle`：
    /// 第一次用就弹「新纪录」是在笑人（连击 0 不算破纪录）。
    private var settledRow: some View {
        HStack(spacing: 10) {
            Text(blitz.summaryText)
                .appFont(12, weight: .medium, design: .rounded)
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            if isNewRecord {
                Text(ReviewBlitzRecord.badgeTitle)
                    .appFont(11, weight: .bold, design: .rounded)
                    .foregroundStyle(theme.onAccentFill)
                    .padding(.horizontal, 8)
                    .appPadding(.vertical, 3)
                    .background(Capsule().fill(theme.accentFill))
            }
            Spacer(minLength: 0)
            Button {
                onRestart()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                    Text("再来一轮")
                }
                .appFont(11, weight: .semibold, design: .rounded)
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 10)
                .appPadding(.vertical, 5)
                .background(Capsule().fill(theme.accent.opacity(0.12)))
                .contentShape(Capsule())
            }
            .help("再抢一轮 60 秒")
        }
    }
}
