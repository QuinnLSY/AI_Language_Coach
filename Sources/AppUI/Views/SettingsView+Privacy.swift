import AppKit
import SwiftUI

// #662 自 SettingsView.swift 拆出（2026-10-24）：原文件 3227 行、单结构体 22 个 MARK 段，按主题分文件。
// 同模块移动，语义与拆分前完全一致；跨文件引用的成员已从 private 放宽到 internal
// （模块内可见，跨模块零影响，public API 不变）。

extension SettingsView {
    // MARK: - 隐私与安全（本地优先 + 外发披露）

    var privacyCard: some View {
        card(title: "隐私与安全", systemImage: "lock.shield.fill") {
            VStack(alignment: .leading, spacing: 10) {
                let report = state.privacyReport
                let disclosure = report.disclosure

                HStack(spacing: 6) {
                    Image(systemName: disclosure.isLocalOnly ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                        .appFont(12)
                        .foregroundStyle(disclosure.isLocalOnly ? .green : theme.warning)
                    Text(disclosure.summary)
                        .appFont(12, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.primaryText)
                }

                // 有外发就得把「谁、发到哪、发了什么」摊开给用户看——
                // 这是 §33 的硬要求：云端功能必须显式启用并明确披露。
                if !disclosure.flows.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(disclosure.flows) { flow in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(flow.kind.displayName)
                                    .appFont(11, weight: .semibold, design: .rounded)
                                    .foregroundStyle(theme.accent)
                                Text(flow.displayName)
                                    .appFont(11, design: .rounded)
                                    .foregroundStyle(theme.primaryText)
                                Text(flow.host)
                                    .appFont(11, design: .monospaced)
                                    .foregroundStyle(theme.secondaryText)
                                Spacer(minLength: 4)
                                Text(flow.categories.map(\.displayName).joined(separator: "、"))
                                    .appFont(10, design: .rounded)
                                    .foregroundStyle(theme.secondaryText)
                            }
                        }
                    }
                }

                // 公共服务（#604 天气预报）与云端能力**分开一组**：它们没有供应商、
                // 没有模型，混在上一段里会让「谁在收走我的数据」这条信息变模糊。
                if !disclosure.publicServiceFlows.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(disclosure.publicServiceFlows) { flow in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(flow.service.displayName)
                                    .appFont(11, weight: .semibold, design: .rounded)
                                    .foregroundStyle(theme.accent)
                                Text(flow.host)
                                    .appFont(11, design: .monospaced)
                                    .foregroundStyle(theme.secondaryText)
                                Spacer(minLength: 4)
                                Text(flow.outboundNote)
                                    .appFont(10, design: .rounded)
                                    .foregroundStyle(theme.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Text("在设置里关掉「跟随天气」，这两项就不再被联系。")
                            .appFont(10, design: .rounded)
                            .foregroundStyle(theme.secondaryText)
                    }
                }

                Divider().overlay(theme.divider)

                // 数据存放位置
                Text("数据存放位置")
                    .appFont(12, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.primaryText)

                ForEach(report.locations) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Image(systemName: item.isSensitive ? "lock.fill" : "doc")
                                .appFont(9)
                                .foregroundStyle(item.isSensitive ? theme.accent : theme.secondaryText)
                            Text(item.title)
                                .appFont(12, design: .rounded)
                                .foregroundStyle(theme.primaryText)
                            Spacer(minLength: 6)
                            if let reveal = item.revealPath {
                                FinderRevealButton(path: reveal, compact: true)
                            }
                        }
                        Text(item.detail)
                            .appFont(10, design: .rounded)
                            .foregroundStyle(theme.secondaryText)
                        Text(item.path)
                            .appFont(10, design: .monospaced)
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }

                if !report.dataDirectory.isEmpty {
                    FinderRevealButton(path: report.dataDirectory)
                }

                Text("默认全部在本机处理：录音、转写、学习记忆与配置都不上传。只有你在「模型管理中心」启用了云端供应商，对应能力的数据才会发往上面列出的域名；日志与留痕只记录元数据，不记录你说的话。")
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    /// 「在 Finder 中打开」按钮。
    ///
    /// 打开目录这件事在 App 内部是**零副作用的**——界面哪里都不会变。
    /// 不给即时反馈，用户会以为自己没点上（Finder 窗口也可能藏在其它窗口后面）。
    /// 所以：按住缩一下 + 松开回弹，打开后短暂显示「已在 Finder 中打开」。
    struct FinderRevealButton: View {
        @Environment(\.forestTheme) private var theme
        @State private var isPressing = false
        @State private var didOpen = false
        @State private var revertTask: Task<Void, Never>?

        let path: String
        /// 按钮文案（默认是数据根目录那句）。
        var title: String = "在 Finder 中打开数据目录"
        /// 紧凑模式：只画一个图标。
        ///
        /// 「数据存放位置」列表里每一行都自带落点，六行各配一句完整文案会把卡片撑爆，
        /// 于是列表内只留图标（提示走 `.help`），卡片底部那颗才是完整按钮。
        var compact: Bool = false

        var body: some View {
            Button(action: reveal) {
                HStack(spacing: 5) {
                    Image(systemName: didOpen ? "checkmark.circle.fill" : (isPressing ? "folder.fill" : "folder"))
                        .appFont(11)
                    if !compact {
                        Text(didOpen ? "已在 Finder 中打开" : title)
                            .appFont(12, weight: .semibold, design: .rounded)
                    }
                }
                .foregroundStyle(didOpen ? .green : theme.accent)
                .padding(.horizontal, compact ? 6 : 9)
                .padding(.vertical, compact ? 3 : 5)
                .background(Capsule().fill(theme.surfaceAlt))
                .scaleEffect(isPressing ? 0.94 : 1)
                .contentShape(Capsule())
            }
            .buttonStyle(.appPressable)
            .help(path)
            // simultaneous 而非 gesture：保留 Button 自身的点击语义。
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in withAnimation(.app(.press)) { isPressing = true } }
                    .onEnded { _ in
                        withAnimation(.app(.press)) { isPressing = false }
                    }
            )
            .appAnimation(.reveal, value: didOpen)
        }

        private func reveal() {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            didOpen = true
            revertTask?.cancel()
            revertTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.app(.reveal)) { didOpen = false }
            }
        }
    }
}
