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

