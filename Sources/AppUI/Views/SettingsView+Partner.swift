import SwiftUI

// #662 自 SettingsView.swift 拆出（2026-10-24）：原文件 3227 行、单结构体 22 个 MARK 段，按主题分文件。
// 同模块移动，语义与拆分前完全一致；跨文件引用的成员已从 private 放宽到 internal
// （模块内可见，跨模块零影响，public API 不变）。

extension SettingsView {
    // MARK: - 我的伙伴（老师 / 小学员形象切换）

    var partnerCard: some View {
        card(title: "我的伙伴", systemImage: "pawprint.fill") {
            VStack(alignment: .leading, spacing: 12) {
                // 角色选择：老师与小学员共用下方的小动物展示区
                HStack(spacing: 8) {
                    ForEach(PartnerRole.allCases) { role in
                        Button {
                            withAnimation(.app(.reveal)) { partnerRole = role }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: role.icon)
                                    .appFont(12)
                                Text(role.title)
                                    .appFont(13, weight: .semibold, design: .rounded)
                            }
                            .foregroundStyle(partnerRole == role ? theme.onAccentFill : theme.primaryText)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(partnerRole == role ? theme.accentFill : theme.surfaceAlt)
                            )
                        }
                        .buttonStyle(.appPressable)
                    }
                    Spacer()
                }

                // 当前角色说明
                HStack(spacing: 8) {
                    Image(systemName: partnerRole.icon)
                        .appFont(11)
                        .foregroundStyle(theme.accent)
                    Text(partnerRole.caption)
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                }

                // 小动物展示区：当前角色已选中的动物带身份配件 + 高亮圈
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 12) {
                    ForEach(AnimalKind.allCases) { kind in
                        partnerCell(kind)
                    }
                }
                .appPadding(.top, 2)

                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .appFont(11)
                        .foregroundStyle(theme.accent)
                    Text("老师持教棍，小学员戴红领巾，小伙伴跟着一起换。点选即可分别更换三个形象。")
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
    }

    /// 当前角色已选中的是哪一只（三个角色同一个展示区，判据收在这里一份）。
    private func selectedKind(for role: PartnerRole) -> AnimalKind {
        switch role {
        case .teacher: return state.teacherAnimalKind
        case .student: return state.studentAnimalKind
        case .companion: return state.companionAnimalKind
        }
    }

    private func partnerCell(_ kind: AnimalKind) -> some View {
        let isSelected = selectedKind(for: partnerRole) == kind
        // ⚠️ 设置页预览一律用**基线配饰**（老师教棍 / 学员红领巾）：
        // 这里选的是「角色是谁」，不是「它爬到哪一站了」。
        let accessory: AnimalAccessory = isSelected
            ? (partnerRole == .teacher ? .teacher : .student)
            : .none

        return Button {
            Task {
                switch partnerRole {
                case .teacher: await state.setTeacherAnimal(kind)
                case .student: await state.setStudentAnimal(kind)
                case .companion: await state.setCompanionAnimal(kind)
                }
            }
        } label: {
            VStack(spacing: 4) {
                CuteAnimalView(kind: kind, isSleeping: theme.isNight, size: 58, accessory: accessory)
                Text(kind.displayName)
                    .appFont(10, design: .rounded)
                    .foregroundStyle(isSelected ? theme.accent : theme.secondaryText)
                    .fontWeight(isSelected ? .semibold : .regular)
            }
            .frame(maxWidth: .infinity)
            .appPadding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? theme.selection.opacity(0.7) : theme.surfaceAlt.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? theme.accent : Color.clear, lineWidth: 2)
            )
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: partnerRole.icon)
                        .appFont(9, weight: .bold)
                        .foregroundStyle(theme.onAccentFill)
                        .appPadding(4)
                        .background(Circle().fill(theme.accentFill))
                        .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(.appPressable)
        .help("设为\(partnerRole.title)：\(kind.displayName)")
    }

    // MARK: - 森林伙伴（气泡 / 活动开关，全部全局记忆）

    var forestCompanionsCard: some View {
        card(title: "森林伙伴", systemImage: "pawprint") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("老师激励气泡", isOn: Binding(
                    get: { state.teacherBubblesEnabled },
                    set: { enabled in Task { await state.setTeacherBubbles(enabled) } }
                ))
                .appFont(13, design: .rounded)

                Toggle("小动物气泡（点击/自发冒泡）", isOn: Binding(
                    get: { state.animalBubblesEnabled },
                    set: { enabled in Task { await state.setAnimalBubbles(enabled) } }
                ))
                .appFont(13, design: .rounded)

                Toggle("小动物自由活动", isOn: Binding(
                    // 夜晚：显示为未勾选且不可点击（白天的小动物都睡了），
                    // 但**不改动用户白天的配置**，切回白天即恢复原选择。
                    get: { AppState.animalActivityToggleValue(enabled: state.animalActivityEnabled, isNight: theme.isNight) },
                    set: { enabled in Task { await state.setAnimalActivity(enabled) } }
                ))
                .appFont(13, design: .rounded)
                .disabled(theme.isNight)
                .help(theme.isNight ? "夜晚小动物们都在睡觉，白天才能开启活动" : "开启后小动物会在林间自由活动")

                // 活动频率滑条：关闭活动（或夜晚）时置灰不可拖
                HStack(spacing: 10) {
                    Text("移动频率")
                        .appFont(13, design: .rounded)
                        .foregroundStyle(activityControlsActive ? theme.primaryText : theme.secondaryText)
                    Slider(
                        value: Binding(
                            get: { state.animalActivityFrequency },
                            set: { value in Task { await state.setAnimalActivityFrequency(value) } }
                        ),
                        in: 0...1
                    )
                    .disabled(!activityControlsActive)
                    Text(activityControlsActive ? frequencyLabel : "—")
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 52, alignment: .trailing)
                        .monospacedDigit()
                }
                .padding(.leading, 20)
                .opacity(activityControlsActive ? 1 : 0.45)

                Text(theme.isNight
                     ? "现在是夜晚，小动物们都在睡觉，活动开关已暂时锁定；切回白天即可重新调整。"
                     : "关闭活动时，小动物们会回到初始位置排排站好（成长之树右下角有同步的表情开关）。夜晚它们会自动安静下来。小动物们还会不定时告别离开、换新邻居进场。以上开关全局记忆，下次打开应用自动延续。")
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    /// 小动物活动相关控件是否可用（夜晚一律锁定）。
    private var activityControlsActive: Bool {
        state.animalActivityEnabled && !theme.isNight
    }

    /// 频率滑条的展示文案。
    private var frequencyLabel: String {
        let value = state.animalActivityFrequency
        if value < 0.25 { return "悠闲" }
        if value < 0.55 { return "正常" }
        if value < 0.8 { return "活泼" }
        return "撒欢"
    }
}
