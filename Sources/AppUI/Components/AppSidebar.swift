import AIDomain
import SwiftUI

/// 左侧可收拉侧边栏。App 的 logo / 名称 / 设置 等全局功能入口都放这里。
/// 日夜切换按用户要求收进设置页，不再单独拎出。
/// 侧栏高度（展开的黑板要按它算自己最多能长多高）。
private struct SidebarHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 底部那块（老师座位 + 分隔线 + 收拉按钮）的高度 = 座位顶距侧栏底多远。
/// 展开的黑板底边固定在座位上方，所以「还能往上长多少」全靠它。
private struct BottomBlockHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

public struct AppSidebar: View {

    @Environment(\.forestTheme) private var theme
    @Bindable var state: AppState

    public static let expandedWidth: CGFloat = 220
    public static let collapsedWidth: CGFloat = 76

    public init(state: AppState) { self.state = state }

    public var body: some View {
        VStack(spacing: 0) {
            // 头部：与其他两栏同高的 64pt 顶栏，保证顶部分界线对齐
            header
                .frame(height: 64)

            Divider().overlay(theme.divider)

            navList

            Spacer(minLength: 8)

            bottomBlock
        }
        .padding(.horizontal, isExpanded ? 12 : 10)
        .frame(width: isExpanded ? Self.expandedWidth : Self.collapsedWidth)
        .background(theme.surfaceAlt.opacity(0.94))
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isExpanded)
        // 每次老师回复后刷新黑板上的今日 token 用量
        .onChange(of: state.chat.messages.count) { _, _ in
            state.refreshTodayTokens()
        }
        // 侧栏实测高度：喂给展开的黑板当「最高能长到哪儿」。
        .overlay {
            GeometryReader { proxy in
                Color.clear.preference(key: SidebarHeightKey.self, value: proxy.size.height)
            }
        }
        .onPreferenceChange(SidebarHeightKey.self) { sidebarHeight = $0 }
        .onPreferenceChange(BottomBlockHeightKey.self) { seatTopFromBottom = $0 }
        // ⚠️ 老师角落（座位 + 展开的黑板 + 气泡）画在**整条侧栏**的浮层里，必须最后套：
        // 它的容器要和侧栏同高，板才不会跑出容器边界（跑出去就点不到，见 `TeacherCorner`）。
        .overlay(alignment: .bottom) { teacherOverlay }
    }

    private var isExpanded: Bool { state.isSidebarExpanded }

    // MARK: - 头部（与其他两栏 64pt 顶栏对齐）

    private var header: some View {
        Group {
            if isExpanded {
                HStack(spacing: 10) {
                    AppLogo(size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("语林")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.primaryText)
                        Text("AI 语言私教")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(theme.secondaryText)
                    }
                    Spacer(minLength: 0)
                    // 打卡徽章（连续天数提到台前）：连续 ≥1 天才出现；
                    // 今天还没练时亮警示色 —— 悬停是断签保护那句「练一会儿保住 N 天」。
                    // 点一下跳去「学习进度」的**年度学习记录卡**：这个数字的上下文全在那儿。
                    if let streak = TodayPanel.streakBadge(
                        streakDays: state.progressSnapshot.streakDays,
                        hasPracticeToday: state.progressSnapshot.today.hasPractice
                    ) {
                        StreakBadgeView(badge: streak) {
                            Task { await state.openAnnualRecapInProgress() }
                        }
                    }
                }
                .padding(.horizontal, 6)
            } else {
                AppLogo(size: 34)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - 导航

    private var navList: some View {
        VStack(spacing: 4) {
            // 页面条目由 `AppSection.allCases` 生成：顺序、图标、文案、高亮判断、快捷键编号
            // 全来自同一处。旧写法是这里手写 7 段 navItem，高亮还要靠 7 个布尔量反推 ——
            // 结果是「学习记录 + 情景对话」会同时亮（`openScenarios()` 漏清了一个标记）。
            ForEach(AppSection.allCases) { section in
                navItem(
                    icon: section.systemImage,
                    title: section.title,
                    isActive: !state.showingSettings && state.activeSection == section,
                    shortcutDigit: section.shortcutDigit,
                    // 老师已经在后台开口了，但人不在对话页 —— 只在「练习」上点一个提示点，
                    // 不弹窗、不抢画面（开场白现在是后台任务，见 `AppState.openInBackground`）。
                    badge: section == .practice && state.teacherOpenerPending
                ) {
                    Task { await state.go(to: section) }
                }
            }

            // 设置是**浮层**，不参与 `AppSection` 的互斥：打开它不该关掉底下那一页。
            navItem(
                icon: "gearshape.fill",
                title: "设置",
                isActive: state.showingSettings,
                shortcutDigit: nil
            ) {
                state.showingSettings = true
            }

            Divider().overlay(theme.divider)
                .padding(.vertical, 6)
        }
        .padding(.top, 10)
    }

    // MARK: - 老师座位（黑板 + 教棍老师 + 督促气泡；白天夜晚文案随主题）

    /// 侧栏实测高度（展开的黑板要知道自己最多能长多高）。
    @State private var sidebarHeight: CGFloat = 0
    /// 「座位顶距侧栏底」的实测值（见 `BottomBlockHeightKey`）。
    @State private var seatTopFromBottom: CGFloat = 0

    /// 底部三件套：老师座位 + 分隔线 + 收拉按钮。
    ///
    /// ⚠️ 三件一起量：座位顶距侧栏底的高度就是「展开的黑板最多能往上长多少」，
    /// 少了分隔线和按钮那 30 多 pt，板就会越过侧栏顶部（边界条件算错过一次）。
    ///
    /// ⚠️ 座位**本体**不在这里画（见 `teacherOverlay`）—— 流程里留的是**同高的占位**：
    /// 展开的板要比座位高 200+pt，只有让「座位 + 板 + 气泡」待在整条侧栏那么高的容器里，
    /// 板才不会跑出容器边界（跑出去就点不到）。占位不能省 —— 它撑着上面那个测量值。
    private var bottomBlock: some View {
        VStack(spacing: 0) {
            teacherSeat

            Divider().overlay(theme.divider)

            collapseButton
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: BottomBlockHeightKey.self, value: proxy.size.height)
            }
        )
    }

    @ViewBuilder
    private var teacherSeat: some View {
        if isExpanded {
            // 座位占位：尺寸与 `TeacherCorner` 的座位**严格一致**（座位那一行的高度
            // 在 `TeacherCorner` 里被钉成 `BlackboardLayout.nameHeight`，所以这个数是准的）。
            Color.clear
                .frame(width: 176, height: BlackboardLayout.seatHeight)
                .allowsHitTesting(false)
        } else {
            // 侧栏收起时：只有一只小动物。
            // ⚠️ 点它**先拉开侧栏、动画结束后再开板** —— 两步走而不是同时动，
            // 否则「侧栏变宽」和「板展开」两个弹簧叠在一起会抖。
            // 直接开板也不行：76pt 宽装不下一块板。
            CuteAnimalView(kind: state.teacherAnimalKind, isSleeping: theme.isNight, size: 46, accessory: .teacher)
                .frame(height: 96)
                .contentShape(Rectangle())
                .onTapGesture { openBoardFromCollapsedSidebar() }
                .help("展开侧栏看今日作业")
        }
    }

    /// 老师角落：座位贴在占位那一格上，展开的板与气泡都在这一层里往上长。
    ///
    /// ⚠️ 容器 = 整条侧栏（浮层的默认尺寸），座位底再按「分隔线 + 收拉按钮」那一截
    /// （`seatBottomInset`）整体上移 —— 与流程里的占位像素级对齐。
    ///
    /// ⚠️ **这一层绝对不许再套 `.help`**（`TeacherCorner` 的根和侧栏同高，套上去等于
    /// 给整条侧栏挂提示）：实测鼠标停在展开的黑板右上角那个「跳转今日任务」上，
    /// 弹出来的是「AI 老师 · 小熊猫（可在设置中更换）」—— 按钮自己的提示被盖掉了。
    /// 老师介绍那句现在挂在**座位那一格**里（`TeacherCorner.helpText`），
    /// 板上的按钮则各报各的（`BlackboardPanel` 的 header）。
    @ViewBuilder
    private var teacherOverlay: some View {
        if isExpanded {
            TeacherCorner(
                kind: state.teacherAnimalKind,
                isSleeping: theme.isNight,
                todayTokens: state.todayTokens,
                plan: state.dailyPlan,
                streakDays: state.progressSnapshot.streakDays,
                todayHasPractice: state.progressSnapshot.today.hasPractice,
                dueAtDayStart: state.progressSnapshot.vocabulary.dueAtDayStart,
                reviewedOfDue: state.progressSnapshot.vocabulary.dueAtDayStartReviewed,
                reviewedToday: state.progressSnapshot.vocabularyReviewedToday,
                todaySeconds: state.progressSnapshot.today.seconds,
                bubblesAllowed: state.teacherBubblesEnabled,
                isCelebrating: state.isCelebratingToday,
                isExpanded: $state.isBlackboardExpanded,
                availableHeight: boardAvailableHeight,
                onOpenTask: { kind in Task { await state.openTodayTask(kind) } },
                onOpenProgress: { state.openTodayTasksInProgress() }
            )
            .padding(.bottom, seatBottomInset)
            .transition(.opacity)
        }
    }

    /// 座位底距侧栏底的高度（分隔线 + 收拉按钮那一截）：浮层里的座位与板按它整体上移。
    private var seatBottomInset: CGFloat {
        max(0, seatTopFromBottom - BlackboardLayout.seatHeight)
    }

    /// 收起态点老师：先拉侧栏，等弹簧动画走完再开板。
    private func openBoardFromCollapsedSidebar() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            state.isSidebarExpanded = true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 360_000_000)
            // 这中间用户可能又收回去了 —— 那就别开了（开了也看不见）。
            guard state.isSidebarExpanded else { return }
            withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                state.isBlackboardExpanded = true
            }
        }
    }

    /// 黑板能用的最大高度：从板底（座位底往上 `panelBottomOffset`）到侧栏顶，两头留 8pt 呼吸位。
    ///
    /// ⚠️ 别再写成「侧栏高 − panelBottomOffset」——那漏算了座位底下那 30 多 pt
    /// （分隔线 + 收拉按钮），板会顶出侧栏。口径统一在 `BlackboardLayout` 里。
    private var boardAvailableHeight: CGFloat {
        BlackboardLayout.availableHeight(
            sidebarHeight: sidebarHeight,
            seatTopFromBottom: seatTopFromBottom
        )
    }

    // MARK: - 条目

    private func navItem(
        icon: String,
        title: String,
        isActive: Bool = false,
        isEnabled: Bool = true,
        shortcutDigit: Int? = nil,
        badge: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(isActive ? theme.accent : (isEnabled ? theme.primaryText : theme.secondaryText))
                    .frame(width: 22, height: 22)

                if isExpanded {
                    Text(title)
                        .font(.system(size: 13, weight: isActive ? .semibold : .regular, design: .rounded))
                        .foregroundStyle(isEnabled ? theme.primaryText : theme.secondaryText)
                    Spacer(minLength: 0)
                    if !isEnabled {
                        Text("soon")
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(theme.secondaryText.opacity(0.8))
                    }
                }
            }
            .padding(.horizontal, isExpanded ? 12 : 0)
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isActive ? theme.selection : Color.clear)
            )
            // 提示点：老师开口了但你不在对话页。收起态画在图标右上角，展开态落在行尾。
            .overlay(alignment: isExpanded ? .trailing : .topTrailing) {
                if badge {
                    Circle()
                        .fill(theme.accent)
                        .frame(width: 7, height: 7)
                        .padding(.trailing, isExpanded ? 16 : 6)
                        .padding(.top, isExpanded ? 0 : 8)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        // 提示里带上快捷键：不写出来的快捷键等于不存在（这是全项目唯一一处能看见它们的地方）。
        .help(helpText(title: title, isEnabled: isEnabled, shortcutDigit: shortcutDigit))
        // VoiceOver：读出来的要是「跟读（⌘2）」而不是光一个「跟读」；
        // 当前所在页另外报成选中态 —— 高亮是靠底色画的，读屏看不见底色。
        .accessibilityLabel(helpText(title: title, isEnabled: isEnabled, shortcutDigit: shortcutDigit))
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    private func helpText(title: String, isEnabled: Bool, shortcutDigit: Int?) -> String {
        guard isEnabled else { return "\(title)（即将推出）" }
        guard let shortcutDigit else { return title }
        return "\(title)（⌘\(shortcutDigit)）"
    }

    // MARK: - 收拉

    private var collapseButton: some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                // ⚠️ 收起侧栏要**连黑板一起收**：黑板只在展开态侧栏里存在，
                // 留着 `isBlackboardExpanded == true` 的话，下次展开侧栏它会自己弹开 ——
                // 用户没点过它，它会显得「自己动了」。
                if state.isSidebarExpanded { state.isBlackboardExpanded = false }
                state.isSidebarExpanded.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.left" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                if isExpanded {
                    Text("收起")
                        .font(.system(size: 12, design: .rounded))
                }
            }
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, isExpanded ? 12 : 0)
            .frame(height: 32)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.hover)
            )
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "收起侧边栏" : "展开侧边栏")
    }
}
