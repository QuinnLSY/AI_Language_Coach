import AIDomain
import SwiftUI

/// 情景练完的**课程覆盖度**卡片（P1-2：CEFR 课程体系）。
///
/// 与 `RewardToast` 的分工（两者会同时出现，各说一件事）：
/// - `RewardToast` 说的是**参与度**：说了几轮 → 拿了几颗星；
/// - 这一张说的是**内容覆盖**：这一关的目标句 / 目标词真的说出了几个。
///
/// 刻意分成两张卡：说满 14 轮但全是 `yes` / `ok` 也能拿满星，
/// 目标句却一句没说 —— 混成一条提示就必然要在其中一件事上说谎。
///
/// 三条文案纪律：
/// 1. **达标就说达标，没达标就说差多少**（`reasons` 逐条都由 `CurriculumScorer` 算出来）；
/// 2. 没说不等于说错 —— 这里不出现「发音不对」这类评价，只说「还没说到」；
/// 3. 分数只来自学员真说过的话，卡片上不出现「预估」「大概」。
struct CurriculumVerdictCard: View {

    @Environment(\.forestTheme) private var theme

    let assessment: CurriculumAssessment
    /// 情景的中文名（让学员知道这是哪一关的判定）。
    let scenarioTitle: String
    var onClose: (() -> Void)? = nil
    /// 离屏渲染测试用：关掉底色才不会让整宽背景糊住墨迹边界。
    var showsContainer: Bool = true

    /// 过关用的绿（与「今天」卡片、「今日任务」同一个色）。
    private let passedGreen = Color(hex: 0x8FD694)
    /// 「就差一点」用的琥珀（与记录页「再练练」同一个色）。
    private let closeAmber = Color(hex: 0xF7B32B)

    private var tint: Color {
        switch assessment.verdict {
        case .passed: passedGreen
        case .close: closeAmber
        case .notYet: theme.secondaryText
        }
    }

    private var icon: String {
        switch assessment.verdict {
        case .passed: "checkmark.seal.fill"
        case .close: "target"
        case .notYet: "arrow.clockwise.circle.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Text(assessment.summary)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(assessment.reasons.enumerated()), id: \.offset) { _, reason in
                    reasonRow(reason)
                }
            }
            Text("这一关按 \(assessment.level.code)（\(assessment.level.displayName)）的标准判定：\(assessment.level.passCriteria.summary(maxTurns: assessment.coverage.maxTurns))。")
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(showsContainer ? 14 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if showsContainer {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(theme.panel)
                    .shadow(color: theme.shadow, radius: 14, x: 0, y: 6)
            }
        }
        .overlay {
            if showsContainer {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(theme.divider, lineWidth: 1)
            }
        }
    }

    // MARK: - 头

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(assessment.level.code)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .frame(height: 15)
                        .background(Capsule().fill(tint))
                    Text("\(scenarioTitle) · \(assessment.verdict.headline)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                }
                Text("课程覆盖度")
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }

            Spacer(minLength: 8)

            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(theme.hover))
                }
                .buttonStyle(.plain)
                .help("收起")
            }
        }
    }

    // MARK: - 逐条原因

    private func reasonRow(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Circle()
                .fill(tint.opacity(0.75))
                .frame(width: 3, height: 3)
                .padding(.top, 5)
            Text(reason)
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        }
    }
}
