import AIDomain
import AIInfrastructure
import AIServices
import AppCore
@testable import AppUI
import XCTest

/// 页面枚举（`AppSection`）与「当前在哪一页」的一致性回归。
///
/// 背景：原先「当前页」由 7 个独立布尔量拼出来，每个 `open*()` 各自手写一串复位。
/// 两个必然的毛病都真实发生过：
/// 1. `openScenarios()` 漏清 `showingRecords` → 从「学习记录」点「情景对话」时两个条目同时高亮；
/// 2. 想加「跳转到第 N 页」时没有任何一处能说清「第 3 页是什么」。
/// 这些用例把「顺序 = 侧栏顺序 = 快捷键编号」和「七个标记互斥」钉成契约。
@MainActor
final class AppSectionTests: XCTestCase {

    /// 一份临时目录里的 AppState：绝不碰真实配置与真实数据库。
    private func makeState() -> AppState {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("section-probe-\(UUID().uuidString)", isDirectory: true)
        let dictionaryBase = directory.appendingPathComponent("dict", isDirectory: true)
        return AppState(services: CoachServices(
            config: ConfigStore(fileURL: directory.appendingPathComponent("config.json")),
            databasePath: ":memory:",
            dictionaryStore: DictionaryBookStore(
                fileURL: dictionaryBase.appendingPathComponent("dictionaries.json"),
                booksDirectory: dictionaryBase.appendingPathComponent("books", isDirectory: true)
            )
        ))
    }

    // MARK: - 枚举本身

    /// 侧栏从上到下的顺序就是 `allCases` 的顺序 —— 这是「快捷键编号 = 位置」的前提。
    func testSidebarOrderIsStable() {
        XCTAssertEqual(
            AppSection.allCases.map(\.rawValue),
            ["practice", "shadowing", "writing", "reading", "dictionary", "vocabulary", "scenarios", "progress", "records"]
        )
    }

    /// 快捷键编号从 1 连号，中间不断档（断档会让 ⌘N 静默失效，肉眼看不出来）。
    func testShortcutDigitsAreSequentialFromOne() {
        XCTAssertEqual(AppSection.allCases.map(\.shortcutDigit), Array(1...AppSection.allCases.count))
    }

    /// 标题与图标都要有，且不重复 —— 重名会让菜单里出现两个一样的条目。
    func testTitlesAndIconsArePresentAndUnique() {
        let titles = AppSection.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count)
        for section in AppSection.allCases {
            XCTAssertFalse(section.title.isEmpty)
            XCTAssertFalse(section.systemImage.isEmpty)
        }
        let icons = AppSection.allCases.map(\.systemImage)
        XCTAssertEqual(Set(icons).count, icons.count)
    }

    // MARK: - activeSection（唯一取数点）

    /// 一个标记都没开时就是练习页 —— 练习是**兜底**而不是「某几个标记都关了」推出来的。
    func testActiveSectionFallsBackToPractice() {
        XCTAssertEqual(makeState().activeSection, .practice)
    }

    /// 每个页面标记各自对应的页面要认对。这条同时钉住「侧栏高亮读的是同一处」。
    func testEachFlagMapsToItsOwnSection() {
        let state = makeState()

        state.showingShadowing = true
        XCTAssertEqual(state.activeSection, .shadowing)
        state.showingShadowing = false

        state.showingDictionary = true
        XCTAssertEqual(state.activeSection, .dictionary)
        state.showingDictionary = false

        state.showingVocabulary = true
        XCTAssertEqual(state.activeSection, .vocabulary)
        state.showingVocabulary = false

        state.showingScenarios = true
        XCTAssertEqual(state.activeSection, .scenarios)
        state.showingScenarios = false

        state.showingProgress = true
        XCTAssertEqual(state.activeSection, .progress)
        state.showingProgress = false

        state.showingRecords = true
        XCTAssertEqual(state.activeSection, .records)
        state.showingRecords = false

        XCTAssertEqual(state.activeSection, .practice)
    }

    // MARK: - 切换的互斥性（原 bug 的回归）

    /// 回归：从「学习记录」点「情景对话」，记录标记必须一起清掉。
    /// 修复前 `openScenarios()` 只清了 `showingDictionary`，于是两个条目同时高亮。
    func testOpeningScenariosClearsRecordsFlag() async {
        let state = makeState()
        state.showingRecords = true

        await state.openScenarios()

        XCTAssertFalse(state.showingRecords, "开情景对话时没清掉「学习记录」，两个条目会同时高亮")
        XCTAssertEqual(state.activeSection, .scenarios)
    }

    /// 切到练习页会把其他页面标记全部清掉。
    /// 修复前 `openPractice()` 漏了 `showingScenarios`，情景浮层会压着练习页不放。
    func testOpeningPracticeClearsEveryOtherFlag() async {
        let state = makeState()
        state.showingScenarios = true
        state.showingRecords = true

        await state.openPractice()

        XCTAssertEqual(state.activeSection, .practice)
        XCTAssertFalse(state.showingScenarios)
        XCTAssertFalse(state.showingRecords)
    }

    /// 设置是**浮层**：打开它不该把底下的页面关掉，否则关掉设置会掉回练习页，像页面丢了。
    func testSettingsOverlayKeepsCurrentPage() async {
        let state = makeState()
        await state.openPractice()
        state.showingVocabulary = true

        state.showingSettings = true

        XCTAssertTrue(state.showingSettings)
        XCTAssertEqual(state.activeSection, .vocabulary, "开设置把底下那一页关掉了")
    }
}
