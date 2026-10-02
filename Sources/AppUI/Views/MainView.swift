import AIDomain
import AppCore
import AppKit
import SwiftUI

/// 主界面：**左侧可收拉侧边栏 / 中间对话 / 右侧成长之树闯关画布**。
/// - 三栏顶栏统一 64pt 高，顶部分界线对齐；
/// - 对话与成长之树之间是可拖动分割线（拖动调整两栏宽度，内容自适应居中）；
/// - 整页弹性布局：窗口变化时按可用宽度重新分配，不再需要手动拉大窗口。
public struct MainView: View {

    @Bindable var state: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.forestTheme) private var theme

    /// 成长之树面板宽度（可拖动），由窗口宽度约束夹取。
    @State private var treePanelWidth: CGFloat = 380
    @State private var treeDragStart: CGFloat?

    private let sideDividerWidth: CGFloat = 1
    private let resizeHandleWidth: CGFloat = 14

    public init(state: AppState) { self.state = state }

    public var body: some View {
        GeometryReader { proxy in
            let total = proxy.size.width
            // 侧栏展开 = 用户偏好 ∧ 窗口允许（#417）：窄窗**临时**收成图标栏，
            // 窗口拉宽自动还原 —— 偏好本身不被窗口尺寸悄悄改掉。
            let sidebarExpanded = AppLayoutMetrics.sidebarExpanded(
                userPrefers: state.isSidebarExpanded, windowWidth: total
            )
            let sidebarW = sidebarExpanded ? AppSidebar.expandedWidth : AppSidebar.collapsedWidth
            let fixedW = sidebarW + sideDividerWidth + resizeHandleWidth
            let treeW = AppLayoutMetrics.treeWidth(preferred: treePanelWidth, available: total - fixedW)
            let chatW = max(AppLayoutMetrics.chatMinWidth, total - fixedW - treeW)

            ZStack {
                // 天空不再自己画天体：右上角的太阳/月亮由 CelestialToggle 画在内容层之上，
                // 这样它才是「看得见、点得到」的日夜切换控件（点击即切换）。
                // ambientStill：连点天空 5 次收起云和萤火虫（批次六 · E 可玩彩蛋）。
                ForestSky(theme: state.theme, showsCelestial: false,
                          ambientStill: state.forest.ambientHidden)

                HStack(spacing: 0) {
                    AppSidebar(state: state, widthAllowsExpansion: sidebarExpanded)
                        .frame(width: sidebarW)
                        // ⚠️ 侧栏要抬一层（2026-09-24 报障：徽章浮卡右半截被中间栏底色
                        // 盖住）。徽章的悬浮说明卡画在自己 220pt 之外，而分隔线 / 中间栏 /
                        // 右栏都是**更晚的兄弟节点**，默认会把溢出的浮卡画在下面。
                        // 浮卡自己 `allowsHitTesting(false)`，抬层不抢任何点击；
                        // 设置 / 情景这类浮层在更外层的 ZStack 上、zIndex 更高，仍然压得住它。
                        .zIndex(1)

                    Divider().overlay(state.theme.divider)
                        .frame(width: sideDividerWidth)

                    chatArea
                        .frame(width: chatW)

                    resizeHandle
                        .frame(width: resizeHandleWidth)

                    levelPanel
                        .frame(width: treeW)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 右上角：太阳 / 月亮 = 日夜切换。
                //
                // 开着「跟随时间」时它**沿弧线走**：日出从左边缘升起、正午到最高、
                // 日落沉到右边缘，夜里换月亮走同一条弧。关着时钉在右上角（既有位置），
                // 老用户开屏看到的还是原来那颗太阳。
                let followsClock = state.forestFollowsClock
                let anchor = ForestAtmosphere.celestialAnchor(hour: state.clockHour, width: total)
                // spins：氛围演出隐藏档下（批次六 · E），切换控件里那颗太阳的光环也停。
                CelestialToggle(action: {
                    Task { await state.toggleDayNight() }
                }, spins: !state.forest.ambientHidden)
                .frame(width: ForestAtmosphere.celestialSize, height: ForestAtmosphere.celestialSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: followsClock ? .topLeading : .topTrailing)
                .padding(.leading, followsClock ? anchor.x : 0)
                .padding(.trailing, followsClock ? 0 : ForestAtmosphere.celestialMargin)
                .padding(.top, followsClock ? anchor.y : 44)
                .zIndex(2)

                if state.showingSettings {
                    settingsOverlay
                }

                if state.showingScenarios {
                    scenariosOverlay
                }

                // 上传材料浮层：叠在情景面板**之上**（它是从情景面板的头部入口进来的）。
                if state.showingMaterialUpload {
                    materialUploadOverlay
                }

                // 描述场景浮层（⑦）：同上 —— 也是从情景面板头部竖起来的，与它同层。
                if state.showingScenarioComposer {
                    scenarioComposerOverlay
                }

                // 入学定级浮层：从学习进度页进来，与上传材料同一层。
                if state.isPlacementShowing {
                    placementOverlay
                }

                // 考后结算卡：报告浮在最前面。**只有两个出口**（再来一次 / 完成），
                // 点遮罩不关 —— 一场考试的报告随手点掉就找不回来了。
                if let report = state.examReport {
                    examReportOverlay(report)
                }

                // 模型启停 / 星星结算 / 课程覆盖度三张浮卡：抽成独立计算属性
                //（body 贴着类型检查预算，这三段链留在 body 里就超时——编译器实测报过错）。
                globalToastOverlays
            }
            // 划词气泡浮层：挂在**最外层 ZStack** 上（2026-09-29 报障的修复）。
            //
            // ⚠️ 位置纪律：必须在 ZStack 的**闭合括号之后**。写进括号里、紧跟在某个
            // 孩子后面，ViewBuilder 会把它解析成「挂在那个孩子身上」——上一版挂在
            // `globalToastOverlays`（无 toast 时是 EmptyView）上，锚点 preference 一个
            // 都收不到，结果就是「任何地方都触发不了划词」（用户实测报障的根因）。
            //
            // 挂在这里，sidebar(1) / CelestialToggle(2) / 各面板(18~50) 全在它底下；
            // 面板打开时 `isContentCovered` 已把气泡收掉（见下方 onChange），互不打架。
            // anchor 的坐标是**相对浮层所在层级**实时解算的（`geo[anchor.bounds]`），
            // 换层只需要平移一次原点，摆位算式（`WordLookupLayerPlacement`）不用动。
            .wordLookupBubbleOverlay()
            // 全局搜索（#414）：挂在**划词浮层之后**。浮层置顶纪律里「越晚挂越在上」，
            // 挂进 ZStack 里会被划词气泡盖掉一截（气泡也在最外层）。
            .overlay {
                if state.showingGlobalSearch {
                    globalSearchOverlay
                }
            }
            // 帮助中心（#413）：菜单栏「帮助 → 使用说明」开的是同一个 `state.showingHelp`。
            // 挂在这一层，设置页那张卡（sheet 在设置浮层里）与菜单入口看到的是同一份。
            .sheet(isPresented: $state.showingHelp) {
                HelpCenterView { state.showingHelp = false }
            }
        }
        .frame(minWidth: AppLayoutMetrics.minWindowWidth, minHeight: AppLayoutMetrics.minWindowHeight)
        .forestTheme(state.theme)
        // ⚠️ 动效档位在这一层注入一次，整棵树都跟着走：应用内覆盖档（设置页「动画效果」）
        // 与系统「减弱动态效果」在此合成（同一份逻辑在 MotionMode.reducesMotion）。
        // Sheet 挂在另一条分支上，覆盖不到，各自加。
        .appMotionRoot(override: state.motionMode)
        // 排版档位（#416）也在这一层注入一次：字号档与密度档的倍率
        // 经 `\.appTypography` 传导到全树（`.appFont` / `.appPadding` 读它）。
        // Sheet 挂在另一条分支上，覆盖不到，各自加。
        .appTypographyRoot(typeSize: state.typeSize, density: state.interfaceDensity)
        // 统一的按压反馈：165 处 Button 不必逐个改。只改不透明度、不动布局，
        // 所以命中区与间距完全不变（详见 AppButtonStyle 的说明）。
        // 显式写了 `.buttonStyle(.plain)` 的地方会以自己为准 —— 那是刻意的。
        .buttonStyle(.appPressable)
        // 划词气泡的浮层由 `AppState` 持有：中间栏任何页面的句子都能把气泡交给它画。
        .environment(\.wordLookupPresenter, state.lookupBubble)
        // 面板一开就把气泡收掉：它浮在内容层之上，否则会跟着留在面板外面。
        .onChange(of: state.isContentCovered) { _, covered in
            if covered { state.lookupBubble.hide() }
        }
        // 结算成功的触觉（#358）：只在**出现**时触发（收起不打扰）。
        // 挂在常驻的根容器上 —— 挂进 if let 分支里每次都是新装视图，trigger 等不到变化。
        // 结算成功的触觉（#358）：只在**出现**时触发（收起不打扰）。
        // 挂在常驻的根容器上 —— 挂进 if let 分支里每次都是新装视图，trigger 等不到变化。
        // ⚠️ 闭包参数写显式类型：body 已经大到贴着类型检查预算，推断负担能省则省
        // （不加标注时整条链「unable to type-check in reasonable time」）。
        .sensoryFeedback(.success, trigger: state.lastReward) { (old: ScenarioReward?, new: ScenarioReward?) in
            old == nil && new != nil
        }
        // 日夜切换作用于全局：原生控件（TextField / Picker / 滚动条）也一起跟随。
        .preferredColorScheme(state.theme.isNight ? .dark : .light)
        .animation(.easeInOut(duration: 0.5), value: state.theme.palette)
        // 批次八 · H：欢迎演出要在**地面带到场之后**才发脉冲（发早了 onChange 收不到
        // 第一拍）—— 盯着 isBooting 翻 false 的那一刻消费待演标记。
        .task(id: state.isBooting) {
            guard !state.isBooting else { return }
            state.consumeForestWelcome()
        }
        // 批次八 · H：老师联系不上（模型未配置 / 网络失败…）→ 林子里的小动物举牌。
        // 详情仍在聊天区的错误横幅，牌子只举一句短的概括。
        .onChange(of: state.chat.errorMessage) { _, message in
            guard let message else { return }
            state.forest.showError(headline: ForestErrorSign.headline(for: message))
        }
        .appAnimation(.reveal, value: state.showingSettings)
        .appAnimation(.reveal, value: state.showingScenarios)
        .appAnimation(.reveal, value: state.showingMaterialUpload)
        .appAnimation(.reveal, value: state.showingScenarioComposer)
        .task {
            state.systemIsDark = (colorScheme == .dark)
            // ⚠️ 界面开关要在 `start()` **前后各压一次**：
            // `start()` 末尾跑「继续上次练习」，老师开场白是一次真实模型调用
            // （本机冷加载实测 30～60s）。排在它后面的钩子会被一直堵住 ——
            // 表现为「--theme night 截出来还是白天」「--open-settings 面板根本不出现」；
            // 而 `start()` 里若续上了某个情景，又会把页面状态改回去（`startScenario` 会收起面板）。
            // 所以：先压一次让界面立刻正确，`start()` 之后再压一次盖掉它改过的状态。
            await applyLaunchViewHooks()
            await state.start()
            await state.loadScenarios()
            await applyLaunchViewHooks()
            // 验证辅助：--export-report <路径> 把年度学习记录卡直接导出成 PNG（跳过保存面板）。
            if let index = CommandLine.arguments.firstIndex(of: "--export-report"),
               index + 1 < CommandLine.arguments.count {
                await state.reloadProgress()
                if let data = ReportExporter.annualRecapPNG(recap: state.annualRecap, theme: state.theme) {
                    try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                    try? "report written".write(to: URL(fileURLWithPath: "/tmp/alc-hook-debug.txt"), atomically: true, encoding: .utf8)
                } else {
                    try? "report PNG nil".write(to: URL(fileURLWithPath: "/tmp/alc-hook-debug.txt"), atomically: true, encoding: .utf8)
                }
            }
            // 验证辅助：--import-backup <路径> 走完整导入流程（校验 → 确认 → 暂存），跳过确认框。
            if let index = CommandLine.arguments.firstIndex(of: "--import-backup"),
               index + 1 < CommandLine.arguments.count {
                await state.inspectBackup(at: CommandLine.arguments[index + 1])
                if state.backupImportPlan != nil {
                    await state.confirmBackupImport()
                    state.showingSettings = true
                }
            }
            // 验证辅助：--import-material <路径> 导入材料正文并生成拆解（真实模型调用）。
            if let index = CommandLine.arguments.firstIndex(of: "--import-material"),
               index + 1 < CommandLine.arguments.count {
                state.importMaterialFile(at: CommandLine.arguments[index + 1])
                await state.generateMaterialFromDraft()
                state.showingScenarios = true
                try? "material hook done: draft=\(state.materialDraft.count) result=\(state.materialResult ?? "nil") kits=\(state.materialKits.count)"
                    .write(to: URL(fileURLWithPath: "/tmp/alc-hook-debug2.txt"), atomically: true, encoding: .utf8)
            }
            // 截图/验证辅助：--open-records 启动时直接进入学习记录页
            if CommandLine.arguments.contains("--open-records") {
                Task { await state.openRecords() }
            }
            // 截图/验证辅助：--open-progress 启动时直接进入学习进度页（第 25 步 Dashboard）
            // --progress-days N 指定统计窗口（7/14/30）
            if CommandLine.arguments.contains("--open-progress") {
                if let index = CommandLine.arguments.firstIndex(of: "--progress-days"),
                   index + 1 < CommandLine.arguments.count,
                   let days = Int(CommandLine.arguments[index + 1]) {
                    state.progressWindowDays = min(max(days, 7), 90)
                }
                await state.openProgress()
            }
            // 截图/验证辅助：--open-shadowing 启动时直接进入跟读页
            if CommandLine.arguments.contains("--open-shadowing") {
                await state.openShadowing()
            }
            // 段落级跟读（#232）：--open-shadowing-passage 直接进整段模式，
            // 省掉一次手工点选（本机 UI 自动化对 SwiftUI 不可靠）。
            if CommandLine.arguments.contains("--open-shadowing-passage") {
                await state.openShadowing()
                state.setShadowingMode(.passage)
            }
            // 截图/验证辅助：--open-vocabulary 启动时直接进入词汇本页
            // （--daily-flip / --vocabulary-tail 自带进页，见 VocabularyView 的验证钩子）
            if CommandLine.arguments.contains("--open-vocabulary")
                || CommandLine.arguments.contains("--daily-flip")
                || CommandLine.arguments.contains("--vocabulary-tail") {
                await state.openVocabulary()
            }
            // 截图/验证辅助：--open-dictionary 启动时直接进入词典页（空查询态 → 推荐词一排）
            if CommandLine.arguments.contains("--open-dictionary") {
                await state.openDictionary()
            }
            // 截图/验证辅助：--dictionary-word "nominal" 进词典页并直接查这个词。
            // （观察固定搭配 / 例句的排版与划词气泡；本机 UI 自动化对 SwiftUI 不可靠。）
            if let index = CommandLine.arguments.firstIndex(of: "--dictionary-word"),
               index + 1 < CommandLine.arguments.count {
                await state.openDictionary()
                await state.lookUpDictionaryWord(CommandLine.arguments[index + 1], pushing: false)
            }
            // 截图/验证辅助：--define-vocabulary 进词汇本 + 给第一个每日推荐词查释义、
            // 给最新一条词条重新释义，并朗读「单词 + 例句」。
            // 一次跑完「提示词 → 解析 → 卡片排版 → 朗读」整条链路，
            // 不需要模拟点击（本机 UI 自动化对 SwiftUI 不可靠）。
            if CommandLine.arguments.contains("--define-vocabulary") {
                await state.openVocabulary()
                await state.loadDailyWordsIfNeeded()
                if let first = state.dailyWords.first {
                    await state.toggleDailyDefinition(word: first.word)
                    let example = state.dailyDefinitions[first.word]?.example ?? ""
                    let spoken = example.isEmpty ? first.word : "\(first.word). \(example)"
                    Task { await state.speak(spoken) }
                }
                if let newest = state.vocabularyEntries.first {
                    await state.redefineVocabulary(id: newest.id)
                }
            }
            // 截图/验证辅助：--shadowing-sample "识别文本" 用**同一条评测链路**预览反馈界面
            // （本机无法合成点击、也无法自动对麦克风说话；它不录音、不落库，
            //   发音卡用合成的演示波形驱动 —— 真实录音时走的是同一段纯函数）
            if let index = CommandLine.arguments.firstIndex(of: "--shadowing-sample"),
               index + 1 < CommandLine.arguments.count {
                await state.openShadowing()
                await state.previewShadowingResult(CommandLine.arguments[index + 1])
            }
            // 端到端验证辅助：--scenario <id> 启动后直接进入某个情景
            if let index = CommandLine.arguments.firstIndex(of: "--scenario"),
               index + 1 < CommandLine.arguments.count,
               let scenario = state.scenarios.first(where: { $0.id == CommandLine.arguments[index + 1] }) {
                await state.startScenario(scenario)
            }
            // 截图/验证辅助：--expand-scenario <id> 已在 `start()` 之前处理（见上）。
            // 截图/验证辅助：--free-talk 直接开一段随口练（观察学生主导的引导风格，需求 4）
            if CommandLine.arguments.contains("--free-talk") {
                await state.startFreeTalk()
            }
            // 端到端验证辅助：--exam <考卷 id> 启动后直接开一场考试（观察考场条 / 出题）
            if let index = CommandLine.arguments.firstIndex(of: "--exam"),
               index + 1 < CommandLine.arguments.count {
                await state.loadExamBlueprints()
                let wanted = CommandLine.arguments[index + 1]
                if let blueprint = state.examBlueprints.first(where: { $0.id == wanted }) {
                    await state.startExam(blueprint)
                } else {
                    // 没找到就说清楚是哪一套没找到，别静默什么都不发生。
                    state.practiceNotice = AppNotice(
                        text: "没有找到考卷 \(wanted)（可用："
                            + state.examBlueprints.map(\.id).joined(separator: "、") + "）"
                    )
                }
            }
            // 端到端验证辅助：--auto-finish-exam-after <秒> 等 N 秒后自动交卷（观察结算卡）
            if let index = CommandLine.arguments.firstIndex(of: "--auto-finish-exam-after"),
               index + 1 < CommandLine.arguments.count,
               let seconds = Double(CommandLine.arguments[index + 1]) {
                Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    await state.finishExam()
                }
            }
            // 端到端验证辅助：--send "文本" 启动后自动发送一条消息
            if let index = CommandLine.arguments.firstIndex(of: "--send"),
               index + 1 < CommandLine.arguments.count {
                let text = CommandLine.arguments[index + 1]
                Task {
                    // ⚠️ 必须**等老师开口生成结束**再发，不能固定 sleep：
                    // `ChatService.send` 里 `guard !isGenerating else { return }` 会**静默丢弃**
                    // 生成中抢话的消息。原来固定等 1 秒，在本机模型冷加载（几十秒）时必然踩空 ——
                    // 表现为「--send 传了文本，会话里却一句都没有」，很容易被误读成功能坏了。
                    for _ in 0..<90 where state.chat.isGenerating || state.chat.messages.isEmpty {
                        try? await Task.sleep(for: .seconds(1))
                    }
                    state.chat.send(text)
                }
            }
            // 端到端验证辅助：--auto-speak 启动即打开自动朗读（观察分句流水线时序）
            if CommandLine.arguments.contains("--auto-speak") {
                await state.setAutoSpeak(true)
            }
            // 端到端验证辅助：--auto-end-scenario 启动 12 秒后自动结束情景（观察星星结算）
            if CommandLine.arguments.contains("--auto-end-scenario") {
                Task {
                    try? await Task.sleep(for: .seconds(12))
                    await state.endScenario()
                }
            }
            // 端到端验证辅助：--auto-free-talk-after <秒> 等 N 秒后走**顶栏「开启新练习」的同一条路径**
            // （`startFreeTalk` 会先自动复盘上一段并清掉流水）。
            // 用它一箭三雕：观察「自动复盘回执」（需求 5）+「随口练开场白」（需求 4）。
            if let index = CommandLine.arguments.firstIndex(of: "--auto-free-talk-after"),
               index + 1 < CommandLine.arguments.count,
               let seconds = Double(CommandLine.arguments[index + 1]) {
                Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    await state.startFreeTalk()
                }
            }
        }
        .onChange(of: colorScheme) { _, newValue in
            state.systemIsDark = (newValue == .dark)
        }
        // 截图/验证辅助：--translate-last 等老师开口后，自动翻译最后一条消息（验证气泡翻译）
        .task {
            guard CommandLine.arguments.contains("--translate-last") else { return }
            // 等首条消息出现且生成结束（老师主动打招呼需要几秒到几十秒）。
            for _ in 0..<60 where state.chat.messages.isEmpty || state.chat.isGenerating {
                try? await Task.sleep(for: .seconds(2))
            }
            guard !state.chat.messages.isEmpty else { return }
            // 学员与老师各翻一条：一个开关就能同时验两种译文对齐（学员右 / 老师左）。
            if let teacher = state.chat.messages.last(where: { $0.role == .assistant }) {
                await state.translateMessage(teacher.id)
            }
            if let learner = state.chat.messages.last(where: { $0.role == .user }) {
                await state.translateMessage(learner.id)
            }
        }
    }

    // MARK: - 全局浮卡（从 body 抽出来减类型检查负担）

    /// 三张全局浮卡（模型启停结果 / 情景结算 / 课程覆盖度）。
    ///
    /// ⚠️ 别把它们并回 body：body 贴着类型检查预算，这三段修饰链留在里面
    /// 整个表达式就会「unable to type-check in reasonable time」（编译器实测报过错）。
    /// 全局搜索（#414）：半透明遮罩 + 居中卡片。点遮罩关闭。
    private var globalSearchOverlay: some View {
        ZStack {
            theme.scrim
                .contentShape(Rectangle())
                .onTapGesture { state.closeGlobalSearch() }
            GlobalSearchPanel(state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                // ⚠️ 这里是**落点坐标**不是留白（2026-10-01 修）：改「界面密度」不该让
                // 浮层上下挪位，所以保留裸 `.padding`（其余真正的内边距走 `.appPadding`）。
                .padding(.top, 40)
        }
        .escCloses { state.closeGlobalSearch() }
        .transition(.opacity)
    }

    @ViewBuilder
    private var globalToastOverlays: some View {
        // 模型启停结果：顶部最前方，向下弹入 → 数秒后向上收起
        if let toast = state.modelToast {
            ModelToastView(toast: toast) { state.dismissModelToast() }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // 落点坐标，不吃密度档（同上）
                .padding(.top, 18)
                .zIndex(50)
                .transition(.move(edge: .top).combined(with: .opacity))
        }

        // 情景结算提示（星星入账 / 通关）——浮在最上层，数秒后自动消失
        if let reward = state.lastReward {
            RewardToast(reward: reward) { state.dismissReward() }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // 落点坐标，不吃密度档（同上）
                .padding(.top, 78)
                .zIndex(30)
                .transition(.move(edge: .top).combined(with: .opacity))
        }

        // 课程覆盖度判定（这一关的目标句说到了几句）——**另起一张**，
        // 不与奖励条合并：星星说的是参与度，这一张说的是内容覆盖，两者会不一致。
        if let assessment = state.lastAssessment {
            let assessedTitle = state.scenario(for: state.lastAssessedScenarioID)?.titleZh ?? "这一关"
            CurriculumVerdictCard(
                assessment: assessment,
                scenarioTitle: assessedTitle,
                onClose: { state.dismissAssessment() }
            )
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // 落点坐标，不吃密度档（同上）
            .padding(.top, 146)
            .zIndex(29)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - 启动期界面钩子（截图 / 验证用，不影响正常使用）

    /// 处理「纯界面」启动参数：主题、直接打开某个面板、展开某张情景卡。
    ///
    /// ⚠️ 分成独立方法是因为它要被调用**两次**（`start()` 前、后各一次）：
    /// 详见 `.task` 里的注释 —— 一次是为了不被模型开场白挡住，一次是为了盖掉
    /// `start()` 里「继续上次」改过的页面状态。方法本身是幂等的。
    private func applyLaunchViewHooks() async {
        // 整窗光标裁决（幂等）：AppKit 的光标矩形不理会 SwiftUI 浮层遮挡，
        // 划词卡片 / 按钮上的插入符只能靠按命中测试的裁决压掉（#233 四轮）。
        CursorGuard.shared.install()
        // --theme day|night|system 临时切换主题（**不写入配置**）
        if let index = CommandLine.arguments.firstIndex(of: "--theme"),
           index + 1 < CommandLine.arguments.count,
           let mode = ThemeMode(rawValue: CommandLine.arguments[index + 1]) {
            state.themeMode = mode
        }
        // --open-settings 启动时直接打开设置面板
        if CommandLine.arguments.contains("--open-settings") {
            state.showingSettings = true
        }
        // --open-reading 启动时直接打开阅读页（验证辅助：截屏核对光标形状）
        if CommandLine.arguments.contains("--open-reading") {
            await state.openReading()
        }
        // --open-scenarios 启动时直接打开情景选择面板
        // 走 `openScenarios()` 而不是直接置标记：那里顺带加载场景列表，
        // 否则面板会开出一个空清单（而且这条钩子在 `start()` 前后各调一次）。
        if CommandLine.arguments.contains("--open-scenarios") {
            await state.openScenarios()
        }
        // --expand-scenario <id> 打开情景面板并展开那张卡
        // （观察「主线任务 + 教学重点 + 大树联动」，需求 3）
        if let index = CommandLine.arguments.firstIndex(of: "--expand-scenario"),
           index + 1 < CommandLine.arguments.count {
            await state.openScenarios()
            state.expandedScenarioID = CommandLine.arguments[index + 1]
        }
        // --open-blackboard 启动时拉开侧栏并展开老师的今日作业（观察黑板的三个状态与按钮）
        if CommandLine.arguments.contains("--open-blackboard") {
            state.isSidebarExpanded = true
            state.isBlackboardExpanded = true
        }
    }

    // MARK: - 宽度分配

    // 树宽夹取已收进 `AppLayoutMetrics.treeWidth`（与窗口下限同源，#417）。

    // MARK: - 中间：对话 / 学习记录

    @ViewBuilder
    private var chatArea: some View {
        VStack(spacing: 0) {
            persistenceBanner
            // 今日作业不在中间栏：它在左栏老师的黑板上（见 `TeacherCorner`）。
            // 中间栏保持一种版式 —— 卷轴挂在这里会破坏三栏的一致性。
            Group {
            if state.showingShadowing {
                ShadowingView(state: state)
            } else if state.showingWriting {
                WritingView(state: state)
            } else if state.showingReading {
                ReadingView(state: state)
            } else if state.showingListening {
                ListeningView(state: state)
            } else if state.showingDictionary {
                DictionaryView(state: state)
            } else if state.showingVocabulary {
                VocabularyView(state: state)
            } else if state.showingProgress {
                LearningProgressView(state: state)
            } else if state.showingRecords {
                RecordsView(state: state)
            } else {
                ChatView(
                    chat: state.chat,
                    modelName: state.currentModelName,
                    health: state.health,
                    isBooting: state.isBooting,
                    providerLabel: state.activeProviderName,
                    contextLimit: state.contextLimit,
                    reasoningLabel: Self.reasoningDisplay(state.activeReasoningEffort),
                    teacherKind: state.teacherAnimalKind,
                    studentKind: state.studentAnimalKind,
                    studentAccessory: state.studentAccessory,
                    // 批次三氛围：中间栏连胜飞鸟（数据与侧栏火苗同源，判据在 AppState）
                    streakBadge: state.streakBadgeForChat,
                    onOpenStreak: { state.requestOpenAnnualRecap() },
                    voicePhase: state.voicePhase,
                    autoSpeak: state.autoSpeak,
                    onMicStart: { await state.startVoiceInput() },
                    onMicStop: { await state.finishVoiceInput() },
                    onCancelVoiceInput: { Task { await state.cancelVoiceInput() } },
                    voiceError: state.voiceError,
                    onDismissVoiceError: { state.clearVoiceError() },
                    onSpeakTap: { text in Task { await state.speak(text) } },
                    onStopSpeak: { Task { await state.stopSpeaking() } },
                    speechPhase: state.speechPhase,
                    speakingText: state.speakingText,
                    speechRate: state.speechRate,
                    voiceIndicator: state.activeVoiceIndicator,
                    onSpeechRateChange: { rate in Task { await state.setSpeechRate(rate) } },
                    scenario: state.activeScenario,
                    onOpenScenarios: { Task { await state.openScenarios() } },
                    onEndScenario: { Task { await state.endScenario() } },
                    voiceTranscript: state.voiceTranscript,
                    modelStoppedNotice: state.llmStoppedNotice,
                    starterQuestions: state.starterQuestions,
                    onTranslate: { id in await state.translateMessage(id) },
                    translationError: state.translationNotice,
                    onDismissTranslationError: { state.clearTranslationNotice() },
                    wordLookup: state.wordLookupContext,
                    pendingAttachments: state.pendingAttachments,
                    attachmentNotice: state.attachmentNotice,
                    attachmentSaveNotice: state.attachmentSaveNotice,
                    llmSupportsVision: state.llmSupportsVision,
                    isImportingAttachments: state.isImportingAttachments,
                    onAddAttachments: { urls in
                        Task { await state.addAttachments(from: urls) }
                    },
                    onRemoveAttachment: { id in
                        Task { await state.removePendingAttachment(id) }
                    },
                    onDownloadAttachment: { attachment in
                        state.downloadAttachment(attachment)
                    },
                    attachmentLocation: { state.attachmentLocation(for: $0) },
                    onDismissAttachmentNotice: { state.clearAttachmentNotice() },
                    onDismissAttachmentSaveNotice: { state.clearAttachmentSaveNotice() },
                    onClearAttachments: { state.clearPendingAttachments() },
                    practiceMode: state.productPracticeMode,
                    onStartFreeTalk: { await state.startFreeTalk() },
                    briefing: state.briefing,
                    practiceNotice: state.practiceNotice,
                    onDismissPracticeNotice: { state.dismissPracticeNotice() },
                    exam: state.examBarModel,
                    onExamTimeout: { Task { await state.examQuestionTimedOut() } },
                    onExamSkip: { Task { await state.skipExamQuestion() } },
                    onExamFinish: { Task { await state.finishExam() } },
                    onSend: { text in state.sendChat(text) },
                    onDeleteMessage: { id in state.deleteChatMessage(id) },
                    onResendEditedMessage: { id, text in state.resendEditedChatMessage(id, text: text) },
                    onRegenerateReply: { id in state.regenerateChatReply(to: id) },
                    canMutateMessages: state.canMutateChatMessages
                )
            }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(state.theme.surfaceAlt.opacity(0.55))
        // 每轮对话落库之后复查一次「还存得住吗」：库可能开着开着就写不进去了
        // （磁盘满 / 文件被挪走 / 权限变了）。成功也会把横幅撤掉 ——
        // 恢复了就不该继续挂着一条旧警告吓人。
        .task(id: state.chat.messages.count) { await state.refreshPersistenceHealth() }
        // 划词气泡**不再挂在这一层**（2026-09-29 报障：侧栏抬到 zIndex(1) 之后，
        // 挂在中间栏上的气泡被压在侧栏底下，左半截被侧栏底色盖住）。
        // 浮层现在挂在最外层 ZStack 上 —— 那是整个应用的最上方，谁也压不住它。
    }

    /// 学习记录存不住时的**常驻**横幅（中间栏顶部，切到哪一页都看得见）。
    ///
    /// ⚠️ 常驻、不自动消失：库打不开时应用照常能聊，「存不住」没有任何天然症状，
    /// 一条几秒后自己消失的 toast 等于没说 —— 用户会以为只是刚才那一下没存住。
    /// 横幅上带「打开设置」：那里有数据目录与备份入口，是能动手的地方。
    @ViewBuilder
    private var persistenceBanner: some View {
        if let notice = state.persistenceNotice {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .appFont(12)
                    .foregroundStyle(theme.warning)
                Text(notice.text)
                    .appFont(12)
                    .foregroundStyle(theme.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let action = notice.action {
                    Button(action.title) { action.run() }
                        .buttonStyle(.appPressable)
                        .appFont(12)
                        .foregroundStyle(theme.accent)
                }
            }
            .appPadding(.horizontal, 14)
            .appPadding(.vertical, 8)
            .background(theme.surface)
            .overlay(alignment: .leading) {
                Rectangle().fill(theme.warning).frame(width: 3)
            }
            .overlay(alignment: .bottom) {
                Divider().overlay(theme.divider)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("学习记录保存异常。\(notice.text)")
        }
    }

    // MARK: - 可拖动分割线（聊天 / 成长之树之间）

    private var resizeHandle: some View {
        ZStack {
            Rectangle()
                .fill(theme.divider)
                .frame(width: 1)

            Capsule()
                .fill(theme.divider.opacity(0.9))
                .frame(width: 5, height: 44)
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle().inset(by: -2))
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if treeDragStart == nil { treeDragStart = treePanelWidth }
                    // 拖动越靠左（translation < 0），树越宽。
                    treePanelWidth = (treeDragStart ?? treePanelWidth) - value.translation.width
                }
                .onEnded { _ in
                    treeDragStart = nil
                }
        )
        .onHover { hovering in
            // ⚠️ 分裂条的左右箭头是**显式接管**：不暂停策略的话，
            // 整窗光标裁决（`CursorGuard`）会在下一次鼠标移动时把它盖成箭头。
            if hovering {
                CursorPolicy.suspend()
                NSCursor.resizeLeftRight.push()
            } else {
                CursorPolicy.resume()
                NSCursor.pop()
            }
        }
        .help("拖动调整对话与成长之树的宽度")
    }

    // MARK: - 右侧：成长之树

    private var levelPanel: some View {
        VStack(spacing: 0) {
            levelHeader
                .frame(height: 64)
            Divider().overlay(state.theme.divider)
            // 树可上下滚动；林间地面带固定吸附在底部（小动物始终可见、可点击说话）
            ZStack(alignment: .bottom) {
                TreeScrollView(
                    theme: state.theme,
                    progress: state.progress,
                    studentAnimal: state.studentAnimalKind,
                    // 批次五 · D：小伙伴陪着学员一起爬树（没选过就自动配一只）
                    companionAnimal: state.companionAnimalKind,
                    levelNotes: state.treeLevelNotes,
                    // #418-B：树根年轮徽记（年度数据到场后后台补上）
                    annualSummary: state.annualTreeSummary,
                    // 森林回应：攒星弹果实、通关全套仪式、练完/收词飘叶
                    ceremonyTick: state.forest.ceremonyTick,
                    practiceTick: state.forest.practiceTick,
                    wordTick: state.forest.wordTick,
                    // 批次六 · E：点天空飘叶（连点计数在 ForestStage）
                    skyTapTick: state.forest.skyTapTick,
                    // 批次八 · H：首次进入欢迎，树冠也挥挥手
                    welcomeTick: state.forest.welcomeTick,
                    onSkyTap: { state.forest.registerSkyTap() },
                    // 批次六 · F：点学员 / 小伙伴一声叫（叫声随物种走，2026-09-29 拆分）
                    onLearnerTap: { kind in state.sound.animalVoice(kind) }
                ) { level in
                    Task { await open(level) }
                }
                // #418-B：年轮徽记要吃的年度汇总**不在启动关键路径上**（开屏只查窗口），
                // 树面板到场后在这里补拉一次 —— 幂等（加载过/在途都直接返回），不重复查询。
                .task { await state.ensureAnnualRecapLoaded() }

                ForestGroundBand(
                    theme: state.theme,
                    bubblesAllowed: state.animalBubblesEnabled,
                    activityAllowed: state.animalActivityEffective,
                    activityFrequency: state.animalActivityFrequency,
                    onActivityToggle: {
                        Task { await state.setAnimalActivity(!state.animalActivityEnabled) }
                    },
                    // 今日任务全部完成 → 林子里的小动物一起跳一下（一天只触发一次）。
                    celebrationTick: state.celebrationTick,
                    // 小剧场：收词叼回来、纠错歪头安慰。
                    wordTick: state.forest.wordTick,
                    wordPayload: state.forest.lastCollectedWord,
                    comfortTick: state.forest.comfortTick,
                    // 批次四 · A：分模块回应 / 簇拥安慰 / 对话陪伴 / 安静打盹。
                    huddleComfortTick: state.forest.huddleComfortTick,
                    moduleTick: state.forest.moduleTick,
                    lastModule: state.forest.lastModule,
                    abandonTick: state.forest.abandonTick,
                    lastAbandonedModule: state.forest.lastAbandonedModule,
                    learnerTurnTick: state.forest.learnerTurnTick,
                    teacherTurnTick: state.forest.teacherTurnTick,
                    lastActivityAt: state.forest.lastActivityAt,
                    previewSleepBubble: CommandLine.arguments.contains("--sleep-bubble"),
                    // 批次六 · F：点小动物一声叫（气泡照旧；叫声随物种走，2026-09-29 拆分）
                    onResidentTap: { kind in state.sound.animalVoice(kind) },
                    // 批次八 · H：首次进入欢迎演出 / 错误举牌（老师联系不上时）
                    welcomeTick: state.forest.welcomeTick,
                    errorSignTick: state.forest.errorSignTick,
                    errorHeadline: state.forest.lastErrorHeadline,
                    // 对话种下的植物：学员每开口一次，大树下草坪上多一株（2026-09-29 搬进林子）
                    conversationRounds: state.chat.learnerTurnCount,
                    // #418-C：连续剧情出幕（判定与记账在 ForestStage，草坪只管挑角演）
                    storyActTick: state.forest.storyActTick,
                    lastStoryAct: state.forest.lastStoryAct
                )
                .frame(height: TreeViewport.groundBandHeight)
                .allowsHitTesting(true)
            }
            // 通关烟花 + 今日任务全部完成的烟花：盖在整块树面板上（不裁切、不吃点击），放完自动收。
            // ⚠️ 2026-09-29 用户报障「森林也没有任务完成的烟花」：庆祝此前只落在黑板与地面带，
            // 林子自己毫无表示 —— 补一层由 `state.celebrationTick` 驱动的烟花（与通关各管各的 tick）。
            .overlay {
                ZStack {
                    CeremonyFireworksLayer(theme: state.theme, tick: state.forest.ceremonyTick)
                    CeremonyFireworksLayer(theme: state.theme, tick: state.celebrationTick)
                }
            }
        }
        .background(state.theme.surface.opacity(0.62))
    }

    private var levelHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "tree.fill")
                    .foregroundStyle(state.theme.accent)
                    .appFont(14)
                Text("成长之树")
                    .appFont(15, weight: .bold, design: .rounded)
                    .foregroundStyle(state.theme.primaryText)
                Spacer()
                if state.isBooting {
                    ProgressView().controlSize(.mini)
                }
                Text("已爬升 \(Int(state.progress.climbFraction * 100))%")
                    .appFont(11, design: .rounded)
                    .foregroundStyle(state.theme.secondaryText)
            }

            HStack(spacing: 6) {
                Image(systemName: "star.fill")
                    .foregroundStyle(state.theme.accent)
                    .appFont(11)
                Text("\(state.progress.totalStars) 颗星星")
                    .appFont(11, weight: .semibold, design: .rounded)
                    .foregroundStyle(state.theme.primaryText)
                Spacer()
                Text("\(state.progress.levels.filter { $0.state == .completed }.count)/\(state.progress.levels.count) 关")
                    .appFont(11, design: .rounded)
                    .foregroundStyle(state.theme.secondaryText)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity)
    }

    // MARK: - 考后结算卡（考试模式）

    private func examReportOverlay(_ report: ExamReport) -> some View {
        ZStack {
            state.theme.scrim
                .contentShape(Rectangle())
                // 点遮罩**不关**：这场考试的报告只有「再来一次」与「完成」两个出口。
                // 一场考完的分数结构随手点掉就再也拿不回来了（报告不落库，见 #206 说明）。
                .onTapGesture { }

            GeometryReader { geo in
                ExamReportCard(
                    report: report,
                    sampleAnswers: state.examSampleAnswers,
                    sampleTargets: state.examSampleTargets,
                    sampleNotice: state.examSampleNotice,
                    isGeneratingSamples: state.isGeneratingExamSamples,
                    onRetrySamples: { state.retryExamSampleAnswers() },
                    onSpeak: { text in Task { await state.speak(text) } },
                    onRetake: { Task { await state.retakeExam() } },
                    onClose: { state.dismissExamReport() }
                )
                // ⚠️ 高度按可用高夹取（#417 起最小窗高 640 < 设计高 660）：
                // 不夹的话最矮窗口下卡顶/卡底被切，而出口只有底部那两个按钮。
                .frame(width: 560, height: AppLayoutMetrics.examReportHeight(available: geo.size.height))
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(state.theme.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(state.theme.divider, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .appElevation(.sheet)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .center)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .zIndex(28)
    }

    // MARK: - 设置浮层（全局响应日夜，可关闭）

    private var settingsOverlay: some View {
        ZStack {
            state.theme.scrim
                .contentShape(Rectangle())
                .onTapGesture { state.showingSettings = false }

            SettingsView(state: state)
                .frame(width: 720)
                .frame(maxHeight: 780)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(state.theme.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(state.theme.divider, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .appElevation(.sheet)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .center)))
        }
        .zIndex(20)
    }

    // MARK: - 情景选择浮层（数据驱动，随日夜主题）

    private var scenariosOverlay: some View {
        ZStack {
            state.theme.scrim
                .contentShape(Rectangle())
                .onTapGesture { state.closeScenarios() }

            ScenarioPickerView(state: state) { state.closeScenarios() }
                .frame(width: 720)
                .frame(maxHeight: 720)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(state.theme.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(state.theme.divider, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .appElevation(.sheet)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .center)))
        }
        .escCloses { state.closeScenarios() }
        .zIndex(18)
    }

    // MARK: - 入学定级浮层（进阶 ⑤）

    /// 摸底浮层：点遮罩**不关**。
    ///
    /// 与上传材料不同，答题中途随手点一下遮罩就把这一轮丢掉太亏了（做到第 9 题了）；
    /// 出口只有右上角那个 × 与结果页的按钮 —— 关掉也不会丢进度（`closePlacement` 只关浮层）。
    private var placementOverlay: some View {
        ZStack {
            state.theme.scrim
                .contentShape(Rectangle())

            PlacementSheet(state: state) { state.closePlacement() }
                .frame(width: 520)
                .frame(maxHeight: 600)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(state.theme.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(state.theme.divider, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .appElevation(.sheet)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .center)))
        }
        .zIndex(20)
    }

    // MARK: - 描述场景浮层（⑦，与上传材料同层）

    private var scenarioComposerOverlay: some View {
        ZStack {
            state.theme.scrim
                .contentShape(Rectangle())
                .onTapGesture { state.closeScenarioComposer() }

            ScenarioComposerSheet(state: state) { state.closeScenarioComposer() }
                .frame(width: 560)
                .frame(maxHeight: 560)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(state.theme.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(state.theme.divider, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .appElevation(.sheet)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .center)))
        }
        .escCloses { state.closeScenarioComposer() }
        .zIndex(20)
    }

    // MARK: - 上传材料浮层（#208，比情景面板高一层）
    private var materialUploadOverlay: some View {
        ZStack {
            state.theme.scrim
                .contentShape(Rectangle())
                .onTapGesture { state.closeMaterialUpload() }

            MaterialUploadSheet(state: state) { state.closeMaterialUpload() }
                .frame(width: 560)
                .frame(maxHeight: 640)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(state.theme.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(state.theme.divider, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .appElevation(.sheet)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .center)))
        }
        .escCloses { state.closeMaterialUpload() }
        .zIndex(20)
    }

    // MARK: -

    /// 推理强度展示文案（low/medium/high → 低/中/高）。
    ///
    /// `nonisolated`：纯查表函数，不碰任何隔离状态；隔离它只会让非隔离上下文
    /// （单测）调用时被判越界。
    public nonisolated static func reasoningDisplay(_ effort: String?) -> String? {
        switch effort {
        case "low": "低"
        case "medium": "中"
        case "high": "高"
        default: nil
        }
    }

    private func open(_ level: TreeLevel) async {
        guard level.state != .locked else { return }
        // 绑定情景的关卡：点它就直接进入该情景（老师按角色开场，结算也记在这一关）
        if let scenario = state.scenario(for: level.scenarioID) {
            await state.startScenario(scenario)
            return
        }
        // ⚠️ 走 `sendChat` 而不是 `chat.send`：前者会置「学员开口了」的标志。
        // 少了它，开屏流程可能在这句话落库之后才决定换段，把一段对话劈成两段。
        state.sendChat("Let's practice: \(level.title)")
    }
}
