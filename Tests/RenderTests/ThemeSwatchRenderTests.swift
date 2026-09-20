import AppKit
import AppUI
import SwiftUI
import XCTest

/// 「黄这一族怎么定档」的**离屏留档**。
///
/// 并排摆出**三个阶段**的同一组控件，直接出图 —— 让人一眼看出差在哪，而不是听描述：
///
/// 1. `original`：最初那支高亮黄（`0xFFB703` / `0xFFD98A`）。用户原话是
///    「白天看不清、夜晚太刺眼」。
/// 2. `dimmed`：09-16 上午为修上面那句而压暗的一版（`0xB07C12` 承白字）。
///    用户随即反馈「白天的颜色已经变成棕色了」。
/// 3. `current`：现在这版（白档亮金底 `0xEAC541` 承深墨字；夜档保持不变）。
///    金底后来按用户口径「再亮半档」从 `0xE0B833` 提到 `0xEAC541`（同一档，不另开一列）。
///
/// ⚠️ 前两档的色号**刻意写死**：它们记录的是「过去的样子」，不跟着主题令牌走
/// —— 令牌以后再变，这两列也不该跟着变，否则对照就失效了。
@MainActor
final class ThemeSwatchRenderTests: XCTestCase {

    private var window: NSWindow?

    /// 对照的三个阶段。前两档是历史快照，第三档读当前令牌。
    private enum Stage: CaseIterable {
        case original
        case dimmed
        case current
    }

    private enum Snapshot {
        /// 最初那支高亮黄。
        static let brightDay = Color(hex: 0xFFB703)
        static let brightNight = Color(hex: 0xFFD98A)
        /// 最原来的 `Color.orange`（散在各处硬编码的那支）。
        static let oldWarning = Color(hex: 0xFF9500)
        /// 09-16 上午压暗的那一版。
        static let dimDay = Color(hex: 0x96670E)
        static let dimNight = Color(hex: 0xD2A34C)
        static let dimFillDay = Color(hex: 0xB07C12)
        static let dimFillNight = Color(hex: 0xA87B26)
    }

    // MARK: - 对照板

    private struct TokenBoard: View {

        @Environment(\.forestTheme) private var theme
        let stage: Stage

        /// 当文字 / 描边用的那支。
        private var base: Color {
            switch stage {
            case .original: theme.isNight ? Snapshot.brightNight : Snapshot.brightDay
            case .dimmed: theme.isNight ? Snapshot.dimNight : Snapshot.dimDay
            case .current: theme.accent
            }
        }

        /// 当底用的那支（胶囊填充）。
        private var fill: Color {
            switch stage {
            case .original: theme.isNight ? Snapshot.brightNight : Snapshot.brightDay
            case .dimmed: theme.isNight ? Snapshot.dimFillNight : Snapshot.dimFillDay
            case .current: theme.accentFill
            }
        }

        /// 压在填充色上的字色。历史两档都写死白字（那正是当时的样子 / 当时的问题）。
        private var ink: Color {
            switch stage {
            case .original, .dimmed: .white
            case .current: theme.onAccentFill
            }
        }

        private var warn: Color {
            stage == .original ? Snapshot.oldWarning : theme.warning
        }

        private var title: String {
            switch stage {
            case .original: "① 最初（亮黄）"
            case .dimmed: "② 上午那版（棕）"
            case .current: "③ 现在（金）"
            }
        }

        private var caption: String {
            switch stage {
            case .original: "白天看不清 / 夜晚刺眼"
            case .dimmed: "对比度够了，但发褐"
            case .current: theme.isNight ? "夜档保持不动" : "亮金底 + 深墨字"
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Text(caption)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }

                // ① 主按钮：黄底 + 字（截图里那颗「开始复习」）
                HStack(spacing: 5) {
                    Image(systemName: "play.fill")
                    Text("开始复习")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(fill))

                // ② 描边按钮：透明黄底 + 黄字（截图里那颗「回到最初」）
                HStack(spacing: 5) {
                    Image(systemName: "arrow.uturn.backward")
                    Text("回到最初")
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(base)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(base.opacity(0.12)))
                .overlay(Capsule().strokeBorder(base.opacity(0.35), lineWidth: 1))

                // ③ 提示条：淡黄底 + 告警图标
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(warn)
                    Text("这里是一条提示")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(warn.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(warn.opacity(0.35), lineWidth: 1)
                )

                // ④ 当文字用：音标那种小字（截图里最难认的一处）
                Text("美 /ˈdʒentl/")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(base)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .overlay(Capsule().strokeBorder(theme.divider, lineWidth: 1))

                // ⑤ 插画用的亮黄：只画太阳，不跟着降
                HStack(spacing: 8) {
                    Circle()
                        .fill(RadialGradient(colors: [Color(hex: 0xFFF0B8), theme.glow],
                                             center: .center, startRadius: 2, endRadius: 16))
                        .frame(width: 24, height: 24)
                    Text("太阳（插画，不跟着降）")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .padding(16)
            .frame(width: 250, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(theme.divider, lineWidth: 1)
            )
        }
    }

    private struct Board: View {
        var body: some View {
            HStack(alignment: .top, spacing: 14) {
                ForEach(Stage.allCases, id: \.self) { stage in
                    TokenBoard(stage: stage)
                }
            }
            .padding(18)
        }
    }

    // MARK: - 出图

    private func render(_ view: AnyView, day: Bool) throws -> (NSBitmapImageRep, CGSize) {
        let theme = ForestThemeResolver.resolve(mode: day ? .day : .night, systemIsDark: !day)
        let backdrop: Color = day ? Color(hex: 0xE9EFE4) : Color(hex: 0x101B2E)
        let host = NSHostingView(rootView: AnyView(view.forestTheme(theme).background(backdrop)))
        host.frame = NSRect(x: 0, y: 0, width: 860, height: 460)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let size = CGSize(width: 860, height: max(120, ceil(host.fittingSize.height)))
        host.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return (rep, size)
    }

    private func dump(_ rep: NSBitmapImageRep, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name))
    }

    func testDumpsThreeStageBoardForBothThemes() throws {
        let day = try render(AnyView(Board()), day: true)
        let night = try render(AnyView(Board()), day: false)
        try dump(day.0, name: "round40-yellow-tokens-day.png")
        try dump(night.0, name: "round40-yellow-tokens-night.png")
        XCTAssertGreaterThan(day.1.height, 200)
        XCTAssertGreaterThan(night.1.height, 200)
    }
}
