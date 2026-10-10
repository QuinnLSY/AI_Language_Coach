import AIDomain
import XCTest

/// ④ 纵向那一半（发音跨次对比）的**接线**哨兵。
///
/// 纯函数（`PronunciationComparisonRule`）测得再好，如果生产侧没喂对数据，
/// 结论照样是错的 —— 而且是**静默**的错：页面照常画，只是永远画不出对比卡。
///
/// 三条最容易静默失守的接缝：
/// 1. `recentAttempts` 是**新 → 旧**，不反序的话前后两段互换，进步会说成退步；
/// 2. 没量到发音的次（纯文本预览）不能进样本 —— 它们连分都没有；
/// 3. 练完之后必须重算，否则学员刚读完看到的还是上一次的对比。
final class PronunciationComparisonWiringTests: XCTestCase {

    private static let appState = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // AILanguageCoachTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // 仓库根
        .appendingPathComponent("Sources/AppUI/AppState+Shadowing.swift")

    private var source: String {
        (try? String(contentsOf: Self.appState, encoding: .utf8)) ?? ""
    }

    /// ⚠️ 只钉**参数表开头**（和 `AdaptivePathRule.evaluate` 那条哨兵同一纪律）：
    /// 整段函数体逐字比对会在正常重构时假红，起不到真闸作用。
    func testCompareIsFedNewToOldAscendingSamples() {
        let text = source
        XCTAssertTrue(text.contains("services.shadowing.recentAttempts("),
                      "对比必须走已有的逐次取数 `recentAttempts`，不许自己查库")
        XCTAssertTrue(text.contains(".sorted { $0.createdAt < $1.createdAt }"),
                      "`recentAttempts` 是新→旧，必须显式排成旧→新，否则前后两段互换、进步说成退步")
    }

    /// 只在**量到发音的那些次**里比：`.compactMap(\.pronunciation)` 一去掉，
    /// 没分可比的次会变成 0 分混进均值（表现为「历史越久平均分越低」这种假退步）。
    func testOnlyAttemptsWithPronunciationBecomeSamples() {
        XCTAssertTrue(source.contains("compactMap(\\.pronunciation)"),
                      "样本必须由 `compactMap(\\.pronunciation)` 过滤 —— 没量到发音的次没有分可比")
    }

/// ⚠️ 判据必须钉**真调用形态**（`async let comparison: Void = …`），
/// 不能只数函数名出现几次 —— 把调用改成 `if false { refresh() }` 名字照样在，
/// 计数判据会**假绿**（已实测）。
func testPracticeCompletionRefreshesTheComparison() {
    let text = source
    XCTAssertTrue(text.contains("async let comparison: Void = refreshPronunciationComparison()"),
                  "练完之后必须以 `async let` 真的并发调一次刷新（读完了对比还不动）")
    XCTAssertTrue(text.contains("await comparison"),
                  "必须 `await comparison` 收口 —— 只发起不 await，这一条 refresh 会随作用域结束被丢掉")
    // 声明处 + 载入时 + 练完后：三个调用点（少一处就是某条路径不更新）。
    let occurrences = text.components(separatedBy: "refreshPronunciationComparison()").count - 1
    XCTAssertGreaterThanOrEqual(occurrences, 3,
                                "调用点至少要有：声明 1 + 载入 1 + 练完 1，实得 \(occurrences)")
}

    /// 对比卡是**派生**的：属性必须留给刷新函数写，不许在 body 求值时查库。
    func testComparisonIsStoredNotQueriedDuringRender() {
        XCTAssertTrue(source.contains("pronunciationComparison = PronunciationComparisonRule.compare(samples)"),
                      "对比结果应由刷新函数落到属性上（body 求值里查库 = 每次重绘都查一次）")
        XCTAssertFalse(source.contains("var pronunciationComparison: PronunciationComparison? {"),
                       "`pronunciationComparison` 是存下来的属性，不能是 computed（否则渲染期查库）")
    }
}