import AIDomain
import AIServices
import AIInfrastructure
@testable import AppUI
import XCTest

/// 快捷键系统（#279 / #280）的回归。
///
/// 分两层：上面一批打**纯逻辑**（绑定怎么显示、撞没撞车、按下该跑谁），
/// 下面一批打 `AppState` 的存 / 改 / 跑。
///
/// 三条最容易坏、也最难自查的事，这里各钉一条：
/// 1. 出厂键撞车 → 一个动作「配着键却按不动」；
/// 2. 打字时无修饰键被抢 → 用户在聊天框里打不出字母（这是最招骂的一类）；
/// 3. 新增动作没接 `perform` → 设置页有这一行、按下去没反应。
@MainActor
final class ShortcutTests: XCTestCase {

    /// 一份临时目录里的 AppState：绝不碰真实配置与真实数据库。
    private func makeState() -> AppState {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcut-probe-\(UUID().uuidString)", isDirectory: true)
        let dictionaryBase = directory.appendingPathComponent("dict", isDirectory: true)
        let state = AppState(services: CoachServices(
            config: ConfigStore(fileURL: directory.appendingPathComponent("config.json")),
            databasePath: ":memory:",
            dictionaryStore: DictionaryBookStore(
                fileURL: dictionaryBase.appendingPathComponent("dictionaries.json"),
                booksDirectory: dictionaryBase.appendingPathComponent("books", isDirectory: true)
            )
        ))
        // ⚠️ 绑定表存在 `UserDefaults.standard` 上，而它是**进程内共享**的：
        // 一个用例改过的键会被下一个用例的 AppState 读出来（实测因此误判过两次）。
        // 每个用例都从出厂键起步，用例之间才互不牵连。
        state.resetAllShortcutBindings()
        return state
    }

    // MARK: - 绑定本身

    /// 出厂键不许撞车：撞了就是「两个动作绑同一个键，只有一个会响」。
    func testFactoryBindingsNeverCollide() {
        let conflicts = ShortcutConflict.detect(ShortcutBindingArchive.defaults())
        XCTAssertTrue(conflicts.isEmpty, "出厂键撞车了：\(conflicts)")
    }

    /// 跳转键的编号 = 侧栏位置（加一页时编号自己跟着走，不靠手写常量）。
    func testNavigationDefaultsFollowSidebarOrder() {
        for action in ShortcutAction.allCases where action.group == .navigation {
            guard let section = action.section else {
                return XCTFail("跳转动作 \(action.rawValue) 没有对应页面")
            }
            XCTAssertEqual(
                action.defaultBinding,
                ShortcutBinding(key: "\(section.shortcutDigit)", command: true)
            )
        }
    }

    /// 键面顺序固定为 ⌃⌥⇧⌘（照系统菜单的样子读），乱序会让人按错。
    func testDisplayStringUsesAppleModifierOrder() {
        let binding = ShortcutBinding(key: "r", command: true, shift: true, option: true, control: true)
        XCTAssertEqual(binding.displayString, "⌃⌥⇧⌘R")
    }

    /// 特殊键写中文名（"space" 给个 "SPACE" 没人认得）。
    func testSpecialKeysUseReadableNames() {
        XCTAssertEqual(ShortcutBinding(key: "space").displayString, "空格")
        XCTAssertEqual(ShortcutBinding(key: "return").displayString, "回车")
    }

    /// 大小写不敏感：`⇧R` 与 `r` 都压成小写，修饰键另记。
    func testKeyIsNormalizedToLowercase() {
        XCTAssertEqual(ShortcutBinding(key: "R").key, "r")
        XCTAssertEqual(ShortcutEventKey(key: "R").key, "r")
    }

    // MARK: - 落盘

    /// 编解码往返：改过的键要能原样回来。
    func testArchiveRoundTrip() {
        var bindings = ShortcutBindingArchive.defaults()
        bindings[.openPractice] = ShortcutBinding(key: "p", command: true, shift: true)
        guard let data = ShortcutBindingArchive.encode(bindings) else {
            return XCTFail("编码失败")
        }
        XCTAssertEqual(ShortcutBindingArchive.decode(data), bindings)
    }

    /// 老配置里没有新动作 → 用出厂键补齐。
    ///
    /// 不补的话，那个新动作就是「设置页有这一行、按下去毫无反应」的死键。
    func testArchiveFillsMissingActionsWithDefaults() {
        let partial = ["reviewSpeak": ShortcutBinding(key: "s")]
        guard let data = try? JSONEncoder().encode(partial) else {
            return XCTFail("编码失败")
        }
        let decoded = ShortcutBindingArchive.decode(data)
        XCTAssertEqual(decoded[.reviewSpeak], ShortcutBinding(key: "s"))
        XCTAssertEqual(decoded[.reviewReveal], ShortcutAction.reviewReveal.defaultBinding)
        XCTAssertEqual(decoded.count, ShortcutAction.allCases.count)
    }

    // MARK: - 分发判据

    /// **最关键的一条**：光标在输入框里时，无修饰键必须放行 —— 否则打字打不出字母。
    func testPlainKeyIsIgnoredWhileTyping() {
        let bindings = ShortcutBindingArchive.defaults()
        let typing = ShortcutResolver.Context(isTextInputFocused: true, isReviewActive: true)
        XCTAssertNil(ShortcutResolver.action(
            for: ShortcutEventKey(key: "r"),
            bindings: bindings,
            context: typing
        ))
        XCTAssertNil(ShortcutResolver.action(
            for: ShortcutEventKey(key: "1"),
            bindings: bindings,
            context: typing
        ))
    }

    /// 但带修饰键的组合在打字时**照常生效**（⌘1 从来不是在打 "1"）。
    func testModifiedKeyStillWorksWhileTyping() {
        let bindings = ShortcutBindingArchive.defaults()
        let typing = ShortcutResolver.Context(isTextInputFocused: true)
        XCTAssertEqual(
            ShortcutResolver.action(
                for: ShortcutEventKey(key: "1", command: true),
                bindings: bindings,
                context: typing
            ),
            .openPractice
        )
    }

    /// 没在复习时，复习键不许响（否则按空格会莫名其妙翻面）。
    func testReviewKeysNeedAnActiveSession() {
        let bindings = ShortcutBindingArchive.defaults()
        let idle = ShortcutResolver.Context(isReviewActive: false)
        XCTAssertNil(ShortcutResolver.action(
            for: ShortcutEventKey(key: "space"), bindings: bindings, context: idle
        ))
        let reviewing = ShortcutResolver.Context(isReviewActive: true)
        XCTAssertEqual(
            ShortcutResolver.action(
                for: ShortcutEventKey(key: "space"), bindings: bindings, context: reviewing
            ),
            .reviewReveal
        )
    }

    /// 录制期间一切按键都不分发（都归录制器）。
    func testEverythingIsSilentWhileCapturing() {
        let bindings = ShortcutBindingArchive.defaults()
        let capturing = ShortcutResolver.Context(isReviewActive: true, isCapturing: true)
        XCTAssertNil(ShortcutResolver.action(
            for: ShortcutEventKey(key: "space"), bindings: bindings, context: capturing
        ))
    }

    /// 有整块浮层盖着时不分发：底下那一页看不见，切页只会让人莫名其妙。
    func testEverythingIsSilentUnderOverlay() {
        let bindings = ShortcutBindingArchive.defaults()
        let covered = ShortcutResolver.Context(isOverlayPresented: true)
        XCTAssertNil(ShortcutResolver.action(
            for: ShortcutEventKey(key: "1", command: true), bindings: bindings, context: covered
        ))
    }

    /// 命中顺序是确定的（按 `allCases`），撞键时永远是同一个赢。
    func testCollisionResolvesToTheSameWinner() {
        var bindings = ShortcutBindingArchive.defaults()
        bindings[.openShadowing] = bindings[.openPractice] ?? ShortcutAction.openPractice.defaultBinding
        XCTAssertEqual(ShortcutConflict.detect(bindings).count, 1)
        let first = ShortcutResolver.action(
            for: ShortcutEventKey(key: "1", command: true), bindings: bindings, context: .init()
        )
        let second = ShortcutResolver.action(
            for: ShortcutEventKey(key: "1", command: true), bindings: bindings, context: .init()
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, .openPractice)
    }

    // MARK: - 提示读的是当前绑定

    /// 卡上那行提示跟着改过的键走（改了键还显示旧的 = 界面在撒谎）。
    func testHintsFollowCustomizedBinding() {
        var bindings = ShortcutBindingArchive.defaults()
        bindings[.reviewRemembered] = ShortcutBinding(key: "j")
        let hints = ReviewShortcutHints(bindings: bindings)
        XCTAssertEqual(hints.remembered, "J")
        XCTAssertEqual(hints.reveal, "空格")
    }

    // MARK: - AppState：改键

    /// 撞键当场拒绝，并说清被谁占了。
    func testSetBindingRejectsCollision() {
        let state = makeState()
        let result = state.setShortcutBinding(
            ShortcutBinding(key: "1", command: true),
            for: .openShadowing
        )
        guard case .rejectedBy(let owner) = result else {
            return XCTFail("撞键应当被拒绝")
        }
        XCTAssertEqual(owner, .openPractice)
        XCTAssertNotNil(state.shortcutNotice, "拒绝时要说清被谁占了")
        // 被拒绝的动作保持原样。
        XCTAssertEqual(state.shortcutBinding(for: .openShadowing), ShortcutAction.openShadowing.defaultBinding)
    }

    /// 不撞就改得动。
    func testSetBindingAppliesWhenFree() {
        let state = makeState()
        let target = ShortcutBinding(key: "p", command: true, shift: true)
        XCTAssertEqual(state.setShortcutBinding(target, for: .openPractice), .applied)
        XCTAssertEqual(state.shortcutBinding(for: .openPractice), target)
        XCTAssertNil(state.shortcutNotice)
    }

    /// 全部恢复出厂。
    func testResetAllRestoresFactory() {
        let state = makeState()
        state.shortcutBindings[.openPractice] = ShortcutBinding(key: "p", command: true, shift: true)
        state.resetAllShortcutBindings()
        XCTAssertEqual(state.shortcutBinding(for: .openPractice), ShortcutAction.openPractice.defaultBinding)
    }

    // MARK: - AppState：录制

    /// 录制 → 按下 → 落进去；录完立刻不再处于录制态。
    func testCaptureAppliesPressedKey() {
        let state = makeState()
        state.beginShortcutCapture(for: .reviewSpeak)
        XCTAssertTrue(state.isCapturingShortcut)

        let consumed = state.handleShortcutEvent(ShortcutEventKey(key: "s"))

        XCTAssertTrue(consumed, "录制期间的按键必须被吃掉，否则会被当成普通快捷键跑掉")
        XCTAssertFalse(state.isCapturingShortcut)
        XCTAssertEqual(state.shortcutBinding(for: .reviewSpeak), ShortcutBinding(key: "s"))
    }

    /// Esc 取消录制，不改任何键。
    func testEscapeCancelsCapture() {
        let state = makeState()
        state.beginShortcutCapture(for: .reviewSpeak)
        XCTAssertTrue(state.handleShortcutEvent(ShortcutEventKey(key: "escape")))
        XCTAssertFalse(state.isCapturingShortcut)
        XCTAssertEqual(state.shortcutBinding(for: .reviewSpeak), ShortcutAction.reviewSpeak.defaultBinding)
    }

    // MARK: - AppState：跑动作

    /// 复习「翻面」是接上的（防「加了动作没接行为」）。
    func testPerformRevealIsWired() async {
        let state = makeState()
        await state.perform(shortcut: .reviewReveal)
        XCTAssertTrue(state.vocabularyReviewRevealed)
    }

    /// 每一页都要有对应的跳转动作，且那个动作指向的就是这一页。
    func testEverySectionHasItsNavigationAction() {
        for section in AppSection.allCases {
            guard let action = ShortcutAction.navigationAction(for: section) else {
                return XCTFail("\(section.title) 没有对应的跳转动作")
            }
            XCTAssertEqual(action.section, section)
            XCTAssertEqual(action.group, .navigation)
        }
    }

    /// 跳转动作真的切了页。
    ///
    /// 只打一个页面就够：`perform` 的 switch 对 13 个动作**全部**列了分支（没有 default），
    /// 漏一个就是编译错误 —— 编译器已经替我们把「某个动作没接行为」钉死了，
    /// 这里只需证明分支里的动作是对的。（逐个页面都跑一遍要 17 秒，都在等各页自己那份加载。）
    func testPerformNavigationSwitchesPage() async {
        let state = makeState()
        await state.perform(shortcut: .openRecords)
        XCTAssertEqual(state.activeSection, .records)
    }

    /// 没接上的键不吞事件（放行给系统，否则输入框里那个键就废了）。
    func testUnboundKeyPassesThrough() {
        let state = makeState()
        let consumed = state.handleShortcutEvent(ShortcutEventKey(key: "z", command: true, option: true, control: true))
        XCTAssertFalse(consumed)
    }

    // MARK: - #599 覆盖盘点（补进去的动作，与「以后别再漏」的闸）

    /// 每个动作都要在 `perform` 里被覆盖到，而且**不许有 `default` 兜底**。
    ///
    /// 现在「漏接行为」是编译器替我们钉着的：`perform` 的 switch 穷举 `ShortcutAction`，
    /// 少一个 case 就编译不过。真正会坏的是**后人为省事加一句 `default: break`** ——
    /// 从那一刻起，「设置页里有这一行、按下去没反应」又变回静默的了。
    ///
    /// 反证：在 `perform` 里加 `default: break` → 本条红在「不许用 default 兜底」。
    func testEveryActionIsCoveredAndNoDefaultFallback() throws {
        let src = try source("AppUI/AppState+Shortcuts.swift")
        let body = self.body(
            of: "public func perform(shortcut action: ShortcutAction) async {", in: src
        )
        XCTAssertFalse(body.isEmpty, "找不到 perform(shortcut:)")
        XCTAssertFalse(
            body.contains("default:"),
            "perform 不许用 default 兜底：那会让漏接的动作变成「配了键、按下去没反应」"
        )
        for action in ShortcutAction.allCases {
            XCTAssertTrue(
                body.contains(".\(action.rawValue)"),
                "「\(action.title)」在 perform 里没有出现 —— 那就是个死键"
            )
        }
    }

    /// 三个全局动作真的把各自的面板开出来。
    ///
    /// #599 之前：搜索只有侧栏那颗放大镜能开，设置 / 说明的键写死在菜单里
    /// （改不了，也没进绑定表）。
    func testGlobalActionsOpenTheirPanels() async {
        let state = makeState()
        await state.perform(shortcut: .openSearch)
        XCTAssertTrue(state.showingGlobalSearch, "全局搜索要能不靠侧栏那颗按钮开出来")
        await state.perform(shortcut: .openSettings)
        XCTAssertTrue(state.showingSettings)
        await state.perform(shortcut: .openHelp)
        XCTAssertTrue(state.showingHelp)
    }

    /// 全局动作的出厂键都带修饰键：无修饰键那一档是留给复习卡的（且会和打字抢字母）。
    func testGlobalDefaultsAreNotPlainKeys() {
        for action in ShortcutAction.allCases where action.group == .global {
            XCTAssertFalse(
                action.defaultBinding.isPlainKey,
                "「\(action.title)」出厂就用了无修饰键，打字时会被它抢走字母"
            )
        }
    }

    /// 复习卡新补的两个键（跟读录音 / 回放）受「复习进行中」这条上下文管着。
    ///
    /// 反证：把这两个动作的 `group` 改成 `.global` → 没在复习时按 m / p 也会响 → 本条红。
    func testReviewExtrasNeedAnActiveSession() {
        let bindings = ShortcutBindingArchive.defaults()
        let idle = ShortcutResolver.Context(isReviewActive: false)
        XCTAssertNil(ShortcutResolver.action(
            for: ShortcutEventKey(key: "m"), bindings: bindings, context: idle
        ))
        XCTAssertNil(ShortcutResolver.action(
            for: ShortcutEventKey(key: "p"), bindings: bindings, context: idle
        ))
        let reviewing = ShortcutResolver.Context(isReviewActive: true)
        XCTAssertEqual(
            ShortcutResolver.action(
                for: ShortcutEventKey(key: "m"), bindings: bindings, context: reviewing
            ),
            .reviewToggleRecording
        )
        XCTAssertEqual(
            ShortcutResolver.action(
                for: ShortcutEventKey(key: "p"), bindings: bindings, context: reviewing
            ),
            .reviewReplay
        )
    }

    /// 设置页按分组画格子：新加的分组要真有动作，否则画出来是一块空的。
    func testEveryGroupHasAtLeastOneAction() {
        for group in ShortcutGroup.allCases {
            XCTAssertFalse(
                ShortcutCenterCard.actions(in: group).isEmpty,
                "「\(group.title)」分组一个动作都没有，快捷键中心会画出一块空地"
            )
        }
    }

    // MARK: - #617 发送键进注册表

    /// 发送键受「对话页且发得出去」这条上下文管着：不在对话页时按 ⌘↩ 不响。
    ///
    /// 反证：把 `sendMessage` 的 group 移出 `.chat`（或删掉 resolver 里那道上下文闸）
    /// → 在词典页按 ⌘↩ 也会触发 → 本条红。
    func testSendKeyNeedsChatContext() {
        let bindings = ShortcutBindingArchive.defaults()
        let elsewhere = ShortcutResolver.Context(isChatActive: false)
        XCTAssertNil(ShortcutResolver.action(
            for: ShortcutEventKey(key: "return", command: true),
            bindings: bindings,
            context: elsewhere
        ))
        let chatting = ShortcutResolver.Context(isChatActive: true)
        XCTAssertEqual(
            ShortcutResolver.action(
                for: ShortcutEventKey(key: "return", command: true),
                bindings: bindings,
                context: chatting
            ),
            .sendMessage
        )
    }

    /// 发送键带 ⌘：正打着字也要能发（无修饰键那一档会被「打字抢字母」护栏挡下）。
    func testSendKeyWorksWhileTyping() {
        let bindings = ShortcutBindingArchive.defaults()
        let typing = ShortcutResolver.Context(isTextInputFocused: true, isChatActive: true)
        XCTAssertEqual(
            ShortcutResolver.action(
                for: ShortcutEventKey(key: "return", command: true),
                bindings: bindings,
                context: typing
            ),
            .sendMessage
        )
    }

    /// 出厂键就是按钮上那颗写死多年的 ⌘↩（改动会让老用户的手感突变）。
    func testSendDefaultBindingIsCommandReturn() {
        XCTAssertEqual(ShortcutAction.sendMessage.defaultBinding, ShortcutBinding(key: "return", command: true))
        XCTAssertEqual(ShortcutAction.sendMessage.defaultBinding.displayString, "⌘回车")
        XCTAssertEqual(ShortcutAction.sendMessage.group, .chat)
        XCTAssertFalse(ShortcutAction.sendMessage.defaultBinding.isPlainKey)
    }

    /// 按下发送键 → 触发票 +1（ChatView 观察到变化才真发，见哨兵两条）。
    ///
    /// 只钉「票涨了」：真正的发送要读视图的 @State，AppState 这层复现不了 ——
    /// 但那套顺序由渲染层与下面的哨兵各管一段。
    func testPerformSendBumpsTicket() async {
        let state = makeState()
        XCTAssertEqual(state.chatComposerSendTicket, 0)
        await state.perform(shortcut: .sendMessage)
        XCTAssertEqual(state.chatComposerSendTicket, 1, "发送键按下去必须敲一下票，否则 ChatView 不知道")
        await state.perform(shortcut: .sendMessage)
        XCTAssertEqual(state.chatComposerSendTicket, 2, "再按一次要再涨一次（连按两次发两条）")
    }

    /// 哨兵一：ChatView 必须**观察**触发票并调用发送。
    ///
    /// 反证：把 `.onChange(of: sendShortcutTicket)` 从 ChatView 删掉 → 本条红在
    /// 「没人接这张票」—— 表现是快捷键按下去界面毫无反应。
    func testChatViewObservesTheSendTicket() throws {
        let src = try source("AppUI/Views/ChatView.swift")
        let body = self.body(of: "public var body: some View {", in: src)
        XCTAssertTrue(
            body.contains(".onChange(of: sendShortcutTicket)"),
            "ChatView 必须观察发送触发票，否则快捷键敲了票也没人发送"
        )
        XCTAssertTrue(
            body.contains("send()"),
            "观察到触发票变化时要调用 send()（那个方法才读得到输入框 / 轮换 / 附件）"
        )
    }

    /// 哨兵二：发送按钮上**不许再有自己的** `keyboardShortcut`。
    ///
    /// 这是「同键双触发」的防线：按钮那颗留着的话，⌘↩ 会同时走 SwiftUI 的按钮快捷键
    /// 和全局监听，一条消息发两遍。
    func testSendButtonHasNoOwnKeyboardShortcut() throws {
        let src = try source("AppUI/Views/ChatView.swift")
        let button = self.body(of: "private var sendButton: some View {", in: src)
        XCTAssertFalse(button.isEmpty, "找不到 sendButton")
        XCTAssertFalse(
            button.contains("keyboardShortcut"),
            "发送按钮不许自带 keyboardShortcut：全局监听是唯一分发器，两处都接会双触发"
        )
    }

    /// 哨兵三：悬停提示读当前绑定，不写死 ⌘↩（改了键还显示旧的 = 界面在撒谎）。
    func testSendButtonHelpReadsTheBinding() throws {
        let src = try source("AppUI/Views/ChatView.swift")
        let help = self.body(of: "private var sendButtonHelp: String {", in: src)
        XCTAssertTrue(
            help.contains("sendShortcutHint"),
            "发送提示要读当前绑定（sendShortcutHint），不能写死 ⌘↩"
        )
    }

    // MARK: - #619 划词气泡两键（查单词 / 加入复习）

    /// 划词两键受「气泡正开着」这条上下文管着：没收着气泡时按 ⌘D / ⌘R 不响
    /// —— 否则用户在任何一个页面按 ⌘D 都会被莫名跳去词典。
    ///
    /// 反证：删掉 resolver 里 `action.group == .wordLookup` 那道闸
    /// → 任何时候按都会触发 → 本条红。
    func testWordLookupKeysNeedTheBubble() {
        let bindings = ShortcutBindingArchive.defaults()
        let idle = ShortcutResolver.Context(isWordLookupActive: false)
        XCTAssertNil(ShortcutResolver.action(
            for: ShortcutEventKey(key: "d", command: true), bindings: bindings, context: idle
        ))
        XCTAssertNil(ShortcutResolver.action(
            for: ShortcutEventKey(key: "r", command: true), bindings: bindings, context: idle
        ))
        let bubbling = ShortcutResolver.Context(isWordLookupActive: true)
        XCTAssertEqual(
            ShortcutResolver.action(
                for: ShortcutEventKey(key: "d", command: true), bindings: bindings, context: bubbling
            ),
            .wordLookupDictionary
        )
        XCTAssertEqual(
            ShortcutResolver.action(
                for: ShortcutEventKey(key: "r", command: true), bindings: bindings, context: bubbling
            ),
            .wordLookupAddReview
        )
    }

    /// 拖选单词后第一响应者是文本视图（⌘A 才会被当 Select All 的那张纸）：
    /// 划词两键**带 ⌘**，所以「打字抢字母」护栏挡不到它们 —— 无修饰键在这一刻
    /// 恰好被护栏挡掉，气泡最常见的使用场景就会不灵（选键时的取舍，见注册表注释）。
    func testWordLookupKeysWorkWhileTextIsSelected() {
        let bindings = ShortcutBindingArchive.defaults()
        let selecting = ShortcutResolver.Context(isTextInputFocused: true, isWordLookupActive: true)
        XCTAssertEqual(
            ShortcutResolver.action(
                for: ShortcutEventKey(key: "d", command: true), bindings: bindings, context: selecting
            ),
            .wordLookupDictionary
        )
        XCTAssertEqual(
            ShortcutResolver.action(
                for: ShortcutEventKey(key: "r", command: true), bindings: bindings, context: selecting
            ),
            .wordLookupAddReview
        )
    }

    /// 出厂键逐字：⌘D = 查词典，⌘R = 加入复习。
    func testWordLookupDefaultBindings() {
        XCTAssertEqual(ShortcutAction.wordLookupDictionary.defaultBinding,
                       ShortcutBinding(key: "d", command: true))
        XCTAssertEqual(ShortcutAction.wordLookupDictionary.defaultBinding.displayString, "⌘D")
        XCTAssertEqual(ShortcutAction.wordLookupDictionary.group, .wordLookup)
        XCTAssertFalse(ShortcutAction.wordLookupDictionary.defaultBinding.isPlainKey)
        XCTAssertEqual(ShortcutAction.wordLookupAddReview.defaultBinding,
                       ShortcutBinding(key: "r", command: true))
        XCTAssertEqual(ShortcutAction.wordLookupAddReview.defaultBinding.displayString, "⌘R")
        XCTAssertEqual(ShortcutAction.wordLookupAddReview.group, .wordLookup)
        XCTAssertFalse(ShortcutAction.wordLookupAddReview.defaultBinding.isPlainKey)
    }

    /// 按 ⌘D → 真的跳到词典页并把这个词查出来（不是「配了键没反应」）。
    func testPerformWordLookupDictionaryOpensTheDictionary() async {
        let state = makeState()
        state.wordLookupCard = WordLookupCard(text: "resilient", translation: "有韧性的")
        let before = state.activeSection

        await state.perform(shortcut: .wordLookupDictionary)

        XCTAssertNotEqual(state.activeSection, before, "气泡上按 ⌘D 要真的跳到词典页")
        XCTAssertEqual(state.activeSection, .dictionary)
        XCTAssertEqual(state.dictionaryQuery, "resilient", "跳过去还要把这个词查出来")
    }

    /// 按 ⌘R → 这个词真的进词汇本（走的是服务层，:memory: 库上验）。
    func testPerformWordLookupAddReviewAddsTheWord() async {
        let state = makeState()
        state.wordLookupCard = WordLookupCard(text: "resilient", translation: "有韧性的")

        await state.perform(shortcut: .wordLookupAddReview)

        XCTAssertTrue(
            state.vocabularyEntries.contains { $0.word == "resilient" },
            "气泡上按 ⌘R 要真的把这个词加进词汇本"
        )
    }

    /// 气泡已经收了（按键到执行隔着一个 Task，宽限期可能刚好走完）→ 什么都不做：
    /// 拿一个空词去翻词典，用户只会看到莫名其妙跳到词典页。
    ///
    /// 反证：删掉 perform 里那两个 `guard let word = wordLookupCard?.text` → 本条红。
    func testPerformWordLookupWithoutACardDoesNothing() async {
        let state = makeState()
        state.wordLookupCard = nil
        let before = state.activeSection

        await state.perform(shortcut: .wordLookupDictionary)
        await state.perform(shortcut: .wordLookupAddReview)

        XCTAssertEqual(state.activeSection, before, "没有气泡就不该跳页")
        XCTAssertNil(state.wordLookupCard)
    }

    /// 气泡底部那行提示读的是**当前**绑定：用户在设置里把 ⌘D 改成了 ⌘L，
    /// 气泡上必须跟着写 ⌘L —— 写死的那一行就是在撒谎（同复习卡纪律）。
    ///
    /// 反证：把 `wordLookupContext` 里两个 hint 写成死串 → 改键后仍显示 ⌘D → 本条红。
    func testWordLookupHintsFollowCustomizedBinding() {
        let state = makeState()
        XCTAssertEqual(state.wordLookupContext.openDictionaryHint, "⌘D", "出厂键下提示应为 ⌘D")
        XCTAssertEqual(state.wordLookupContext.addReviewHint, "⌘R")

        _ = state.setShortcutBinding(ShortcutBinding(key: "l", command: true), for: .wordLookupDictionary)
        XCTAssertEqual(state.wordLookupContext.openDictionaryHint, "⌘L", "改过键之后提示必须跟着变")

        _ = state.setShortcutBinding(ShortcutBinding(key: "e", command: true), for: .wordLookupAddReview)
        XCTAssertEqual(state.wordLookupContext.addReviewHint, "⌘E")
    }

    /// 哨兵：气泡上要真的渲染那行提示（不写死键面，读传进来的两个 hint）。
    ///
    /// 反证：删掉 body 里 `shortcutHintRow(...)` 那一处 → 本条红在
    /// 「气泡底部要渲染按键提示行」—— 表现是提示数据备齐了却没人画。
    func testWordLookupBubbleRendersTheHintRow() throws {
        let src = try source("AppUI/Components/WordLookupBubble.swift")
        let bubble = self.body(of: "public var body: some View {", in: src)
        XCTAssertTrue(
            bubble.contains("shortcutHintRow(dictionaryKey: dictionaryHint, reviewKey: addReviewHint)"),
            "气泡底部要渲染按键提示行（两个 hint 都空的老调用点不渲染）"
        )
        let row = self.body(
            of: "private func shortcutHintRow(dictionaryKey: String, reviewKey: String) -> some View {", in: src
        )
        XCTAssertFalse(row.isEmpty, "找不到 shortcutHintRow")
        XCTAssertTrue(row.contains("hintChip(dictionaryKey,"), "提示行要画「键面 + 动作」芯片（词典）")
        XCTAssertTrue(row.contains("hintChip(reviewKey,"), "提示行要画「键面 + 动作」芯片（复习）")
    }

    // MARK: - 工具

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: "Sources/\(relativePath)", encoding: .utf8)
    }

    /// 取出函数体：从 `needle` 起到下一个成员声明为止。
    ///
    /// ⚠️ **整行注释先剔掉**：判据字符串一旦在注释里出现过，哨兵就是假绿。
    /// 与 `VoiceInputWiringTests.codeLines` / `PracticeProgressTests.body` 同一条纪律。
    private func body(of needle: String, in source: String) -> String {
        guard let range = source.range(of: needle) else { return "" }
        let rest = source[range.lowerBound...]
        let tail = rest.dropFirst(needle.count)
        let terminators = ["\n    public func ", "\n    private func ", "\n    func ",
                           "\n    public var ", "\n    private var ", "\n    var ",
                           "\n    // MARK:", "\n}"]
        let ends = terminators.compactMap { tail.range(of: $0)?.lowerBound }
        let raw = ends.min().map { String(rest[..<$0]) } ?? String(rest)
        return raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
