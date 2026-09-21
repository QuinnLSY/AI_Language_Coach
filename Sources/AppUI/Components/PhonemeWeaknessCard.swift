import AIDomain
import SwiftUI

/// 顽固音素卡：把「跨很多次跟读」攒出来的错音摆出来，并直通一轮专项练习。
///
/// 为什么值得单独占一块：每次跟读完只看到「这次 72 分」，看不出**哪个音**在拖后腿。
/// 把这些音跨次聚合出来，练习才有靶子 —— 中文母语者的问题高度集中在少数几个音上，
/// 对着这几个音练，比继续泛泛跟读快得多。
///
/// ⚠️ 只在**真有顽固音素**时才挂出来（`weaknesses` 非空）。没有数据时挂一张空卡，
/// 等于凭空多一个让人困惑的区块；「数据还不够」是这个功能的正常状态，不是异常。
public struct PhonemeWeaknessCard: View {

    @Environment(\.forestTheme) private var theme

    private let weaknesses: [PhonemeWeakness]
    /// 当前是不是正在练专项（是的话显示「退出」而不是「开始」）。
    private let isDrillActive: Bool
    /// 专项正在练哪个音（ARPAbet；nil = 不在专项里）。
    private let activePhoneme: String?
    private let onStart: (PhonemeWeakness) -> Void
    private let onExit: () -> Void

    public init(
        weaknesses: [PhonemeWeakness],
        isDrillActive: Bool,
        activePhoneme: String?,
        onStart: @escaping (PhonemeWeakness) -> Void,
        onExit: @escaping () -> Void
    ) {
        self.weaknesses = weaknesses
        self.isDrillActive = isDrillActive
        self.activePhoneme = activePhoneme
        self.onStart = onStart
        self.onExit = onExit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ForEach(weaknesses) { weakness in
                row(weakness)
            }
            if isDrillActive {
                exitRow
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.surface)
                .shadow(color: theme.shadow, radius: 8, x: 0, y: 3)
        )
    }

    // MARK: - 分段

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.accent)
                Text("老发错的音")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
            }
            Text("挑一个音，用只差这一个音的词对来练")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(theme.secondaryText)
        }
    }

    private func row(_ weakness: PhonemeWeakness) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(weakness.display)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(theme.accent)
                .frame(width: 34, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text("\(weakness.sampleCount) 次里错了 \(weakness.missCount) 次")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Text(pairPreview(weakness))
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            drillButton(weakness)
        }
    }

    /// 这一音素用哪对词来练（让用户点之前就知道要读什么）。
    private func pairPreview(_ weakness: PhonemeWeakness) -> String {
        guard let pair = MinimalPairCatalog.pairs(for: weakness.phoneme).first else {
            return "这个音暂时没有合适的词对"
        }
        return "\(pair.left) / \(pair.right)"
    }

    private func drillButton(_ weakness: PhonemeWeakness) -> some View {
        let hasPairs = !MinimalPairCatalog.pairs(for: weakness.phoneme).isEmpty
        return Button {
            onStart(weakness)
        } label: {
            Text(isDrillActive && activePhoneme == weakness.phoneme ? "正在练" : "练这个音")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(hasPairs ? theme.accentCool : theme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .strokeBorder(hasPairs ? theme.accentCool.opacity(0.5) : theme.divider, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        // ⚠️ 词表里没有对应词对的音素不给点：点了没反应比不给点更让人困惑，
        // 而硬凑一对（比如拿毫不相干的两个音）练的就不是最小对立对了。
        .disabled(!hasPairs)
        .help(hasPairs ? "用最小对立对练这个音" : "这个音暂时没有合适的词对")
    }

    private var exitRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.uturn.left")
                .font(.system(size: 10))
                .foregroundStyle(theme.secondaryText)
            Text("练完这一轮可以回到今日跟读")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                onExit()
            } label: {
                Text("回到今日跟读")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 2)
    }
}
