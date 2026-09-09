import AIInterfaces
import AppCore
import SwiftUI

public struct SettingsView: View {

    @Environment(\.forestTheme) private var theme
    @Bindable var state: AppState

    @State private var endpointDraft: String = ""
    @State private var temperatureDraft: Double = 0.7
    @State private var logs: [LogEntry] = []
    @State private var showAdvanced = false
    @State private var isRefreshing = false

    public init(state: AppState) { self.state = state }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().overlay(theme.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    forestCard
                    modelCard
                    learningCard
                    advancedCard
                    logsCard
                }
                .padding(20)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .background(theme.panel)
        .task { await loadRuntimeValues() }
    }

    // MARK: - 顶部栏（含关闭按钮 + 日夜快捷切换）

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 15))
                .foregroundStyle(theme.accent)
            Text("设置")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(theme.primaryText)

            Spacer()

            Button {
                Task { await state.toggleDayNight() }
            } label: {
                Image(systemName: theme.isNight ? "moon.stars.fill" : "sun.max.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.accent)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(theme.surfaceAlt))
            }
            .buttonStyle(.plain)
            .help(theme.isNight ? "切换到白天" : "切换到夜晚")

            Button {
                state.showingSettings = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(theme.surfaceAlt))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("关闭设置 (Esc)")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - 森林时刻

    private var forestCard: some View {
        card(title: "森林时刻", systemImage: theme.isNight ? "moon.stars.fill" : "sun.max.fill") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("", selection: Binding(
                    get: { state.themeMode },
                    set: { mode in Task { await state.setThemeMode(mode) } }
                )) {
                    ForEach(ThemeMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 12) {
                    ForEach(AnimalKind.allCases) { kind in
                        VStack(spacing: 4) {
                            CuteAnimalView(kind: kind, isSleeping: theme.isNight, size: 62)
                            Text(kind.displayName)
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                }
                .padding(.top, 4)

                Text(theme.isNight ? "夜深了，小动物们都在睡觉，星星陪你练习。" : "阳光正好，小动物们都醒着，一起爬树吧！")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    // MARK: - 模型

    private var modelCard: some View {
        card(title: "AI 大脑", systemImage: "brain") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(state.health.isUsable ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(state.health.userFacingDescription)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                    Spacer()
                    Button {
                        isRefreshing = true
                        Task {
                            await state.refreshStatus()
                            isRefreshing = false
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .disabled(isRefreshing)
                    .help("重新检测本地模型")
                }

                if state.availableModels.isEmpty {
                    Text("没有检测到本地模型。请确认本地模型服务已启动后点击刷新。")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.orange)
                } else {
                    Picker("选择模型", selection: Binding(
                        get: { state.modelDraft },
                        set: { name in Task { await state.applyModel(name) } }
                    )) {
                        ForEach(state.availableModels) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                    .labelsHidden()
                }

                HStack(spacing: 8) {
                    TextField("或手动填写模型名", text: $state.modelDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .rounded))
                    Button("应用") {
                        Task { await state.applyModel(state.modelDraft) }
                    }
                    .disabled(state.modelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Text("模型完全在本地运行，不上传任何对话内容。")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    // MARK: - 学习

    private var learningCard: some View {
        card(title: "学习设置", systemImage: "leaf.fill") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("练习模式", selection: Binding(
                    get: { state.productPracticeMode },
                    set: { mode in Task { await state.setPracticeMode(mode) } }
                )) {
                    ForEach(PracticeMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                HStack {
                    Text("学习语言").frame(width: 88, alignment: .leading)
                    TextField("如 en-US", text: Binding(
                        get: { state.learningLanguage },
                        set: { value in Task { await state.setLearningLanguage(value) } }
                    ))
                    .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text("母语").frame(width: 88, alignment: .leading)
                    TextField("如 zh-CN", text: Binding(
                        get: { state.nativeLanguage },
                        set: { value in Task { await state.setNativeLanguage(value) } }
                    ))
                    .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Text("教师音色").frame(width: 88, alignment: .leading)
                    TextField("音色名称", text: Binding(
                        get: { state.teacherVoice },
                        set: { value in Task { await state.setTeacherVoice(value) } }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }
            .font(.system(size: 13, design: .rounded))
        }
    }

    // MARK: - 高级

    private var advancedCard: some View {
        card(title: "高级", systemImage: "slider.horizontal.3") {
            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("服务端点").frame(width: 88, alignment: .leading)
                        TextField("http://127.0.0.1:11434", text: $endpointDraft)
                            .textFieldStyle(.roundedBorder)
                        Button("应用") {
                            Task { await state.setLLMEndpoint(endpointDraft) }
                        }
                    }

                    HStack {
                        Text("创意度").frame(width: 88, alignment: .leading)
                        Slider(value: $temperatureDraft, in: 0...1.4, step: 0.05)
                        Text(String(format: "%.2f", temperatureDraft))
                            .frame(width: 44, alignment: .trailing)
                            .monospacedDigit()
                        Button("应用") {
                            Task { await state.setLLMTemperature(temperatureDraft) }
                        }
                    }

                    Text("普通用户不需要修改这些。默认值已针对本机优化。")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                }
                .padding(.top, 8)
                .font(.system(size: 13, design: .rounded))
            } label: {
                Text("显示高级选项")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    // MARK: - 日志

    private var logsCard: some View {
        card(title: "运行日志", systemImage: "doc.text") {
            VStack(alignment: .leading, spacing: 6) {
                if logs.isEmpty {
                    Text("暂无日志")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(theme.secondaryText)
                } else {
                    ForEach(logs.suffix(30)) { entry in
                        HStack(alignment: .top, spacing: 6) {
                            Text(entry.level.rawValue.uppercased())
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(color(for: entry.level))
                                .frame(width: 48, alignment: .leading)
                            Text(entry.message)
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(theme.secondaryText)
                            Spacer()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 通用

    private func card<Content: View>(title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(theme.accent)
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.surface)
                .shadow(color: theme.shadow, radius: 8, x: 0, y: 3)
        )
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: .gray
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }

    private func loadRuntimeValues() async {
        let configuration = await state.services.configuration
        endpointDraft = configuration.enabledProvider(for: .llm)?.endpoint ?? ""
        temperatureDraft = configuration.enabledProvider(for: .llm)?.temperature ?? 0.7
        logs = await LogBus.shared.recent(limit: 60)
    }
}
