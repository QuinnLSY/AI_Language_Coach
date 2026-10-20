import AIDomain
import Foundation

// MARK: - 快捷键（#279 / #280）
//
// 分工：`AIDomain` 那一侧管「有哪些动作、一个键长什么样、撞没撞车、按下该跑谁」，
// 这里只管三件 AppState 该管的事 —— 存、改、跑。
//
// ⚠️ **改键的两个护栏**（都是用户会当场撞上的坑）：
// 1. 撞键直接拒绝并说清被谁占了：两个动作绑同一个键时，只有 `allCases` 里靠前那个
//    会赢，另一个从界面上看好好配着键却按不动 —— 那等于界面在撒谎。
// 2. 录制期间**一切按键**归录制器（连 ⌘1 也一样）：否则菜单的等价键会先把 ⌘1
//    抢走，用户根本录不进去自己想要的组合。

extension AppState {

    /// 改键的结果（设置页据此决定要不要显示那句提示）。
    public enum ShortcutSetResult: Sendable, Equatable {
        case applied
        /// 这个键已经被别的动作占了 → 没改。
        case rejectedBy(ShortcutAction)
    }

    /// 绑定表的落盘键（UserDefaults：一份几十字节的 [动作: 键]，不值得为此建表）。
    static let shortcutBindingsKey = "app.shortcuts.bindings.v1"

    static func loadShortcutBindings() -> [ShortcutAction: ShortcutBinding] {
        guard let data = UserDefaults.standard.data(forKey: shortcutBindingsKey) else {
            return ShortcutBindingArchive.defaults()
        }
        return ShortcutBindingArchive.decode(data)
    }

    func persistShortcutBindings() {
        guard let data = ShortcutBindingArchive.encode(shortcutBindings) else { return }
        UserDefaults.standard.set(data, forKey: Self.shortcutBindingsKey)
    }

    // MARK: 读

    /// 某个动作当前绑的键（表里没有就用出厂键）。
    public func shortcutBinding(for action: ShortcutAction) -> ShortcutBinding {
        shortcutBindings[action] ?? action.defaultBinding
    }

    /// 某个动作正跟谁撞键（设置页给那一行标红用）。
    public func shortcutConflicts(for action: ShortcutAction) -> [ShortcutAction] {
        ShortcutConflict.conflicts(for: action, in: shortcutBindings)
    }

    /// 复习卡底部那行提示（读的是**当前**绑定，不是写死的「空格 / 1 / 2 / R」）。
    public var reviewShortcutHints: ReviewShortcutHints {
        ReviewShortcutHints(bindings: shortcutBindings)
    }

    public var isCapturingShortcut: Bool { capturingShortcutAction != nil }

    // MARK: 写

    /// 给一个动作换键。撞键就不改（见文件头的护栏 1）。
    @discardableResult
    public func setShortcutBinding(
        _ binding: ShortcutBinding,
        for action: ShortcutAction
    ) -> ShortcutSetResult {
        if let owner = ShortcutAction.allCases.first(where: {
            $0 != action && shortcutBinding(for: $0).collides(with: binding)
        }) {
            shortcutNotice = "\(binding.displayString) 已经被「\(owner.title)」占用了，先改掉那一个。"
            return .rejectedBy(owner)
        }
        shortcutBindings[action] = binding
        shortcutNotice = nil
        persistShortcutBindings()
        return .applied
    }

    /// 单个动作恢复出厂键（出厂键也可能被别人占，所以同样走一次校验）。
    public func resetShortcutBinding(_ action: ShortcutAction) {
        _ = setShortcutBinding(action.defaultBinding, for: action)
    }

    /// 全部恢复出厂。
    public func resetAllShortcutBindings() {
        shortcutBindings = ShortcutBindingArchive.defaults()
        shortcutNotice = nil
        persistShortcutBindings()
    }

    public func beginShortcutCapture(for action: ShortcutAction) {
        capturingShortcutAction = action
        shortcutNotice = nil
    }

    public func cancelShortcutCapture() {
        capturingShortcutAction = nil
    }

    public func dismissShortcutNotice() {
        shortcutNotice = nil
    }

    // MARK: 事件 → 动作

    /// 装上全局监听（应用启动时调一次；测试不进 `start()`，所以不会装）。
    public func installShortcutMonitor() {
        guard shortcutMonitor == nil else { return }
        let monitor = ShortcutMonitor { [weak self] key in
            self?.handleShortcutEvent(key) ?? false
        }
        monitor.install()
        shortcutMonitor = monitor
    }

    /// 一次按键进来：要么被录制器收走，要么翻译成动作跑掉，要么放行（false）。
    func handleShortcutEvent(_ key: ShortcutEventKey) -> Bool {
        if let action = capturingShortcutAction {
            // 录制中：一切按键都归录制器（见文件头的护栏 2）。
            capturingShortcutAction = nil
            if key.key == "escape", key.binding.isPlainKey {
                shortcutNotice = nil
                return true
            }
            _ = setShortcutBinding(key.binding, for: action)
            return true
        }

        let context = ShortcutResolver.Context(
            isTextInputFocused: ShortcutMonitor.isTextInputFocused(),
            isReviewActive: vocabularyReview != nil,
            isCapturing: false,
            isOverlayPresented: isShortcutBlockingOverlayPresented,
            isChatActive: isChatComposerActive
        )
        guard let action = ShortcutResolver.action(
            for: key,
            bindings: shortcutBindings,
            context: context
        ) else { return false }
        Task { await self.perform(shortcut: action) }
        return true
    }

    /// 有整块浮层盖着：底下那一页此刻看不见，快捷键再切页只会让人莫名其妙。
    ///
    /// ⚠️ S4-8：真源只有一个（`AppState.blockingOverlays`），与 `isContentCovered` 共用。
    /// 以前这里和那边各写一份清单，各自漏项（这里漏过描述场景浮层，那边漏过考试报告）。
    /// 与 `coveringPanels` 的唯一区别：**已经在别的页上**不算拦截 —— 切页键本来就是干这个的。
    var isShortcutBlockingOverlayPresented: Bool { blockingOverlays }

    /// 「发送」快捷键的上下文（#617）：对话页 + 没在生成 + 模型没被关。
    ///
    /// 与 ChatView 里 `canSend` 的差别：输入框里有没有字在视图的 `@State` 里，
    /// AppState 不知道、也不该知道 —— 这里只挡「按了也一定发不出去」的两种，
    /// 剩下的交给 `send()` 自己的 guard（空着按发送本来就不做事，与今天一致）。
    var isChatComposerActive: Bool {
        activeSection == .practice && llmStoppedNotice == nil && !chat.isGenerating
    }

    /// 当前该响应 Esc 的那一层（叠放栈顶）；nil = 没有浮层。
    ///
    /// 唯一出口：`escCloses(..., isActive:)` 与设置页的 `escShortcut(isActive:)` 都读它，
    /// 保证同屏多个浮层时**只有栈顶**注册 `.escape` 键等价项（见 `EscDismissLayer`）。
    var escDismissLayer: EscDismissLayer? {
        EscDismissLayer.topmost(
            settings: showingSettings,
            scenarios: showingScenarios,
            materialUpload: showingMaterialUpload,
            scenarioComposer: showingScenarioComposer,
            courseComposer: showingCourseComposer,
            globalSearch: showingGlobalSearch
        )
    }

    /// 真正跑一个动作。
    ///
    /// ⚠️ 加动作时这里必须跟着加分支：`ShortcutAction` 在设置页里会好好列出一个新条目，
    /// 但漏了这一处的话，那条就是「配了键、按下去毫无反应」。
    ///
    /// 是 `async` 而不是自己起一个 `Task`：起 Task 的动作在测试里就是「还没跑完就断言了」，
    /// 行为对不对根本测不出来。
    public func perform(shortcut action: ShortcutAction) async {
        switch action {
        case .reviewReveal:
            revealVocabularyReviewCard()
        case .reviewRemembered:
            await gradeVocabularyReviewCard(remembered: true)
        case .reviewForgotten:
            await gradeVocabularyReviewCard(remembered: false)
        case .reviewSpeak:
            await speakVocabularyReviewWord()
        case .reviewToggleRecording:
            await toggleVocabularyReviewRecording()
        case .reviewReplay:
            await replayVocabularyReviewRecording()
        case .openSearch:
            openGlobalSearch()
        case .openSettings:
            showingSettings = true
        case .openHelp:
            showingHelp = true
        case .sendMessage:
            // 只敲票：真正的发送在 ChatView（要读输入框 / 轮换 / 附件，见属性注释）。
            chatComposerSendTicket += 1
        case .openPractice, .openShadowing, .openWriting, .openReading, .openListening,
             .openDictionary, .openVocabulary, .openScenarios, .openProgress, .openRecords:
            guard let section = action.section else { return }
            await go(to: section)
        }
    }
}
