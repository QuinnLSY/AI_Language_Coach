import SwiftUI

// #661 自 TreeCanvas.swift 拆出（2026-10-24）：原文件 2812 行、21 个类型混居，按主题分文件。
// 同模块移动，语义与拆分前完全一致；跨文件引用的成员已从 private 放宽到 internal
// （模块内可见，跨模块零影响，public API 不变）。
extension ForestGroundBand {

// MARK: 花草

/// 点草地冒一朵花（批次六 · E）：花色随机抽，上限与挤掉规则在 `GroundFlowerBed`。
func plantFlower(at x: CGFloat) {
    plantedCounter += 1
    let planted = PlantedFlower(id: plantedCounter, x: x,
                                palette: Int.random(in: 0..<3))
    withAnimation(.app(.reveal)) {
        plantedFlowers = GroundFlowerBed.push(planted, into: plantedFlowers)
    }
}

func grassBlade(x: CGFloat, h: CGFloat, w: CGFloat, seed: Int, groundLine: ForestGroundSurface) -> some View {
    // 风摆包在 `.position` **之内**：元素自身的坐标系里绕底边转（= 根部扎根在晃）。
    // 包到 position 外面就变成绕整块画布的底边转 —— 那不是草在动，是地在动。
    WindSway(x: x, height: h, gain: 0.9, rotationGain: 1.1) {
        Capsule()
            .fill(theme.foliage.opacity(0.7))
            .frame(width: w, height: h)
            .rotationEffect(.degrees(Double((pr(seed, 6) - 0.5) * 24)))
    }
    .position(x: x, y: groundLine(x) - h / 2 + 3)
}

func flower(x: CGFloat, groundLine: ForestGroundSurface, palette: Int) -> some View {
    let color: Color = palette == 0 ? Color(hex: 0xFF9BB5)
        : palette == 1 ? Color(hex: 0xFFF0B8)
        : Color(hex: 0xFFFFFF)
    return WindSway(x: x, height: 14, gain: 1.0, rotationGain: 1.3) {
        ZStack {
            ForEach(0..<5, id: \.self) { petal in
                Ellipse()
                    .fill(color)
                    .frame(width: 4.4, height: 3.0)
                    .offset(y: -3.2)
                    .rotationEffect(.degrees(Double(petal) * 72))
            }
            Circle()
                .fill(Color(hex: 0xF7B32B))
                .frame(width: 4, height: 4)
        }
    }
    .position(x: x, y: groundLine(x) - 8)
    .opacity(0.95)
}

// MARK: 灌木

func bush(x: CGFloat, groundLine: ForestGroundSurface, seed: Int) -> some View {
    let s: CGFloat = 26 + pr(seed, 13) * 14
    // 灌木最重一档（gain 0.45）：一丛叶子兜住风，风来是整丛微微欠身，
    // 不是每片叶子各晃各的 —— 与草叶（0.9）拉开「质量感」的差距。
    return WindSway(x: x, height: s, gain: 0.45, rotationGain: 0.35) {
        ZStack {
            Circle().fill(theme.foliage.opacity(0.9)).frame(width: s, height: s * 0.82)
            Circle().fill(theme.foliageDeep.opacity(0.85))
                .frame(width: s * 0.72, height: s * 0.6)
                .offset(x: s * 0.42, y: s * 0.08)
            Circle().fill(theme.foliage.opacity(0.8))
                .frame(width: s * 0.6, height: s * 0.5)
                .offset(x: -s * 0.45, y: s * 0.1)
        }
    }
    .position(x: x, y: groundLine(x) - s * 0.32)
    .opacity(0.95)
}

}


// MARK: - 点草地冒花（批次六 · E 可玩彩蛋）

/// 用户亲手点出来的一朵小花。
struct PlantedFlower: Identifiable, Equatable {
    /// 自增序号（同时当 id）。
    let id: Int
    /// 点下的横向位置（本视图坐标；渲染时钳回草地两端之内）。
    let x: CGFloat
    /// 花色（0/1/2，与既有的三色小花同一套）。
    let palette: Int
}

/// 花坛的账本（纯函数，便于单测）：只管一条规则 —— 上限之内随便长，
/// 超了挤掉**最早**那朵（地就那么大，最新的心意最要紧）。
enum GroundFlowerBed {
    /// 12 与林间空地（GladeGrowth.maxPlants）同一口径：再多就糊成噪点。
    static let cap = 12

    static func push(_ flower: PlantedFlower, into bed: [PlantedFlower]) -> [PlantedFlower] {
        var bed = bed
        bed.append(flower)
        if bed.count > cap {
            bed.removeFirst(bed.count - cap)
        }
        return bed
    }
}
