import AppKit
import Foundation

/// 验证辅助：在截图的某一条横带里，逐列统计「和背景不同」的像素数。
/// 用来**精确定位**控件的左右边界（边框列会是整条带里计数最高的那几列）。
///
/// 用法： swift Scripts/col-profile.swift <png> <y0> <y1> [x0 x1]
let args = CommandLine.arguments
guard args.count >= 4, let image = NSImage(contentsOfFile: args[1]),
      let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let y0 = Int(args[2]), let y1 = Int(args[3]) else {
    FileHandle.standardError.write(Data("用法: col-profile <png> <y0> <y1> [x0 x1]\n".utf8))
    exit(2)
}
let scale = Double(rep.pixelsWide) / image.size.width
let x0 = args.count >= 6 ? Int(args[4])! : 0
let x1 = args.count >= 5 ? Int(args[5])! : rep.pixelsWide

func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return (255, 255, 255) }
    return (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
}
let background = rgb(x0 + 1, y0 - 1)

print("scale=\(scale) 背景=\(background) 带 y[\(y0)…\(y1)]")
for x in x0..<min(x1, rep.pixelsWide) {
    var count = 0
    for y in y0...min(y1, rep.pixelsHigh - 1) {
        let c = rgb(x, y)
        if abs(c.0 - background.0) + abs(c.1 - background.1) + abs(c.2 - background.2) > 24 { count += 1 }
    }
    // 只打印有内容的列，附带它离屏幕左边的点坐标，便于直接对照。
    if count > 0 { print("x=\(x) (pt \(Double(x) / scale)) 列内命中=\(count)") }
}
