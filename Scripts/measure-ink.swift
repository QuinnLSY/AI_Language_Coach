import AppKit
import Foundation

/// 验证辅助：在截图里量出一块「和背景不一样」的区域的包围盒（点）。
///
/// 用法：
///   swift Scripts/measure-ink.swift <png> [x0 y0 x1 y1]
/// 给的是**截图像素**范围（不给就整图）。输出包围盒的像素与点尺寸。
///
/// 为什么需要它：离屏渲染量的是「声明尺寸」，实机量的是「布局之后的实际尺寸」——
/// 被父容器压缩这种事只有实机量得出来（本项目为这类「想当然」付过学费）。
let args = CommandLine.arguments
guard args.count >= 2, let image = NSImage(contentsOfFile: args[1]),
      let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff) else {
    FileHandle.standardError.write(Data("用法: measure-ink <png> [x0 y0 x1 y1]\n".utf8))
    exit(2)
}
let scale = Double(rep.pixelsWide) / image.size.width
let x0 = args.count >= 6 ? Int(args[2])! : 0
let y0 = args.count >= 6 ? Int(args[3])! : 0
let x1 = args.count >= 6 ? Int(args[4])! : rep.pixelsWide
let y1 = args.count >= 6 ? Int(args[5])! : rep.pixelsHigh

/// 背景色取区域左上角，当基准。
func color(_ x: Int, _ y: Int) -> (Int, Int, Int) {
    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return (255, 255, 255) }
    return (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
}
let background = color(x0 + 1, y0 + 1)

var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
var count = 0
for y in y0..<min(y1, rep.pixelsHigh) {
    for x in x0..<min(x1, rep.pixelsWide) {
        let c = color(x, y)
        let delta = abs(c.0 - background.0) + abs(c.1 - background.1) + abs(c.2 - background.2)
        guard delta > 24 else { continue }
        count += 1
        minX = Swift.min(minX, x); maxX = Swift.max(maxX, x)
        minY = Swift.min(minY, y); maxY = Swift.max(maxY, y)
    }
}
guard count > 0 else {
    print("区域里没有任何「和背景不同」的像素")
    exit(0)
}
print("背景 rgb=\(background)  命中像素=\(count)  scale=\(scale)")
print("像素包围盒 x[\(minX)…\(maxX)] y[\(minY)…\(maxY)]  \(maxX - minX + 1)×\(maxY - minY + 1) px")
print("折合点尺寸 \(Double(maxX - minX + 1) / scale) × \(Double(maxY - minY + 1) / scale) pt")
