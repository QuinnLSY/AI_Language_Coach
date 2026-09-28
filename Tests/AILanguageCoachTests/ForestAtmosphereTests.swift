import AppCore
@testable import AppUI
import XCTest

/// 批次五 · C「时段天空 + 季节」的测试。
///
/// 分两块：
/// - **纯函数**：小时→时刻、月份→季节、天体弧线位置、主题解析（都能直接算）；
/// - **接线哨兵**：开了「跟随时间」之后哪条线没接上，编译器一声不响，
///   只是「太阳不动了 / 季节没换」，只能扫源码钉住。
///
/// ⚠️ 反证必须**真删真改**：`body(of:)` 扫的是原始文本，注释掉的代码行照样被扫到。
@MainActor
final class ForestAtmosphereTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: "Sources/\(relativePath)", encoding: .utf8)
    }

    private func codeLines(_ source: String) -> [(number: Int, text: String)] {
        source.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, raw in
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { return nil }
            return (index + 1, line)
        }
    }

    // MARK: - ① 时刻 / 季节判据

    /// 六档时刻的分界（含越界钳回）：夜里跨 0 点，是最容易写错的那一档。
    func testMomentBoundaries() {
        XCTAssertEqual(ForestAtmosphere.moment(hour: 4), .night)
        XCTAssertEqual(ForestAtmosphere.moment(hour: 5), .dawn)
        XCTAssertEqual(ForestAtmosphere.moment(hour: 7), .dawn)
        XCTAssertEqual(ForestAtmosphere.moment(hour: 8), .morning)
        XCTAssertEqual(ForestAtmosphere.moment(hour: 10), .morning)
        XCTAssertEqual(ForestAtmosphere.moment(hour: 11), .noon)
        XCTAssertEqual(ForestAtmosphere.moment(hour: 14), .noon)
        XCTAssertEqual(ForestAtmosphere.moment(hour: 15), .afternoon)
        XCTAssertEqual(ForestAtmosphere.moment(hour: 17), .afternoon)
        XCTAssertEqual(ForestAtmosphere.moment(hour: 18), .dusk)
        XCTAssertEqual(ForestAtmosphere.moment(hour: 19), .dusk)
        XCTAssertEqual(ForestAtmosphere.moment(hour: 20), .night)
        XCTAssertEqual(ForestAtmosphere.moment(hour: 23), .night)
        // 越界钳回而不是崩 / 落到奇怪的档
        XCTAssertEqual(ForestAtmosphere.moment(hour: -3), .night)
        XCTAssertEqual(ForestAtmosphere.moment(hour: 99), .night)
    }

    /// 季节按自然月份（含越界钳回）。
    func testSeasonBoundaries() {
        XCTAssertEqual(ForestAtmosphere.season(month: 1), .winter)
        XCTAssertEqual(ForestAtmosphere.season(month: 2), .winter)
        XCTAssertEqual(ForestAtmosphere.season(month: 3), .spring)
        XCTAssertEqual(ForestAtmosphere.season(month: 5), .spring)
        XCTAssertEqual(ForestAtmosphere.season(month: 6), .summer)
        XCTAssertEqual(ForestAtmosphere.season(month: 8), .summer)
        XCTAssertEqual(ForestAtmosphere.season(month: 9), .autumn)
        XCTAssertEqual(ForestAtmosphere.season(month: 11), .autumn)
        XCTAssertEqual(ForestAtmosphere.season(month: 12), .winter)
        XCTAssertEqual(ForestAtmosphere.season(month: 0), .winter)
        XCTAssertEqual(ForestAtmosphere.season(month: 13), .winter)
    }

    /// 「天黑了」的判据：黄昏（18–20 点）天还亮着，不算夜里。
    func testNightHourJudgement() {
        for hour in [20, 21, 23, 0, 3, 4] {
            XCTAssertTrue(ForestAtmosphere.isNightHour(hour), "\(hour) 点该算夜里")
        }
        for hour in [5, 8, 12, 17, 18, 19] {
            XCTAssertFalse(ForestAtmosphere.isNightHour(hour), "\(hour) 点天还亮着，不算夜里")
        }
    }

    // MARK: - ② 天体沿弧线走

    /// 日出在左、日落前移到画面右侧、正午升到弧顶（y 最小）。
    func testCelestialRidesAnArc() {
        let width: CGFloat = 1200
        let dawn = ForestAtmosphere.celestialAnchor(hour: 5, width: width)
        let noon = ForestAtmosphere.celestialAnchor(hour: 12, width: width)
        let beforeSunset = ForestAtmosphere.celestialAnchor(hour: 18.5, width: width)

        XCTAssertEqual(dawn.x, ForestAtmosphere.celestialMargin, accuracy: 1, "日出贴着左边缘")
        XCTAssertLessThan(dawn.x, noon.x)
        XCTAssertLessThan(noon.x, beforeSunset.x)
        XCTAssertGreaterThan(beforeSunset.x, width * 0.75, "日落前太阳应当已经走到画面右侧")

        // y 是上边距：越**小**越靠上。正午最高，日出最低。
        XCTAssertLessThan(noon.y, dawn.y, "正午的太阳必须比日出时高")
        XCTAssertEqual(noon.y, ForestAtmosphere.arcTop, accuracy: 1, "正午应当在弧顶")
        XCTAssertEqual(dawn.y, ForestAtmosphere.arcTop + ForestAtmosphere.arcDrop, accuracy: 1)
    }

    /// 日落那一刻换月亮：从左边重新升起（太阳沉在右边，月亮从另一头起来），
    /// 而不是原地「变」成月亮 —— 后者看着像卡住了。
    func testMoonRisesFromTheLeftAtSunset() {
        let width: CGFloat = 1000
        let handoff = ForestAtmosphere.celestialAnchor(hour: 19, width: width)
        XCTAssertEqual(handoff.x, ForestAtmosphere.celestialMargin, accuracy: 1, "月亮从左边升起")
        XCTAssertEqual(handoff.y, ForestAtmosphere.arcTop + ForestAtmosphere.arcDrop, accuracy: 1,
                       "刚升起来的月亮贴着弧底")
    }

    /// 夜里换月亮走同一条弧（19 点 → 次日 5 点），别让月亮卡在一处。
    func testMoonAlsoMovesAtNight() {
        let width: CGFloat = 900
        let earlyNight = ForestAtmosphere.celestialAnchor(hour: 20, width: width)
        let midnight = ForestAtmosphere.celestialAnchor(hour: 0, width: width)
        let lateNight = ForestAtmosphere.celestialAnchor(hour: 4, width: width)
        XCTAssertLessThan(earlyNight.x, midnight.x)
        XCTAssertLessThan(midnight.x, lateNight.x)
        XCTAssertLessThan(midnight.y, earlyNight.y, "半夜的月亮应当在弧顶附近")
    }

    // MARK: - ③ 主题解析

    /// 关着「跟随时间」时逐字等于老行为（时刻与季节都是 nil）——老用户开屏不该变样。
    func testResolverWithoutFollowsClockIsTheOldBehavior() {
        let old = ForestThemeResolver.resolve(mode: .day, systemIsDark: true)
        let now = ForestThemeResolver.resolve(mode: .day, systemIsDark: true,
                                              hour: 22, month: 10, followsClock: false)
        XCTAssertNil(now.moment)
        XCTAssertNil(now.season)
        XCTAssertEqual(now, old)
    }

    /// 开着时：天黑切夜景、白天挑时刻、按月份换季节。
    func testResolverFollowsClockDrivesPaletteMomentAndSeason() {
        let night = ForestThemeResolver.resolve(mode: .day, systemIsDark: false,
                                                hour: 22, month: 4, followsClock: true)
        XCTAssertTrue(night.isNight, "夜里就算手动选了白天，跟随时间也该切夜景")
        XCTAssertEqual(night.moment, .night)

        let morning = ForestThemeResolver.resolve(mode: .night, systemIsDark: true,
                                                  hour: 9, month: 10, followsClock: true)
        XCTAssertFalse(morning.isNight)
        XCTAssertEqual(morning.moment, .morning)
        XCTAssertEqual(morning.season, .autumn)
    }

    // MARK: - ④ 季节只改插画层（硬约束）

    /// **语义色一行都不许动**：它们被 `ThemeContrastTests` 用对比度与 ΔE 钉住，
    /// 随季节漂会当场失真（秋黄压在白卡片上就不是一个能读的颜色了）。
    ///
    /// 反证：让 `accent` 也走 `seasonal(...)` → 红。
    func testSeasonNeverTouchesSemanticColors() {
        let base = ForestTheme(palette: .day)
        let nightBase = ForestTheme(palette: .night)
        for season in ForestSeason.allCases {
            let day = ForestTheme(palette: .day, season: season)
            XCTAssertEqual(day.accent, base.accent, "\(season) 改了 accent")
            XCTAssertEqual(day.warning, base.warning, "\(season) 改了 warning")
            XCTAssertEqual(day.streak, base.streak, "\(season) 改了 streak")
            XCTAssertEqual(day.danger, base.danger, "\(season) 改了 danger")
            XCTAssertEqual(day.success, base.success, "\(season) 改了 success")
            XCTAssertEqual(day.primaryText, base.primaryText, "\(season) 改了 primaryText")
            XCTAssertEqual(day.surface, base.surface, "\(season) 改了 surface")

            let night = ForestTheme(palette: .night, season: season)
            XCTAssertEqual(night.accent, nightBase.accent, "夜档 \(season) 改了 accent")
            XCTAssertEqual(night.primaryText, nightBase.primaryText, "夜档 \(season) 改了 primaryText")
        }
    }

    /// 山丘与叶色**确实**按季节变（不许接了半天一点没动）。
    ///
    /// 反证：`seasonal(_:)` 直接 `return Color(hex: day)` → 四季同色 → 红。
    func testSeasonActuallyRetintsTheScenery() {
        let set = ForestSeason.allCases.map { season -> String in
            let theme = ForestTheme(palette: .day, season: season)
            return "\(theme.hillNear)-\(theme.foliage)"
        }
        XCTAssertEqual(Set(set).count, ForestSeason.allCases.count,
                       "四季的叶色/山丘必须是四种：\(set)")
    }

    /// 夜里不看季节（夜里看不出叶色，改了只会把夜景改坏）。
    func testNightKeepsItsOwnScenery() {
        let base = ForestTheme(palette: .night)
        for season in ForestSeason.allCases {
            let theme = ForestTheme(palette: .night, season: season)
            XCTAssertEqual(theme.foliage, base.foliage, "夜档不该随 \(season) 改叶色")
            XCTAssertEqual(theme.hillNear, base.hillNear, "夜档不该随 \(season) 改山丘")
        }
    }

    /// 天空按时刻变；夜档不受时刻影响（夜里就是夜里那片天）。
    func testSkyVariesByMomentButNightStaysNight() {
        let dawn = ForestTheme(palette: .day, moment: .dawn).sky
        let noon = ForestTheme(palette: .day, moment: .noon).sky
        let dusk = ForestTheme(palette: .day, moment: .dusk).sky
        XCTAssertNotEqual(dawn, noon)
        XCTAssertNotEqual(dusk, noon)

        let night = ForestTheme(palette: .night).sky
        let nightAtNoon = ForestTheme(palette: .night, moment: .noon).sky
        XCTAssertEqual(night, nightAtNoon, "夜档的天空不看时刻")
    }

    /// 冬天飘雪、秋天飘金叶（同一套飘落动画换个颜色，季节自己就出来了）。
    func testFallingFlakeFollowsTheSeason() {
        XCTAssertNotEqual(ForestTheme(palette: .day, season: .autumn).fallingFlake,
                          ForestTheme(palette: .day, season: .summer).fallingFlake)
        XCTAssertNotEqual(ForestTheme(palette: .day, season: .winter).fallingFlake,
                          ForestTheme(palette: .day, season: .summer).fallingFlake)
    }

    // MARK: - ⑤ 接线哨兵

    /// 主界面把天体挂到弧线位置上（且关掉时仍钉在右上角）。
    ///
    /// 反证：删掉 `celestialAnchor(hour:` 那一行 → 红。
    func testMainViewPlacesCelestialOnTheArc() throws {
        let main = try source("AppUI/Views/MainView.swift")
        XCTAssertTrue(main.contains("ForestAtmosphere.celestialAnchor(hour: state.clockHour, width: total)"),
                      "天体位置必须由弧线算出来")
        XCTAssertTrue(main.contains("alignment: followsClock ? .topLeading : .topTrailing"),
                      "关掉跟随时天体要退回右上角")
        XCTAssertTrue(main.contains("state.forestFollowsClock"), "主界面要读跟随开关")
    }

    /// AppState 的 `theme` 把小时/月份/开关一起交给解析器。
    ///
    /// 反证：改回只传 `mode` 与 `systemIsDark` → 红。
    func testAppStateFeedsTheClockIntoTheTheme() throws {
        let state = try source("AppUI/AppState.swift")
        XCTAssertTrue(state.contains("hour: Int(clockHour.rounded(.down)), month: clockMonth,"),
                      "主题解析要拿到小时与月份")
        XCTAssertTrue(state.contains("followsClock: product.forestFollowsClock"),
                      "主题解析要拿到跟随开关")
    }

    /// 手动点太阳/月亮必须**收回自动**，否则开了跟随后那个按钮点了没反应。
    ///
    /// 反证：删掉 `product.forestFollowsClock = false` → 红。
    func testManualCelestialTapTakesBackTheAutoMode() throws {
        let state = try source("AppUI/AppState.swift")
        // 取 `toggleDayNight` 的函数体：里面必须先关自动，再按当前明暗切到另一档。
        guard let range = state.range(of: "public func toggleDayNight() async {") else {
            return XCTFail("找不到 toggleDayNight")
        }
        let tail = state[range.lowerBound...]
        let end = tail.range(of: "\n    public func ") ?? tail.range(of: "\n    func ")
        let body = String(end.map { tail[..<$0.lowerBound] } ?? tail)
        XCTAssertTrue(body.contains("product.forestFollowsClock = false"),
                      "自动开着时点天体要先收回自动，否则按钮是死的")
        XCTAssertTrue(body.contains("await setThemeMode(theme.isNight ? .day : .night)"),
                      "收回自动之后还要真的切一次")
    }

    /// 设置里有这个开关（且文案说清了「点太阳会收回自动」这层关系）。
    func testSettingsExposesTheFollowClockToggle() throws {
        let settings = try source("AppUI/Views/SettingsView.swift")
        XCTAssertTrue(settings.contains("await state.setForestFollowsClock(on)"),
                      "设置里要有跟随时间与季节的开关")
        XCTAssertTrue(settings.contains("跟随时间与季节"))
    }
}
