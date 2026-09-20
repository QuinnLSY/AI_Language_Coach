import AppKit
import AppUI
import SwiftUI
import XCTest

/// 主题令牌的**可读性守卫**。
///
/// 强调色这一族天生亮度高，是个很容易被「调亮一点更好看」带偏的地方：
/// 原来白天那支 `0xFFB703` 当文字时在白卡片上只有 1.75:1，夜晚那支
/// `0xFFD98A` 当底时白字压上去只有 1.35:1 —— 用户的原话是「白天看不清、
/// 夜晚太刺眼」。这两个数不是审美，是可测量的失败，所以在这里钉住。
///
/// ⚠️ 09-21 起这一族的主色**由黄改橘**（用户：「把棕色改成橘色」）。
/// 但守卫的判据一个都没放松：下面这些线管的是「读不读得清」和「分不分得开」，
/// 跟具体是黄还是橘无关 —— 换色反而更要跑一遍，因为色相一挪，
/// `accent` / `warning` 之间的分档差（ΔE）会当场变化。
///
/// 判据一律用 WCAG 相对亮度算，不靠肉眼：
/// - 令牌当**文字**用 → 与它所在的卡片底对比 ≥ 3:1；
/// - 令牌当**底**用 → 与压在它上面的 `onAccentFill` 对比 ≥ 3:1。
///
/// ⚠️ 09-16 补了一句教训：**「压够暗」不等于「好看」**。上一轮只盯着对比度上限，
/// 把白档黄一路压到 `0xB07C12`（亮度 0.24、色相 40°），用户反馈「变成棕色了」。
/// 所以现在两头顶着：上限（别刺眼）由 `testAccentStaysDimmed` + 承字色那条管，
/// 下限（别发褐）由 `testDayFillStaysGoldenNotBrown` 管。只守一头必然跑偏。
final class ThemeContrastTests: XCTestCase {

    private let day = ForestTheme(palette: .day)
    private let night = ForestTheme(palette: .night)

    /// 卡片底的**不透明近似值**（`surface` 是 0.92 透明的白/深蓝，压在
    /// 页面底色上；这里取压完之后的实色，算出来的对比度与实际观感一致）。
    private let daySurface = Color(hex: 0xFFFFFF)
    private let nightSurface = Color(hex: 0x152238)

    // MARK: - 度量

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

    private func contrast(_ a: Color, _ b: Color) -> Double {
        let la = luminance(a)
        let lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// sRGB → CIELAB，只为算 ΔE（色差），比「亮度差」更接近「看起来是不是两个颜色」。
    ///
    /// ⚠️ 进 XYZ 矩阵前**必须先线性化**：直接拿 sRGB 分量去乘矩阵会算出一个
    /// 偏小的 ΔE（本仓库实测偏小 6 左右），而它正是「分档够不够开」的判据。
    private func lab(_ color: Color) -> (Double, Double, Double) {
        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return (0, 0, 0) }
        func linear(_ value: CGFloat) -> Double {
            let c = Double(value)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = linear(ns.redComponent)
        let g = linear(ns.greenComponent)
        let b = linear(ns.blueComponent)
        let x = 0.4124 * r + 0.3576 * g + 0.1805 * b
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = 0.0193 * r + 0.1192 * g + 0.9505 * b
        func f(_ t: Double) -> Double {
            t > 0.008856 ? pow(t, 1.0 / 3) : 7.787 * t + 16.0 / 116
        }
        let fx = f(x / 0.95047)
        let fy = f(y)
        let fz = f(z / 1.08883)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    private func deltaE(_ a: Color, _ b: Color) -> Double {
        let la = lab(a)
        let lb = lab(b)
        return sqrt(pow(la.0 - lb.0, 2) + pow(la.1 - lb.1, 2) + pow(la.2 - lb.2, 2))
    }

    private func check(
        _ name: String, _ color: Color, on surface: Color, atLeast minimum: Double,
        _ message: String
    ) {
        let ratio = contrast(color, surface)
        XCTAssertGreaterThanOrEqual(
            ratio, minimum,
            "\(name)：对比度 \(String(format: "%.2f", ratio)):1，低于 \(minimum):1 —— \(message)"
        )
    }

    // MARK: - ① 强调黄当文字：两档都要在各自的卡片上读得清

    func testAccentIsReadableAsForeground() {
        check("白天 accent 当文字", day.accent, on: daySurface, atLeast: 3,
              "白天这档黄压在白卡片上会糊成一片")
        check("夜晚 accent 当文字", night.accent, on: nightSurface, atLeast: 3,
              "夜晚这档黄压不出足够亮度，字会陷进深蓝底里")
    }

    // MARK: - ② 强调黄当底：上面压的是它自己的字色 `onAccentFill`

    /// 这条是用户第一张截图里「全亮黄底 + 白字」的直接判据。
    ///
    /// ⚠️ 09-16 之后判据换了一根轴：白档的黄**故意提亮成金黄**，代价就是字必须换成
    /// 深墨色（`onAccentFill`）。所以这里不再拿 `.white` 当底上的字，而是拿令牌自己
    /// 那一支 —— 否则会把「正确的深墨字」判成失败，反过来把人逼回褐色。
    func testAccentFillCarriesItsOwnInk() {
        check("白天 accentFill 承自己的字色", day.accentFill, on: day.onAccentFill, atLeast: 3,
              "「开始复习」这类胶囊会变成看不清字的浅黄块")
        check("夜晚 accentFill 承自己的字色", night.accentFill, on: night.onAccentFill, atLeast: 3,
              "夜晚的白字压在亮黄上只有 1.35:1，实测读不出字")
    }

    // MARK: - ②b 「黄字压在淡黄底上」的有效对比度

    /// 这条才是用户实际看到的那一层：黄字**不是**压在白卡片上，而是压在
    /// 「自己 0.12 透明度的淡黄底」上（`Capsule().fill(accent.opacity(0.12))`）。
    /// 底被染黄了，实际对比度比对着纯白算出来的低一截。
    ///
    /// 判据先例：旁边那颗紫按钮（`accentCool` 文字压在它自己的 0.12 淡底上）
    /// 在离屏渲染图上实测 3.80:1 —— 用户就是拿它当「看得清」的参照。
    /// 门槛设 3.5，留一点余量。
    func testAccentTextOnItsOwnTintIsReadable() {
        func effective(_ tint: Color, on surface: Color) -> Double {
            guard let ns = NSColor(tint).usingColorSpace(.sRGB),
                  let bg = NSColor(surface).usingColorSpace(.sRGB)
            else { return 0 }
            let mixed = Color(
                .sRGB,
                red: Double(ns.redComponent) * 0.12 + Double(bg.redComponent) * 0.88,
                green: Double(ns.greenComponent) * 0.12 + Double(bg.greenComponent) * 0.88,
                blue: Double(ns.blueComponent) * 0.12 + Double(bg.blueComponent) * 0.88
            )
            return contrast(tint, mixed)
        }
        check(
            "白天 accent 压在自己的淡底上", day.accent,
            on: Color(hex: 0xF6F1E6), atLeast: 3.5,
            "「回到最初」这类胶囊会显得比旁边的紫按钮更难认"
        )
        // 这一条是拿真实混合色算的，不是近似——两档都走同一个 0.12。
        let dayEffective = effective(day.accent, on: daySurface)
        XCTAssertGreaterThanOrEqual(
            dayEffective, 3.5,
            "白天黄字压在 0.12 淡黄底上只有 \(String(format: "%.2f", dayEffective)):1（紫按钮是 3.80:1）"
        )
        let nightEffective = effective(night.accent, on: nightSurface)
        XCTAssertGreaterThanOrEqual(
            nightEffective, 3.5,
            "夜晚黄字压在 0.12 淡黄底上只有 \(String(format: "%.2f", nightEffective)):1"
        )
    }

    // MARK: - ③ 软警告色同样要读得清（原来是硬编码的 `Color.orange`）
    func testWarningIsReadable() {
        check("白天 warning", day.warning, on: daySurface, atLeast: 3, "告警图标/文字看不清")
        check("夜晚 warning", night.warning, on: nightSurface, atLeast: 3, "告警图标/文字看不清")
    }

    /// 警示色要和主强调色**分得开**：它占的是「满分/良好/加油/重来」里的
    /// 一档，撞色就等于少一档信息（这是当初没有直接复用 `accent` 的原因）。
    ///
    /// ⚠️ 判据用 ΔE（色差）而不是亮度比：这两支是**同族换色相**，亮度可以几乎
    /// 一样 —— 拿亮度当判据会把「色相差 12°」判成「同一个颜色」。门槛取 15，
    /// 参照系是**原设计里 `accent`(#FFB703) 与 `Color.orange`(#FF9500) 的 ΔE
    /// 是 19.9** —— 也就是说 15 已经比这个应用一直以来的分档还保守了。
    func testWarningStaysDistinctFromAccent() {
        let dayDelta = deltaE(day.accent, day.warning)
        let nightDelta = deltaE(night.accent, night.warning)
        XCTAssertGreaterThanOrEqual(
            dayDelta, 15,
            "白天 accent 与 warning 色差只有 ΔE \(String(format: "%.1f", dayDelta))，分档看不出来"
        )
        XCTAssertGreaterThanOrEqual(
            nightDelta, 15,
            "夜晚 accent 与 warning 色差只有 ΔE \(String(format: "%.1f", nightDelta))，分档看不出来"
        )
    }

    // MARK: - ④ 亮度上限：别再调回「高亮笔」那个档

    /// 对比度守不住这一条 —— 夜晚把黄调得更亮，对比度反而更高，但刺眼程度
    /// 也一起上去了。所以亮度另设上限，作为「降亮度」这个口径的守卫。
    func testAccentStaysDimmed() {
        XCTAssertLessThanOrEqual(
            luminance(day.accent), 0.30,
            "白天 accent 又变亮了（原色 0xFFB703 的亮度是 0.55）"
        )
        XCTAssertLessThanOrEqual(
            luminance(night.accent), 0.48,
            "夜晚 accent 又变亮了（原色 0xFFD98A 的亮度是 0.73）"
        )
    }

    /// 白档的底**不许再暗回褐色**。
    ///
    /// 这是用户 09-16 的原话：「白天的颜色可以更亮一些，现在已经变成棕色了」。
    /// 褐色不是审美问题，是**可测量的**：低亮度的深黄/深橙在 sRGB 里天然发褐，
    /// 旧的 `0xB07C12` 亮度只有 0.236。上面那条 `testAccentStaysDimmed` 只管上限，
    /// 光有它拦不住「越压越像棕色」这一头，所以这里把**下限**也钉住。
    ///
    /// ⚠️ 09-21 橘化后这条仍然有效且更重要：**橘色想够深就必须离褐色的边**——
    /// 亮度掉到 0.40 以下，再高的饱和度也会读成土色。现档 `0xF0A24A`（0.449）
    /// 与 `accent` 的深橘（0.164，走文字）是两个用途，别试图合成一支。
    func testDayFillStaysGoldenNotBrown() {
        XCTAssertGreaterThanOrEqual(
            luminance(day.accentFill), 0.40,
            "白档黄底又暗回褐色了（旧值 0xB07C12 亮度 0.236，用户称其为「棕色」）"
        )
        // 夜档方向相反：深金底 + 白字，底一亮点字就读不出，上限钉住。
        XCTAssertLessThanOrEqual(
            luminance(night.accentFill), 0.30,
            "夜档黄底变亮后白字会糊掉（用户已实测认可当前的深金档）"
        )
    }

    /// 白档金底的上限：**它和所在的白卡片必须还能分得开**。
    ///
    /// 用户 09-16 的第二次口径是「金底可以再亮半档」—— 能亮，但不是无上限：金底越亮，
    /// 那个实心胶囊就越像糊进白卡片里。实测这档（`0xEAC541`）与白卡片的对比是 1.67:1，
    /// 到 `0xEFCB4E` 只剩 1.50 —— 所以线画在 1.5，再往上不是「更亮的金」而是「看不清的块」。
    func testDayFillStaysDistinguishableFromTheCard() {
        let separation = contrast(day.accentFill, daySurface)
        XCTAssertGreaterThanOrEqual(
            separation, 1.5,
            "白档金底只有 \(String(format: "%.2f", separation)):1 与白卡片分不开，实心胶囊会糊进背景"
        )
    }

    /// 日间的黄要**追平旁边的紫色按钮**（`accentCool`）——用户是拿紫的当「看得清」的
    /// 参照说的。这条把两支放在同一把尺上，防止以后只调其中一支。
    func testDayAccentKeepsPaceWithTheCoolAccent() {
        let gold = contrast(day.accent, daySurface)
        let violet = contrast(day.accentCool, daySurface)
        XCTAssertGreaterThanOrEqual(
            gold, violet - 0.3,
            "日间黄 \(String(format: "%.2f", gold)):1 落后紫 \(String(format: "%.2f", violet)):1 太多，又该显得「看不清」了"
        )
    }

    /// 插画用的亮黄**不受**上面那条约束：太阳/月晕压暗只会变成一颗土黄色的球。
    /// 但正因如此，它必须和 UI 那支分开 —— 这里顺手把「两个用途两个令牌」钉住。
    func testGlowKeepsTheBrightYellowButOnlyForIllustration() {
        XCTAssertGreaterThan(
            luminance(day.glow), luminance(day.accent) * 1.5,
            "glow 应当明显比 accent 亮（它只画太阳，不承担信息传达）"
        )
        XCTAssertGreaterThan(
            luminance(night.glow), luminance(night.accent) * 1.5,
            "glow 应当明显比 accent 亮（它只画月晕，不承担信息传达）"
        )
    }

    // MARK: - ⑤ `accent` 只当文字，不许当实心底

    /// ⚠️ **要橙底请用 `accentFill` + `onAccentFill`，别拿 `accent` 去 `fill`。**
    ///
    /// 这不是洁癖：夜档的 `accent` 是亮琥珀，白字压上去只有 **2.31:1** —— 正是用户
    /// 第一张截图里那团读不出的字。09-16 一并收编了 5 处这么误用的地方
    /// （设置里的角色 chip / 开关 chip、厂商 chip、对话里的高亮胶囊、发送键）。
    ///
    /// 判据取夜档：它一旦被调到「能承白字」，就说明有人已经把它当成底来调了 ——
    /// 而它同时还得当暗底上的亮字，两个角色会当场打架。
    func testAccentIsNotUsedAsAFill() {
        XCTAssertLessThan(
            contrast(night.accent, .white), 3,
            "夜档 accent 已亮到能承白字（应 <3:1）—— 「暗底上的亮字」和「白字脚下的底」不能是同一支；要黄底请用 accentFill"
        )
    }
}
