import AppCore
import SwiftUI

// #662 自 SettingsView.swift 拆出（2026-10-24）：原文件 3227 行、单结构体 22 个 MARK 段，按主题分文件。
// 同模块移动，语义与拆分前完全一致；跨文件引用的成员已从 private 放宽到 internal
// （模块内可见，跨模块零影响，public API 不变）。

extension SettingsView {
    // MARK: - 顶部栏（含关闭按钮；日夜切换收在下方「森林时刻」卡片里）

    var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "gearshape.fill")
                .appFont(15)
                .foregroundStyle(theme.accent)
            Text("设置")
                .appFont(16, weight: .bold, design: .rounded)
                .foregroundStyle(theme.primaryText)

            Spacer()

            Button {
                state.showingSettings = false
            } label: {
                Image(systemName: "xmark")
                    .appFont(12, weight: .bold)
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(theme.surfaceAlt))
            }
            .buttonStyle(.appPressable)
            // ⚠️ 栈顶仲裁（#S2-1）：设置页可与情景/材料浮层同屏并存，
            // Esc 只该关最上面那一层，别把底下那层替用户关了。
            .escShortcut(isActive: state.escDismissLayer == .settings)
            .help("关闭设置 (Esc)")
            .accessibilityLabel("关闭设置")
        }
        .padding(.horizontal, 18)
        .appPadding(.vertical, 14)
    }

    // MARK: - 森林时刻（日夜切换在此，不再单独拎出）

    /// 使用说明（#413）。
    ///
    /// 此前全应用只有悬浮提示（`help(...)`）：想知道「这个功能到底怎么用」时
    /// 没有任何地方可查 —— 悬浮提示只在鼠标恰好停在那儿的一刻才存在。
    var helpCenterCard: some View {
        card(title: "使用说明", systemImage: "questionmark.circle.fill") {
            VStack(alignment: .leading, spacing: 8) {
                Text("第一次用、或者忘了某个功能怎么用，点开按节查（支持搜索）。")
                    .appFont(12, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    state.showingHelp = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "book.fill").appFont(11)
                        Text("打开使用说明")
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
            }
        }
        .sheet(isPresented: $state.showingHelp) {
            HelpCenterView { state.showingHelp = false }
        }
    }

    /// 显示卡（#416）：字号档 + 界面密度档。
    ///
    /// 档位只改「倍率」，实际字号/留白由 `AppTypography` 在全树统一换算 ——
    /// 所以这里切档即全应用生效，不需要各页面各自监听。
    var displayCard: some View {
        card(title: "显示", systemImage: "textformat.size") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("字号", selection: Binding(
                    get: { state.typeSize },
                    set: { mode in Task { await state.setTypeSize(mode) } }
                )) {
                    ForEach(FontSizeMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Picker("界面密度", selection: Binding(
                    get: { state.interfaceDensity },
                    set: { mode in Task { await state.setInterfaceDensity(mode) } }
                )) {
                    ForEach(DensityMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Divider().overlay(theme.divider)

                // 状态栏那枚叶子（2026-10-14）：用户要求「展不展示由自己定」。
                // ⚠️ 提示里必须带上「系统设置 → 菜单栏」：macOS 26 起菜单栏图标
                // 还受一道系统级权限管（关掉后本应用里再打开也不显示），
                // 不说的话用户只会以为这个开关是坏的。
                Toggle(isOn: Binding(
                    get: { !state.statusBarIconHidden },
                    set: { on in state.setStatusBarIconHidden(!on) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("显示菜单栏图标")
                            .appFont(13, design: .rounded)
                        Text(statusBarIconHint)
                            .appFont(11, design: .rounded)
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .toggleStyle(.switch)

                Text(displayHint)
                    .appFont(12, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 档位说明（抽成纯属性便于钉住措辞）：写清「密度只松紧纵向」这个刻意取舍，
    /// 免得用户横向没变以为开关是坏的。
    private var displayHint: String {
        switch (state.typeSize, state.interfaceDensity) {
        case (.regular, .regular):
            return "标准档就是设计基准。字号整体放大缩小，密度只松紧上下留白（横向不变，避免文字被裁）。"
        case let (t, d):
            let size = t == .regular ? "字号保持标准" : "字号\(t.displayName)一档"
            let density = d == .regular ? "留白保持标准" : "上下留白更\(d == .compact ? "紧凑" : "宽松")"
            return "\(size)，\(density)。只影响界面排版，不改动任何内容。"
        }
    }

    /// 菜单栏图标开关的说明。**常驻不变**（不随开关状态改口）——
    /// 变来变去的说明本身就会让人怀疑开关没生效。
    private var statusBarIconHint: String {
        "菜单栏那枚叶子点开就能看到今天练什么，一步跳到对应页面。若打开后仍不显示，请在「系统设置 → 菜单栏」里允许语林显示。"
    }

    var themeCard: some View {
        card(title: "森林时刻", systemImage: theme.isNight ? "moon.stars.fill" : "sun.max.fill") {
            VStack(alignment: .leading, spacing: 10) {
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

                Text(theme.isNight ? "夜晚的森林很安静，星星陪着小动物们睡觉，也陪你练习。" : "阳光正好，小动物们都醒着，一起爬树学英语吧！")
                    .appFont(12, design: .rounded)
                    .foregroundStyle(theme.secondaryText)

                Divider().overlay(theme.divider)

                // 跟随时间：天黑了自己切夜景、太阳沿弧线走（日夜档位的事）。
                // ⚠️ 手动点右上角太阳/月亮会**收回**自动（否则那个按钮点了没反应）。
                Toggle(isOn: Binding(
                    get: { state.forestFollowsClock },
                    set: { on in Task { await state.setForestFollowsClock(on) } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("跟随时间")
                            .appFont(13, design: .rounded)
                        Text(followClockHint)
                            .appFont(11, design: .rounded)
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .toggleStyle(.switch)

                // 跟随季节：按月份换叶色/落花（春华秋实；日夜档位不受它影响）。
                Toggle(isOn: Binding(
                    get: { state.forestFollowsSeason },
                    set: { on in Task { await state.setForestFollowsSeason(on) } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("跟随季节")
                            .appFont(13, design: .rounded)
                        Text(followSeasonHint)
                            .appFont(11, design: .rounded)
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .toggleStyle(.switch)

                // 手动选季（#602）：关掉跟随后在这里挑（开着 = 按月自动派生，挑了也不算）。
                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: Binding(
                        get: { state.forestSeasonOverride ?? .spring },
                        set: { season in Task { await state.setForestSeasonOverride(season) } }
                    )) {
                        ForEach(ForestSeason.allCases) { season in
                            Text(season.displayName).tag(season)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(state.forestFollowsSeason)

                    Text(seasonOverrideHint)
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                }

                // 跟随天气（#418-A）：按日期定晴 / 下雨 / 下雪（同一天不会变卦）。
                Toggle(isOn: Binding(
                    get: { state.forestFollowsWeather },
                    set: { on in Task { await state.setForestFollowsWeather(on) } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("跟随天气")
                            .appFont(13, design: .rounded)
                        Text(followWeatherHint)
                            .appFont(11, design: .rounded)
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .toggleStyle(.switch)

                // 手动选天气（#602）：只有下雨 / 下雪两个选项 ——
                // 「晴」不是手动档，它是「跟随天气开着且今天无降水」或整条关掉时的样子。
                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: Binding(
                        get: { state.forestWeatherOverride ?? .rain },
                        set: { weather in Task { await state.setForestWeatherOverride(weather) } }
                    )) {
                        ForEach([ForestWeather.rain, .snow]) { weather in
                            Text(weather.displayName).tag(weather)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(state.forestFollowsWeather)

                    Text(weatherOverrideHint)
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                }

                Divider().overlay(theme.divider)

                // 跟随学习节奏（#600）：连胜一周且今日达标 → 林子进丰季（叶色更盛、兜底天气偏晴）。
                Toggle(isOn: Binding(
                    get: { state.forestFollowsMomentum },
                    set: { on in Task { await state.setForestFollowsMomentum(on) } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("跟随学习节奏")
                            .appFont(13, design: .rounded)
                        Text(followMomentumHint)
                            .appFont(11, design: .rounded)
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .toggleStyle(.switch)
            }
        }
    }

    /// 「跟随时间」的说明（抽成纯属性便于钉住措辞）。
    private var followClockHint: String {
        if !state.forestFollowsClock { return "关着时，日夜只由上面这一排决定。" }
        let moment = ForestAtmosphere.moment(hour: Int(state.clockHour)).displayName
        return "现在是\(moment)，太阳月亮会在天上慢慢走。"
    }

    /// 「跟随季节」的说明。
    private var followSeasonHint: String {
        if !state.forestFollowsSeason { return "关着时，林子四季常青。" }
        let season = ForestAtmosphere.season(month: state.clockMonth).displayName
        return "林子正处在\(season)季，叶色与落花会跟着月份走。"
    }

    /// 「跟随天气」的说明（#418-A 按日期推算；#604 起优先真实预报）。
    ///
    /// ⚠️ 关着时也要交代「开着会怎样」：这个开关一合上应用就开始**联网**，
    /// 而用户在 toggle 那一刻是看不见任何别的变化的 —— 不写出来，
    /// 「连线问天气」就成了一项用户不知道自己同意了的事。
    private var followWeatherHint: String {
        guard state.forestFollowsWeather else {
            return "关着时，天上永远是老样子；开着会联网取你所在城市的天气（只发城市级位置，不含对话内容）。"
        }
        // 真实预报拿到了 → 说明它来自真天气；没拿到（断网 / 服务没回应）→
        // 老实交代在按日期推算。谎称「当地下雨」是最不该有的那类错。
        if let forecast = state.weatherForecast {
            switch forecast {
            case .clear: return "当地今天晴（真实天气预报），天上没有降水。"
            case .rain: return "当地今天下雨（真实天气预报），云更密、有雨丝。"
            case .snow: return "当地今天下雪（真实天气预报），云更密、有雪片。"
            }
        }
        switch ForestAtmosphere.weather(dayOfYear: state.clockDayOfYear) {
        case .clear: return "今天晴天（没取到预报，按日期推算）。"
        case .rain: return "今天下雨（没取到预报，按日期推算），云更密、有雨丝。"
        case .snow: return "今天下雪（没取到预报，按日期推算），云更密、有雪片。"
        }
    }

    /// 「手动选季」的说明（#602；抽成纯属性便于钉住措辞）。
    private var seasonOverrideHint: String {
        if state.forestFollowsSeason {
            return "正在跟随真实月份，手动挑选已锁定。"
        }
        if let season = state.forestSeasonOverride {
            return "已手动选定\(season.displayName)季，叶色与落花一直按这个季节走。"
        }
        return "关掉跟随后，可在这里手动挑一季。"
    }

    /// 「手动选天气」的说明（#602）。手动只有下雨 / 下雪两档。
    private var weatherOverrideHint: String {
        if state.forestFollowsWeather {
            return "正在跟随真实天气，手动挑选已锁定。"
        }
        if let weather = state.forestWeatherOverride {
            return "已手动选定\(weather == .rain ? "下雨" : "下雪")，云更密、天上一直有\(weather == .rain ? "雨丝" : "雪片")。"
        }
        return "关掉跟随后，可在这里手动挑下雨或下雪。"
    }

    /// 「跟随学习节奏」的说明（#600；抽成纯属性便于钉住措辞）。
    ///
    /// ⚠️ 关着时也要交代「开着会怎样」：这个开关一合上，森林就开始**读学习记录**。
    /// 它不外发任何数据（节奏全部本机派生），但用户该知道自己同意了这件事。
    private var followMomentumHint: String {
        guard state.forestFollowsMomentum else {
            return "关着时，森林不读你的学习数据，林子长什么样只由上面几项决定。"
        }
        switch state.forestMomentum {
        case .flourishing:
            return "连续学满一周且今日目标已达成，林子正进入丰季：叶色更盛，没取到天气预报时也更容易是晴天。"
        case .growing:
            return "今天有在学（或连胜还没断），林子跟着长。连胜满一周并达成今日目标，就会进入丰季。"
        case .resting, nil:
            return "今天还没练。练起来、连胜满一周并达成今日目标，林子就会进入丰季。"
        }
    }

    // MARK: - 动画效果（应用内动效开关，三态）

    var motionCard: some View {
        card(title: "动画效果", systemImage: "sparkles") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: Binding(
                    get: { state.motionMode },
                    set: { mode in Task { await state.setMotionMode(mode) } }
                )) {
                    ForEach(MotionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(motionHint)
                    .appFont(12, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    /// 三态的说明文案（抽成纯函数便于钉住措辞）。
    private var motionHint: String {
        switch state.motionMode {
        case .followSystem:
            "跟着系统的「减弱动态效果」设置走 —— 系统安静，语林也安静。"
        case .reduced:
            "星星、树叶都停下来，动画退成轻轻的淡入淡出。"
        case .full:
            "所有动画都开，与系统的「减弱动态效果」设置无关。"
        }
    }

    // MARK: - 轻音效（批次六 · F：默认关）

    var soundCard: some View {
        card(title: "轻音效", systemImage: "speaker.wave.2.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(
                    get: { state.soundEffectsEnabled },
                    set: { on in Task { await state.setSoundEffects(on) } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("开启轻音效")
                            .appFont(13, design: .rounded)
                        Text("收进生词一声「叮」、通关一段小旋律、点小动物一声叫。默认关着，想要热闹再打开。")
                            .appFont(11, design: .rounded)
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .toggleStyle(.switch)
            }
        }
    }
}
