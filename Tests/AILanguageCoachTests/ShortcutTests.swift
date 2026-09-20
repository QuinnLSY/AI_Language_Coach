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
}
