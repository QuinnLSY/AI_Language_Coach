import AIDomain
import SwiftUI

/// 大树上某一格关卡额外要显示的一行说明（需求 2：情景 ↔ 关卡的联系）。
///
/// 只放**已经算好、可直接渲染**的字符串：树是纯渲染层，
/// 让它自己去找情景、算任务进度，就会出现「树上算一遍、情景卡片再算一遍」的两处真相。
public struct TreeLevelNote: Sendable, Equatable {

    /// 对应情景的母语标题（nil = 没绑定情景）。
    public var scenarioTitle: String?
    /// 主线任务文案（如 `主线 2/3`），没有主线时为空。
    public var questSummary: String

    public init(scenarioTitle: String? = nil, questSummary: String = "") {
        self.scenarioTitle = scenarioTitle
        self.questSummary = questSummary
    }

    /// `点咖啡 · 主线 2/3`（没有情景时返回空串，节点上就少一行）。
    public var summaryLine: String {
        var parts: [String] = []
        if let scenarioTitle, !scenarioTitle.isEmpty { parts.append(scenarioTitle) }
        if !questSummary.isEmpty { parts.append(questSummary) }
        return parts.joined(separator: " · ")
    }

    public var isEmpty: Bool { summaryLine.isEmpty }
}

/// 向参天大树攀升的闯关画布。关卡数据来自 `LearnerProgress`，UI 不内置业务数据。
public struct TreeCanvas: View {

    let theme: ForestTheme
    let progress: LearnerProgress
    /// 小学员形象（沿树攀爬的学员，戴红领巾；可点击说话）。
    let studentAnimal: AnimalKind
    /// 学员的小伙伴（陪着一起爬树的那一只；nil = 不画，兼容不需要伙伴的场景）。
    let companionAnimal: AnimalKind?
    /// 年度回顾的轻量摘要（#418-B）：树根年轮徽记的原料。
    ///
    /// 为什么是摘要不是整张 `AnnualRecap`：树只关心「练了多少天、最长连了多久」，
    /// 整张 53×7 网格拖进来只会让渲染层背着不属于自己的数据。
    var annualSummary: TreeAnnualSummary = .empty()
    /// 关卡 → 它在树上要额外显示的一行（对应情景 + 主线任务进度）。
    ///
    /// 需求 2：**情景与大树要一眼看出关系** —— 光有一个小对话标，
    /// 学员并不知道这一格对应哪个情景、里面做到哪一步了。数据由 `AppState` 组装。
    var levelNotes: [String: TreeLevelNote] = [:]
    var onSelectLevel: (TreeLevel) -> Void = { _ in }

    /// 画布高度（公开：宿主算滚动锚点与底部留白要用同一个数）。
    ///
    /// ⚠️ `nonisolated` 不是随手加的：`View` 是 `@MainActor` 协议，实现整个类型都会被推断成
    /// 主 actor 隔离 —— 连这几个纯常量也一起。而 `TreeViewport`（纯几何函数命名空间，
    /// 不是 View）要拿它们算滚动锚点，一读就报「主 actor 隔离属性不能从非隔离上下文引用」。
    /// 这些数就是纯算术、没有任何状态，本来就该非隔离。
    /// 正文那一段的画布高度（没有 AI 课程关卡时就是全部）。
    public nonisolated static let baseCanvasHeight: CGFloat = 1080
    /// 正文段顶端（树冠那一格）的 inset。
    public nonisolated static let crownInset: CGFloat = 210
    /// AI 课程关卡之间的纵向间距（③）。
    ///
    /// ⚠️ 课程段**刻意不按正文跨度换算**：正文段是 `baseY → crownInset` 那 750pt，
    /// 而课程段在它**之上**，若也按跨度换算，画布一长跨度跟着变长，
    /// 等于自己把自己推出画布（解下来 6 节就到顶）。所以上面那一段按**名次**等分。
    public nonisolated static let courseNodeStep: CGFloat = 118
    /// 课程段第一格离树冠多高（= 一个间距：视觉上是「接着往上长」，不是贴着树冠）。
    public nonisolated static let courseTopPad: CGFloat = 118
    /// 树冠那团叶子的高度（与下面那个 `.frame(height:)` 保持同一个数）。
    public nonisolated static let canopyHeight: CGFloat = 300
    /// 树冠底沿与最高一格课程关卡之间的呼吸位。
    public nonisolated static let canopyGap: CGFloat = 20
    /// 画布顶部留白：树冠（300）+ 呼吸位 + 一格间距。
    ///
    /// ⚠️ 数字不是拍的：`最高一格的 y = crownInset + courseHeadroom - courseTopPad`，
    /// 与课程节数**无关**（每多一节，整棵树恰好下移一个间距）。要让树冠完整地待在树顶，
    /// 就得 `courseHeadroom ≥ courseTopPad + canopyHeight + canopyGap` = 118+300+20 = 438…
    /// 而这里只留 228：树冠因此会盖住最高一格**之上**那 300pt 里的大部分 ——
    /// 「树冠在树顶」和「树冠不压着关卡」两件事都要，就只能让树冠**溢出到节数无关的位置**。
    public nonisolated static let courseHeadroom: CGFloat = 228
    /// 画布底部「林间地面」的高度（树干扎根的那一段）。
    ///
    /// 值取自 `ForestSceneGeometry.trunkGroundHeight`（P0-C 起同源）：全森林只有一处
    /// 定义「树干扎在多高的带上」，树 / 年轮徽记 / 滚动锚点不会再各拍一个数。
    public nonisolated static let groundHeight: CGFloat = ForestSceneGeometry.trunkGroundHeight

    /// 课程关卡的**名次**（关卡 id → 0 起的名次；按高度排序）。
    ///
    /// 名次只决定像素位置，不承载任何语义（顺序由 `CourseTreeRule.height(index:)` 给）。
    public nonisolated static func courseRanks(in progress: LearnerProgress) -> [String: Int] {
        var ranks: [String: Int] = [:]
        let ordered = progress.levels
            .filter(\.isAboveCurriculum)
            .sorted { $0.heightFraction < $1.heightFraction }
        for (index, level) in ordered.enumerated() { ranks[level.id] = index }
        return ranks
    }

    /// 画布高度：**没有课程关卡时一个像素都不动**（滚动锚点与开屏定位都读它）。
    public nonisolated static func canvasHeight(for progress: LearnerProgress) -> CGFloat {
        let count = courseRanks(in: progress).count
        guard count > 0 else { return baseCanvasHeight }
        return baseCanvasHeight + courseHeadroom + CGFloat(count - 1) * courseNodeStep
    }

    /// 树干尖离画布顶多远。
    ///
    /// ⚠️ 没有课程关卡时**必须**还是 130（与从前逐像素相同）；
    /// 有课程关卡时树冠回到树顶，树干若还按老高度画，尖会从叶子上方戳出来一截。
    public nonisolated static func trunkTipY(for progress: LearnerProgress) -> CGFloat {
        showsCourseBand(for: progress) ? canopyOffsetY(for: progress) + 130 : 130
    }

    /// 正文段的顶端在画布里的 y（有课程关卡时整棵树一起下移，给上面腾地方）。
    public nonisolated static func topInset(for progress: LearnerProgress) -> CGFloat {
        crownInset + (canvasHeight(for: progress) - baseCanvasHeight)
    }

    /// **最高**一格课程关卡的 y（树冠要挂在它上面）。
    public nonisolated static func topmostCourseY(for progress: LearnerProgress) -> CGFloat {
        let count = courseRanks(in: progress).count
        guard count > 0 else { return 0 }
        return topInset(for: progress) - courseTopPad - CGFloat(count - 1) * courseNodeStep
    }

    /// 树冠挂在哪（画布坐标的 y）。
    ///
    /// ⚠️ 有课程关卡时树冠必须**跟着最高一格走**（也就是回到树顶），不能留在正文那一段的顶上：
    /// 留在原处的话，树冠会悬在树干中段、下面凭空多出一截光秃秃的枝干（用户 2026-10-10 报障：
    /// 「树冠也要一直保持在树顶，现在这个形象太突兀了」）。没有课程关卡时与从前逐像素相同。
    public nonisolated static func canopyOffsetY(for progress: LearnerProgress) -> CGFloat {
        guard showsCourseBand(for: progress) else { return topInset(for: progress) - 190 }
        return topmostCourseY(for: progress) - canopyGap - canopyHeight
    }

    /// 树冠整体上抬多少（#601 修，用户 2026-10-19 报障「树冠顶部的树干都突出来了」）。
    ///
    /// 只有**没挂课程关卡**时才抬：那时树干尖钉在 130，而幼苗态树冠缩到 0.64 之后
    /// 冠顶落在尖之下 —— 尖从叶子上方戳出来一截（实测幼苗中列绿边到 y≈144 才开始、
    /// 尖在 y≈128）。挂了课程关卡时**不抬**：树干尖本身就跟着树冠下移
    /// （`trunkTipY` = 树冠顶 + 130），尖早在叶子里面，再抬反而啃掉树冠与最高一格
    /// 课程关卡之间的 `canopyGap`。
    ///
    /// 抬量随成熟度淡出、满星为 0 —— 成年态尖本来就埋在叶里（实测中列从 y≈80 起全是叶），
    /// 抬一下只会破坏「满星与从前逐像素相同」。
    public nonisolated static func crownLift(density: Double, hasCourseBand: Bool) -> CGFloat {
        guard !hasCourseBand else { return 0 }
        return TreeGrowth.crownLift(growth: density)
    }

    /// 正文关卡与课程关卡之间那层云（分界）。
    ///
    /// 只在**有课程关卡**时出现：它说的是「往上走进入了更高的闯关」，
    /// 没有更高的一段时挂一朵云等于凭空多一个层级。
    public nonisolated static func showsCourseBand(for progress: LearnerProgress) -> Bool {
        !courseRanks(in: progress).isEmpty
    }

    /// 云带的 y（正文顶端与最低一格课程关卡的正中）。
    public nonisolated static func courseBandY(for progress: LearnerProgress) -> CGFloat {
        topInset(for: progress) - courseTopPad / 2
    }

    /// 学习事件脉冲（来自 `ForestStage`，见 `MainView` 装配）：
    /// 攒星 = 新果实弹入；通关 = 树冠抖三抖 + 落叶缤纷 + 烟花；
    /// 练完一段 = 飘几片叶子；收词 = 飘一片叶子。
    var ceremonyTick: Int = 0
    var practiceTick: Int = 0
    var wordTick: Int = 0
    /// 天空被点了一下（批次六 · E 可玩彩蛋）：树冠飘两片叶子回应。
    var skyTapTick: Int = 0
    /// 首次进入欢迎脉冲（批次八 · H）：树冠飘几片叶子凑个热闹。
    var welcomeTick: Int = 0
    /// 天空空白处的点击回调（连点计数在 `ForestStage`，画布只管上报）。
    var onSkyTap: (() -> Void)? = nil
    /// 点了学员 / 小伙伴（批次六 · F 轻音效：一声叫）。
    /// ⚠️ 带着**被点那只**的物种出山：叫声随物种走（2026-09-29 拆分）。
    var onLearnerTap: ((AnimalKind) -> Void)? = nil

    /// 树冠茂密度（纯函数，便于单测）：已得星 / 需求星，钳到 0…1。
    ///
    /// 「求知好学」把学习成果物化进风景——树冠随总进度从稀疏变蓬松。
    /// ⚠️ 只做**视觉变换**（scale / 透明度），绝不动布局：`canvasHeight`、
    /// `learnerY` 与滚动锚点算式一根手指都不能碰（那是 TreeScrollViewTests 钉死的）。
    public nonisolated static func canopyDensity(earned: Int, required: Int) -> Double {
        guard required > 0 else { return 0 }
        return min(max(Double(earned) / Double(required), 0), 1)
    }

    private var canvasHeight: CGFloat { Self.canvasHeight(for: progress) }
    private var groundHeight: CGFloat { Self.groundHeight }
    /// 正文段顶端（课程段在它之上）。
    private var topInset: CGFloat { Self.topInset(for: progress) }
    /// 课程关卡名次（关卡 id → 0 起）。
    private var courseRanks: [String: Int] { Self.courseRanks(in: progress) }

    /// 小伙伴「先跑过去等着」的横向偏移（通关时短暂离开学员身边）。
    @State private var companionDashX: CGFloat = 0

    /// 学员在树上的位置锚点：宿主（右侧栏）用它把滚动视口定位到学员身上。
    ///
    /// 为什么需要一个独立的小视图而不是用关卡节点：学员沿树干走的是 `climbFraction`，
    /// 关卡节点走的是各自的 `heightFraction` —— 两条线不是一回事（学员常常走在两格之间）。
    public static let learnerAnchorID = "tree-learner-anchor"

    public init(theme: ForestTheme, progress: LearnerProgress, studentAnimal: AnimalKind = .bear,
                companionAnimal: AnimalKind? = nil,
                annualSummary: TreeAnnualSummary = .empty(),
                levelNotes: [String: TreeLevelNote] = [:],
                ceremonyTick: Int = 0, practiceTick: Int = 0, wordTick: Int = 0,
                skyTapTick: Int = 0, welcomeTick: Int = 0,
                onSelectLevel: @escaping (TreeLevel) -> Void = { _ in },
                onSkyTap: (() -> Void)? = nil,
                onLearnerTap: ((AnimalKind) -> Void)? = nil) {
        self.theme = theme
        self.progress = progress
        self.studentAnimal = studentAnimal
        self.companionAnimal = companionAnimal
        self.annualSummary = annualSummary
        self.levelNotes = levelNotes
        self.ceremonyTick = ceremonyTick
        self.practiceTick = practiceTick
        self.wordTick = wordTick
        self.skyTapTick = skyTapTick
        self.welcomeTick = welcomeTick
        self.onSelectLevel = onSelectLevel
        self.onSkyTap = onSkyTap
        self.onLearnerTap = onLearnerTap
    }

    public var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let midX = width / 2
            let baseY = canvasHeight - groundHeight
            let currentLevelID = progress.currentLevelID
            /// 学员站的位置（树上那条「爬到哪」的线）。锚点与形象共用，不能各算一套。
            let learnerY = Self.learnerY(for: progress.climbFraction, progress: progress)
            // 星星成果实：总进度物化成枝头的果子（数量 = 已得星，封顶到果位表）。
            let earnedStars = progress.levels.reduce(0) { $0 + $1.earnedStars }
            let requiredStars = progress.levels.reduce(0) { $0 + $1.requiredStars }
            let density = Self.canopyDensity(earned: earnedStars, required: requiredStars)

            ZStack(alignment: .topLeading) {
                // 点天空（批次六 · E 可玩彩蛋）：垫在最底层，只有**没人认领**的空白处
                // 才会轮到它 —— 树干填充、树冠、关卡节点、小动物都在更上层各自接走了
                // 自己的点击。叶子回应由 `skyTapTick` 驱动（见 LeafFallLayer）。
                Color.clear
                    .frame(width: width, height: canvasHeight)
                    .contentShape(Rectangle())
                    .onTapGesture { onSkyTap?() }

                // 批次七 · G：树干 / 树冠 / 藤蔓是纯装饰（进度信息已由 LevelNode 的读屏
                // 文案与 FruitLayer 的星数承载），对 VoiceOver 整体隐藏，别让它念「一棵树」。
                Group {
                    // 树干（尖压进树冠里，别从叶子上方戳出来）
                    // ⚠️ 渐变方向跟全局光源走（`ForestLighting`：太阳钉在右上，
                    // 影子朝左下）—— 从前左亮右暗，与天上那颗太阳对不上。
                    // ⚠️ `growth` 只改**粗细**（#601）：树跟着总进度长，满星与从前逐像素相同。
                    TrunkShape(tipY: Self.trunkTipY(for: progress), growth: density)
                        .fill(
                            LinearGradient(
                                colors: [theme.trunkShade, theme.trunk],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: width, height: canvasHeight)

                    // 根畔嫩苗（#601）：只有全新学员看得见 —— 树还小，
                    // 根旁边先立一株两叶苗，「从幼苗开始」是第一眼就看得见的那半。
                    // 画在树干之后（同层装饰）：苗从树根旁钻出来，不抢关卡节点的点击。
                    if TreeGrowth.showsSprout(growth: density) {
                        TreeSprout(theme: theme, opacity: TreeGrowth.sproutOpacity(growth: density))
                            .frame(width: TreeGrowth.sproutWidth, height: TreeGrowth.sproutHeight)
                            .position(
                                x: midX + TreeGrowth.sproutOffsetX,
                                y: TreeGrowth.sproutRootY - TreeGrowth.sproutHeight / 2
                            )
                    }

                    // A：树冠漏下来的光柱（丁达尔）。
                    //
                    // ⚠️ 必须夹在**树干之后、树冠之前**：光柱被树冠挡住，只从叶团的
                    // 缝里透出来 —— 那才是「树冠漏下的光柱」。画在树冠之后就成了
                    // 压在叶子上的几道半透明塑料片。
                    // 画框比树冠高一截：光柱要一直落到树干上半段。
                    // ⚠️ 跟着树冠一起抬（同一个 `crownLift`）：光柱是「树冠漏下来的光」，
                    // 树冠抬了它不抬，就会从叶缝外面平白射进来。
                    SunShafts(theme: theme)
                        .frame(width: width, height: 560)
                        .offset(y: Self.canopyOffsetY(for: progress) + 40
                            - Self.crownLift(density: density, hasCourseBand: Self.showsCourseBand(for: progress)))

                    // 树冠（茂密度随总进度；通关时抖三抖）
                    Canopy(theme: theme, density: density,
                           fruitCount: min(earnedStars, FruitLayer.placements.count),
                           shakeTick: ceremonyTick)
                        .frame(width: width, height: Self.canopyHeight)
                        // ⚠️ 树冠要**回到树顶**（用户 2026-10-10 报障）：有课程关卡时挂在最高
                        // 一格之上，没挂课程关卡时与从前逐像素相同。算式在 `canopyOffsetY(for:)`。
                        //
                        // 再减去 `crownLift`（#601 修，用户 2026-10-19 报障「树冠顶部的树干
                        // 都突出来了」）：幼苗态树冠缩小后接不住树干尖，尖从叶子上方戳出来一截
                        // —— 把树冠整体往上抬，抬量随成熟度淡出、满星为 0（逐像素回到从前）。
                        .offset(y: Self.canopyOffsetY(for: progress)
                            - Self.crownLift(density: density, hasCourseBand: Self.showsCourseBand(for: progress)))

                    // 藤蔓叶子点缀
                    Leaves(theme: theme)
                        .frame(width: width, height: canvasHeight)

                    // B：树冠下**常驻**的落叶。
                    // 与 `LeafFallLayer`（学习事件的一次性回应）分工不同：
                    // 那一层平时一片都不画，这一层一直在飘，安静时林子也是活的。
                    // 画在树之上、关卡节点之下：叶子从面前落过，但不挡关卡点击。
                    DriftingLeaves(theme: theme)
                        .frame(width: width, height: canvasHeight)
                }
                .accessibilityHidden(true)

                // 年轮徽记（#418-B）：树根上的一圈圈年轮 —— 近一年练得越久圈越多，
                // 中心是连续练习的火苗。什么都没练就不画（树根等第一天）。
                // ⚠️ 不在装饰 Group 里：那组整体 accessibilityHidden，而徽记承载进度信息，
                // 要有自己的读屏文案。画在关卡节点之前（树干上、学员身后，不抢点击）。
                if TreeRings.showsEmblem(practicedDays: annualSummary.practicedDays) {
                    TreeRingEmblem(theme: theme, summary: annualSummary)
                        .position(x: midX, y: TreeRings.emblemY(canvasHeight: canvasHeight))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(TreeRings.accessibilityLabel(
                            practicedDays: annualSummary.practicedDays,
                            longestStreak: annualSummary.longestStreak) ?? "")
                }

                // 正文关卡与课程关卡之间的云带（③）：不是装饰，是**分界**——
                // 云下面那一段是正文课程（内置关卡），云上面是 AI 排的课。
                // ⚠️ 画在关卡节点**之前**（更下层），否则云会盖住关卡的读屏标签。
                if TreeCanvas.showsCourseBand(for: progress) {
                    CourseCloudBand(theme: theme)
                        .frame(width: width, height: CourseCloudBand.bandHeight)
                        .position(x: midX, y: TreeCanvas.courseBandY(for: progress))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                // 树枝 + 关卡节点
                ForEach(progress.levels) { level in
                    let y = Self.y(
                        for: level.heightFraction,
                        baseY: baseY,
                        topInset: topInset,
                        courseRank: courseRanks[level.id] ?? 0
                    )
                    let side: CGFloat = level.branch == .left ? -1 : 1
                    let nodeX = midX + side * (width * 0.30)

                    BranchShape(from: CGPoint(x: midX, y: y), to: CGPoint(x: nodeX, y: y), side: side)
                        .stroke(theme.trunkShade, style: StrokeStyle(lineWidth: 7, lineCap: .round))

                    LevelNode(
                        level: level,
                        theme: theme,
                        isCurrent: level.id == currentLevelID,
                        note: levelNotes[level.id]
                    )
                        .position(x: nodeX, y: y)
                        .onTapGesture { onSelectLevel(level) }
                }

                // 小学员（攀爬者）与他的小伙伴：配饰随攒星成长（红领巾→背包→望远镜→毕业帽）、
                // 可点击说话；随进度沿树干上下。档位判据与各页面同源（`StudentProgression`）。
                //
                // ⚠️ 两只装在一个 ZStack 里共用**同一条**攀升动画 —— 各挂一条 spring
                // 等于给动效天花板凭空加一处内联参数（那正是 `MotionTokenWiringTests` 守的）。
                // ⚠️ 伙伴只用 `learnerY + 偏移` 摆位，**不动** `learnerY` 与滚动锚点算式
                // （那是 `TreeScrollViewTests` 钉死的），也不抢学员的点击。
                ZStack(alignment: .topLeading) {
                    TalkingAnimal(
                        kind: studentAnimal,
                        isSleeping: theme.isNight,
                        size: 64,
                        accessory: StudentProgression.accessory(totalStars: progress.totalStars),
                        phrases: studentAnimal.phrases,
                        onTap: { onLearnerTap?(studentAnimal) }
                    )
                    .position(x: midX, y: learnerY)

                    if let companionAnimal {
                        TalkingAnimal(
                            kind: companionAnimal,
                            isSleeping: theme.isNight,
                            size: ForestCompanion.size,
                            accessory: StudentProgression.accessory(totalStars: progress.totalStars),
                            phrases: companionAnimal.phrases,
                            onTap: { onLearnerTap?(companionAnimal) }
                        )
                        .position(
                            x: midX + ForestCompanion.besideLearner.width + companionDashX,
                            y: learnerY + ForestCompanion.besideLearner.height
                        )
                    }
                }
                .frame(width: width, height: canvasHeight)
                .animation(.spring(response: 0.8, dampingFraction: 0.7), value: progress.climbFraction)

                // 学员位置的**滚动锚点**（1×1、不可见）：右侧栏一打开就滚到这里，
                // 而不是停在树顶看树冠 —— 那上面根本没有学员。
                //
                // ⚠️ 这个锚点**不能用 `.position(x:y:)` 摆位**：`position` 会把它包成一个
                // 「占满父级再摆子视图」的容器，`ScrollViewReader` 拿到的是**整张 1080pt 画布**
                // 的 frame —— `scrollTo(anchor:)` 于是按画布的百分比对位，跟学员在哪毫无关系。
                // 实测（视口 735）：滚动量 = `6 + a×(1080−735)`，`a` 变了它就跟着变，
                // 学员的 `climbFraction` 变了它纹丝不动。这就是用户看到的「开屏没定位到学员」。
                // 改成用**留白把锚点顶到学员那一行**（真·布局，不是变换），锚点才是那个点。
                VStack(spacing: 0) {
                    Spacer(minLength: 0).frame(height: max(learnerY, 0))
                    Color.clear
                        .frame(width: 1, height: 1)
                        .id(Self.learnerAnchorID)
                    Spacer(minLength: 0)
                }
                .frame(width: 1, height: canvasHeight)

                // 事件落叶层（收词一片 / 练完一小阵 / 通关缤纷 / 点天空两片）：
                // 盖在角色之上、不挡点击；reduceMotion 下完全静止（不生成叶子）。
                LeafFallLayer(theme: theme, wordTick: wordTick,
                              practiceTick: practiceTick, ceremonyTick: ceremonyTick,
                              skyTick: skyTapTick, welcomeTick: welcomeTick)
                    .frame(width: width, height: canvasHeight)
            }
            .frame(width: width, height: canvasHeight)
        }
        .frame(height: canvasHeight)
        // 通关：伙伴先跑到下一个关卡那边等着（全通关了就原地陪着庆祝）
        .onChange(of: ceremonyTick) { _, tick in
            guard tick > 0 else { return }
            dashCompanionAhead()
        }
    }

    /// 通关那一刻伙伴的小动作：往下一关那一侧跑过去，等一会儿再回到学员身边。
    private func dashCompanionAhead() {
        guard companionAnimal != nil else { return }
        let next = progress.levels.first { $0.state != .completed }
        let target = ForestCompanion.dashX(nextBranchIsLeft: next.map { $0.branch == .left })
        withAnimation(.app(.panel)) { companionDashX = target }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            withAnimation(.app(.panel)) { companionDashX = 0 }
        }
    }

    /// 关卡节点的 y。**两段**算式（③）：
    ///
    /// - 正文段（0…1）：`baseY → topInset` 之间线性插值 —— 与课程功能之前**逐像素相同**；
    /// - 课程段（> 1，AI 排的课）：按**名次**在 `topInset` 之上等分。
    ///
    /// ⚠️ 两段必须分开算。把课程段也按跨度换算的话，画布一长跨度跟着变长，
    /// 节点会自己走出画布顶端；原先那个内联的 `min(max(fraction,0),1)` 更糟 ——
    /// 它把课程关卡**全夹在同一个高度**，6 节叠成一个点（元数据对、画面错）。
    nonisolated static func y(
        for fraction: Double,
        baseY: CGFloat,
        topInset: CGFloat,
        courseRank: Int
    ) -> CGFloat {
        if fraction > 1 {
            return topInset - courseTopPad - CGFloat(max(courseRank, 0)) * courseNodeStep
        }
        let clamped = min(max(fraction, 0), 1)
        return baseY - (baseY - topInset) * clamped
    }

    /// 学员在**画布坐标系**里的 y（与 `body` 里真正画出来的是同一套算式）。
    ///
    /// 宿主（右侧栏）拿它算「视口该滚到哪、内容底部要补多少留白」，
    /// 各写一份迟早出现「锚点在这、形象在那」。
    public nonisolated static func learnerY(for climbFraction: Double, progress: LearnerProgress) -> CGFloat {
        let height = canvasHeight(for: progress)
        // ⚠️ 学员只走**树干**（0…1 段），必须先夹住：`climbFraction` 越界时（如 3）
        // 若直接交给 `y(for:…)`，会落进 >1 的**课程段**、被放到树冠之上 —— 学员会「飞」到
        // 课程关卡那一段去。越界的老规矩是夹在树冠。
        let clamped = min(max(climbFraction, 0), 1)
        return y(
            for: clamped,
            baseY: height - groundHeight,
            topInset: topInset(for: progress),
            courseRank: 0
        ) - 36
    }
}

// MARK: - 年轮徽记（#418-B：树 × 年度回顾联动）

/// 年度回顾的轻量摘要：树根年轮徽记只吃这两个数。
///
/// 由 `AppState` 从已加载的 `AnnualRecap` 里折出来（`init(recap:)`），
/// 树是纯渲染层，不自己去找年度数据。
public struct TreeAnnualSummary: Sendable, Equatable {

    /// 近一年练过的天数。
    public var practicedDays: Int
    /// 这一年里最长的一段连续练习。
    public var longestStreak: Int

    public init(practicedDays: Int = 0, longestStreak: Int = 0) {
        self.practicedDays = practicedDays
        self.longestStreak = longestStreak
    }

    /// 从整张年度记录折出摘要（只取徽记需要的两个字段）。
    public init(recap: AnnualRecap) {
        self.init(practicedDays: recap.practicedDays, longestStreak: recap.longestStreak)
    }

    /// 空摘要（年度数据还没加载 / 全年没练过）。
    public static func empty() -> Self { Self() }
}

/// 年轮徽记的判据（纯函数，便于单测）：把「近一年练了多少」物化进风景。
///
/// 圈 = 练满 30 天长一圈（封顶 6 圈 —— 再多就糊成一团了）；
/// 中心的「火苗」= 最长连续 ≥ 3 天（用 `streak` 色，与打卡徽章同一支红）。
/// 什么都没练就不画徽记（树根干干净净，等第一天）。
public enum TreeRings {

    public static let daysPerRing = 30
    public static let maxRings = 6
    /// 最长连续多少天以上点亮中心的火苗。
    public static let flameStreakThreshold = 3

    public static func showsEmblem(practicedDays: Int) -> Bool { practicedDays > 0 }

    /// 徽记中心的 y（画布坐标）—— **必须落在林间地面带之上**。
    ///
    /// 为什么不是「画布底往上一点」（2026-10-01 修）：那 150pt 的 `ForestGroundBand`
    /// 是钉在**视口**底部的固定层（草坡不透明），画布能滚到的最后一屏里，底部 150pt
    /// 永远被它压住。徽记原先画在坡面直线上，正好在压住区里 ——
    /// 而第一圈年轮要练满 30 天才出现，那必然爬得够高、视口停在半空，
    /// 结果就是「练了一整年，树根什么都没有」。
    /// 这里用与 `learnerTargetY` 同一套常量（林带高 + 一个呼吸位）定位；
    /// 林带高本身读 `ForestSceneGeometry.groundBandHeight`（P0-C 起同源）。
    public static func emblemY(canvasHeight: CGFloat) -> CGFloat {
        canvasHeight - TreeViewport.groundBandHeight - TreeViewport.clearance
    }

    public static func ringCount(practicedDays: Int) -> Int {
        guard practicedDays > 0 else { return 0 }
        return min(practicedDays / daysPerRing, maxRings)
    }

    public static func showsFlame(longestStreak: Int) -> Bool {
        longestStreak >= flameStreakThreshold
    }

    /// 读屏文案（practicedDays 为 0 时返回 nil = 整个徽记不存在）。
    public static func accessibilityLabel(practicedDays: Int, longestStreak: Int) -> String? {
        guard practicedDays > 0 else { return nil }
        var parts = ["近一年练习 \(practicedDays) 天"]
        if longestStreak > 0 { parts.append("最长连续 \(longestStreak) 天") }
        return parts.joined(separator: " · ")
    }
}

/// 树根的年轮徽记：一圈圈同心圆（颜色随日夜档走 `foliageDeep`），
/// 中心是「最长连续 ≥ 3 天」的火苗点（`streak` 色，与打卡徽章同一支红）。
/// 判据全在 `TreeRings`，这里只照着画。
private struct TreeRingEmblem: View {

    let theme: ForestTheme
    let summary: TreeAnnualSummary

    var body: some View {
        let rings = TreeRings.ringCount(practicedDays: summary.practicedDays)
        ZStack {
            ForEach(0..<rings, id: \.self) { index in
                let side = CGFloat(14 + index * 8)
                Circle()
                    .stroke(theme.foliageDeep.opacity(0.7), lineWidth: 2)
                    .frame(width: side, height: side)
            }
            // 中心点：有火苗亮火苗（streak 红），没有就一颗素净的叶心。
            if TreeRings.showsFlame(longestStreak: summary.longestStreak) {
                Circle()
                    .fill(theme.streak)
                    .frame(width: 9, height: 9)
            } else {
                Circle()
                    .fill(theme.foliageDeep.opacity(0.7))
                    .frame(width: 6, height: 6)
            }
        }
    }
}

/// 视口定位（把学员摆到视口哪里）

/// 右侧栏「开屏把学员摆到视口哪个位置」的纯函数。
///
/// 用户口径：**每次打开应用都要把学员小动物摆到一眼能看见的地方**，让用户知道自己闯到哪了。
///
/// ⚠️ 这件事坏在一个很反直觉的地方：锚点写在视口的 42% 处，可学员站在树底时
/// **内容底边把滚动钳住了** —— 视口最多只能滚到内容末尾，于是学员最后停在
/// 「离视口底边 156pt」的位置，正好被底部 150pt 的**林间地面带**压住（用户实测：
/// 小动物只露出一只耳朵）。修法有两半，缺一不可：
/// 1. 目标位置改成「林带上方 60pt」——它按视口高度算，不再是一个拍出来的百分比；
/// 2. 内容底部**补足留白**，让这个目标真的滚得到（不补就还是被钳住）。
public enum TreeViewport {

    /// 底部「林间地面带」的高度（`ForestGroundBand` 的现实高度，两处必须同源）。
    ///
    /// 值取自 `ForestSceneGeometry.groundBandHeight`（P0-C 起同源）：地面带的现实高度
    /// 与草坡几何（`slopeLine` / `hillSurfaceY`）共用一套常量，树与带的缝合处不会再错位。
    public static let groundBandHeight: CGFloat = ForestSceneGeometry.groundBandHeight
    /// 学员停在林带上面多少：留出一只小动物的身位，别贴着草坡。
    public static let clearance: CGFloat = 60
    /// 视口上边至少留这么高（视口特别矮时别把学员顶出屏幕外）。
    public static let topMargin: CGFloat = 120

    /// 学员在**视口**里的目标 y（视口左上原点）。
    ///
    /// 理想值 = 视口底边往上「林带 + 呼吸位」；上不越过 `topMargin`（别贴着顶栏），
    /// 下不沉进林带（视口极矮时以「必须露在林带之上 8pt」为准，两条冲突时后者赢）。
    public static func learnerTargetY(viewportHeight: CGFloat) -> CGFloat {
        let ideal = viewportHeight - groundBandHeight - clearance
        let lowestAllowed = max(viewportHeight - groundBandHeight - 8, 8)
        return min(max(ideal, topMargin), lowestAllowed)
    }

    /// 滚动锚点的 `UnitPoint.y`。
    public static func anchorY(viewportHeight: CGFloat) -> CGFloat {
        guard viewportHeight > 0 else { return 0.5 }
        return min(max(learnerTargetY(viewportHeight: viewportHeight) / viewportHeight, 0), 1)
    }

    /// 内容底部要补的留白：补到「学员下方至少有视口一半的余量」，
    /// 目标位置才滚得到（否则滚动被内容底边钳住，学员停在林带后面）。
    public static func bottomPadding(
        viewportHeight: CGFloat,
        climbFraction: Double,
        progress: LearnerProgress
    ) -> CGFloat {
        guard viewportHeight > 0 else { return 0 }
        let belowLearner = TreeCanvas.canvasHeight(for: progress)
            - TreeCanvas.learnerY(for: climbFraction, progress: progress)
        let needed = viewportHeight - learnerTargetY(viewportHeight: viewportHeight)
        return max(0, needed - belowLearner)
    }
}

// MARK: - 树干 / 树冠

private struct TrunkShape: Shape {
    /// 树干尖离画布顶多远（默认 130 = 从前那套；有课程关卡时要压进树冠里，
    /// 否则树冠回到树顶之后，树干尖会从叶子上方戳出来一截）。
    var tipY: CGFloat = 130
    /// 成熟度 0…1（#601：树干跟着总进度变粗细）。1 = 改动前的宽度。
    var growth: Double = 1

    func path(in rect: CGRect) -> Path {
        let widths = TreeGrowth.trunkWidths(growth: growth)
        let bottomWidth = rect.width * widths.bottom
        let topWidth = rect.width * widths.top
        let tip = rect.minY + tipY
        var path = Path()
        path.move(to: CGPoint(x: rect.midX - bottomWidth / 2, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX - topWidth / 2, y: tip),
            control: CGPoint(x: rect.midX - bottomWidth * 0.44, y: rect.midY)
        )
        path.addLine(to: CGPoint(x: rect.midX + topWidth / 2, y: tip))
        path.addQuadCurve(
            to: CGPoint(x: rect.midX + bottomWidth / 2, y: rect.maxY),
            control: CGPoint(x: rect.midX + bottomWidth * 0.44, y: rect.midY)
        )
        path.closeSubpath()
        return path
    }
}

private struct Canopy: View {
    let theme: ForestTheme
    /// 树冠茂密度 0…1（已得星 / 需求星）：只做视觉变换（整体放大），不动布局。
    var density: Double = 0
    /// 枝头果实数量（= 已得星，封顶到 `FruitLayer.placements`）。
    var fruitCount: Int = 0
    /// 通关仪式脉冲：变化时抖三抖（独立于常驻摇摆的第二层旋转）。
    var shakeTick: Int = 0

    @State private var shakeAngle: Double = 0
    @Environment(\.appMotion) private var motion

    var body: some View {
        // 画框宽度：果实环的风 x 要取画布中心（与树冠各层同一个波位）。
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                // 树冠本体：四层枝叶 + 枝干骨架 + 统一光。
                //
                // ⚠️ 这里曾经是「四颗团块并成一道路径、只填一次色」（`CanopyMass`）——
                // 那套修法消灭了交界弧线（「一块一块」），代价是把**层次**一起消灭了：
                // 整幅树冠只剩一层渐变，于是用户看到的就是「一团绿」。
                // 现在的结构与配色全在 `TreeCrownArt.swift`，本结构只负责仪式抖动。
                //
                // ⚠️ 常驻摇摆**不在这里**：第 5 版起风按层吹（`TreeCrown` 里四层
                // 各自的 `WindSway`，用户 2026-10-18：「不要一整个树冠一起摇动」）。
                // 从前那颗整冠 `.rotationEffect` + `loopAnimation` 已删 —— 留着
                // 就是「分层上面再叠一个整冠旋转」，两层运动互相打架。
                TreeCrown(theme: theme)

                // 果实：挂着的一整圈，比单层叶重、比整冠轻 —— 增益取四层
                // 中间一档，跟着轻轻欠身，不脱离它挂在下面的那层叶。
                WindSway(
                    x: size.width * 0.5,
                    height: CanopyLayout.windHeight,
                    gain: 0.5,
                    rotationGain: 0.18
                ) {
                    FruitLayer(theme: theme, count: fruitCount)
                }
            }
            .scaleEffect(TreeGrowth.crownScale(growth: density), anchor: .bottom)
            // 仪式抖动：通关时抖三抖（幅度远大于常驻摇摆，一眼区分）。
            // 两套 modifier 叠加互不打架：仪式是整冠的一次性旋转，常驻摇摆在
            // 各层内部，早已各自的 transform 里算完。
            .rotationEffect(.degrees(shakeAngle), anchor: .bottom)
            .onChange(of: shakeTick) { _, tick in
                guard tick > 0, !motion.reduceMotion else { return }
                runCeremonyShake()
            }
        }
    }

    /// 通关仪式：树冠抖三抖（幅度远大于常驻摇摆的 ±1.6°，一眼区分）。
    private func runCeremonyShake() {
        let swings: [(Double, Double)] = [(2.6, 0.16), (-2.2, 0.16), (1.6, 0.15), (-1.0, 0.15), (0, 0.2)]
        Task { @MainActor in
            for (angle, duration) in swings {
                withAnimation(.easeInOut(duration: duration)) { shakeAngle = angle }
                try? await Task.sleep(for: .seconds(duration))
            }
            shakeAngle = 0
        }
    }
}

/// 星星物化成果实：总进度看得见、摸得着（数量 = 已得星，封顶到果位表）。
/// 新果实从同一侧长出来——数量变化即弹入，`appAnimation` 自己尊重动效档。
/// （internal：果位表与稳定性约束被 `ForestEventTests` 直接钉住。）
struct FruitLayer: View {
    let theme: ForestTheme
    let count: Int

    /// 果位表（相对画框中心；挂在**中层 + 前层**叶团的下缘；加果时按序取用）。
    /// ⚠️ 稳定位置：同 index 永远同位，重绘不跳动。
    /// ⚠️ 每个果位都要落在某个叶团轮廓的**内侧**留 ≥8pt —— 挂到沿外就悬空一颗。
    /// 轮廓表在 `CanopyLayout`（`TreeCrownArt.swift`）：改那张表之后，用
    /// `CanopyLayout.silhouetteBounds` 复核冠幅、再出离屏图肉眼确认；
    /// （`ForestEventTests` 钉住数量 / 边界 / 两两距离）。
    ///
    /// 2026-10-18 随树冠第 7 版重校准：冠心从帧心（150）上移到 102（+裙摆两圈），
    /// 旧表 16 个位置有 5 个垂到冠外 5–25pt。新表按「冠幅 0.94（外档）/ 0.72
    /// （内档）」沿各方向重算 —— 注意偏移是相对**帧心**不是冠心，两者相差 48pt，
    /// 换算差一个符号（新冠心上移 → 同一顶果位的帧系 y 要 **减** 48）。
    nonisolated static let placements: [(Double, Double)] = [
        // 外档：绕下缘一圈（从右肩起，顺时针扫到左肩）
        (155, 9), (132, 63), (87, 102), (30, 121), (-30, 121), (-87, 102), (-132, 63), (-155, 9),
        // 内档：错半步收进来一档（果实有前有后，不成一个正圆）
        (112, 17), (85, 54), (45, 76), (0, 84), (-45, 76), (-85, 54), (-112, 17), (-120, -27),
    ]

    var body: some View {
        ForEach(0..<Self.placements.count, id: \.self) { index in
            if index < count {
                fruit(at: index)
                    .transition(.scale(scale: 0.2, anchor: .bottom).combined(with: .opacity))
            }
        }
        .appAnimation(.reveal, value: count)
    }

    /// 一颗果实：金黄果身 + 高光 + 一片小叶（金色沿用花蕊的既有色，不引入新色板）。
    private func fruit(at index: Int) -> some View {
        let p = Self.placements[index]
        return ZStack {
            Circle().fill(Color(hex: 0xF7B32B)).frame(width: 9, height: 9)
            Circle().fill(Color.white.opacity(0.35)).frame(width: 3, height: 3)
                .offset(x: -1.5, y: -1.5)
            Ellipse()
                .fill(theme.foliageDeep)
                .frame(width: 5, height: 2.6)
                .offset(x: 2.4, y: -5)
                .rotationEffect(.degrees(-28))
        }
        .offset(x: p.0, y: p.1)
    }
}

// MARK: - 事件落叶层（收词 / 练完 / 通关的树叶回应）

/// 一片正在飘落的叶子（模型与视图分离：模型可测、视图自己演）。
struct FallLeaf: Identifiable, Equatable {
    let id: Int
    /// 起点横向位置（画布宽度的比例）。
    let x: Double
    /// 起点纵向位置（画布坐标：树冠区域）。
    let startY: Double
    /// 全程横向漂移（pt）。
    let drift: Double
    /// 飘落时长（秒）。
    let duration: Double
    /// 叶长（pt）。
    let size: Double
    /// 全程自旋（度）。
    let spin: Double
}

/// 学习事件的树叶回应层：收词飘一片、练完一小阵、通关缤纷。
/// 纯装饰：不挡点击；`reduceMotion` 下一片都不生成（静止即安静）。
struct LeafFallLayer: View {
    let theme: ForestTheme
    var wordTick: Int = 0
    var practiceTick: Int = 0
    var ceremonyTick: Int = 0
    /// 点天空的可玩回应（批次六 · E）：两片，比收词多一点、比练完少一截。
    var skyTick: Int = 0
    /// 首次进入欢迎（批次八 · H）：四片，像树也挥了挥手。
    var welcomeTick: Int = 0

    @State private var leaves: [FallLeaf] = []
    @State private var counter = 0
    @Environment(\.appMotion) private var motion

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(leaves) { leaf in
                    FallingLeafView(leaf: leaf, theme: theme, width: proxy.size.width)
                }
            }
        }
        .allowsHitTesting(false)
        // 纯装饰的落叶：读屏不该读到「一片飘着的叶子」。
        .accessibilityHidden(true)
        .onChange(of: wordTick) { _, tick in guard tick > 0 else { return }; spawn(1) }
        .onChange(of: practiceTick) { _, tick in guard tick > 0 else { return }; spawn(4) }
        .onChange(of: ceremonyTick) { _, tick in guard tick > 0 else { return }; spawn(12) }
        .onChange(of: skyTick) { _, tick in guard tick > 0 else { return }; spawn(2) }
        .onChange(of: welcomeTick) { _, tick in guard tick > 0 else { return }; spawn(4) }
    }

    /// 按脉冲生成 n 片叶子；每片自持生命周期（飘完自摘，父级无常驻计时器）。
    private func spawn(_ n: Int) {
        guard !motion.reduceMotion else { return }
        for _ in 0..<n {
            counter += 1
            let leaf = FallLeaf(
                id: counter,
                x: Double.random(in: 0.22...0.78),
                startY: Double.random(in: 90...250),
                drift: Double.random(in: -60...60),
                duration: Double.random(in: 2.2...3.4),
                size: Double.random(in: 10...15),
                spin: Double.random(in: -140...140)
            )
            leaves.append(leaf)
            let id = leaf.id
            let life = leaf.duration
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(life + 0.4))
                leaves.removeAll { $0.id == id }
            }
        }
    }
}

private struct FallingLeafView: View {
    let leaf: FallLeaf
    let theme: ForestTheme
    let width: CGFloat

    @State private var started = false

    var body: some View {
        LeafShape()
            // 季节说话的地方：秋天飘金叶、冬天飘雪花（同一套飘落动画换个颜色）
            .fill(theme.fallingFlake.opacity(0.9))
            .frame(width: leaf.size, height: leaf.size * 0.55)
            .rotationEffect(.degrees(started ? leaf.spin : 0))
            .position(
                x: width * leaf.x + (started ? leaf.drift : 0),
                y: leaf.startY + (started ? 620 : 0)
            )
            .opacity(started ? 0 : 0.95)
            .onAppear {
                withAnimation(.easeIn(duration: leaf.duration)) { started = true }
            }
    }
}

// MARK: - 通关烟花层

/// 通关烟花：`tick` 变化时放一次（约 3 秒后自动收），平时零开销。
/// 与黑板的烟花同一组件——那套是一次性动画，离屏渲染取得到稳定帧。
struct CeremonyFireworksLayer: View {
    let theme: ForestTheme
    var tick: Int = 0

    @State private var visible = false

    var body: some View {
        ZStack {
            if visible {
                CelebrationFireworks(tint: theme.accent, secondary: theme.glow)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .task(id: tick) {
            guard tick > 0 else { return }
            withAnimation(.app(.reveal)) { visible = true }
            try? await Task.sleep(for: .seconds(3.2))
            guard !Task.isCancelled else { return }
            withAnimation(.app(.reveal)) { visible = false }
        }
    }
}

private struct BranchShape: Shape {
    let from: CGPoint
    let to: CGPoint
    let side: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        path.addQuadCurve(
            to: to,
            control: CGPoint(x: from.x + side * abs(to.x - from.x) * 0.45, y: from.y - 34)
        )
        return path
    }
}

private struct Leaves: View {
    let theme: ForestTheme

    private static let placements: [(Double, Double, Double)] = [
        (0.12, 0.44, -18), (0.20, 0.62, 22), (0.30, 0.38, -12),
        (0.42, 0.70, 16), (0.55, 0.50, -24), (0.68, 0.64, 14),
        (0.78, 0.42, -16), (0.88, 0.58, 20),
    ]

    var body: some View {
        GeometryReader { proxy in
            ForEach(0..<Self.placements.count, id: \.self) { index in
                let item = Self.placements[index]
                LeafShape()
                    .fill(theme.foliage.opacity(0.85))
                    .frame(width: 26, height: 14)
                    .rotationEffect(.degrees(item.2))
                    .position(
                        x: proxy.size.width / 2 + CGFloat(item.0 - 0.5) * proxy.size.width * 0.22,
                        y: proxy.size.height * item.1
                    )
            }
        }
    }
}

private struct LeafShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY), control: CGPoint(x: rect.midX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.midY), control: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

// MARK: - 正文 / 课程关卡之间的云带（③）

/// 云带：三片大小不一的云，标示「往上走进入了更高的闯关」。
///
/// ⚠️ 为什么是云而不是一道横线或一条虚线：树本身就是一根垂直的枝干，
/// 横向的线会被读成「又一棵树干的分界」；云是**天空**的东西，
/// 它说的是「过了这层就是另一片天」—— 正好是「树冠之上还有一层」这件事。
private struct CourseCloudBand: View {

    let theme: ForestTheme

    /// 云带占多高（只影响留白与摆位，不影响云的大小）。
    static let bandHeight: CGFloat = 96

    /// 三片云：横向位置（0…1 相对面板宽）、大小、浓淡。
    /// ⚠️ 浓淡要**不均匀**：三朵一样浓会读成一条横杠，读不出「云」。
    /// ⚠️ 颜色跟随 `primaryText` 的淡色，**不能用白色**：树面板在日间是接近白的底，
    /// 白云画上去等于没画（实测：只有压在树干上的那一小块露出来，成了一团灰影）。
    /// 跟随文字色则日夜两套底色下都自带对比 —— 日间是淡墨、夜间是淡光。
    private let puffs: [(x: CGFloat, scale: CGFloat, opacity: Double)] = [
        (0.17, 0.78, 0.10),
        (0.38, 1.00, 0.15),
        (0.63, 0.86, 0.11),
        (0.84, 0.68, 0.09),
    ]

    var body: some View {
        GeometryReader { proxy in
            ForEach(Array(puffs.enumerated()), id: \.offset) { _, puff in
                Image(systemName: "cloud.fill")
                    .appFont(52 * puff.scale, weight: .regular)
                    .foregroundStyle(theme.primaryText.opacity(puff.opacity))
                    .position(x: proxy.size.width * puff.x, y: proxy.size.height / 2)
            }
        }
    }
}

// MARK: - 关卡节点

private struct LevelNode: View {
    let level: TreeLevel
    let theme: ForestTheme
    let isCurrent: Bool
    /// 对应情景与主线任务进度（没绑定情景时为 nil）。
    let note: TreeLevelNote?

    var body: some View {
        ZStack {
            if isCurrent {
                Circle()
                    .stroke(theme.accent, lineWidth: 3)
                    .frame(width: 76, height: 76)
                    .scaleEffect(isCurrent ? 1.0 : 0.9)
            }

            Circle()
                .fill(fill)
                .frame(width: 58, height: 58)
                .overlay(
                    Circle()
                        .strokeBorder(
                            border,
                            // ③ 课程关卡用虚线圈：颜色之外再加一道形状差，
                            // 色弱用户与深浅两套主题下都分得出来。
                            style: StrokeStyle(
                                lineWidth: 2.5,
                                dash: level.isAboveCurriculum ? [5, 4] : []
                            )
                        )
                )
                .shadow(color: theme.shadow, radius: 6, x: 0, y: 3)

            VStack(spacing: 2) {
                if level.state == .locked {
                    Image(systemName: "lock.fill")
                        .appFont(15, weight: .semibold)
                        .foregroundStyle(.white.opacity(0.85))
                } else {
                    Image(systemName: iconName)
                        .appFont(15, weight: .semibold)
                        .foregroundStyle(iconColor)
                }
                Text("\(level.earnedStars)/\(level.requiredStars)")
                    .appFont(9, weight: .bold, design: .rounded)
                    .foregroundStyle(iconColor.opacity(0.9))
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 1) {
                Text(level.title)
                    .appFont(11, weight: .semibold, design: .rounded)
                    .foregroundStyle(theme.primaryText)
                Text(level.subtitle)
                    .appFont(9, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                // 需求 2：这一格对应哪个情景、主线任务做到哪 —— 一句话说清两者的关系。
                if let note {
                    Text(note.summaryLine)
                        .appFont(9, weight: .medium, design: .rounded)
                        .foregroundStyle(theme.accent)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .fixedSize()
            .offset(y: 46)
        }
        // 绑定了情景的关卡：挂一个小对话标，提示「点它就是进情景练」
        .overlay(alignment: .topTrailing) {
            if level.scenarioID != nil {
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .appFont(8, weight: .bold)
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(theme.accentAlt))
                    .offset(x: 4, y: -4)
            }
        }
        // 批次七 · G：关卡点是 onTapGesture，默认不在 VoiceOver 树里 ——
        // 不补这一段，读屏用户既看不见关卡也进不了练习。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.voiceOverLine(level: level, note: note))
        .accessibilityAddTraits(level.state == .locked ? [] : [.isButton])
        .accessibilityHint(Self.voiceOverHint(isLocked: level.state == .locked))
    }

    /// 关卡节点的读屏提示（文案唯一出处见 `AccessibilityLines.levelHint`）。
    static func voiceOverHint(isLocked: Bool) -> String {
        AccessibilityLines.levelHint(isLocked: isLocked)
    }

    /// 关卡节点的读屏一句话（文案唯一出处见 `AccessibilityLines.levelLine`，可单测）。
    ///
    /// ③ 课程关卡补一句「AI 排的课」：读屏用户看不到虚线圈与冷色描边，
    /// 不说就与正文关卡完全一样 —— 视觉上的区分对读屏用户不存在。
    static func voiceOverLine(level: TreeLevel, note: TreeLevelNote?) -> String {
        let base = AccessibilityLines.levelLine(level: level, note: note)
        guard level.isAboveCurriculum else { return base }
        return "AI 排的课 · " + base
    }

    private var fill: Color {
        switch level.state {
        case .locked: theme.surfaceAlt
        case .unlocked: theme.surface
        case .inProgress: theme.accent.opacity(0.9)
        case .completed: Color(hex: 0x8FD694)
        }
    }

    private var border: Color {
        // ③ AI 排的课里的一节：**描边换成冷色 + 虚线**，一眼与正文关卡分开。
        // 判据是 `isAboveCurriculum`（高度 > 1 这个**数据**），不是 id 前缀。
        if level.isAboveCurriculum { return theme.accentCool }
        return level.state == .locked ? theme.divider : theme.accentAlt
    }

    private var iconName: String {
        // 课程关卡用「路线」图标，与课卡、情景卡（对话气泡 / sparkles）同一套来源识别。
        if level.isAboveCurriculum { return CourseBlueprintRule.icon }
        switch level.state {
        case .completed: return "star.fill"
        case .inProgress: return "flame.fill"
        default: return "leaf.fill"
        }
    }

    private var iconColor: Color {
        level.state == .inProgress ? .white : theme.primaryText
    }
}

// MARK: - 林间地面带（固定吸附在成长之树面板底部，不随树滚动，居民始终可见可点）

struct ForestGroundBand: View {
    let theme: ForestTheme
    /// 小动物气泡总开关（设置可关）。
    var bubblesAllowed: Bool = true
    /// 实际生效的活动开关（配置 && 白天）。夜晚自动安静。
    var activityAllowed: Bool = true
    /// 活动频率（0...1）：值越大动作间隔越短。
    var activityFrequency: Double = 0.5
    /// 右下角表情按钮回调（与设置里的开关联动）。
    var onActivityToggle: (() -> Void)? = nil
    /// 外部庆祝信号（今日任务全部完成）：每次 +1，全体小动物跳一次并冒一句庆祝话。
    var celebrationTick: Int = 0
    /// 收词脉冲（`state.forest.wordTick`）：一只小动物跑出画面叼一张单词卡回来。
    var wordTick: Int = 0
    /// 最近收进的生词（捡词叙事的台词；nil = 不演，只留树上的叶子回应）。
    var wordPayload: String? = nil
    /// 纠错脉冲（`state.forest.comfortTick`）：派一只小动物歪头安慰。
    var comfortTick: Int = 0
    /// 连续错得多时的**簇拥安慰**（`huddleComfortTick`）：几只一起围过来。
    var huddleComfortTick: Int = 0
    /// 模块完成脉冲：按模块演一段戏（批次四 · A 分模块回应）。
    var moduleTick: Int = 0
    /// 最近完成的模块。
    var lastModule: PracticeModule? = nil
    /// 中途退出脉冲：目送你走（不评判、不庆祝）。
    var abandonTick: Int = 0
    /// 最近中途退出的模块。
    var lastAbandonedModule: PracticeModule? = nil
    /// 学员开口脉冲：最近的一只点点头。
    var learnerTurnTick: Int = 0
    /// 老师开口脉冲：几只抬起头听。
    var teacherTurnTick: Int = 0
    /// 最后一次「学习上发生了点什么」的时刻：据此判断人是不是走开了
    /// （安静太久 → 有谁打个盹）。判时间差，不判布尔。
    var lastActivityAt: Date = Date()
    /// 验证钩子：启动时先冒一句「它们在睡觉」（仅在 `--sleep-bubble` 下由主界面传入）。
    var previewSleepBubble: Bool = false
    /// 点了一只小动物（批次六 · F 轻音效：一声叫；气泡照旧由本视图冒）。
    /// ⚠️ 带着**被点那只**的当前物种出山（轮换会换物种，叫声要跟着换 —— 2026-09-29）。
    var onResidentTap: ((AnimalKind) -> Void)? = nil
    /// 首次进入欢迎脉冲（批次八 · H）：居民依次跳一圈 + 一句欢迎词。
    var welcomeTick: Int = 0
    /// 错误举牌脉冲（批次八 · H）：老师联系不上时，最近的小动物举一块牌子。
    var errorSignTick: Int = 0
    /// 牌子上的那句话（与 tick 分开传：同一句话再举一次也要靠 tick 触发）。
    var errorHeadline: String? = nil
    /// 学员在当前会话开口的次数（`ChatService.learnerTurnCount`）：
    /// 大树下草坪上「对话种下的植物」长几株（2026-09-29 从中间栏搬进林子）。
    var conversationRounds: Int = 0
    /// 连续剧情（#418-C）：出幕脉冲 + 这一幕是哪一幕。判定与记账在 `ForestStage`
    /// （它有事件历史），这里只管挑角演 —— 判定在舞台、演在草坪，两边各管各的。
    var storyActTick: Int = 0
    var lastStoryAct: ForestStoryArc.Act? = nil
    /// 学员在树上的攀爬位置（0…1，`LearnerProgress.climbFraction`）。
    ///
    /// **C：动物与学习过程联动**的落点。学习事件面已经很宽（收词 / 纠错 /
    /// 模块完成 / 通关 / 簇拥安慰 / 举牌 / 剧情……），唯独「进度条自己往前走了」
    /// 没有任何回应 —— 而那恰恰就是「学习过程」本身。这里只做一件事：
    /// 涨了就派最近的一只小跳一下、喊一句，**不庆祝、不放烟花**。
    var climbFraction: Double = 0

    /// 已解锁的伙伴数（⑦-C③，`ForestUnlock.companions`）：面板摆得下几只由宽度定，
    /// 林子里**现有几位**由它定，取小者（见 `ForestGroundPlan.plan(width:unlocked:)`）。
    var unlockedCompanions: Int = ForestUnlock.maxCompanions

    /// 连续剧情的主角（#418-C）：一旦绑定，这一轮学习里的各幕都由它领衔
    /// （在场才认；暂离了就换角重绑）。会话级 @State，重启自然换人。
    @State private var storyLead: Int? = nil

    /// 画面上**真的画出来**的居民数（由 `ForestGroundPlan` 按面板宽排，随宽度变）。
    ///
    /// 为什么要有它（2026-10-01 修）：槽位总数恒为 8，但窄面板下只排 3~5 只
    /// （`index >= count` 的槽位画成 `opacity(0)`，气泡层也有 `i < count` 守卫）。
    /// 挑角原先在 8 个槽位里随机，六成概率挑到画外的角色 —— 那一幕就演给空气看：
    /// 动作看不见、气泡也不出，用户只看到「攒够星却什么都没发生」。
    @State private var residentCount: Int = 0

    /// 此刻在场（没暂离）且**看得见**的居民槽位 —— 挑角只能在这一段里挑。
    private var presentResidents: [Int] {
        (0..<residentCount).filter { !away[$0] }
    }

    /// 离场告别语（轮换时随机抽一条）。
    static let leavePhrases = [
        "我先回家吃点心啦～",
        "妈妈叫我回家吃饭！",
        "林子那边好像有好玩的，我去瞧瞧～",
        "拜拜，明天再来找你们玩！",
        "咦，那边的蘑菇好像发芽了，我去看看！",
    ]
    /// 进场打招呼语（轮换时随机抽一条）。
    static let greetPhrases = [
        "嗨～我来了！",
        "你们好呀，我是新搬来的邻居！",
        "嘿！一起玩吗？",
        "刚才在路上捡到一个新单词，分你们一半！",
        "大家好，这里的草真香呀～",
    ]

    /// 夜晚点击右下角表情按钮时冒出的话（**小动物们都睡了**，随机抽一条，连点随机切换）。
    ///
    /// `nonisolated`：这是一张纯文案表，不含任何隔离状态；写成隔离的会让
    /// 单测（非隔离上下文）读它时撞上「主 actor 属性不能从非隔离上下文引用」。
    nonisolated static let sleepPhrases = [
        "嘘——小动物们都睡着啦，别打扰它们哦～",
        "夜深了，它们正做着甜甜的梦呢，明早再来吧！",
        "呼……呼……睡得好香，轻一点声音哦。",
        "月亮值班啦，小动物们都钻进窝里睡觉了。",
        "它们说：明早第一缕阳光时再见！晚安～",
    ]

    /// 双人小对话（一问一答）：一条脚本由两只相邻的小动物交替说完。
    /// 每条 2 句起步，句子里带点学习气但不教训人。
    nonisolated static let dialogueScripts: [[String]] = [
        ["你说，rainbow 为什么有七种颜色？", "因为每种颜色都是一个单词呀！"],
        ["今天你练口语了吗？", "练啦！舌头都绕两圈了～"],
        ["我们比赛背单词吧！", "好呀，输的请吃松果！"],
        ["那朵云像不像 sheep？", "像！b-a-a～"],
        ["你听过回声说英语吗？", "听过！它还会复读呢。"],
        ["今天的句子好长呀。", "没关系，拆成小段就短啦！"],
    ]

    /// 纠错后的安慰话（歪头 + 一句温柔的话——错误被温柔接住）。
    nonisolated static let comfortPhrases = [
        "没关系，错着错着就会啦！",
        "我也常念错呀，再来一遍就好～",
        "错误是单词的小脚印，说明你在往前走！",
        "抱抱你，这次我们慢慢读。",
    ]

    /// 学员又往上爬了一层时的招呼（C：动物与学习过程联动）。
    ///
    /// ⚠️ 语气纪律：**不庆祝**（里程碑有 `ceremonyTick` / `celebrationTick` 两档，
    /// 那两档会跳会放烟花），这里只表示「我看见你往上爬了」——一句话，一个小跳。
    nonisolated static let ascentPhrases = [
        "又上一层啦！",
        "我看见你往上爬了～",
        "这一格也站稳了，继续！",
        "越爬越高，我抬头看你呢。",
        "再往上，风就更好听了！",
    ]

    /// 簇拥安慰的话（错得多时用的，比单人安慰更用力一点）。
    ///
    /// ⚠️ 语气纪律：这里**不提错误本身**（单人那组已经说过了），说的是「我们一起在」。
    nonisolated static let huddleComfortPhrases = [
        "我们都在这儿呢，慢慢来～",
        "一起读，就不难啦！",
        "错几个不算什么，我们陪着你！",
        "来，我们陪你再读一遍。",
    ]

    /// 安静太久时打盹的那句话（不是「睡着」，是困了点个头）。
    nonisolated static let dozingPhrases = [
        "好安静呀……我先打个盹～",
        "等你回来，我眯一会儿。",
        "呼……有点困了，你慢慢想。",
    ]

    /// 捡词叙事：看见词时要出发了。
    nonisolated static let fetchStartPhrases = [
        "咦，那边飘来一个新单词！",
        "等等我，我去把它捡回来！",
        "我的耳朵听到单词落地的声音啦！",
    ]
    /// 捡词叙事：叼着词卡回来展示。
    nonisolated static let fetchDonePhrases = [
        "捡到啦！快看这个词～",
        "回来咯！这个词真漂亮！",
        "新单词到手，收好啦！",
    ]

    /// 首次进入的欢迎词（批次八 · H）：全新学员第一次来，林子的见面礼。
    nonisolated static let welcomePhrases = [
        "欢迎来到语林！",
        "新朋友来啦！这边请～",
        "你来啦！树还小，一起把它养大吧！",
    ]

    /// 每只小动物**独立拥有**一个气泡：`bubbleTexts[i]` 是槽位 i 当前的话（nil = 没在说话）。
    /// 多个气泡可以同时存在；`bubbleStamps[i]` 记录出现序号，序号越大画得越上层（最新出现的永远在最上方）。
    @State private var bubbleTexts: [String?] = Array(repeating: nil, count: Self.maxResidents)
    @State private var bubbleStamps: [Int] = Array(repeating: 0, count: Self.maxResidents)
    @State private var bubbleCounter = 0
    /// 各居民的**持续位移**：游走后停在新位置，不回原位。
    @State private var offsets: [CGSize] = Array(repeating: .zero, count: Self.maxResidents)
    /// 鸟类是否正栖在枝桠上。
    @State private var perched: [Bool] = Array(repeating: false, count: Self.maxResidents)
    /// 动作触发器（父级递增，LivelyAnimal 变化即执行）。
    @State private var actionTicks: [Int] = Array(repeating: 0, count: Self.maxResidents)
    @State private var actionKinds: [LivelyAnimalAction] = Array(repeating: .hop, count: Self.maxResidents)
    /// 各槽位的物种（轮换：随机离开/进入）。空时用伪随机初始顺序兜底。
    @State private var kinds: [AnimalKind] = []
    /// 各槽位朝向（游走时按移动方向翻转）。
    @State private var facings: [CGFloat] = []
    /// 夜晚点右下角表情按钮冒出的「睡觉」气泡（nil = 没在显示）。
    @State private var sleepLine: String?
    /// 连点刷新用：变化即重启 3 秒自动收起计时（与动物气泡同一套逻辑）。
    @State private var sleepTick = 0
    /// 各槽位是否暂离（轮换中「走了还没回来」）。可见 = 槽位在宽度档位内 **且** 没暂离——
    /// 走了之后画面上真的少一只，回来的时间看缘分（错落感的关键，见 `ForestRotationPacing`）。
    @State private var away: [Bool] = Array(repeating: false, count: Self.maxResidents)
    /// 捡词叙事进行中（同一时刻只演一场；期间的收词只留树上的叶子回应）。
    @State private var isFetchingWord = false
    /// 正在展示的「叼回来的单词卡」（nil = 没有；slot = 哪只小动物叼着）。
    @State private var wordCard: (slot: Int, word: String)? = nil
    /// 安静期间已经打过盹了（学习上又有动静时解锁，见 `dozeOffIfQuiet`）。
    @State private var hasDozed = false
    /// 正在举牌的居民槽位（批次八 · H 错误举牌；nil = 没在举）。
    @State private var signHolder: Int? = nil
    /// 本次举牌对应的脉冲序号：自动收起时对账，防止收掉下一场新举的牌。
    @State private var signShownTick = 0
    /// 欢迎演出是否已经演过（onAppear 补演与 onChange 二选一的闸）。
    @State private var welcomePlayed = false
    /// 点草地冒出来的花（批次六 · E 可玩彩蛋；上限与挤掉规则见 `GroundFlowerBed`）。
    @State private var plantedFlowers: [PlantedFlower] = []
    @State private var plantedCounter = 0
    /// 各槽位**当前生效的移动批次**（见 `hopTo`）。
    ///
    /// ⚠️ 活动编排与轮换编排是**两条并发的循环**，它们在同一只居民身上撞车时，
    /// 两个 `hopTo` 会交替写同一个 `offsets[index]` —— 一只动物被两边同时拽，
    /// 画面上就是原地抽搐。批次号让**后发起的意图胜出**、前一个自己退场。
    @State private var hopTokens: [Int] = Array(repeating: 0, count: Self.maxResidents)
    @State private var hopCounter = 0
    /// **庆祝演出的代际令牌**（#S3-11）。
    ///
    /// ⚠️ `celebrate()` 一次要起 24+ 个错峰 `Task`（三波欢跳 + 三只台词 + 一次收尾），
    /// 它们谁也不持有、也没法取消 —— 而 `try? await Task.sleep` 会把取消错误吞掉，
    /// 就算持有并取消也照样往下走。于是「演出进行到一半、全员已经回家」时，
    /// 剩下的那几个 Task 仍会照常 `trigger(.hop)`，把刚站好的队伍又拽走一只。
    /// 沿用本文件已有的对账风格（`hopTokens` / `bubbleStamps`）：演出开始时领号，
    /// 每个 Task 动手之前先对一次账，**号对不上就直接退场**。
    @State private var celebrationToken = 0

    private static let maxResidents = 8
    // 各类元素的**上限**：始终按上限创建视图，靠透明度控制显隐。
    // 这样拖动分割线时元素不会突然创建/销毁（那正是画面抖动的来源）。
    private let grassCount = 26
    private let maxBushes = 4
    private let maxFlowers = 7

    /// 稳定伪随机（同 index/salt 永远同值），保证布局不随重绘跳动。
    private func pr(_ index: Int, _ salt: Int) -> CGFloat {
        let x = sin(Double(index * 137 + salt * 61)) * 43758.5453
        let frac = x - floor(x)
        return CGFloat(frac)
    }

    /// 物种顺序已收到 `AnimalKind.unlockOrder`（⑦-C③）：预告要能点出「下一位是谁」，
    /// 顺序就不能只活在视图里。

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            // 草坡表面（相对本视图坐标）：坡是鼓包不是直线 —— 谁站在坡上就问坡自己要高度。
            // （从前这里是一条直线：草叶 / 灌木 / 小花 / 小动物 / 对话植物全站在上面，
            // 而坡面中心高出 20pt、两角低下 34pt，于是「中心埋进坡里、两边浮在半空」——
            // 用户看到的「一块一块」正源于此。）
            // ⚠️ 名字仍叫 `groundLine`（它回答的就是「这根线在 x 处的高度」），类型从
            //  CGFloat 变成坡面函数；下游 30 处调用点因此原样不动，只是各自问一次 x。
            let groundLine: ForestGroundSurface = { x in
                ForestSceneGeometry.hillSurfaceY(x: x, bandWidth: width, bandHeight: height)
            }
            let inset: CGFloat = 74
            let span = max(1, width - inset * 2)
            // 量化宽度：一切「离散决策」（数量、个体大小）只在 28pt 档位上变化，
            // 连续量（坐标）仍跟随真实宽度平滑移动 —— 消除拖动时的逐帧重排抖动。
            let step: CGFloat = 28
            let qw = (width / step).rounded() * step
            // 退化档（批次八 · H）：多宽配多少动物 / 灌木 / 小花，收成一个纯函数
            // （正常 / 窄 / 极窄三档，树面板最小 300pt 时只留 1 只居中——林子不空也不挤）。
            let plan = ForestGroundPlan.plan(width: qw, unlocked: unlockedCompanions)
            let count = plan.residents
            let bushCount = plan.bushes
            let flowerCount = plan.flowers
            let order = AnimalKind.unlockOrder

            ZStack(alignment: .bottomLeading) {
                // 批次七 · G：下面这一段（草坡 / 草叶 / 灌木 / 小花 / 点出来的花 / 栖木桠）
                // 全是纯装饰 —— 包成一个 Group 对 VoiceOver 整体隐藏，居民（动物）保留读屏。
                Group {
                    // 草坡：顶沿到坡底一道「空气」渐变（大气透视按景深推，顶沿远一点）
                    // —— 从前是一条硬邦邦的剪纸边，绿的坡冷不丁切进背后的天空里。
                    HillCap()
                        .fill(
                            LinearGradient(
                                colors: [
                                    ForestAerialPerspective.adjust(
                                        theme.hillNear,
                                        depth: ForestSceneGeometry.treeDepth,
                                        haze: theme.aerialHaze),
                                    ForestAerialPerspective.adjust(
                                        theme.hillNear,
                                        depth: ForestSceneGeometry.nearHillDepth,
                                        haze: theme.aerialHaze)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(height: ForestSceneGeometry.hillCapHeight)

                    // 远处草丛（固定数量，按宽度均布；倾角只跟 index 走，不随宽度乱跳）
                    ForEach(0..<grassCount, id: \.self) { i in
                        grassBlade(x: inset + CGFloat(i) / CGFloat(grassCount - 1) * span,
                                   h: 9 + pr(i, 1) * 11,
                                   w: 2.6 + pr(i, 2) * 1.6,
                                   seed: i,
                                   groundLine: groundLine)
                    }

                    // 灌木丛（增加层次，压住「排排站」的感觉）
                    ForEach(0..<maxBushes, id: \.self) { i in
                        bush(x: inset + pr(i, 12) * span,
                             groundLine: groundLine,
                             seed: i)
                            .opacity(i < bushCount ? 1 : 0)
                            .appAnimation(.reveal, value: bushCount)
                    }

                    // 小花（错落 + 三种花色）
                    ForEach(0..<maxFlowers, id: \.self) { i in
                        flower(x: inset + pr(i, 8) * span,
                               groundLine: groundLine,
                               palette: i % 3)
                            .opacity(i < flowerCount ? 1 : 0)
                            .appAnimation(.reveal, value: flowerCount)
                    }

                    // 点草地冒出来的花（批次六 · E）：从点下的位置长出来，挤掉最早的
                    ForEach(plantedFlowers) { planted in
                        flower(x: min(max(planted.x, 16), width - 16),
                               groundLine: groundLine,
                               palette: planted.palette)
                            .transition(.scale(scale: 0.4, anchor: .bottom).combined(with: .opacity))
                    }

                    // 对话种下的植物（2026-09-29 从中间栏搬进林子）：大树下草坪上
                    // 随学员开口一株株长出来，带土丘扎根痕迹与轻微倒向（见 ForestFloraBed）。
                    ForestFloraBed(theme: theme, rounds: conversationRounds, groundLine: groundLine)

                    // 树干底部的两根枝桠栖木（鸟类专用；画在树干透出区域的中心两侧）
                    perchStubs(width: width)
                }
                .accessibilityHidden(true)

                // 林间居民：各物种独立个体，朝向/大小/站位/动与静各不相同
                ForEach(0..<Self.maxResidents, id: \.self) { i in
                    resident(
                        kind: order[i % order.count],
                        index: i,
                        visibleCount: count,
                        span: span,
                        inset: inset,
                        groundLine: groundLine,
                        quantizedWidth: qw
                    )
                }

                // 气泡层：每只小动物一份，统一画在所有居民之上。
                // 层级由出现序号决定 —— 最新出现的气泡 zIndex 最大，不会被任何动物或其他气泡遮挡。
                ForEach(0..<Self.maxResidents, id: \.self) { i in
                    if i < count, !away[i], let text = bubbleTexts[i] {
                        let home = homePosition(index: i, count: count, span: span,
                                                inset: inset, groundLine: groundLine, quantizedWidth: qw)
                        SpeechBubble(text: text, maxWidth: 150)
                            .fixedSize()
                            .position(
                                x: home.x + offsets[i].width,
                                y: home.y + offsets[i].height - home.size * 0.78
                            )
                            .transition(.opacity.combined(with: .scale(scale: 0.55, anchor: .bottom)))
                            .zIndex(Double(1000 + bubbleStamps[i]))
                            .allowsHitTesting(false)
                    }
                }

                // 叼回来的单词卡：跟着捡词小动物的头顶走，展示完自动收。
                if let card = wordCard, card.slot < count, !away[card.slot] {
                    let home = homePosition(index: card.slot, count: count, span: span,
                                            inset: inset, groundLine: groundLine, quantizedWidth: qw)
                    CarriedWordCard(word: card.word, theme: theme)
                        .position(
                            x: home.x + offsets[card.slot].width,
                            y: home.y + offsets[card.slot].height - home.size * 1.08
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .bottom)))
                        .zIndex(2000)
                        .allowsHitTesting(false)
                }

                // 错误举牌（批次八 · H）：举在持牌小动物的头顶，5 秒自动收。
                // 夜晚也举——错误不挑时候；牌子只是转述，完整错误在聊天区横幅。
                if let holder = signHolder, holder < count, !away[holder],
                   let headline = errorHeadline {
                    let home = homePosition(index: holder, count: count, span: span,
                                            inset: inset, groundLine: groundLine, quantizedWidth: qw)
                    ForestSignBoard(theme: theme, text: headline)
                        .position(
                            x: home.x + offsets[holder].width,
                            y: home.y - home.size * 0.5 - 40
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .bottom)))
                        .zIndex(2100)
                }
            }
            .frame(width: width, height: height, alignment: .bottomLeading)
            // 档位切换时让位置/大小平滑过渡，而不是瞬移
            .appAnimation(.reveal, value: qw)
            // 初始化物种/朝向状态（轮换的基础）
            .onAppear { ensureResidents(order: order) }
            .onChange(of: count, initial: true) { _, value in
                // 可见居民数：挑角 / 编排都只认这一段（见 `presentResidents`）。
                // `initial: true` —— 首帧就得写进去，否则第一次出幕时它还是 0。
                residentCount = value
                ensureResidents(order: order)
            }
            // 活动编排（宽度或活动开关/频率变化时重启循环，取最新几何与开关值）
            .task(id: "\(qw)-\(activityAllowed)-\(activityFrequency)-\(theme.isNight)") {
                async let life: () = orchestrateLife(count: count, span: span, inset: inset,
                                                     groundLine: groundLine, quantizedWidth: qw,
                                                     width: width, order: order)
                async let rotation: () = orchestrateRotation(count: count, span: span, inset: inset,
                                                             groundLine: groundLine, quantizedWidth: qw,
                                                             order: order)
                _ = await (life, rotation)
            }
            // 关闭活动（设置开关或入夜）：全体回家排排站好（带过渡动画）
            .onChange(of: activityAllowed) { _, allowed in
                if !allowed { sendEveryoneHome() }
            }
            .onChange(of: theme.isNight) { _, night in
                if night {
                    sendEveryoneHome()
                } else {
                    // 天亮了：把「它们在睡觉」的气泡收掉
                    withAnimation(.app(.reveal)) { sleepLine = nil }
                }
            }
            // 今日任务全部完成：全体跳一下 + 冒一句庆祝（外部一天只推一次）
            .onChange(of: celebrationTick) { _, _ in celebrate() }
            // 收词小剧场：一只小动物跑出去叼一张单词卡回来（上一场没演完就只留树上的叶子）
            .onChange(of: wordTick) { _, tick in
                guard tick > 0 else { return }
                Task { await fetchWord(count: count, span: span, inset: inset,
                                       groundLine: groundLine, quantizedWidth: qw) }
            }
            // 纠错安慰：派一只在场的小动物歪头 + 一句温柔的话
            .onChange(of: comfortTick) { _, tick in
                guard tick > 0 else { return }
                comfort()
            }
            // 错得多了：几只一起围过来（同一件事，安慰的分量更足）
            .onChange(of: huddleComfortTick) { _, tick in
                guard tick > 0 else { return }
                huddleComfort()
            }
            // 模块完成：按模块演一段戏（读完想听故事 / 写完在地上划两笔…）
            .onChange(of: moduleTick) { _, tick in
                guard tick > 0, let module = lastModule else { return }
                playModuleSkit(module)
            }
            // 中途退出：目送你走
            .onChange(of: abandonTick) { _, tick in
                guard tick > 0, let module = lastAbandonedModule else { return }
                waveGoodbye(module)
            }
            // 学员开口：最近的一只点点头（「嗯，你在说」）
            .onChange(of: learnerTurnTick) { _, tick in
                guard tick > 0 else { return }
                acknowledgeLearner()
            }
            // 老师开口：几只抬起头听（不用全员，两三只就够像「在听」）
            .onChange(of: teacherTurnTick) { _, tick in
                guard tick > 0 else { return }
                listenUp()
            }
            // 错误举牌（批次八 · H）：老师联系不上，最近的小动物举一块牌子。
            .onChange(of: errorSignTick) { _, tick in
                guard tick > 0 else { return }
                holdUpSign(tick)
            }
            // 首次进入欢迎（批次八 · H）：居民依次跳一圈 + 一句欢迎词。
            // ⚠️ 脉冲可能在地面带上屏**前**就发出（启动流程里记名）——onChange
            // 收不到第一拍，所以 onAppear 里对着已存在的 tick 补演一次（见下）。
            .onChange(of: welcomeTick) { _, tick in
                guard tick > 0 else { return }
                welcomeParty()
            }
            // 连续剧情（#418-C）：舞台判定出幕 → 树上挑角演。
            // ⚠️ 判定（该不该出幕）在 ForestStage，这里不做二次判断 ——
            // 与「簇拥安慰的门槛在舞台」同一条纪律，两处门槛迟早不一致。
            .onChange(of: storyActTick) { _, tick in
                guard tick > 0, let act = lastStoryAct else { return }
                performStoryAct(act)
            }
            // 错误举牌（批次八 · H）：老师联系不上，最近的小动物举一块牌子。
            // 学员又爬上一层（C）：最近的一只小跳一下 + 喊一句。
            .onChange(of: climbFraction) { old, new in
                // 只认**真的向上位移**：进度从库里读回来时也会变（0 → 当前值），
                // 那一次不该演「又上一层」。判据抽成了纯函数，见下。
                guard Self.isRealAscent(old: old, new: new) else { return }
                cheerAscent()
            }
            // 学习上又有动静了 → 解除「已经打过盹」的标记（下次安静还能再演）
            .onChange(of: lastActivityAt) { _, _ in hasDozed = false }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            // 首次进入欢迎的补演：欢迎脉冲在启动流程里发出时本视图可能还没上屏
            //（onChange 只对「出现之后的变化」负责）。tick 已存在而第一拍没演过 → 补上。
            if welcomeTick > 0, !welcomePlayed {
                welcomePlayed = true
                welcomeParty()
            }
        }
        // 点草地（批次六 · E 可玩彩蛋）：落在草地上的点击冒一朵小花。
        // 小动物 / 右下角按钮各自的点击优先级更高，照常工作。
        .gesture(
            SpatialTapGesture().onEnded { value in
                plantFlower(at: value.location.x)
            }
        )
        // 右下角：表情按钮 + 夜晚「睡觉」气泡（右对齐，永远不会溢出面板）
        .overlay(alignment: .bottomTrailing) {
            VStack(alignment: .trailing, spacing: 6) {
                if let sleepLine {
                    SpeechBubble(text: sleepLine, maxWidth: 168)
                        .fixedSize()
                        .transition(.opacity.combined(with: .scale(scale: 0.55, anchor: .bottom)))
                        .zIndex(5)
                }
                activityButton
            }
            .padding(.trailing, 12)
            .appPadding(.bottom, 10)
        }
        // 与动物气泡一致的收起逻辑：连点会取消上一次计时，停手 3 秒后自动消失
        .task(id: sleepTick) {
            guard sleepLine != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.app(.reveal)) { sleepLine = nil }
        }
        // 验证钩子：--sleep-bubble 时持续冒泡（真实行为由点击触发），便于截图确认气泡不越界
        .task(id: "\(previewSleepBubble)-\(theme.isNight)") {
            guard previewSleepBubble, theme.isNight else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled, theme.isNight else { return }
                activityTapped()
            }
        }
    }

    // MARK: 活动编排（唯一的心跳：游走 / 跳 / 摇 / 飞枝）

    private func orchestrateLife(count: Int, span: CGFloat, inset: CGFloat, groundLine: ForestGroundSurface,
                                 quantizedWidth: CGFloat, width: CGFloat,
                                 order: [AnimalKind]) async {
        // 个体错峰启动，避免整排动物同时动作
        try? await Task.sleep(for: .seconds(Double.random(in: 3...6)))
        while !Task.isCancelled {
            // 动作间隔由活动频率决定：0 → ~12s，1 → ~4s（再叠加随机抖动）。
            //
            // ⚠️ **每轮重算**：写在循环外就成了一个固定节拍器，八只动物会踩着同一个
            // 鼓点动（注释里的「随机抖动」也就只剩开跑前那一次）。频率钳回 0…1，
            // 免得配置里存了个越界值把间隔算成负数（`Task.sleep` 负数是立刻返回 → 忙循环）。
            let clampedFrequency = min(max(activityFrequency, 0), 1)
            let interval = max(1.5, 12 - clampedFrequency * 8) * Double.random(in: 0.8...1.25)
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled, activityAllowed, !theme.isNight else { continue }
            guard count > 0 else { continue }
            // 人是不是走开了？安静太久就有谁打个盹（判时间差，零新增定时器）
            dozeOffIfQuiet()
            // 只在**在场**的居民里挑：轮换暂离的槽位不能「凭空演戏」
            //
            // ⚠️ 谁上场按**当前物种的活跃度**加权，且判「爱不爱飞」看的是当前物种
            // （`kindAt`）—— 早先看的是初始 `order`，轮换换过人之后性格就串了味。
            let present = (0..<count).filter { !away[$0] }
            guard let index = AnimalPersonaBook.pick(kinds: kinds, present: present,
                                                     roll: Double.random(in: 0..<1)) else { continue }
            let kind = kindAt(index: index, fallback: order[index % order.count])
            let persona = AnimalPersonaBook.persona(for: kind)

            if persona.favorsPerch && !perched[index] && Int.random(in: 0..<10) < 3 {
                // 鸟类：飞上枝桠，停留一阵（期间会小幅挪动），再飞回草地
                await flyToPerch(index, count: count, span: span, inset: inset,
                                 groundLine: groundLine, quantizedWidth: quantizedWidth, width: width)
                // 枝上小憩：随机停留 + 小幅挪动
                let stay = Int.random(in: 1...2)
                for _ in 0..<stay {
                    try? await Task.sleep(for: .seconds(Double.random(in: 4...8)))
                    guard !Task.isCancelled, activityAllowed, !theme.isNight else { break }
                    if Bool.random() { shuffleOnPerch(index) }
                }
                try? await Task.sleep(for: .seconds(Double.random(in: 3...6)))
                guard !Task.isCancelled else { return }
                await flyBackToGrass(index)
            } else if perched[index] {
                // 已在枝上：要么小幅挪动，要么飞回草地
                if Bool.random() {
                    shuffleOnPerch(index)
                } else {
                    await flyBackToGrass(index)
                }
            } else {
                // 地面：游走 / 跳 / 摇 / 独角戏 / 双人社交（结对舞或一问一答）
                //
                // 跳与摇这两档也会「改演招牌动作」—— 兔子更爱蹦、考拉爱打盹，
                // 就靠 `AnimalPersonaBook.action` 那三成概率。
                let roll = Int.random(in: 0..<10)
                let signatureRoll = Double.random(in: 0..<1)
                if roll < 4 {
                    wander(index, count: count, span: span, inset: inset,
                           groundLine: groundLine, quantizedWidth: quantizedWidth)
                } else if roll < 6 {
                    trigger(index, action: AnimalPersonaBook.action(for: kind, roll: signatureRoll,
                                                                    fallback: .hop))
                } else if roll < 8 {
                    trigger(index, action: AnimalPersonaBook.action(for: kind, roll: signatureRoll,
                                                                    fallback: .shake))
                } else if roll == 8 {
                    // 独角戏：从本物种的偏好池里抽（wiggle 只留给双人舞）
                    trigger(index, action: AnimalPersonaBook.soloAction(for: kind, roll: signatureRoll))
                } else {
                    await socialise(count: count, span: span, inset: inset,
                                    groundLine: groundLine, quantizedWidth: quantizedWidth)
                }
            }
        }
    }

    /// 触发一次动作（具体演哪个由 `LivelyAnimalAction` 语义表决定）。
    private func trigger(_ index: Int, action: LivelyAnimalAction) {
        actionKinds[index] = action
        actionTicks[index] += 1
    }

    /// 地面游走：在草地范围内累计位移（走到哪停在哪），跳动前进，不会走出草坡。
    private func wander(_ index: Int, count: Int, span: CGFloat, inset: CGFloat,
                        groundLine: ForestGroundSurface, quantizedWidth: CGFloat) {
        let home = homePosition(index: index, count: count, span: span, inset: inset,
                                groundLine: groundLine, quantizedWidth: quantizedWidth)
        let current = offsets[index]
        // 左右各留出草坡内边距，纵向限制在坡面附近
        let slackLeft = home.x - inset * 0.45
        let slackRight = (inset + span + inset * 0.45) - home.x
        let nx = min(max(current.width + CGFloat.random(in: -24...24), -slackLeft), slackRight)
        let ny = min(max(current.height + CGFloat.random(in: -16...6), -20), 7)
        // 按移动方向转身
        if facings.indices.contains(index), abs(nx - current.width) > 2 {
            facings[index] = nx > current.width ? 1 : -1
        }
        Task { await hopTo(index, target: CGSize(width: nx, height: ny), steps: 3, hopHeight: 7) }
    }

    /// 枝桠位置（相对树干中心对称两根）。
    private func perchPoint(_ k: Int, width: CGFloat) -> CGPoint {
        CGPoint(x: width * 0.5 + (k == 0 ? -1 : 1) * width * 0.085,
                y: 22 + CGFloat(k) * 16)
    }

    /// 树干底部的枝桠栖木（视觉上接住飞上来的鸟）。
    @ViewBuilder
    private func perchStubs(width: CGFloat) -> some View {
        ForEach(0..<2, id: \.self) { k in
            let point = perchPoint(k, width: width)
            Capsule()
                .fill(theme.trunkShade.opacity(0.9))
                .frame(width: 36, height: 5)
                .rotationEffect(.degrees(k == 0 ? -6 : 6))
                .position(point)
        }
    }

    /// 鸟类飞上枝桠。
    private func flyToPerch(_ index: Int, count: Int, span: CGFloat, inset: CGFloat,
                            groundLine: ForestGroundSurface, quantizedWidth: CGFloat, width: CGFloat) async {
        let home = homePosition(index: index, count: count, span: span, inset: inset,
                                groundLine: groundLine, quantizedWidth: quantizedWidth)
        let perch = perchPoint(Int.random(in: 0..<2), width: width)
        withAnimation(.spring(response: 0.9, dampingFraction: 0.75)) {
            offsets[index] = CGSize(width: perch.x - home.x, height: perch.y - home.y - 4)
            perched[index] = true
        }
    }

    /// 在枝上小幅挪动（沿枝 ±10pt）。
    ///
    /// ⚠️ 这里**只**用 `index`：挪动是相对当前 `offsets` 的增量，位置由 `flyToPerch` 决定。
    /// 早先签名里挂着一串几何入参（count / span / inset / groundLine / quantizedWidth / width）
    /// 却一个都不用，4 个调用点还逐次算好传进来 —— 读签名的人会以为它在重新定位。
    private func shuffleOnPerch(_ index: Int) {
        let delta = CGFloat.random(in: -10...10)
        withAnimation(.easeInOut(duration: 0.5)) {
            offsets[index].width += delta
        }
    }

    /// 飞回草地（直接回家，`offsets` 归零）。
    private func flyBackToGrass(_ index: Int) async {
        withAnimation(.spring(response: 0.9, dampingFraction: 0.75)) {
            offsets[index] = .zero
            perched[index] = false
        }
    }

    /// 全体回家排排站好（关闭活动 / 入夜时调用，带过渡动画）。
    /// ⚠️ 暂离状态一并清掉：轮换循环醒来看到的是「全员到场」，不会有人卡在画外。
    private func sendEveryoneHome() {
        // 作废所有在飞的移动：否则离场/游走那趟 `hopTo` 会在「回家」之后继续写
        // `offsets`，把刚站好的队伍又拽走一只（入夜那一刻最容易看见）。
        invalidateHops()
        // 庆祝演出同样要作废（#S3-11）：它剩下的那些错峰 Task 不归 `hopTokens` 管，
        // 不递令牌的话「回家」之后还会有人跳一下、冒一句。
        celebrationToken += 1
        withAnimation(.spring(response: 0.7, dampingFraction: 0.8)) {
            for i in 0..<Self.maxResidents {
                offsets[i] = .zero
                perched[i] = false
                away[i] = false
            }
            clearAllBubbles()
        }
    }

    /// 收起所有小动物的气泡（各自独立，互不干扰）。
    private func clearAllBubbles() {
        bubbleCounter += 1     // 作废所有在飞的自动收起任务
        for i in bubbleTexts.indices { bubbleTexts[i] = nil }
    }

    // MARK: 庆祝（今日任务全部完成）

    /// 今日任务全部完成时小动物冒的话（轮换，避免每次都是同一句）。
    static let celebrationPhrases = [
        "今天的任务都完成啦！",
        "好棒！明天也一起来～",
        "你今天真认真，我看见了！",
        "任务全清！去休息一下吧～",
    ]

    /// 全体错落欢跳（跳好几下）+ 前几只错落冒庆祝气泡。
    ///
    /// ⚠️ 只递 `actionTicks`（`LivelyAnimal` 靠它变化触发动作），不自己写动画 ——
    /// 身体动画归 `LivelyAnimal`，气泡层级归本视图，两边各管各的才不会打架。
    /// ⚠️ 只点**在场**的居民：轮换暂离的槽位不演戏、不冒泡。
    ///
    /// 2026-09-29 用户报障「只是集体跳了一下，然后同时冒出气泡」：
    /// 改成**三波**欢跳 —— 每只按位次错开 0.18s、波与波隔 0.85s，同一只前后要跳三下；
    /// 气泡也按位次错开 0.7s 陆续冒出来（齐刷刷同帧冒泡看着像贴图，不像一群活的）。
    /// 夜晚 / 活动被关（`activityAllowed` 已含「配置 && 白天」）只冒气泡不跳——
    /// 睡着的小动物被吵醒跳就不礼貌了，但庆祝的话还是要说。
    private func celebrate() {
        // 领号：这次演出的一切都挂在这个号上；期间只要有人递号（回家 / 重新庆祝），
        // 剩下的 Task 一动手就对不上账、自行退场（#S3-11）。
        celebrationToken += 1
        let token = celebrationToken
        let present = presentResidents
        if activityAllowed {
            for wave in 0..<3 {
                for (order, index) in present.enumerated() {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(Double(wave) * 0.85 + Double(order) * 0.18))
                        guard celebrationToken == token else { return }
                        trigger(index, action: .hop)
                    }
                }
            }
        }
        // 只让前三只在场的说话：八只同时冒泡会糊成一片；错落着冒才有「你一句我一句」的感觉。
        let bubbled = Array(present.prefix(3))
        // 派号与出场分开：**先同步派号**，出场顺序才与序号递增一致（zIndex 靠序号），
        // 也才能把这几个号冻结成常量交给收尾 Task 去对账 —— 让每个 Task 自己派号的话，
        // 收尾那一个根本不知道要收哪几个（原先它是无差别清空的，会连带清掉别人的话）。
        var plan: [(index: Int, stamp: Int)] = []
        for index in bubbled {
            bubbleCounter += 1
            bubbleStamps[index] = bubbleCounter
            plan.append((index: index, stamp: bubbleCounter))
        }
        let bubblePlan = plan
        for (order, entry) in bubblePlan.enumerated() {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(Double(order) * 0.7))
                guard celebrationToken == token,
                      bubbleStamps.indices.contains(entry.index),
                      bubbleStamps[entry.index] == entry.stamp else { return }
                withAnimation(.app(.panel)) {
                    bubbleTexts[entry.index] =
                        Self.celebrationPhrases[(entry.index + celebrationTick) % Self.celebrationPhrases.count]
                }
            }
        }
        Task { @MainActor in
            // 最后一句话冒出来的时刻 + 3s 展示期，一起收。
            try? await Task.sleep(for: .seconds(Double(bubblePlan.count - 1) * 0.7 + 3))
            guard celebrationToken == token else { return }
            // 只收**自己那一批**的号：期间这只被点了、或换过一句，就不是我们的泡泡了。
            for entry in bubblePlan {
                guard bubbleStamps.indices.contains(entry.index),
                      bubbleStamps[entry.index] == entry.stamp else { continue }
                withAnimation(.app(.reveal)) { bubbleTexts[entry.index] = nil }
            }
        }
    }

    // MARK: 小剧场（批次二：双人社交 / 歪头安慰 / 捡词叙事）

    /// 双人社交：挑 x 距离最近的一对邻居，要么结对摇摆（跳舞），要么一问一答。
    /// 只剩一只时就给它一段独舞，不让社交意图落空。
    private func socialise(count: Int, span: CGFloat, inset: CGFloat,
                           groundLine: ForestGroundSurface, quantizedWidth: CGFloat) async {
        let present = (0..<count).filter { !away[$0] }
        let xs = present.reduce(into: [Int: CGFloat]()) { result, index in
            let home = homePosition(index: index, count: count, span: span, inset: inset,
                                    groundLine: groundLine, quantizedWidth: quantizedWidth)
            result[index] = home.x + offsets[index].width
        }
        if let pair = ForestTheatrePacing.closestPair(x: xs, present: present) {
            if Bool.random() {
                // 结对跳舞：两只同时摇摆，同步的节奏就是舞步
                trigger(pair.0, action: .wiggle)
                trigger(pair.1, action: .wiggle)
                if bubblesAllowed, Bool.random() {
                    requestRawBubble(pair.0, pool: ["跳个舞吧！"])
                }
            } else {
                await performDialogue(pair)
            }
        } else if let only = present.first {
            trigger(only, action: .wiggle)
        }
    }

    /// 一问一答：按 `ForestTheatrePacing.dialogueCues` 的节拍，两只邻居交替把脚本说完。
    private func performDialogue(_ pair: (Int, Int)) async {
        guard bubblesAllowed, let script = Self.dialogueScripts.randomElement() else { return }
        let cues = ForestTheatrePacing.dialogueCues(lineCount: script.count)
        for (i, cue) in cues.enumerated() {
            if i > 0 {
                try? await Task.sleep(for: .seconds(cue.start - cues[i - 1].start))
                guard !Task.isCancelled else { return }
            }
            let speaker = i.isMultiple(of: 2) ? pair.0 : pair.1
            requestRawBubble(speaker, pool: [script[i]], hold: cue.hold)
        }
    }

    /// 歪头安慰：纠错后派一只在场的小动物歪歪头，说句温柔的话。
    /// ⚠️ 只点在场的居民；安慰语固定轮换（连续纠错不会每次都是同一句）。
    private func comfort() {
        guard activityAllowed, !theme.isNight, bubblesAllowed else { return }
        let present = presentResidents
        guard let index = present.randomElement() else { return }
        trigger(index, action: .tilt)
        requestRawBubble(index, pool: Self.comfortPhrases)
    }

    /// 这一次 `climbFraction` 的变化算不算「真的往上爬了一层」。
    ///
    /// 三条否定，每条都是一次真实会发生的事：
    /// - **没动**（`new == old`）：同一帧被 SwiftUI 重算，不是学习事件；
    /// - **往下走**：进度回退（如重置闯关）时，小动物不该跳起来叫好；
    /// - **从 0 起步**（`old == 0`）：进度刚从库里读回来填上初始值，
    ///   那一次变化是「加载」不是「攀爬」——不演，否则每次开屏都要演一遍。
    ///
    /// 剩下一个极小阈值 0.0004：把浮点噪声和「几乎没动」一起挡掉。
    /// 抽成纯函数是为了能单测（`onChange` 闭包没法直接测）。
    nonisolated static func isRealAscent(old: Double, new: Double) -> Bool {
        guard old > 0 else { return false }
        return new > old + 0.0004
    }

    /// 学员往上爬了一层：最近的一只小跳两下 + 一句招呼。
    ///
    /// 为什么挑「最近的一只」而不是随便一只：学员在树干上，离树干最近的那只
    /// 就是「就在他脚下」的那只，抬头就能看见他 —— 远处那几只抬头是看不到的。
    /// 这里没有几何可算（调用点在 `body` 之外），退一步取栈顶第一只：
    /// 地面带的排布本来就是从树干向两侧铺开的。
    private func cheerAscent() {
        guard activityAllowed, !theme.isNight else { return }
        let present = presentResidents
        guard let index = present.first else { return }
        trigger(index, action: .hop)
        Task { @MainActor in
            // 两下才像"高兴"，一下更像绊了一下
            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled else { return }
            trigger(index, action: .hop)
        }
        if bubblesAllowed {
            requestRawBubble(index, pool: Self.ascentPhrases)
        }
    }

    // MARK: 边界状态（批次八 · H）

    /// 首次进入欢迎：居民从左到右依次跳一圈（像点名报到），队头冒一句欢迎词。
    /// 夜晚 / 活动被关时**只冒气泡不跳**——睡着的小动物被吵醒跳就不礼貌了。
    private func welcomeParty() {
        welcomePlayed = true
        let present = presentResidents
        if activityAllowed, !theme.isNight {
            for (order, index) in present.enumerated() {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(Double(order) * 0.35))
                    trigger(index, action: .hop)
                }
            }
        }
        if let first = present.first {
            requestRawBubble(first, pool: Self.welcomePhrases, hold: 3.6)
        }
    }

    /// 错误举牌：最近的一只在场小动物举起牌子，5 秒后自己收。
    ///
    /// 夜晚也举（错误不挑时候）；牌子举在头顶，详情在聊天区横幅——这里只喊一嗓子。
    private func holdUpSign(_ tick: Int) {
        guard let headline = errorHeadline, !headline.isEmpty else { return }
        guard let index = presentResidents.first else { return }
        signShownTick = tick
        withAnimation(.app(.panel)) { signHolder = index }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            // 期间又出了新错（新一轮举牌）→ 本次收起作废，由新一轮自己收。
            guard signHolder == index, signShownTick == tick else { return }
            withAnimation(.app(.reveal)) { signHolder = nil }
        }
    }

    // MARK: 分模块回应（批次四 · A）

    /// 簇拥安慰：一轮错得多了，几只一起围过来（不是一只歪头了事）。
    ///
    /// ⚠️ 与 `comfort()` 只差「几只」和台词分量 —— 判据（错几条）在 `ForestStage`，
    /// 这里不做二次判断，免得两处门槛不一致。
    private func huddleComfort() {
        guard activityAllowed, !theme.isNight else { return }
        let present = presentResidents
        guard !present.isEmpty else { return }
        // 最多三只：再多就不是安慰，是围观的
        let cast = Array(present.shuffled().prefix(min(3, present.count)))
        for index in cast {
            trigger(index, action: .tilt)
            if bubblesAllowed {
                requestRawBubble(index, pool: Self.huddleComfortPhrases)
            }
        }
    }

    /// 模块完成戏码：按 `ForestModuleSkit` 派 1–2 只，演这个模块的动作与台词。
    private func playModuleSkit(_ module: PracticeModule) {
        guard activityAllowed, !theme.isNight else { return }
        let present = presentResidents
        guard !present.isEmpty else { return }
        let cast = Array(present.shuffled().prefix(ForestModuleSkit.castSize(for: module)))
        for index in cast {
            trigger(index, action: ForestModuleSkit.action(for: module))
        }
        // 只让领衔的那只说话：两只同时冒同一句会像复读机。
        if bubblesAllowed, let lead = cast.first {
            requestRawBubble(lead, pool: ForestModuleSkit.lines(for: module))
        }
    }

    /// 中途退出：目送你走。
    ///
    /// 动作选 `shake`（左右摆 = 挥手），台词走 `farewellLines` —— 语气上
    /// 不评判、不催促，退出不是失败。
    private func waveGoodbye(_ module: PracticeModule) {
        guard activityAllowed, !theme.isNight else { return }
        let present = presentResidents
        guard !present.isEmpty else { return }
        let cast = Array(present.shuffled().prefix(min(2, present.count)))
        for index in cast {
            trigger(index, action: .shake)
        }
        if bubblesAllowed, let lead = cast.first {
            requestRawBubble(lead, pool: ForestModuleSkit.farewellLines(for: module))
        }
    }

    /// 学员开口：最近的一只点点头（「嗯，你在说」）。
    ///
    /// ⚠️ 判「最近」看的是**画面上的 x**，不是槽位号：草坡上站位是错落的，
    /// 槽位相邻的两只未必挨着。
    private func acknowledgeLearner() {
        guard activityAllowed, !theme.isNight else { return }
        let present = presentResidents
        guard let index = present.randomElement() else { return }
        trigger(index, action: .nod)
    }

    /// 老师开口：两三只抬起头听（全员一起抬头反而像受惊）。
    private func listenUp() {
        guard activityAllowed, !theme.isNight else { return }
        let present = presentResidents
        guard !present.isEmpty else { return }
        let cast = Array(present.shuffled().prefix(min(2, present.count)))
        for index in cast {
            trigger(index, action: .listen)
        }
    }

    // MARK: 连续剧情（#418-C）

    /// 各幕的台词池（每幕自己的语气，别混用）。
    private static let storyLines: [ForestStoryArc.Act: [String]] = [
        .harvest: ["枝头又结果子啦！", "看，那是你攒下的星星。"],
        .encore: ["还想再来一段？先让我热热身！", "通关了还练，佩服佩服！"],
        .focus: ["你练得真专注，我都不好意思打闹了。", "这么认真，我陪你一块儿。"],
    ]

    /// 演一幕：主角演动作 + 冒一句幕词。
    ///
    /// ⚠️ **演员绑定**：这一轮学习里的各幕由同一位领衔（`storyLead`）——
    /// 剧情感来自「是同一个小伙伴在陪你」，每次换角就成了随机点播。
    /// 主角暂离（轮换出去了）就换角重绑，不能让画外的角色凭空演戏。
    /// 夜晚 / 活动被关时不演（舞台的记账照走，这一幕会话里就此错过）。
    private func performStoryAct(_ act: ForestStoryArc.Act) {
        guard activityAllowed, !theme.isNight else { return }
        let present = presentResidents
        if let lead = storyLead, !present.contains(lead) { storyLead = nil }
        let lead = storyLead ?? present.randomElement()
        if storyLead == nil { storyLead = lead }
        guard let lead else { return }
        switch act {
        case .harvest: trigger(lead, action: .hop)
        case .encore: trigger(lead, action: .wiggle)
        case .focus: trigger(lead, action: .nod)
        }
        if bubblesAllowed, let lines = Self.storyLines[act] {
            requestRawBubble(lead, pool: lines)
        }
    }

    /// 安静太久了：有谁打个盹（不是「睡着」，是困了点个头）。
    ///
    /// 由**既有心跳**判时间差（`lastActivityAt` 距今），因此不需要新增任何定时器；
    /// `hasDozed` 保证安静期间只演一次，直到学习上又有动静才解锁。
    private func dozeOffIfQuiet() {
        guard activityAllowed, !theme.isNight, !hasDozed else { return }
        let quiet = Date().timeIntervalSince(lastActivityAt)
        guard quiet >= ForestStage.idleThresholdSeconds else { return }
        let present = presentResidents
        guard let index = present.randomElement() else { return }
        hasDozed = true
        trigger(index, action: .nod)
        if bubblesAllowed {
            requestRawBubble(index, pool: Self.dozingPhrases)
        }
    }

    /// 捡词具象叙事：看见新词 → 跑出画面 → 叼一张单词卡回来展示。
    ///
    /// 「事事有回应」的具象版——收词不只是飘一片叶子，而是森林里真的有谁
    /// 为这件事跑了一趟。上一场没演完时新事件只留树上的叶子回应（不排队、不叠加）。
    private func fetchWord(count: Int, span: CGFloat, inset: CGFloat,
                           groundLine: ForestGroundSurface, quantizedWidth: CGFloat) async {
        guard activityAllowed, !theme.isNight, !isFetchingWord, let word = wordPayload else { return }
        // 只派**在场且站在草地上**的居民（枝上的鸟不接这活）
        let present = (0..<count).filter { !away[$0] && !perched[$0] }
        guard let fetcher = present.randomElement() else { return }

        isFetchingWord = true
        defer {
            isFetchingWord = false
            // 捡到一半被打断时这位可能正站在画外（`away` 已置真）—— 接回来，
            // 否则它这一趟就再没机会回来，草坡上永久少一只。
            bringStraysHome()
        }

        // ① 看见词：先冒一句「我去捡」，动身
        if bubblesAllowed {
            requestRawBubble(fetcher, pool: Self.fetchStartPhrases, hold: ForestTheatrePacing.fetchNoticeSeconds)
        }
        try? await Task.sleep(for: .seconds(ForestTheatrePacing.fetchNoticeSeconds))
        guard !Task.isCancelled else { return }

        // ② 跑出画面（朝离自家近的一侧），短暂消失翻找
        let home = homePosition(index: fetcher, count: count, span: span, inset: inset,
                                groundLine: groundLine, quantizedWidth: quantizedWidth)
        let exitLeft = home.x + offsets[fetcher].width < inset + span / 2
        if facings.indices.contains(fetcher) { facings[fetcher] = exitLeft ? -1 : 1 }
        let exitX = exitLeft ? -(inset + 40) : (inset + span + 40) - home.x
        await hopTo(fetcher, target: CGSize(width: exitX, height: offsets[fetcher].height),
                    steps: 3, hopHeight: 8)
        guard !Task.isCancelled else { return }
        away[fetcher] = true
        try? await Task.sleep(for: .seconds(ForestTheatrePacing.fetchLingerSeconds))
        guard !Task.isCancelled else { return }

        // ③ 叼着词卡现身，走回家
        away[fetcher] = false
        wordCard = (fetcher, word)
        withAnimation(.app(.reveal)) {
            if facings.indices.contains(fetcher) { facings[fetcher] = exitLeft ? 1 : -1 }
        }
        try? await Task.sleep(for: .seconds(0.2))
        guard !Task.isCancelled else { return }
        await hopTo(fetcher, target: .zero, steps: 5, hopHeight: 8)
        guard !Task.isCancelled else { return }

        // ④ 展示：冒一句炫耀 + 词卡挂一会儿，然后各自收场
        if bubblesAllowed {
            requestRawBubble(fetcher, pool: Self.fetchDonePhrases)
        }
        try? await Task.sleep(for: .seconds(ForestTheatrePacing.wordCardHoldSeconds))
        guard !Task.isCancelled else { return }
        withAnimation(.app(.reveal)) { wordCard = nil }
    }

    // MARK: 花草

    /// 点草地冒一朵花（批次六 · E）：花色随机抽，上限与挤掉规则在 `GroundFlowerBed`。
    private func plantFlower(at x: CGFloat) {
        plantedCounter += 1
        let planted = PlantedFlower(id: plantedCounter, x: x,
                                    palette: Int.random(in: 0..<3))
        withAnimation(.app(.reveal)) {
            plantedFlowers = GroundFlowerBed.push(planted, into: plantedFlowers)
        }
    }

    private func grassBlade(x: CGFloat, h: CGFloat, w: CGFloat, seed: Int, groundLine: ForestGroundSurface) -> some View {
        // 风摆包在 `.position` **之内**：元素自身的坐标系里绕底边转（= 根部扎根在晃）。
        // 包到 position 外面就变成绕整块画布的底边转 —— 那不是草在动，是地在动。
        WindSway(x: x, height: h, gain: 0.9, rotationGain: 1.1) {
            Capsule()
                .fill(theme.foliage.opacity(0.7))
                .frame(width: w, height: h)
                .rotationEffect(.degrees(Double((pr(seed, 6) - 0.5) * 24)))
        }
        .position(x: x, y: groundLine(x) - h / 2 + 3)
    }

    private func flower(x: CGFloat, groundLine: ForestGroundSurface, palette: Int) -> some View {
        let color: Color = palette == 0 ? Color(hex: 0xFF9BB5)
            : palette == 1 ? Color(hex: 0xFFF0B8)
            : Color(hex: 0xFFFFFF)
        return WindSway(x: x, height: 14, gain: 1.0, rotationGain: 1.3) {
            ZStack {
                ForEach(0..<5, id: \.self) { petal in
                    Ellipse()
                        .fill(color)
                        .frame(width: 4.4, height: 3.0)
                        .offset(y: -3.2)
                        .rotationEffect(.degrees(Double(petal) * 72))
                }
                Circle()
                    .fill(Color(hex: 0xF7B32B))
                    .frame(width: 4, height: 4)
            }
        }
        .position(x: x, y: groundLine(x) - 8)
        .opacity(0.95)
    }

    // MARK: 灌木

    private func bush(x: CGFloat, groundLine: ForestGroundSurface, seed: Int) -> some View {
        let s: CGFloat = 26 + pr(seed, 13) * 14
        // 灌木最重一档（gain 0.45）：一丛叶子兜住风，风来是整丛微微欠身，
        // 不是每片叶子各晃各的 —— 与草叶（0.9）拉开「质量感」的差距。
        return WindSway(x: x, height: s, gain: 0.45, rotationGain: 0.35) {
            ZStack {
                Circle().fill(theme.foliage.opacity(0.9)).frame(width: s, height: s * 0.82)
                Circle().fill(theme.foliageDeep.opacity(0.85))
                    .frame(width: s * 0.72, height: s * 0.6)
                    .offset(x: s * 0.42, y: s * 0.08)
                Circle().fill(theme.foliage.opacity(0.8))
                    .frame(width: s * 0.6, height: s * 0.5)
                    .offset(x: -s * 0.45, y: s * 0.1)
            }
        }
        .position(x: x, y: groundLine(x) - s * 0.32)
        .opacity(0.95)
    }

    // MARK: 居民个体

    /// 家位置（与 resident() 完全同一套伪随机，编排与绘制共用）。
    private func homePosition(index: Int, count: Int, span: CGFloat, inset: CGFloat,
                              groundLine: ForestGroundSurface, quantizedWidth: CGFloat)
        -> (x: CGFloat, y: CGFloat, size: CGFloat) {
        let depth = pr(index, 14)
        let base = min(54, 28 + quantizedWidth * 0.045) * (0.72 + depth * 0.42)
        let size = base * (0.94 + pr(index, 5) * 0.14)
        let pitch = span / CGFloat(max(1, count))
        let jitter = (pr(index, 4) - 0.5) * min(24, pitch * 0.34)
        let x = inset + (CGFloat(index) + 0.5) * pitch + jitter
        let y = groundLine(x) - size * 0.5 - depth * 10 + pr(index, 9) * 6
        return (x, y, size)
    }

    private func resident(kind: AnimalKind, index: Int, visibleCount: Int,
                          span: CGFloat, inset: CGFloat, groundLine: ForestGroundSurface,
                          quantizedWidth: CGFloat) -> some View {
        let visible = index < visibleCount && !away[index]
        let home = homePosition(index: index, count: visibleCount, span: span, inset: inset,
                                groundLine: groundLine, quantizedWidth: quantizedWidth)
        let facing = facingAt(index: index)
        let currentKind = kindAt(index: index, fallback: kind)

        return ZStack {
            // 脚底阴影（落到脚部而不是身体中心；鸟在枝上时收起）
            // ⚠️ 方向走全局光源（`ForestLighting`：太阳右上 → 影子左下）——
            // 从前所有影子笔直朝下，等于默认太阳正在头顶，和天边那颗对不上。
            if !perched[index] {
                let shadow = ForestLighting.shadowOffset(forDepth: ForestSceneGeometry.nearHillDepth)
                Ellipse()
                    .fill(theme.shadow)
                    .frame(width: home.size * 0.92, height: home.size * 0.15)
                    .offset(x: shadow.width, y: home.size * 0.42 + shadow.height)
            }

            LivelyAnimal(
                kind: currentKind,
                isSleeping: theme.isNight,
                size: home.size,
                facing: facing,
                actionTick: actionTicks[index],
                actionKind: actionKinds[index],
                onTap: {
                    requestBubble(index)
                    onResidentTap?(currentKind)
                },
                onSpontaneousBubble: { requestBubble(index) },
                // 槽位号即初相种子：8 个槽位的初相互不重叠（见 `blinkLead` 的说明），
                // 于是「整排一起眨」变成「一只接一只地眨」。
                blinkPhaseSeed: index,
                // 季节装扮与降水行为（#605）：主题的 season / weather 只改插画层，
                // 顺着环境一路带到每只居民身上。nil（不跟随）= 老样子。
                season: theme.season,
                weather: theme.weather
            )
        }
        .position(x: home.x + offsets[index].width, y: home.y + offsets[index].height)
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.6, anchor: .bottom)
        .allowsHitTesting(visible)
        // 显隐动画认「在不在场」这一个量：宽度档位变化与轮换暂离/回归共用同一条曲线
        .appAnimation(.reveal, value: visible)
    }

    // MARK: 物种轮换（随机离开 → 新邻居进入）

    /// 初始化/对齐各槽位的物种与朝向状态（数量或首次出现时调用）。
    private func ensureResidents(order: [AnimalKind]) {
        guard kinds.count != Self.maxResidents || facings.count != Self.maxResidents else { return }
        if kinds.isEmpty {
            kinds = (0..<Self.maxResidents).map { order[$0 % order.count] }
        } else {
            kinds = (0..<Self.maxResidents).map { kinds.indices.contains($0) ? kinds[$0] : order[$0 % order.count] }
        }
        if facings.isEmpty {
            facings = (0..<Self.maxResidents).map { pr($0, 3) > 0.5 ? 1 : -1 }
        } else {
            facings = (0..<Self.maxResidents).map { facings.indices.contains($0) ? facings[$0] : 1 }
        }
    }

    private func kindAt(index: Int, fallback: AnimalKind) -> AnimalKind {
        kinds.indices.contains(index) ? kinds[index] : fallback
    }

    private func facingAt(index: Int) -> CGFloat {
        facings.indices.contains(index) ? facings[index] : 1
    }

    /// 轮换编排（自然化版）：告别 → 各自看缘分错落回来。
    ///
    /// 与旧版「走一只、紧跟回来一只」的传送带不同：
    /// ① 约三成概率**结伴两只**前后脚走（`ForestRotationPacing.groupSize`）；
    /// ② 归期各自独立 4–45s——有快得像「提前来」的，也有大半天不见影的，
    ///    期间画面上真的少一两只（数量动态变化）；
    /// ③ 下一批告别前安静 0.5–1.5 个周期，一成概率来一段长歇（留白）。
    private func orchestrateRotation(count: Int, span: CGFloat, inset: CGFloat,
                                     groundLine: ForestGroundSurface, quantizedWidth: CGFloat,
                                     order: [AnimalKind]) async {
        // ⚠️ 本循环**被取消时**（拖分割线 → `.task(id:)` 重启，或入夜）把还没回来的
        // 居民接回场上：它们此刻 `away = true`，而新的循环只从「在场」的槽位里挑人，
        // 于是这些槽位再也排不到归期 —— 画面上永久少几只，越拖越少。
        // （正常路径是死循环，这个 defer 只在取消 / 退出时跑一次。）
        defer { bringStraysHome() }

        // 个体错峰启动，别开屏就整整齐齐换班
        try? await Task.sleep(for: .seconds(Double.random(in: 8...20)))
        while !Task.isCancelled {
            // 轮换属于「活动」：开关关闭或入夜时静默等待（醒来时全员已被送回家）
            guard activityAllowed, !theme.isNight else {
                try? await Task.sleep(for: .seconds(5))
                continue
            }
            guard count > 0 else { continue }
            let present = (0..<count).filter { !away[$0] }
            guard !present.isEmpty else {
                // 全在「回家路上」：等下一轮（归期循环没跑完不会走到这，兜底而已）
                try? await Task.sleep(for: .seconds(4))
                continue
            }

            // ① 这一批走几只？
            let group = ForestRotationPacing.groupSize(present: present.count,
                                                       roll: Double.random(in: 0..<1))
            let leavers = Array(present.shuffled().prefix(group))

            // ② 告别 + 沿地面走出画面：结伴时前后脚错落动身，不齐步走
            for (offset, index) in leavers.enumerated() {
                if offset > 0 {
                    try? await Task.sleep(for: .seconds(
                        ForestRotationPacing.staggerDelay(roll: Double.random(in: 0..<1))))
                    guard !Task.isCancelled else { return }
                }
                if bubblesAllowed {
                    requestRawBubble(index, pool: Self.leavePhrases)
                    try? await Task.sleep(for: .seconds(2.6))
                }
                guard !Task.isCancelled else { return }
                await hopOutOfStage(index, count: count, span: span, inset: inset,
                                    groundLine: groundLine, quantizedWidth: quantizedWidth)
                away[index] = true
            }

            // ③ 归期各自独立：谁先到看缘分（回来顺序与离开顺序刻意打乱）
            for index in leavers.shuffled() {
                try? await Task.sleep(for: .seconds(
                    ForestRotationPacing.returnDelay(roll: Double.random(in: 0..<1))))
                guard !Task.isCancelled else { return }
                // 入夜 / 关活动：剩下的不再回来（sendEveryoneHome 已把 away 清掉）
                guard activityAllowed, !theme.isNight else { break }
                await arriveFromEdge(index: index, count: count, span: span, inset: inset,
                                     groundLine: groundLine, quantizedWidth: quantizedWidth,
                                     order: order)
            }

            // ④ 下一批告别前先安静一阵
            try? await Task.sleep(for: .seconds(ForestRotationPacing.nextDepartureDelay(
                frequency: activityFrequency,
                roll: Double.random(in: 0..<1),
                spread: Double.random(in: 0..<1))))
        }
    }

    /// 把还挂着「暂离」标记的居民接回场上（轮换循环退出 / 被取消时）。
    ///
    /// ⚠️ 只复位**标记**，位置交给 `offsets` 归零（回家）—— 暂离的那只此刻在画外，
    /// 直接翻牌显形会凭空多出一只站在草坡边上。
    private func bringStraysHome() {
        let strays = away.indices.filter { away[$0] }
        guard !strays.isEmpty else { return }
        withAnimation(.app(.panel)) {
            for index in strays {
                away[index] = false
                if offsets.indices.contains(index) { offsets[index] = .zero }
                if perched.indices.contains(index) { perched[index] = false }
            }
        }
    }

    /// 沿地面走出画面（朝离自家近的一侧边缘小跳离场）。
    private func hopOutOfStage(_ index: Int, count: Int, span: CGFloat, inset: CGFloat,
                               groundLine: ForestGroundSurface, quantizedWidth: CGFloat) async {
        let home = homePosition(index: index, count: count, span: span, inset: inset,
                                groundLine: groundLine, quantizedWidth: quantizedWidth)
        let current = offsets[index]
        let bandCenter = inset + span / 2
        let exitLeft = home.x + current.width < bandCenter
        let exitX = exitLeft ? -(inset + 40) : (inset + span + 40) - home.x
        if facings.indices.contains(index) { facings[index] = exitLeft ? -1 : 1 }
        await hopTo(index, target: CGSize(width: exitX, height: current.height),
                    steps: 4, hopHeight: 9)
    }

    /// 一位「新邻居」从离场那一侧的边缘走进来（换物种 → 走回家位 → 打招呼）。
    private func arriveFromEdge(index: Int, count: Int, span: CGFloat, inset: CGFloat,
                                groundLine: ForestGroundSurface, quantizedWidth: CGFloat,
                                order: [AnimalKind]) async {
        // 换物种：谁回来是缘分（只保证不是走掉的那位）
        let pool = AnimalKind.allCases.filter { $0 != kindAt(index: index, fallback: order.first ?? .fox) }
        let newKind = pool.randomElement() ?? .rabbit
        if kinds.indices.contains(index) { kinds[index] = newKind }
        // 此刻还在画外（离场位置），现身走进来
        away[index] = false
        if facings.indices.contains(index) {
            facings[index] = offsets[index].width < 0 ? -1 : 1
        }
        try? await Task.sleep(for: .seconds(0.15))
        guard !Task.isCancelled else { return }
        let current = offsets[index]
        await hopTo(index, target: CGSize(width: 0, height: current.height),
                    steps: 6, hopHeight: 8)
        if bubblesAllowed {
            requestRawBubble(index, pool: Self.greetPhrases)
        }
    }

    /// 作废所有在飞的移动批次（入夜 / 关活动用）。
    ///
    /// 只自增计数器不够 —— 在飞的那一批手里拿的正是「当前」批次号；必须把
    /// 每个槽位的批次号推到新值，它们才对不上账、自行退场。
    private func invalidateHops() {
        hopCounter += 1
        hopTokens = Array(repeating: hopCounter, count: Self.maxResidents)
    }

    /// 多段小跳从当前位置移动到目标位移（跳动前进，而不是平移）。
    ///
    /// ⚠️ **后来者胜出**：每次发起都领一个新批次号并记进 `hopTokens[index]`，
    /// 循环里每一步都对一次账 —— 对不上说明期间又有新的移动意图（游走 / 离场 /
    /// 归位 / 捡词撞车），本次立刻退出，不再碰 `offsets`。
    /// 两个编排循环并发盯上同一只时，没有这个对账就是两边交替写同一个位移。
    private func hopTo(_ index: Int, target: CGSize, steps: Int, hopHeight: CGFloat) async {
        guard offsets.indices.contains(index), hopTokens.indices.contains(index) else { return }
        hopCounter += 1
        let token = hopCounter
        hopTokens[index] = token
        let start = offsets[index]
        for step in 1...max(1, steps) {
            guard !Task.isCancelled else { return }
            guard hopTokens.indices.contains(index), hopTokens[index] == token else { return }
            let t = Double(step) / Double(steps)
            let x = start.width + (target.width - start.width) * t
            let y = start.height + (target.height - start.height) * t
            // 起跳：横移一段 + 向上抬起
            withAnimation(.app(.press)) {
                offsets[index] = CGSize(width: x, height: y - hopHeight)
            }
            try? await Task.sleep(for: .seconds(0.17))
            // 落地
            withAnimation(.app(.press)) {
                offsets[index] = CGSize(width: x, height: y)
            }
            try? await Task.sleep(for: .seconds(0.13))
        }
    }

    /// 轮换专用冒泡（不走物种文案池，直接给文案）。
    /// 每个小动物持有自己的气泡：新气泡只覆盖**自己**那一句，其他动物的话照常挂着；
    /// 出现序号递增 → 最新出现的画在最上层；`hold` 秒后各自独立收起。
    private func requestRawBubble(_ index: Int, pool: [String], hold: Double = 3) {
        guard !pool.isEmpty, bubbleTexts.indices.contains(index) else { return }
        bubbleCounter += 1
        let stamp = bubbleCounter
        withAnimation(.app(.panel)) {
            bubbleStamps[index] = stamp
            bubbleTexts[index] = pool.randomElement()
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(hold))
            // 期间这只小动物又说了新话（或全体收声）→ 本次收起作废
            guard bubbleStamps.indices.contains(index), bubbleStamps[index] == stamp else { return }
            withAnimation(.app(.reveal)) { bubbleTexts[index] = nil }
        }
    }

    /// 请求冒泡（点击或自发动作统一入口）：顶层展示，3 秒后自动收起。
    ///
    /// 文案池走 `bubblePhrases(season:weather:)`（#606）：通用句打底、
    /// 当季与当天的句子做增量 —— 无季节无天气时逐字等于物种原池。
    private func requestBubble(_ index: Int) {
        guard bubblesAllowed else { return }
        let kind = kindAt(index: index, fallback: AnimalKind.allCases[index % AnimalKind.allCases.count])
        requestRawBubble(index, pool: kind.bubblePhrases(season: theme.season, weather: theme.weather))
    }

    // MARK: 右下角活动开关（与设置联动）

    private var activityButton: some View {
        Button {
            activityTapped()
        } label: {
            Image(systemName: theme.isNight ? "moon.zzz.fill"
                  : (activityAllowed ? "face.smiling" : "face.dashed"))
                .appFont(13, weight: .semibold)
                .foregroundStyle(activityAllowed && !theme.isNight ? theme.accent : theme.secondaryText)
                .frame(width: 30, height: 30)
                .background(Circle().fill(theme.surface.opacity(0.9)))
                .overlay(Circle().strokeBorder(theme.divider, lineWidth: 1))
        }
        .buttonStyle(.appPressable)
        .help(activityHelp)
    }

    /// 点击行为：白天 = 活动开关；夜晚 = 冒一句「它们在睡觉」（连点随机换一句）。
    private func activityTapped() {
        guard theme.isNight else {
            onActivityToggle?()
            return
        }
        let pool = Self.sleepPhrases.filter { $0 != sleepLine }
        let next = pool.randomElement() ?? Self.sleepPhrases[0]
        withAnimation(.app(.panel)) { sleepLine = next }
        sleepTick += 1
    }

    private var activityHelp: String {
        if theme.isNight { return "夜深了，小动物们正在睡觉（点一下看看它们的梦话）" }
        return activityAllowed ? "小动物们正在自由活动（点击让它们排排站好）" : "小动物们已安静（点击放它们出来玩）"
    }

    /// 草坡（林间地面带中央那只鼓包）。
    ///
    /// 曲线与 `ForestSceneGeometry.hillSurfaceY` 是**同一条的两种写法**（解析式 ↔
    /// 二次曲线）：鼓包量与坡高都读统一常量，改动不会只落在一侧。
    private struct HillCap: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.maxY),
                control: CGPoint(x: rect.midX, y: rect.minY - ForestSceneGeometry.hillCapBulge)
            )
            path.closeSubpath()
            return path
        }
    }
}

/// 小动物「叼回来」的单词卡：圆角小白卡 + 一片小叶 + 单词本体。
/// 纯展示（不吃点击），挂在捡词动物的头顶，展示完由父级收走。
private struct CarriedWordCard: View {
    let word: String
    let theme: ForestTheme

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: "leaf.fill")
                .appFont(8, weight: .bold)
                .foregroundStyle(theme.accent)
            Text(word)
                .appFont(11, weight: .bold, design: .rounded)
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 9)
        .appPadding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9).fill(theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(theme.accent.opacity(0.55), lineWidth: 1))
        .shadow(color: theme.shadow, radius: 4, x: 0, y: 2)
    }
}

// MARK: - 点草地冒花（批次六 · E 可玩彩蛋）

/// 用户亲手点出来的一朵小花。
struct PlantedFlower: Identifiable, Equatable {
    /// 自增序号（同时当 id）。
    let id: Int
    /// 点下的横向位置（本视图坐标；渲染时钳回草地两端之内）。
    let x: CGFloat
    /// 花色（0/1/2，与既有的三色小花同一套）。
    let palette: Int
}

/// 花坛的账本（纯函数，便于单测）：只管一条规则 —— 上限之内随便长，
/// 超了挤掉**最早**那朵（地就那么大，最新的心意最要紧）。
enum GroundFlowerBed {
    /// 12 与林间空地（GladeGrowth.maxPlants）同一口径：再多就糊成噪点。
    static let cap = 12

    static func push(_ flower: PlantedFlower, into bed: [PlantedFlower]) -> [PlantedFlower] {
        var bed = bed
        bed.append(flower)
        if bed.count > cap {
            bed.removeFirst(bed.count - cap)
        }
        return bed
    }
}
