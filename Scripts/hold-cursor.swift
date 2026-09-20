import AppKit
import Foundation

/// 验证辅助：把指针「按住」在某个点上一段时间（每 50ms 重发一次移动事件）。
///
/// 为什么需要它：用户可能正在用同一台机器，物理鼠标随时会把指针拽走 ——
/// 而气泡靠「指针停住 0.22 秒」才出来，被拽走一次就前功尽弃。
/// 反复重发能把指针按在原地（同一个词重复到达不会打断计时，见 `mouseMoved` 里的
/// `word != lastHoverWord` 短路）。
///
/// 用法： swift Scripts/hold-cursor.swift <x> <y> <秒> [截图输出]
let args = CommandLine.arguments
guard args.count >= 4, let x = Double(args[1]), let y = Double(args[2]),
      let seconds = Double(args[3]) else {
    FileHandle.standardError.write(Data("用法: hold-cursor <x> <y> <秒> [out.png]\n".utf8))
    exit(2)
}
let point = CGPoint(x: x, y: y)
let deadline = Date().addingTimeInterval(seconds)
while Date() < deadline {
    CGWarpMouseCursorPosition(point)
    if let event = CGEvent(
        mouseEventSource: nil, mouseType: .mouseMoved,
        mouseCursorPosition: point, mouseButton: .left
    ) {
        event.post(tap: .cghidEventTap)
    }
    usleep(50_000)
}
if args.count >= 5 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-C", "-x", "-R",
        "\(Int(x - 210)),\(Int(y - 86)),420,260", args[4]]
    try? process.run()
    process.waitUntilExit()
}
print("held at (\(Int(x)),\(Int(y))) for \(seconds)s")
