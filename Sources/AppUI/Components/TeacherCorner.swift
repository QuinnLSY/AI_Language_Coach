import AIDomain
import SwiftUI

/// 侧边栏底部的「老师角落」：老师背后挂一块小黑板，黑板上是**今天要交的作业**。
///
/// 三种状态（一次只做一件事，别让它们互相打架）：
/// 1. **收起（默认）**：黑板斜挂在老师背后偏左上，板上写今日 token 用量；
///    黑板**上边缘平行的那条线上**排三个圆圈，今日任务做完一项就打一个绿勾 ——
///    这是「不点开也能看见今天做了几项」的唯一入口。
/// 2. **悬停**：黑板摆正（默认 -3° 是「随手挂上去」的松弛感，摆正 = 可以点了）。
/// 3. **展开**：黑板上移到老师头顶、放大到侧栏宽，板上写今日三项 + 完成情况；
///    老师用教棍**敲两下**（往右上抬着敲），然后冒一句气泡 —— 没做完就催（给可核对的缺口），
///    做完了才夸。再点老师本人（或板右上角那个收起按钮）就收起。
///
/// ⚠️ 展开的板**没有遮罩**：板以外的地方要能正常点到（用户实测过「板挡着时点不到设置」）。
/// 板自己的矩形整块吃点击，板外一律穿透 —— 见 `expandedLayer`。
///
/// ⚠️ 根视图必须**与容器同高**（`frame(maxHeight: .infinity)`）：板比座位高得多，
/// 挂在座位的 overlay 上就会跑出座位 frame，再被座位的 `.contentShape(Rectangle())`
/// 把命中区裁掉 —— 板画得出来却点不到（详见 `body` 里的注释）。
/// 侧栏因此只在流程里留一个同高的占位，把真正的角落画在整条侧栏的浮层里（见 `AppSidebar`）。
///
/// ⚠️ 「今天也要一起加油哦」这类常驻副标题已经**并进气泡文案池**，那一行不再占版面；
/// 座位里也**不留空高**（`BlackboardLayout.teacherBox` 只装老师 + 教棍的呼吸位）——
/// 座位里每多 1pt 空白，展开的板就被顶高 1pt，最后挡住侧栏上部的入口。
public struct TeacherCorner: View {

    @Environment(\.forestTheme) private var theme
    let kind: AnimalKind
    let isSleeping: Bool
    /// 今日整个应用累计使用的 token（估算）—— 黑板收起时板上就写这个。
    let todayTokens: Int
    /// 今日计划（纯函数从快照排出来的）。
    let plan: DailyPlan
    let streakDays: Int
    /// 今天有没有练过（断签保护：连续还在、今天没练 = 老师要催一句别断签）。
    let todayHasPractice: Bool
    /// **今天起初**（0 点）到期的词数 —— 复习任务的固定指标（不是「此刻到期」）。
    let dueAtDayStart: Int
    /// 上面那批词里今天已经复习过的个数。
    let reviewedOfDue: Int
    /// 今天复习过的**不同**词数（含今天新加的词，只在今天起初没有到期词时兜个话）。
    let reviewedToday: Int
    /// 今天已练习的秒数（只用于 help / 朗读文案 —— 板上放不下，但**不能瞎说 0**）。
    let todaySeconds: TimeInterval
    /// 老师气泡开关（设置可关）。
    var bubblesAllowed: Bool = true
    /// 今日全部完成 → 板上盖个章 + 放一次烟花。
    var isCelebrating: Bool = false
    /// 黑板是否展开（归 `AppState` 持有：开屏要能自动展开一次）。
    @Binding var isExpanded: Bool
    /// 侧栏里黑板能用的最大高度（由侧栏实测高度算出来）。
    var availableHeight: CGFloat = 420
    /// 板上点某一项 → 去做。
    var onOpenTask: ((DailyTask.Kind) -> Void)? = nil
    /// 板上那个小图标 → 跳到「学习进度」里的今日任务卡。
    var onOpenProgress: (() -> Void)? = nil

    @State private var isHovering = false
    @State private var nudge: TodayPanel.BubbleLine?
    @State private var nudgeTick = 0
    @State private var knockTick = 0
    private let nudgeTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    public init(
        kind: AnimalKind,
        isSleeping: Bool,
        todayTokens: Int,
        plan: DailyPlan,
        streakDays: Int,
        todayHasPractice: Bool = true,
        dueAtDayStart: Int,
        reviewedOfDue: Int,
        reviewedToday: Int,
        todaySeconds: TimeInterval = 0,
        bubblesAllowed: Bool = true,
        isCelebrating: Bool = false,
        isExpanded: Binding<Bool>,
        availableHeight: CGFloat = 420,
        onOpenTask: ((DailyTask.Kind) -> Void)? = nil,
        onOpenProgress: (() -> Void)? = nil
    ) {
        self.kind = kind
        self.isSleeping = isSleeping
        self.todayTokens = todayTokens
        self.plan = plan
        self.streakDays = streakDays
        self.todayHasPractice = todayHasPractice
        self.dueAtDayStart = dueAtDayStart
        self.reviewedOfDue = reviewedOfDue
        self.reviewedToday = reviewedToday
        self.todaySeconds = todaySeconds
        self.bubblesAllowed = bubblesAllowed
        self.isCelebrating = isCelebrating
        self._isExpanded = isExpanded
        self.availableHeight = availableHeight
        self.onOpenTask = onOpenTask
        self.onOpenProgress = onOpenProgress
    }

    public var body: some View {
        // 根是**与容器同高的一层**，座位钉在底部。
        //
        // ⚠️ 三层必须是同一个 ZStack 的孩子，且这一层要装得下整块展开的板。
        // 以前「板 / 气泡」挂在座位的 `overlay` 上，而座位只有 `seatHeight`（≈109pt）那么高 ——
        // 板整个跑到座位 frame **之外**；座位身上又套着 `.contentShape(Rectangle())`，
        // 而 `contentShape` 会把**整棵子树**的命中区裁成那个矩形（SwiftUI 的语义，macOS 上实测过）。
        // 两者一叠加：板画得出来、任务行和右上角那两个按钮却一个都点不到
        // （用户实测「右上角按钮点击无反应」）。现在容器与侧栏同高，板/气泡/按钮全在界内。
        //
        // 展开层在座位**之上**、气泡**之下**：气泡要能压在板前面（老师说的话不该被板挡住）。
        ZStack(alignment: .bottom) {
            seatLayer
            expandedLayer
            bubbleLayer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .onChange(of: isExpanded) { _, expanded in
            guard expanded else { return }
            announceBoard()
        }
        // 以「已经展开」的姿态被挂上来（侧栏从收起态拉出来时）也要敲 —— 不然
        // 这次开板会静悄悄，用户以为没反应。`onAppear` 只在首次挂载时跑一次。
        .onAppear { if isExpanded { announceBoard() } }
        .task(id: nudgeTick) {
            guard nudge != nil else { return }
            try? await Task.sleep(nanoseconds: 3_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.app(.reveal)) { nudge = nil }
        }
        .onReceive(nudgeTimer) { _ in showRandomBubble() }
    }

    /// 座位那一格（老师 + 收起态小板）：**只有它吃「点一下开 / 合板」**。
    ///
    /// ⚠️ `.contentShape` / 手势 / `.help` / 无障碍都只能落在这一格上，绝不能再往上套一层：
    /// 套到根上会把整块展开的板一起裁进命中区（`seatHeight` 那一小格）——
    /// 板就全点不到了；`.help` 还会变成「鼠标在侧栏任何地方都弹提示」，
    /// 而且**会把板上那两个按钮自己的提示盖掉**（用户实测：停在「跳转今日任务」上
    /// 弹的是老师介绍）。侧栏那边因此也撤掉了套在 `TeacherCorner` 外层的 `.help`
    /// （见 `AppSidebar.teacherOverlay`）。
    private var seatLayer: some View {
        seat
            .contentShape(Rectangle())
            .onTapGesture { toggle() }
            .onHover { hovering in
                // 展开着就不玩摆正了 —— 那块小板此刻已经让位给上面那块大的。
                isHovering = isExpanded ? false : hovering
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(isExpanded ? [.isButton, .isSelected] : [.isButton])
            .help(helpText)
    }

    // MARK: - 座位（老师 + 收起态黑板 + 三个圆圈）

    private var seat: some View {
        VStack(spacing: BlackboardLayout.nameGap) {
            ZStack(alignment: .bottom) {
                // 收起态的小黑板（连带头顶那排圆圈）：挂在老师背后偏左上，展开时淡出让位。
                //
                // ⚠️ 圆圈行必须和板**放在同一个 VStack 里**摆位：分开摆两次 offset，
                // 实测会算错 —— 圆圈会掉进板面里（离屏字符图量出来的）。
                collapsedBoard
                    .zIndex(1)

                CuteAnimalView(
                    kind: kind,
                    isSleeping: isSleeping,
                    size: BlackboardLayout.animalFrame,
                    accessory: .teacher,
                    knockTick: knockTick
                )
                .zIndex(2)
            }
            // ⚠️ 这一格只该装得下老师本体 + 教棍的呼吸位（`BlackboardLayout.teacherBox`）：
            // 多出来的空白会被展开的板当成自己的落脚点，把板顶上侧栏上半部分。
            .frame(width: 176, height: BlackboardLayout.teacherBox)

            Text(kind.displayName + "老师")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.primaryText)
                // ⚠️ 这一行的高度写死成 `nameHeight`：座位总高必须是
                // `BlackboardLayout.seatHeight` 这个**算出来的数** ——
                // 侧栏里留的占位、板底偏移、板能长多高全按它推。11pt 圆体自然行高只有 13pt，
                // 差这 2pt 就会让浮层里的座位和流程里的占位错位。
                .frame(height: BlackboardLayout.nameHeight)
        }
    }

    /// 收起态的小黑板（木框 + 墨绿板面 + 白色粉笔字写今日 token）。
    ///
    /// 板顶那排圆圈是「今日完成到第几项」的常驻提示，位置靠 `VStack` 压在板上边缘之上，
    /// 不靠另算一个 offset —— 板挪了它跟着挪，不会掉进板面里。
    private var collapsedBoard: some View {
        VStack(spacing: 5) {
            // 板斜着挂（-3°），圆圈要**保持水平**才读得出来，所以反向转回来。
            taskDots
                .rotationEffect(.degrees(-tilt))
            BlackboardSmall(text: chalkText)
        }
        // ⚠️ 这一组（圆圈 + 小板）整体挪到老师背后偏左上。位移上限是**座位那一格的高度**：
        // 挪出去的部分落在座位 frame 之外，就不再属于「点老师开板」的命中区
        // （现在 box 是 92 高，-30 之后圆圈刚好落在座位顶上沿内侧，别再往上加）。
        .offset(x: -34, y: -30)
        .rotationEffect(.degrees(tilt))
        .scaleEffect(isHovering ? 1.04 : 1)
        // 摆正要快（0.18s）：这是「可以点了」的手感，不是动画表演。
        .appAnimation(.reveal, value: isHovering)
        .opacity(isExpanded ? 0 : 1)
        .animation(.easeOut(duration: 0.14).delay(isExpanded ? 0 : 0.18), value: isExpanded)
    }

    /// 板的倾斜角：默认「随手挂上去」的松弛感，悬停时摆正（= 可以点了）。
    private var tilt: Double { isHovering || isExpanded ? 0 : -3 }

    /// 三个圆圈（今日任务有几项就画几个 —— 到期词为 0 时「复习」不排，就只有两个）。
    @ViewBuilder
    private var taskDots: some View {
        if !plan.tasks.isEmpty {
            HStack(spacing: 6) {
                ForEach(plan.tasks) { task in
                    TaskDot(isDone: task.isDone, theme: theme)
                }
            }
        }
    }

    // MARK: - 展开层（大黑板）

    /// 展开的那一层：**只有黑板本体，没有遮罩**。
    ///
    /// ⚠️ 原来这里垫了一层半透明遮罩（点它收起）。用户点名去掉：
    /// 遮罩把侧栏整片压暗，还吃掉了板以外所有点击 —— 想顺手点上面的入口（比如「设置」）
    /// 点不动。现在板的矩形范围之外一律**穿透**到侧栏本身；板自己的矩形（含圆角外的空隙）
    /// 用 `contentShape` 全部吃掉，板挡住的组件不会被点到。
    @ViewBuilder
    private var expandedLayer: some View {
        if isExpanded {
            BlackboardPanel(
                theme: theme,
                plan: plan,
                streakDays: streakDays,
                dueAtDayStart: dueAtDayStart,
                reviewedOfDue: reviewedOfDue,
                reviewedToday: reviewedToday,
                todayTokens: todayTokens,
                isCelebrating: isCelebrating,
                maxHeight: availableHeight,
                // ⚠️ 点了某一项 = 已经决定了要做什么 → **顺手收起**（收起是这里的唯一收尾点）。
                onOpenTask: { kind in
                    collapse()
                    onOpenTask?(kind)
                },
                onOpenProgress: {
                    collapse()
                    onOpenProgress?()
                },
                onCollapse: collapse
            )
            .padding(.bottom, BlackboardLayout.panelBottomOffset)
            // 从「小板那个位置」长出来：先缩着、往下偏一点，再弹到位。
            .scaleEffect(isExpanded ? 1 : 0.62, anchor: .bottom)
            .offset(y: isExpanded ? 0 : 26)
            .opacity(isExpanded ? 1 : 0)
            .transition(.opacity)
        }
    }

    // MARK: - 气泡

    /// 老师的气泡（永远画在最上层：老师说的话不该被黑板挡住）。
    @ViewBuilder
    private var bubbleLayer: some View {
        if let nudge {
            SpeechBubble(segments: nudge.segments, maxWidth: 150)
                .fixedSize()
                .padding(.bottom, 112)
                .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .bottom)))
        }
    }

    // MARK: - 开合

    /// 板刚展开（或被以展开态挂上来）时：教棍敲两下，敲完再开口。
    ///
    /// ⚠️ 「敲完再说」不是讲究 —— 气泡和敲击同时出现会互相抢戏，
    /// 而且敲两下本身就要 0.58s（0.11 出 / 0.13 回 / 停 0.17 ×2）。
    private func announceBoard() {
        knockTick += 1
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 620_000_000)
            guard isExpanded else { return }
            nudge = TodayPanel.knockBubble(
                plan: plan,
                streakDays: streakDays,
                streakAtRisk: !todayHasPractice
            )
            nudgeTick += 1
        }
    }

    private func toggle() {
        // 用弹簧收放，别用 `.animation` 硬套：突然出现/突然消失最劝退。
        withAnimation(.app(.panel)) {
            isExpanded.toggle()
        }
    }

    private func collapse() {
        guard isExpanded else { return }
        withAnimation(.app(.panel)) {
            isExpanded = false
        }
    }

    // MARK: - 气泡文案

    /// 每 15 秒摇一次，约四成概率冒泡；展开时不插嘴；睡觉时不吵。
    private func showRandomBubble() {
        guard bubblesAllowed, nudge == nil, !isSleeping, !isExpanded else { return }
        let roll = Double.random(in: 0..<1)
        guard roll < 0.42 else { return }
        // 一半说今日进度（没做完红字、做完绿字），一半说原来的用量档位文案。
        // ⚠️ `progressLine` 在「今天还没排任务」时返回 nil —— 这时要**退回用量文案**，
        // 不能就这么不冒泡（那会让约两成的摇号白白落空）。
        if roll < 0.21, let line = TodayPanel.progressLine(plan: plan) {
            nudge = line
        } else {
            nudge = TodayPanel.BubbleLine([
                TodayPanel.Segment(Self.randomNudge(for: todayTokens), .plain)
            ])
        }
        nudgeTick += 1
    }

    /// 黑板粉笔字（收起态）。
    private var chalkText: String { ChatView.tokenCount(todayTokens) }

    /// 座位（老师本体 + 收起态小板）的提示：**老师是谁 + 点一下会发生什么**。
    ///
    /// ⚠️ 老师介绍那句（「可在设置中更换」）原来挂在整条侧栏上（`AppSidebar` 套在
    /// `TeacherCorner` 外层的 `.help`），结果展开的板右上角那两个按钮的提示全被它盖住 ——
    /// 用户点名过。现在它并进座位这一格的提示里，覆盖范围就只有老师和那块小板那么大。
    private var helpText: String {
        let intro = "AI 老师 · \(kind.displayName)（可在设置中更换）"
        let action = isExpanded
            ? "点一下收起今日作业"
            : "点一下看今日作业：\(TodayPanel.statusLine(plan: plan, streakDays: streakDays, todaySeconds: todaySeconds))"
        return "\(intro)\n\(action)"
    }

    private var accessibilityText: String {
        let state = isExpanded ? "已展开" : "已收起"
        return "\(kind.displayName)老师的今日作业，\(state)。\(TodayPanel.statusLine(plan: plan, streakDays: streakDays, todaySeconds: todaySeconds))"
    }

    // MARK: - 气泡文案（按今日用量分档，随机抽取）

    /// 今日用量分档阈值（token）。**产品口径，改动请同步测试与文档。**
    /// `nonisolated`：这些是不可变常量，`nudgeTier` / `pool` 等纯函数要在非 MainActor 上下文调用。
    nonisolated public static let urgeUpperBound = 2_000
    nonisolated public static let cheerUpperBound = 20_000

    /// 0–2000：督促学习。
    ///
    /// 最后两句原本是常驻在老师名字底下的副标题（白天 / 夜晚各一句），
    /// 现在改成冒泡 —— 那行占掉的高度让给了展开的黑板。
    nonisolated private static let urgeLines = [
        "今天还没开张呢，来读一句吧！",
        "单词们都想你了，快回来练两句～",
        "每日一句，胜过周末狂练！",
        "小树苗等你浇水呢，开口就是养分！",
        "今天的.first sentence 从哪里开始？就现在！",
        "别让我等太久哦，读一句我听听！",
        "魔法单词书还空着呢，填一个进去？",
        "五分钟就好，跟我念一句好不好？",
        "森林的清晨最适合朗读啦，来一段？",
        "你的椅子和小动物都坐好了，就差你！",
        "今天也要一起加油哦",
    ]

    /// 2000–20000：鼓励/奖励。
    nonisolated private static let cheerLines = [
        "今天火力全开，森林为你骄傲！",
        "这个量，单词本都要给你颁勋章了！",
        "进步神速！奖励你摸摸小树苗🌳",
        "你就是今天的攀登之星，继续闪耀！",
        "老师们都私下夸你了，真的！",
        "这状态保持住，下周就是小高手！",
        "今天的努力，星星都记在账上啦⭐️",
        "读得越多，爬得越高，太棒啦！",
        "给你一朵小红花，今天的你超努力！",
        "照这个节奏，云雀高枝不在话下！",
    ]

    /// ≥ 20000：提醒休息。
    nonisolated private static let restLines = [
        "练了这么多，让眼睛和耳朵歇会儿吧☕️",
        "学得多也要歇得好，去窗边看看远处？",
        "喝口水，伸个懒腰，森林等你回来。",
        "小动物们说：你辛苦啦，休息五分钟！",
        "大脑也要存档哦，休息巩固记得牢。",
        "今天已经非常棒了，别累着小嗓子～",
        "去揉揉小树、望望天空，再回来冲刺！",
        "休息不是偷懒，是为了爬得更高。",
        "合上眼睛听一段轻音乐吧，你值得。",
        "休息时间到！回来时给你讲新故事～",
        "夜深了，明天再爬一棵树",
    ]

    nonisolated public static func randomNudge(for tokens: Int) -> String {
        let options = pool(for: tokens)
        return options.randomElement() ?? options[0]
    }

    /// 今日用量对应的文案池（按 `urgeUpperBound` / `cheerUpperBound` 分档）。
    nonisolated public static func pool(for tokens: Int) -> [String] {
        switch nudgeTier(for: tokens) {
        case 0: urgeLines
        case 1: cheerLines
        default: restLines
        }
    }

    /// 今日用量落在哪一档（0 = 督促 / 1 = 鼓励 / 2 = 休息）。纯函数，便于单测与 UI 展示。
    nonisolated public static func nudgeTier(for tokens: Int) -> Int {
        switch tokens {
        case ..<urgeUpperBound: 0
        case urgeUpperBound..<cheerUpperBound: 1
        default: 2
        }
    }
}

// MARK: - 几何常量

/// 老师座位在侧栏里的几何。**侧栏布局要按这些数字排版**，别在各处硬写偏移。
///
/// ⚠️ 这几个数是一组「紧凑」值，用户量着改过一次：原来的座位里老师画框高 128、
/// 板底距座位底 158，中间抠出三块空白（板内部下方、板与老师之间、老师与名字之间），
/// 结果展开的板被顶到侧栏上半部分去，挡住了入口列表。现在每个空隙只留 2~4pt。
public enum BlackboardLayout {
    /// 老师那张画框的高度（`CuteAnimalView(size:)` 用的是 84）。
    public static let animalFrame: CGFloat = 84
    /// 画框顶上给教棍留的呼吸位：敲黑板时棍梢会抬到框顶附近，别切掉。
    static let animalHeadroom: CGFloat = 8
    /// 座位里老师那一格的高度（画框 + 呼吸位）。
    static let teacherBox: CGFloat = animalFrame + animalHeadroom
    /// 画框与名字之间的间距（字面 2pt；算上字体自带的行内留白，看着约 6pt）。
    static let nameGap: CGFloat = 2
    /// 名字那一行的高度（11pt 系统圆体一行，**实测 14pt**）。
    ///
    /// ⚠️ 这个数决定座位总高（`seatHeight`），而座位总高又决定侧栏里留多高的占位、
    /// 以及展开的板最多能长多高 —— 座位那一行在 `TeacherCorner` 里被**钉成**这个高度，
    /// 所以它必须等于字体的自然行高（写错会整体错位；凭感觉改之前先量一遍）。
    static let nameHeight: CGFloat = 14
    /// 老师座位从侧栏底部往上占的高度。
    public static let seatHeight: CGFloat = teacherBox + nameGap + nameHeight
    /// 展开时黑板底边距**侧栏底部**的距离 = 名字行 + 画框高 + 4pt。
    ///
    /// ⚠️ 从「座位底 + 158」收到这个值，是用户点名要的：板底就该紧贴老师头顶，
    /// 中间那一大段空白会把整块板顶上去挡住入口列表。
    public static let panelBottomOffset: CGFloat = nameGap + nameHeight + animalFrame + 4

    /// 板底到侧栏顶留的呼吸位（板再长也不许顶到顶栏上）。
    public static let topBreathing: CGFloat = 8
    /// 板再挤也得有这点高度（再小就没法看了，宁可让它滚动）。
    public static let minimumPanelHeight: CGFloat = 150

    /// 展开的黑板最多能长多高。
    ///
    /// - Parameters:
    ///   - sidebarHeight: 侧栏高度。
    ///   - seatTopFromBottom: 座位顶距侧栏底的高度（底部三件套实测值）。
    ///
    /// ⚠️ 口径是「板底以上的空间」，不是「侧栏高 − panelBottomOffset」：
    /// 后者漏算了座位底下那 30 多 pt（分隔线 + 收拉按钮），板会顶出侧栏顶部。
    public static func availableHeight(sidebarHeight: CGFloat, seatTopFromBottom: CGFloat) -> CGFloat {
        guard sidebarHeight > 0 else { return 420 }
        let bottomInset = max(0, seatTopFromBottom - seatHeight)
        let boardBottom = bottomInset + panelBottomOffset
        return max(minimumPanelHeight, sidebarHeight - boardBottom - topBreathing)
    }
}

// MARK: - 收起态小黑板（木框 + 墨绿板面 + 白色粉笔字）

struct BlackboardSmall: View {

    @Environment(\.forestTheme) private var theme
    let text: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(BlackboardPalette.frame)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(BlackboardPalette.board)
                .padding(5)
            VStack(spacing: 1) {
                Text("今日")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                Text(text)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("tokens")
                    .font(.system(size: 8, design: .rounded))
            }
            .foregroundStyle(BlackboardPalette.chalk)
            .shadow(color: .white.opacity(0.25), radius: 1.2, x: 0, y: 0)
        }
        .frame(width: 74, height: 60)
        .shadow(color: theme.shadow, radius: 5, x: 0, y: 3)
    }
}

// MARK: - 一个任务圆圈

/// 今日一项任务一个圈：做完了打绿勾，没做完是空心圈。
///
/// 圈的**顺序**就是 `DailyPlanner` 排出来的顺序（开口 → 跟读 → 复习），
/// 位置天天固定，用户才能靠位置认出「第二项还没做」。
struct TaskDot: View {

    let isDone: Bool
    let theme: ForestTheme

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(isDone ? theme.success : theme.secondaryText.opacity(0.7), lineWidth: 1.6)
            if isDone {
                // 圈只有 14pt，勾再小就被抗锯齿吃掉了（实测 7pt 的勾几乎看不出绿）。
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(theme.success)
            }
        }
        .frame(width: 14, height: 14)
        .appAnimation(.panel, value: isDone)
    }
}
