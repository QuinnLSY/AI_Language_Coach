import SwiftUI

/// 应用标志：森林绿底 + 白色小树苗 + 星星。纯矢量，无外部资源。
public struct AppLogo: View {

    let size: CGFloat

    public init(size: CGFloat = 40) { self.size = size }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x5FBF82), Color(hex: 0x2E7D55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // 树冠
            Circle().fill(.white.opacity(0.96)).frame(width: size * 0.30, height: size * 0.30).offset(y: -size * 0.09)
            Circle().fill(.white.opacity(0.88)).frame(width: size * 0.21, height: size * 0.21).offset(x: -size * 0.15, y: size * 0.02)
            Circle().fill(.white.opacity(0.88)).frame(width: size * 0.21, height: size * 0.21).offset(x: size * 0.15, y: size * 0.02)

            // 树干
            RoundedRectangle(cornerRadius: size * 0.03, style: .continuous)
                .fill(.white.opacity(0.92))
                .frame(width: size * 0.09, height: size * 0.24)
                .offset(y: size * 0.17)

            // 树顶的星
            Circle()
                .fill(Color(hex: 0xFFE08A))
                .frame(width: size * 0.11, height: size * 0.11)
                .offset(x: size * 0.02, y: -size * 0.26)
        }
        .frame(width: size, height: size)
        .shadow(color: Color(hex: 0x2E7D55).opacity(0.35), radius: size * 0.12, x: 0, y: size * 0.05)
    }
}
