import AppCore
import AppKit
import SwiftUI

// #662 自 SettingsView.swift 拆出（2026-10-24）：原文件 3227 行、单结构体 22 个 MARK 段，按主题分文件。
// 同模块移动，语义与拆分前完全一致；跨文件引用的成员已从 private 放宽到 internal
// （模块内可见，跨模块零影响，public API 不变）。

extension SettingsView {
    // MARK: - 缓存管理（大小 / 目录显示 + 清除）

    var cacheCard: some View {
        card(title: "存储与缓存", systemImage: "externaldrive.fill") {
            VStack(alignment: .leading, spacing: 10) {
                let snapshot = state.cacheSnapshot

                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .appFont(11)
                        .foregroundStyle(theme.accent)
                    Text(snapshot.directory.isEmpty ? "—" : snapshot.directory)
                        .appFont(11, design: .monospaced)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .help(snapshot.directory)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("合计占用")
                        .appFont(12, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                    Text(snapshot.totalDisplay)
                        .appFont(18, weight: .bold, design: .rounded)
                        .foregroundStyle(theme.primaryText)
                        .monospacedDigit()
                    Spacer()
                    Button {
                        Task { await state.refreshCacheInfo() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.appPressable)
                    .help("重新统计")
                    .accessibilityLabel("重新统计缓存占用")
                }

                // 明细：学习记忆加锁标记（清理时保留）；留痕单独点名（可清，但清的是对账证据）
                ForEach(snapshot.items) { item in
                    HStack(spacing: 6) {
                        Image(systemName: item.isLearningData ? "lock.fill" : (item.isCallLog ? "list.bullet.rectangle" : "doc"))
                            .appFont(9)
                            .foregroundStyle(item.isLearningData ? theme.accent : theme.secondaryText)
                        Text(item.name)
                            .appFont(12, design: .rounded)
                            .foregroundStyle(theme.primaryText)
                        if item.isLearningData {
                            Text("学习记忆")
                                .appFont(9, weight: .semibold, design: .rounded)
                                .foregroundStyle(theme.accent)
                                .padding(.horizontal, 5)
                                .appPadding(.vertical, 2)
                                .background(Capsule().fill(theme.accent.opacity(0.12)))
                        } else if item.isCallLog {
                            Text("对账留痕")
                                .appFont(9, weight: .semibold, design: .rounded)
                                .foregroundStyle(theme.warning)
                                .padding(.horizontal, 5)
                                .appPadding(.vertical, 2)
                                .background(Capsule().fill(theme.warning.opacity(0.12)))
                        }
                        Spacer()
                        Text(CacheSnapshot.byteCount(item.bytes))
                            .appFont(11, design: .rounded)
                            .foregroundStyle(theme.secondaryText)
                            .monospacedDigit()
                    }
                }

                HStack(spacing: 10) {
                    if state.cacheFreedBytes > 0 {
                        Label("已释放 \(CacheSnapshot.byteCount(state.cacheFreedBytes))", systemImage: "trash.slash")
                            .appFont(11, weight: .medium, design: .rounded)
                            .foregroundStyle(.green)
                    }
                    if let cleared = snapshot.lastClearedAt {
                        Text("上次清理：\(cleared.formatted(date: .abbreviated, time: .shortened))")
                            .appFont(11, design: .rounded)
                            .foregroundStyle(theme.secondaryText)
                    }
                    Spacer()
                    Button {
                        showClearConfirm = true
                    } label: {
                        HStack(spacing: 5) {
                            if isClearingCache {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "paintbrush.fill").appFont(11)
                            }
                            Text("清除缓存")
                                .appFont(12, weight: .semibold, design: .rounded)
                        }
                        .foregroundStyle(theme.onAccentFill)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.accentFill))
                    }
                    .buttonStyle(.appPressable)
                    .disabled(isClearingCache || snapshot.items.isEmpty)
                    .help("清理过期对话流水与对外调用留痕，并回收磁盘空间")
                }

                Text("清除只影响可再生的对话流水、数据库碎片与对外调用留痕（留痕会进废纸篓，可捞回）；学习记忆（错题本、进度）和配置始终保留。")
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.secondaryText)

                Divider().overlay(theme.divider)

                // 学习库被隔离重建必须让用户看见：不说，用户会以为旧记录还在。
                if let note = state.databaseRecoveryNote {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .appFont(11)
                            .foregroundStyle(theme.warning)
                        Text(note)
                            .appFont(11, design: .rounded)
                            .foregroundStyle(theme.primaryText)
                    }
                    Divider().overlay(theme.divider)
                }

                // 本轮启动应用了备份恢复：替换了什么要说清楚。
                if let note = state.restoreNote {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .appFont(11)
                            .foregroundStyle(theme.accent)
                        Text(note)
                            .appFont(11, design: .rounded)
                            .foregroundStyle(theme.primaryText)
                    }
                    Divider().overlay(theme.divider)
                }

                Text("数据备份")
                    .appFont(12, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.primaryText)

                // 自动备份（#415）：开关 + 间隔 + 「上次备份是多久以前」。
                // 后者**始终显示**（哪怕开关关着）——「还没备份过」这件事本身就该被看见。
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: Binding(
                        get: { state.autoBackupEnabled },
                        set: { on in Task { await state.setAutoBackupEnabled(on) } }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("自动备份")
                                .appFont(13, design: .rounded)
                            Text(autoBackupHint)
                                .appFont(11, design: .rounded)
                                .foregroundStyle(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if state.autoBackupEnabled {
                        HStack(spacing: 4) {
                            Text("间隔")
                                .appFont(11, design: .rounded)
                                .foregroundStyle(theme.secondaryText)
                            ForEach(Self.autoBackupIntervals, id: \.self) { days in
                                autoBackupIntervalChip(days)
                            }
                        }
                    }
                }

                if let notice = state.autoBackupNotice {
                    NoticeBanner(notice: notice) { state.dismissAutoBackupNotice() }
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await state.exportBackup() }
                    } label: {
                        HStack(spacing: 5) {
                            if state.isExportingBackup {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "square.and.arrow.down.fill").appFont(11)
                            }
                            Text("导出备份")
                                .appFont(12, weight: .semibold, design: .rounded)
                        }
                        .foregroundStyle(theme.onAccentFill)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.accentFill))
                    }
                    .buttonStyle(.appPressable)
                    .disabled(state.isExportingBackup)
                    .help("把学习库、配置和调用留痕打包成一个带时间戳的 zip")

                    Button {
                        chooseBackupToImport()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "square.and.arrow.up.fill").appFont(11)
                            Text("导入备份")
                                .appFont(12, weight: .semibold, design: .rounded)
                        }
                        .foregroundStyle(theme.primaryText)
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(theme.surface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(theme.divider, lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.appPressable)
                    .disabled(state.isExportingBackup)
                    .help("从备份 zip 恢复学习库与配置（重启后生效，恢复前会自动留底当前数据）")

                    if let first = state.backupSnapshots.first {
                        Text("最近备份：\(first.fileName)")
                            .appFont(11, design: .rounded)
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer()
                }

                // 导入确认框：替换范围、自动留底、重启生效，三件事都要说清楚。
                .alert(
                    "用这份备份恢复？",
                    isPresented: $showImportConfirm,
                    presenting: state.backupImportPlan
                ) { plan in
                    Button("恢复并重启后生效", role: .destructive) {
                        Task { await state.confirmBackupImport() }
                    }
                    Button("取消", role: .cancel) {
                        state.cancelBackupImport()
                    }
                } message: { plan in
                    Text(
                        "将替换：\(plan.scopeDescription)\(plan.includesCallLog ? "、调用留痕" : "")。\n"
                        + "替换前会自动把当前数据再备份一份；恢复在重启应用时生效。"
                    )
                }

                HStack(spacing: 8) {
                    Text("备份包（保留最近 \(Self.maxKeptBackups) 份，自动清理）")
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                    if let total = state.backupTotalText {
                        Text("共 \(total)")
                            .appFont(11, design: .rounded)
                            .foregroundStyle(theme.secondaryText)
                            .monospacedDigit()
                    }
                    Spacer()
                    Button {
                        Task { await state.revealBackupsInFinder() }
                    } label: {
                        Image(systemName: "folder").appFont(11)
                    }
                    .buttonStyle(.appPressable)
                    .help("在 Finder 中打开备份目录（可自行拷走或整理）")
                    .accessibilityLabel("在 Finder 中打开备份目录")
                }

                ForEach(state.backupSnapshots.prefix(3)) { item in
                    HStack(spacing: 6) {
                        Image(systemName: "archivebox.fill")
                            .appFont(9)
                            .foregroundStyle(theme.secondaryText)
                        Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .appFont(11, design: .rounded)
                            .foregroundStyle(theme.primaryText)
                        Spacer()
                        Text(item.sizeDisplay)
                            .appFont(11, design: .rounded)
                            .foregroundStyle(theme.secondaryText)
                            .monospacedDigit()
                        Button {
                            Task { await state.deleteBackup(at: item.url) }
                        } label: {
                            Image(systemName: "trash").appFont(10)
                        }
                        .buttonStyle(.appPressable)
                        .help("删除这份备份（移入废纸篓，可恢复）")
                        .accessibilityLabel("删除备份：\(item.fileName)")
                    }
                }
                if state.backupSnapshots.count > 3 {
                    Button {
                        Task { await state.revealBackupsInFinder() }
                    } label: {
                        Text("还有 \(state.backupSnapshots.count - 3) 份更早的备份，在 Finder 中查看")
                            .appFont(11, design: .rounded)
                            .foregroundStyle(theme.accent)
                    }
                    .buttonStyle(.appPressable)
                    .help("打开备份目录")
                }

                // 已安排恢复：如实说明何时生效、替换了什么。
                if let notice = state.backupImportNotice {
                    HStack(alignment: .top, spacing: 6) {
                        Label(notice, systemImage: "checkmark.circle.fill")
                            .appFont(11, design: .rounded)
                            .foregroundStyle(theme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 6)
                        Button {
                            state.dismissBackupImportNotice()
                        } label: {
                            Image(systemName: "xmark")
                                .appFont(9, weight: .semibold)
                                .foregroundStyle(theme.secondaryText)
                        }
                        .buttonStyle(.appPressable)
                        .help("知道了，收起这条回执")
                    }
                }

                if let error = state.backupError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.warning)
                }

                Text("备份包含学习库（含 -wal）、配置与调用留痕，存在本机，不上传任何地方。导入坏包会被校验拦下，不会动现有数据。")
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    /// 自动备份可选的间隔天数（再密就只是在堆重复文件了）。
    private static let autoBackupIntervals = [3, 7, 14]

    /// 自动备份的保留份数（与 `DataBackup.maxKeptBackups` 同口径，文案共用）。
    private static let maxKeptBackups = 12

    /// 「自动备份」开关底下的说明：**始终**带上上次备份的时间 —— 开关关着时
    /// 「还没有备份过 / 半个月前备份过」这件事本身就该被看见，不能藏起来。
    private var autoBackupHint: String {
        let freshness = state.backupFreshness()
        guard state.autoBackupEnabled else {
            return "上一次：\(freshness.text)。开着时每次启动检查一次，到点补一份。"
        }
        return "上一次：\(freshness.text)，每 \(state.autoBackupIntervalDays) 天补一份。"
    }

    private func autoBackupIntervalChip(_ days: Int) -> some View {
        let isSelected = state.autoBackupIntervalDays == days
        return Button {
            Task { await state.setAutoBackupIntervalDays(days) }
        } label: {
            Text("\(days) 天")
                .appFont(10, weight: isSelected ? .bold : .regular, design: .rounded)
                .foregroundStyle(isSelected ? theme.accent : theme.secondaryText)
                .padding(.horizontal, 7)
                .appPadding(.vertical, 3)
                .background(Capsule().fill(theme.accent.opacity(isSelected ? 0.14 : 0)))
                .overlay(
                    Capsule().strokeBorder(
                        isSelected ? theme.accent.opacity(0.6) : theme.divider,
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.appPressable)
        .help("每 \(days) 天自动补一份备份")
    }

    /// 选备份文件 → 校验 → 弹确认框（校验失败的原因会出现在下方错误区）。
    private func chooseBackupToImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip]
        panel.message = "选择要恢复的备份压缩包（AI_Language_Coach_备份_….zip）"
        guard panel.runModal() == .OK, let url = panel.url else {
            state.cancelBackupImport()
            return
        }
        Task {
            await state.inspectBackup(at: url.path)
            if state.backupImportPlan != nil {
                showImportConfirm = true
            }
        }
    }
}
