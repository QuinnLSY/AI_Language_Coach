import AppKit
import CoreGraphics
import Foundation

/// 验证辅助：打印 app 窗口的屏幕 frame（**左上原点，屏幕点**）与显示尺寸，
/// 好让「截屏里看到的位置」换算成 `screencapture -R` / 鼠标坐标。
///
/// 用法： swift Scripts/window-info.swift [窗口名关键字]
let keyword = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AI Language Coach"

let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []
// ⚠️ 只按 **owner** 匹配：窗口标题里出现项目名的地方太多了
// （比如 IDE 的「查看 AI_Language_Coach 测试结果」），按 name 匹配会张冠李戴。
// ⚠️ 全部打印、并且**按面积从大到小排**：app 除了主窗口还会开出一堆小浮窗
// （`.help` 的 tooltip 就是一个 136 宽的小窗口），只取第一行会拿到 tooltip，
// 于是按错误坐标去截屏、截到的是桌面壁纸。
var matches: [(area: CGFloat, line: String)] = []
for info in list {
    let owner = info[kCGWindowOwnerName as String] as? String ?? ""
    guard owner.contains(keyword) else { continue }
    guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
    let layer = info[kCGWindowLayer as String] as? Int ?? 0
    let name = info[kCGWindowName as String] as? String ?? ""
    let width = bounds["Width"] ?? 0
    let height = bounds["Height"] ?? 0
    matches.append((
        width * height,
        "owner=\(owner) name=\(name) layer=\(layer) x=\(Int(bounds["X"] ?? 0)) y=\(Int(bounds["Y"] ?? 0)) w=\(Int(width)) h=\(Int(height))"
    ))
}
for match in matches.sorted(by: { $0.area > $1.area }) {
    print(match.line)
}
if let screen = NSScreen.main {
    print("screen frame=\(screen.frame) visible=\(screen.visibleFrame) scale=\(screen.backingScaleFactor)")
}
