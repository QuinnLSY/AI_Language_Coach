import AIDomain
import AVKit
import AppKit
import SwiftUI

// MARK: - 待发送附件（输入框上方的胶囊行）

/// 还没发出去的附件：缩略图 / 图标 + 文件名 + 体积 + 移除。
///
/// 为什么要有这一行而不是「选了就直接发」：学员常常一次选两三张图再配一句话，
/// 中途还想删掉其中一张。选完即发会逼着他重来一遍。
struct AttachmentChip: View {

    @Environment(\.forestTheme) private var theme

    let attachment: ChatAttachment
    /// 本地文件位置（nil = 已被清理，用占位图标）。
    let fileURL: URL?
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            thumbnail
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.fileName)
                    .appFont(11, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(attachment.kind.displayName) · \(attachment.sizeText)")
                    .appFont(9, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .appFont(11)
                    .foregroundStyle(theme.secondaryText)
            }
            .buttonStyle(.appPressable)
            .help("移除这个附件")
        }
        .padding(.horizontal, 8)
        .appPadding(.vertical, 5)
        .frame(maxWidth: 210)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.surfaceAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.divider, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var thumbnail: some View {
        if attachment.isImage, let fileURL, let image = NSImage(contentsOf: fileURL) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(systemName: attachment.kind.systemImage)
                .appFont(12)
                .foregroundStyle(theme.accent)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.hover)
                )
        }
    }
}

// MARK: - 消息里的附件（气泡内渲染）

/// 一条消息里的附件视图：图片缩略图 / 视频播放器 / 文件卡，右下角统一带下载按钮。
struct MessageAttachmentView: View {

    @Environment(\.forestTheme) private var theme

    let attachment: ChatAttachment
    let fileURL: URL?
    /// 点「下载」。
    var onDownload: () -> Void

    var body: some View {
        Group {
            switch attachment.kind {
            case .image: imageBody
            case .video: videoBody
            case .file: fileBody
            }
        }
        .overlay(alignment: .bottomTrailing) { downloadButton }
    }

    // MARK: 图片

    @ViewBuilder
    private var imageBody: some View {
        if let fileURL, let image = NSImage(contentsOf: fileURL) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 260, maxHeight: 260)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(theme.divider, lineWidth: 1)
                )
                // 点图看原图：用系统默认程序打开，不自己做全屏预览
                //（自建预览要处理缩放/多图切换/键盘，收益远小于成本）。
                .onTapGesture { AttachmentExporter.open(fileURL) }
                .help("点击用默认程序打开原图")
        } else {
            missingCard
        }
    }

    // MARK: 视频

    @ViewBuilder
    private var videoBody: some View {
        if let fileURL {
            InlineVideoPlayer(url: fileURL)
                .frame(width: 260, height: 146)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(theme.divider, lineWidth: 1)
                )
        } else {
            missingCard
        }
    }

    // MARK: 普通文件

    private var fileBody: some View {
        HStack(spacing: 9) {
            Image(systemName: attachment.kind.systemImage)
                .appFont(16)
                .foregroundStyle(theme.accent)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(theme.hover)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.fileName)
                    .appFont(12, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(attachment.sizeText)
                    .appFont(10, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
            }
            // 给右下角的下载按钮让出位置。
            Spacer(minLength: 26)
        }
        .padding(.horizontal, 10)
        .appPadding(.vertical, 8)
        .frame(width: 240, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(theme.surfaceAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(theme.divider, lineWidth: 1)
        )
    }

    /// 文件已被清理时的替身卡。**不静默留白**：让用户知道东西曾经在、现在没了。
    private var missingCard: some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .appFont(11)
                .foregroundStyle(theme.warning)
            Text("\(attachment.fileName) 的本地文件已不可用")
                .appFont(11, design: .rounded)
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .appPadding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.surfaceAlt)
        )
    }

    private var downloadButton: some View {
        Button(action: onDownload) {
            Image(systemName: "arrow.down.circle.fill")
                .appFont(17)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.black.opacity(0.45))
        }
        .buttonStyle(.appPressable)
        .disabled(fileURL == nil)
        .opacity(fileURL == nil ? 0.4 : 1)
        .appPadding(7)
        .help(fileURL == nil ? "本地文件已不可用" : "下载到本机")
    }
}

// MARK: - 内嵌视频播放器

/// 内嵌播放器：**播放器实例只建一次**。
///
/// `AVPlayer` 在 SwiftUI body 里现建现用会随每次重绘换一个新的 ——
/// 症状是「播到一半自己回到开头」并且内存一路涨。所以放进 `@State`，用 `.task` 建、用 `onDisappear` 停。
///
/// ⚠️ 这里**不用 SwiftUI 的 `VideoPlayer`**，而是包一层 AppKit 的 `AVPlayerView`。
/// 原因是 `VideoPlayer` 来自 `_AVKit_SwiftUI` —— 一个 AVKit × SwiftUI 的 **cross-import overlay**，
/// 而 SwiftPM 不会为这种 overlay 准备模块查找路径：编译能过，**一运行就崩**
/// （实测 `swift::fatalError` ← `getSuperclassMetadata` ← `_AVKit_SwiftUI`，
/// 整个应用在启动瞬间 EXC_CRASH/SIGABRT）。`AVPlayerView` 是普通 AppKit 类，
/// 不触发 overlay，代价只是多一层 `NSViewRepresentable`。
private struct InlineVideoPlayer: View {

    let url: URL

    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
            if let player {
                PlayerSurface(player: player)
            } else {
                ProgressView().controlSize(.small).tint(.white)
            }
        }
        .task {
            guard player == nil else { return }
            player = AVPlayer(url: url)
        }
        .onDisappear {
            player?.pause()
        }
    }
}

/// `AVPlayerView` 的 SwiftUI 包装：自带播放 / 暂停 / 进度 / 音量控件，
/// 与系统「快速查看」的手感一致，不自己造一套控件。
private struct PlayerSurface: NSViewRepresentable {

    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        // 允许用户按需要放大观看，但**不自动播放**：列表里同时挂多个视频时自动播放是灾难。
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

// MARK: - 附件导出（下载）

/// 附件的保存 / 打开。**下载就是「另存为」**，不是「在 Finder 里显示」——
/// 用户点下载图标期待的是把文件拿到手，而不是被带到文件所在目录。
enum AttachmentExporter {

    /// 打开「另存为」面板并复制文件。返回是否保存成功。
    @MainActor
    @discardableResult
    static func save(attachment: ChatAttachment, from sourceURL: URL) -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.fileName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "保存附件"
        panel.message = "选择保存位置（\(attachment.sizeText)）"
        guard panel.runModal() == .OK, let destination = panel.url else { return false }
        do {
            let manager = FileManager.default
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.copyItem(at: sourceURL, to: destination)
            return true
        } catch {
            // 失败要说出来：静默失败会让用户以为文件已经存好了。
            let alert = NSAlert()
            alert.messageText = "保存失败"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
            return false
        }
    }

    /// 用系统默认程序打开（点图片看原图）。
    @MainActor
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
