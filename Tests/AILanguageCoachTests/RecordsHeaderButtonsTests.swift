import AppCore
import AppKit
import XCTest
import SwiftUI
@testable import AppUI

/// 学习记录「练习复盘」卡片头部两个按钮的配色约束（2026-09-14 反馈）。
///
/// 需求是「样式一样、颜色不同」：新按钮「前往词汇本练习」挂在「重新生成」旁边。
/// 这里钉住两件容易悄悄回归的事：
/// 1. 冷紫 `accentCool` 必须真的与主色 `accent` 不同（否则两个按钮又一样了）；
/// 2. 胶囊里是白字，两种主题下白字对比度都必须够（曾用过 0xA79BFF，白字只有 2.5:1）。
final class RecordsHeaderButtonsTests: XCTestCase {

    func testCoolAccentDiffersFromMainAccentInBothPalettes() {
        for palette in [ForestPalette.day, .night] {
            let theme = ForestTheme(palette: palette)
            XCTAssertNotEqual(
                theme.accent, theme.accentCool,
                "\(palette) 下「前往词汇本练习」与「重新生成」的颜色不能相同"
            )
        }
    }

    func testWhiteTextOnCoolAccentStaysReadable() throws {
        for palette in [ForestPalette.day, .night] {
            let theme = ForestTheme(palette: palette)
            let ratio = try XCTUnwrap(
                whiteContrastRatio(theme.accentCool),
                "\(palette) 下无法解析 accentCool 的颜色分量"
            )
            XCTAssertGreaterThanOrEqual(
                ratio, 3.0,
                "\(palette) 下白字在 accentCool 上的对比度只有 \(String(format: "%.2f", ratio)):1"
            )
        }
    }

    // MARK: - 对比度

    /// 白字压在给定底色上的 WCAG 对比度（白色亮度固定为 1.0，不必去解析 `.white` 的灰度色空间）。
    private func whiteContrastRatio(_ background: Color) -> Double? {
        guard let value = NSColor(background).usingColorSpace(.sRGB) else { return nil }
        return 1.05 / (luminance(value) + 0.05)
    }

    private func luminance(_ color: NSColor) -> Double {
        func channel(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.redComponent)
            + 0.7152 * channel(color.greenComponent)
            + 0.0722 * channel(color.blueComponent)
    }
}
