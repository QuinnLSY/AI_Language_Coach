import AppKit
import Foundation

/// 验证辅助：把鼠标移到指定点，然后**连同光标一起**截一小块屏。
///
/// 光标形状是 AppKit 的运行时行为，离屏渲染看不见 —— 只能这样取证：
/// `CGWarpMouseCursorPosition` 移动指针 → `screencapture -C` 把光标画进图里
/// → 人眼 / 模型看图判定是箭头还是 I 型。
///
/// 用法： swift Scripts/cursor-shot.swift <x> <y> <out.png> [w h]
let args = CommandLine.arguments
guard args.count >= 4, let x = Double(args[1]), let y = Double(args[2]) else {
    FileHandle.standardError.write(Data("用法: cursor-shot <x> <y> <out.png> [w h]\n".utf8))
    exit(2)
}
let out = args[3]
let width = args.count > 4 ? Double(args[4]) ?? 280 : 280
let height = args.count > 5 ? Double(args[5]) ?? 200 : 200

let point = CGPoint(x: x, y: y)
CGWarpMouseCursorPosition(point)
// 让指针的移动事件真的派发到目标窗口（悬停态 / 光标更新都需要它）。
if let move = CGEvent(
    mouseEventSource: nil, mouseType: .mouseMoved,
    mouseCursorPosition: point, mouseButton: .left
) {
    move.post(tap: .cghidEventTap)
}
usleep(350_000)

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
process.arguments = [
    "-C", "-x",
    "-R", "\(Int(x - width / 2)),\(Int(y - height / 3)),\(Int(width)),\(Int(height))",
    out,
]
try process.run()
process.waitUntilExit()
print("shot \(out) at (\(Int(x)), \(Int(y)))")
