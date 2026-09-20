import AppKit
import SwiftUI

/// 应用标志（侧边栏左上角）。
///
/// 默认渲染品牌位图 `Resources/Brand/brand-logo.png`
/// （源图 `Scripts/brand/yulin-app-icon.png`，由 `Scripts/make_icons.sh` 生成）。
///
/// ⚠️ **位图读不到时降级为内置矢量树苗**，不崩溃也不留空：
/// 资源没打进包属于打包事故，应该表现为「图标退化成旧样式」，
/// 而不是整个应用起不来（侧边栏是每个页面都渲染的，一炸全白屏）。
/// 打包是否真的带上了位图，由 `AppLogoRenderTests` 断言 —— 别靠肉眼。
public struct AppLogo: View {

    let size: CGFloat

    public init(size: CGFloat = 40) { self.size = size }

    @Environment(\.forestTheme) private var theme

    public var body: some View {
        Group {
            if let image = BrandLogo.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    // 母版本身是圆角方形（四角透明），不需要再裁圆角。
                    // 阴影用主题令牌：夜色下要更沉，白天要更淡，硬编码色值两块都不对。
                    .shadow(color: theme.shadow, radius: size * 0.12, x: 0, y: size * 0.05)
                    .accessibilityHidden(true)   // 右侧已有「语林」文字，避免读屏念两遍
            } else {
                vectorFallback
            }
        }
        .frame(width: size, height: size)
    }

    /// 降级外观：森林绿底 + 白色小树苗 + 星星（原纯矢量实现，无外部资源）。
    private var vectorFallback: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [theme.foliage, theme.foliageDeep],
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
                .fill(theme.star)
                .frame(width: size * 0.11, height: size * 0.11)
                .offset(x: size * 0.02, y: -size * 0.26)
        }
        .frame(width: size, height: size)
        .shadow(color: theme.shadow, radius: size * 0.12, x: 0, y: size * 0.05)
    }
}

/// 品牌位图的一次性解码缓存。
///
/// 侧边栏头部的 body 在每次消息到达时都会重算，逐帧新建 `NSImage` 会白烧解码；
/// 同时这也让「位图到底有没有读到」有一个可被测试断言的唯一落点。
@MainActor
enum BrandLogo {
    static let image: NSImage? = UIAssetBundle.brandAssetURL("brand-logo")
        .flatMap { NSImage(contentsOf: $0) }
}
