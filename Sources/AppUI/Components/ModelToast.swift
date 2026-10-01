import SwiftUI

/// 模型启停结果的一次性提示。
///
/// - 成功：绿色弹框（「…已启动：后台服务已拉起。」）
/// - 失败：红色弹框（「启动失败 · 本地模型 · qwen3:8b 服务未启动或不可达：…」）
public struct ModelToast: Sendable, Equatable, Identifiable {

    public let id: UUID
    public let message: String
    public let isSuccess: Bool

    public init(id: UUID = UUID(), message: String, isSuccess: Bool) {
        self.id = id
        self.message = message
        self.isSuccess = isSuccess
    }
}

/// 应用顶部最前方的启停结果弹框：向下弹入，数秒后向上收起。
///
/// 与情景结算提示（RewardToast）的区别：这块是**操作反馈**，
/// 必须能一眼分清成功还是失败，所以用实色绿 / 红而不是主题中性色。
struct ModelToastView: View {

    let toast: ModelToast
    var onClose: (() -> Void)? = nil

    private var tint: Color { toast.isSuccess ? Color.green : Color.red }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: toast.isSuccess ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .appFont(14, weight: .semibold)
                .foregroundStyle(.white)

            Text(toast.message)
                .appFont(13, weight: .semibold, design: .rounded)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)

            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .appFont(10, weight: .bold)
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.appPressable)
                .help("关闭提示")
            }
        }
        .padding(.horizontal, 14)
        .appPadding(.vertical, 10)
        .frame(maxWidth: 520)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tint)
                .shadow(color: tint.opacity(0.35), radius: 14, x: 0, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
        )
    }
}
