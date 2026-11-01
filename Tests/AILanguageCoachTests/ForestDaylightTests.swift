import AppKit
import SwiftUI
import XCTest
@testable import AppUI

/// 日夜连续光色推移（2026-11-01）。
///
/// 改前的状态：**插画层只有 1 个比特** —— `isNight ? 夜档色 : 白档色`。
/// 于是 09:00 与 19:00 的山丘、叶色、树干一模一样，只有天空那一条渐变在变。
/// 用户看到的「一刀切」就来自这儿：天已经橘了，地还是正午的绿。
///
/// 改后：光收成两个标量（`level` 日照强度 / `warmth` 色温），插画色过
/// `ForestAtmosphere.sunlit` —— 一天的推移按**分钟**连续走完，不再是六次跳变。
///
/// 判据分四组：
/// 1. **恒等档**（不跟随时间 / 正午）必须一个字节都不动（否则全部渲染基线一起漂）；
/// 2. **黄昏真的比正午暗、比正午暖**（这是「光色推移」的可测量含义）；
/// 3. **连续**（相邻两分钟之间的差要多小有多小，不是阶梯）；
/// 4. **语义色一行都不许动**（它们被 `ThemeContrastTests` 钉着）。
final class ForestDaylightTests: XCTestCase {

    // MARK: - 度量

    /// WCAG 相对亮度（与 `ThemeContrastTests` 同一把尺，不另起一套）。
    private func luminance(_ color: Color) -> Double {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return 0 }
        func channel(_ value: CGFloat) -> Double {
            let c = Double(value)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(ns.redComponent)
            + 0.7152 * channel(ns.greenComponent)
            + 0.0722 * channel(ns.blueComponent)
    }

    /// 色温的粗糙度量：红减蓝（正值 = 偏暖）。绿草地上这个差值最灵敏 ——
    /// 亮度会被混暖与压暗两头夹住，色相不会。
    private func warmth(_ color: Color) -> Double {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return 0 }
        return Double(ns.redComponent - ns.blueComponent)
    }

    // MARK: - ① 恒等档

    /// 正午与「不跟随时间」都是**恒等变换**：插画色逐字节不变。
    ///
    /// 反证：把 `sunlit` 的快速返回删掉（恒走一遍压暗+混暖）→ 正午那档也变了 → 红。
    func testNoonAndNoClockAreTheIdentity() {
        XCTAssertEqual(ForestAtmosphere.sunlit(0x3F9E67, .noon), 0x3F9E67)
        XCTAssertEqual(ForestAtmosphere.sunlit(0x000000, .noon), 0x000000)
        XCTAssertEqual(ForestAtmosphere.sunlit(0xFFFFFF, .noon), 0xFFFFFF)

        let plain = ForestTheme(palette: .day)
        XCTAssertNil(plain.hourProgress, "没给精确时刻就不该有")
        // 正午（12:00）是曲线的定义点
        let noon = ForestTheme(palette: .day, hourProgress: 12)
        XCTAssertEqual(noon.hillNear, plain.hillNear, "正午的山丘必须与基色逐字节相同")
        XCTAssertEqual(noon.hillFar, plain.hillFar)
        XCTAssertEqual(noon.foliage, plain.foliage)
        XCTAssertEqual(noon.trunk, plain.trunk, "树干也要在恒等档上")
    }

    // MARK: - ② 黄昏 vs 正午

    /// 黄昏：比正午**暗**、比正午**暖**。这两条合起来才是「低角度阳光」。
    ///
    /// ⚠️ 只测「不等」是不够的：混暖会把压暗抵消掉，早些时候真的出现过
    /// 「黄昏比正午还亮」——颜色确实变了，但方向是反的，肉眼一眼假。
    ///
    /// ⚠️ 暖度只对**绿色那一族**断言：`r − b` 量的是「红蓝分家得多开」，
    /// 而树干本来就是饱和的暖褐（`0xA9743F` 的红蓝差已经到顶），再混暖只会
    /// 让它整体压暗、差值原地不动 —— 那不是「没变暖」，是这把尺在暖色上失灵。
    /// 深色那一支因此只钉「变暗 + 确实变了」。
    func testDuskIsDarkerAndWarmerThanNoon() {
        let noon = ForestTheme(palette: .day, hourProgress: 12)
        let dusk = ForestTheme(palette: .day, hourProgress: 19)
        for (name, noonColor, duskColor) in [
            ("hillNear", noon.hillNear, dusk.hillNear),
            ("hillMid", noon.hillMid, dusk.hillMid),
            ("hillFar", noon.hillFar, dusk.hillFar),
            ("foliage", noon.foliage, dusk.foliage),
        ] {
            XCTAssertNotEqual(noonColor, duskColor, "\(name) 在黄昏一点没变")
            XCTAssertLessThan(luminance(duskColor), luminance(noonColor),
                              "\(name) 黄昏比正午还亮 —— 混暖把压暗抵消掉了")
            XCTAssertGreaterThan(warmth(duskColor), warmth(noonColor),
                                 "\(name) 黄昏不比正午暖（红蓝差没拉开）")
        }
        // 树干：只钉变暗与确实变了（见上面那条说明）。
        XCTAssertNotEqual(noon.trunk, dusk.trunk, "树干在黄昏一点没变")
        XCTAssertLessThan(luminance(dusk.trunk), luminance(noon.trunk), "树干黄昏比正午还亮")
        // 暗面也得跟着走：亮面变了、暗面没变，树会看起来像贴了一层新皮。
        XCTAssertNotEqual(noon.trunkShade, dusk.trunkShade, "树干暗部没吃到光")
        XCTAssertLessThan(luminance(dusk.trunkShade), luminance(noon.trunkShade))
    }

    /// 晨曦比黄昏更暗（太阳刚出海平面），黄昏比晨曦更暖（带着一整天的余温）。
    func testDawnIsDimAndDuskIsTheWarmest() {
        let dawn = ForestAtmosphere.daylight(hour: 6)
        let noon = ForestAtmosphere.daylight(hour: 12)
        let dusk = ForestAtmosphere.daylight(hour: 19)
        XCTAssertLessThan(dawn.level, noon.level)
        XCTAssertLessThan(dusk.level, noon.level)
        XCTAssertLessThan(dawn.level, ForestAtmosphere.daylight(hour: 9).level)
        XCTAssertGreaterThan(dusk.warmth, dawn.warmth)
        XCTAssertGreaterThan(dawn.warmth, noon.warmth)
        XCTAssertEqual(noon.level, 1, accuracy: 1e-9, "正午必须是曲线的定义点 level = 1")
        XCTAssertEqual(noon.warmth, 0, accuracy: 1e-9)
    }

    // MARK: - ③ 连续

    /// **一步步走完全天**：相邻两分钟之间的变化必须小到看不见。
    ///
    /// 这就是「连续」的可测含义 —— 六档跳变在 19:00→20:00 之间会有一个大台阶
    /// （大约 0.28 的 level），按分钟走则每步不超过 0.02。
    ///
    /// ⚠️ 取样步长与阈值是配套的：改步长就要重算阈值，别只改一边。
    func testLightMovesContinuouslyAcrossTheDay() {
        let step = 1.0 / 60           // 一分钟
        var maxJump = 0.0
        var hour = 0.0
        while hour < 24 {
            let now = ForestAtmosphere.daylight(hour: hour)
            let next = ForestAtmosphere.daylight(hour: min(hour + step, 24))
            maxJump = max(maxJump, abs(next.level - now.level), abs(next.warmth - now.warmth))
            hour += step
        }
        XCTAssertLessThan(maxJump, 0.02,
                          "一分钟内光跳了 \(maxJump) —— 插画会看到台阶而不是推移")
    }

    /// 曲线本身有界：level / warmth 都在 0…1，且 0 点与 24 点接得上（跨零点不许断）。
    ///
    /// 反证：把关键帧表末尾的 `(24, 0.10, 0.30)` 改成 `(24, 1, 0)` → 红。
    func testLightStaysInRangeAndWrapsAroundMidnight() {
        for minute in 0...(24 * 60) {
            let light = ForestAtmosphere.daylight(hour: Double(minute) / 60)
            XCTAssertGreaterThanOrEqual(light.level, 0)
            XCTAssertLessThanOrEqual(light.level, 1)
            XCTAssertGreaterThanOrEqual(light.warmth, 0)
            XCTAssertLessThanOrEqual(light.warmth, 1)
        }
        let midnight = ForestAtmosphere.daylight(hour: 0)
        let nextMidnight = ForestAtmosphere.daylight(hour: 24)
        XCTAssertEqual(midnight.level, nextMidnight.level, accuracy: 1e-9, "跨零点断了")
        XCTAssertEqual(midnight.warmth, nextMidnight.warmth, accuracy: 1e-9, "跨零点断了")
        // 越界钳回（公共入口，调用方可能给 25 或 -3）
        XCTAssertEqual(ForestAtmosphere.daylight(hour: -3).level,
                       ForestAtmosphere.daylight(hour: 0).level, accuracy: 1e-9)
        XCTAssertEqual(ForestAtmosphere.daylight(hour: 99).level,
                       ForestAtmosphere.daylight(hour: 24).level, accuracy: 1e-9)
    }

    /// 精确时刻真的被 resolver 带进主题 —— 但**只在跟随时间开着的时候**。
    ///
    /// 关着还带进来的话，`testResolverWithoutFollowsIsTheOldBehavior` 那条
    /// 「与老行为逐字相等」的承诺就被悄悄破了。
    func testResolverCarriesTheFractionOnlyWhenFollowingTheClock() throws {
        let following = ForestThemeResolver.resolve(
            mode: .day, systemIsDark: false, hour: 17, month: 6,
            followsClock: true, followsSeason: false, hourFraction: 17.42)
        // ⚠️ `try XCTUnwrap` 不能写进 `XCTAssertEqual` 的 autoclosure（会编译不过），
        // 先搬成局部常量再断言。
        let followingProgress = try XCTUnwrap(following.hourProgress)
        XCTAssertEqual(followingProgress, 17.42, accuracy: 1e-9)

        let notFollowing = ForestThemeResolver.resolve(
            mode: .day, systemIsDark: false, hour: 17, month: 6,
            followsClock: false, followsSeason: false, hourFraction: 17.42)
        XCTAssertNil(notFollowing.hourProgress)
        XCTAssertEqual(notFollowing.hillNear, ForestTheme(palette: .day).hillNear,
                       "不跟随时间时插画色必须与老行为逐字节相同")

        // 只给整点也成立（`hourFraction` 缺省 → 用 hour）
        let wholeHour = ForestThemeResolver.resolve(
            mode: .day, systemIsDark: false, hour: 17, month: 6,
            followsClock: true, followsSeason: false)
        let wholeHourProgress = try XCTUnwrap(wholeHour.hourProgress)
        XCTAssertEqual(wholeHourProgress, 17, accuracy: 1e-9)

        // 越界钳回 0…24
        let clamped = ForestThemeResolver.resolve(
            mode: .day, systemIsDark: false, hour: 17, month: 6,
            followsClock: true, followsSeason: false, hourFraction: 99)
        let clampedProgress = try XCTUnwrap(clamped.hourProgress)
        XCTAssertEqual(clampedProgress, 24, accuracy: 1e-9)
    }

    // MARK: - ④ 语义色与夜档

    /// **语义色一行都不许动**（accent / warning / 文字 / 表面 / 危险 / 成功…）。
    ///
    /// 它们被 `ThemeContrastTests` 用对比度与 ΔE 钉住，随光漂会当场失真：
    /// 黄昏的橘 accent 压在白卡片上就不是一个能读的颜色了。
    ///
    /// 反证：`accent` 也走 `lit(...)` → 红。
    func testSemanticColorsNeverFollowTheLight() {
        let base = ForestTheme(palette: .day)
        for hour in [5.0, 6.5, 12.0, 17.5, 19.5] {
            let theme = ForestTheme(palette: .day, hourProgress: hour)
            XCTAssertEqual(theme.accent, base.accent, "\(hour) 点改了 accent")
            XCTAssertEqual(theme.warning, base.warning, "\(hour) 点改了 warning")
            XCTAssertEqual(theme.streak, base.streak)
            XCTAssertEqual(theme.danger, base.danger)
            XCTAssertEqual(theme.success, base.success)
            XCTAssertEqual(theme.primaryText, base.primaryText)
            XCTAssertEqual(theme.secondaryText, base.secondaryText)
            XCTAssertEqual(theme.surface, base.surface)
            XCTAssertEqual(theme.panel, base.panel)
            XCTAssertEqual(theme.chatBackdrop, base.chatBackdrop)
        }
    }

    /// 夜档不看光（夜里就是夜档那套色板）：光不往上叠，否则夜景会被越叠越灰。
    func testNightPaletteIgnoresTheLight() {
        let base = ForestTheme(palette: .night)
        for hour in [5.0, 12.0, 19.0, 23.0] {
            let theme = ForestTheme(palette: .night, hourProgress: hour)
            XCTAssertEqual(theme.hillNear, base.hillNear, "夜档 \(hour) 点改了山丘")
            XCTAssertEqual(theme.foliage, base.foliage, "夜档 \(hour) 点改了叶色")
            XCTAssertEqual(theme.trunk, base.trunk, "夜档 \(hour) 点改了树干")
        }
    }

    /// 三个维度**叠加**而不是互相顶掉：秋 + 黄昏 ≠ 秋 + 正午 ≠ 常青 + 黄昏。
    ///
    /// 反证：`seasonal` 里把 `lit(...)` 去掉（只留季节色）→ 前两个相等 → 红。
    func testSeasonAndLightCompose() {
        let autumnNoon = ForestTheme(palette: .day, season: .autumn, hourProgress: 12)
        let autumnDusk = ForestTheme(palette: .day, season: .autumn, hourProgress: 19)
        let evergreenDusk = ForestTheme(palette: .day, hourProgress: 19)
        XCTAssertNotEqual(autumnNoon.foliage, autumnDusk.foliage, "季节色没吃到光")
        XCTAssertNotEqual(autumnDusk.foliage, evergreenDusk.foliage, "光把季节色吃掉了")
        let set = [
            ForestTheme(palette: .day, season: .spring, hourProgress: 6).hillNear,
            ForestTheme(palette: .day, season: .spring, hourProgress: 12).hillNear,
            ForestTheme(palette: .day, season: .summer, hourProgress: 12).hillNear,
        ]
        XCTAssertEqual(Set(set.map { "\($0)" }).count, 3)
    }

    // MARK: - 接线（源码哨兵）

    /// 插画层的取色必须**过光照**（而不是各处自己 `Color(hex:)`）。
    ///
    /// ⚠️ 钉调用形态整串、并先剥掉整行注释（注释里留着同样的字符串，光靠
    /// `contains` 的话「把那一行注释掉」这种最自然的反证会照样绿）。
    func testIllustrationColorsGoThroughTheLight() throws {
        let source = try CloudDriftTests.stripped("Theme/ForestTheme.swift")
        XCTAssertTrue(source.contains("return lit(grown)"), "季节色没过光照")
        XCTAssertTrue(source.contains("guard let season else { return lit(day) }"),
                      "无季节那一路没过光照")
        XCTAssertTrue(source.contains("public var trunk: Color { isNight ? Color(hex: 0x4A3626) : lit(0xA9743F) }"),
                      "树干没过光照")
        XCTAssertTrue(source.contains("Color(hex: ForestAtmosphere.sunlit(hex, momentLight))"),
                      "lit 没有走 sunlit")
        // 反向：山丘三支与叶色两支仍然读 `seasonal(...)`（否则上面那几条钉的是死代码）
        for name in ["hillFar", "hillMid", "hillNear", "foliage", "foliageDeep"] {
            XCTAssertTrue(source.contains("public var \(name): Color {\n        seasonal("),
                          "\(name) 没有走 seasonal，光与季节都够不着它")
        }
    }

    /// `AppState.theme` 把**带分钟的时刻**喂给 resolver（与天体走弧用的同一个来源）。
    func testAppStateFeedsTheFractionalHour() throws {
        let source = try CloudDriftTests.stripped("AppState.swift")
        XCTAssertTrue(source.contains("hourFraction: clockHour"),
                      "主题没吃带分钟的时刻 —— 光会停在整点上")
    }
}
