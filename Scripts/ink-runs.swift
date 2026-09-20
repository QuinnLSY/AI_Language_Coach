import AppKit
import Foundation

/// 验证辅助：把截图某条横带里「有内容」的列**按连续段**打出来。
/// 用来无歧义地量出控件宽度（不必靠肉眼对像素）。
///
/// 用法： swift Scripts/ink-runs.swift <png> <y0> <y1> [threshold]
let args = CommandLine.arguments
guard args.count >= 4, let image = NSImage(contentsOfFile: args[1]),
      let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let y0 = Int(args[2]), let y1 = Int(args[3]) else {
    FileHandle.standardError.write(Data("用法: ink-runs <png> <y0> <y1> [threshold]\n".utf8))
    exit(2)
}
let threshold = args.count >= 5 ? Int(args[4])! : 24
let scale = Double(rep.pixelsWide) / image.size.width

func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return (255, 255, 255) }
    return (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
}

// 背景取整条带里出现最多的颜色（众数）——比取某个角更稳。
var tally: [String: Int] = [:]
for y in y0...min(y1, rep.pixelsHigh - 1) {
    for x in 0..<rep.pixelsWide {
        let c = rgb(x, y)
        tally["\(c.0),\(c.1),\(c.2)", default: 0] += 1
    }
}
let mode = tally.max { $0.value < $1.value }?.key ?? "255,255,255"
let parts = mode.split(separator: ",").map { Int($0)! }
print("scale=\(scale) 带内众数色=\(mode)  带 y[\(y0)…\(y1)]")

var runs: [(Int, Int)] = []
var start: Int?
for x in 0..<rep.pixelsWide {
    var hit = false
    for y in y0...min(y1, rep.pixelsHigh - 1) {
        let c = rgb(x, y)
        if abs(c.0 - parts[0]) + abs(c.1 - parts[1]) + abs(c.2 - parts[2]) > threshold { hit = true; break }
    }
    if hit, start == nil { start = x }
    if !hit, let s = start { runs.append((s, x - 1)); start = nil }
}
if let s = start { runs.append((s, rep.pixelsWide - 1)) }

for (s, e) in runs where e - s >= 1 {
    print("段 px[\(s)…\(e)]  宽 \(e - s + 1)px = \(Double(e - s + 1) / scale) pt")
}
