import SwiftUI

// #661 自 TreeCanvas.swift 拆出（2026-10-24）：原文件 2812 行、21 个类型混居，按主题分文件。
// 同模块移动，语义与拆分前完全一致；跨文件引用的成员已从 private 放宽到 internal
// （模块内可见，跨模块零影响，public API 不变）。
// MARK: - 事件落叶层（收词 / 练完 / 通关的树叶回应）

/// 一片正在飘落的叶子（模型与视图分离：模型可测、视图自己演）。
struct FallLeaf: Identifiable, Equatable {
    let id: Int
    /// 起点横向位置（画布宽度的比例）。
    let x: Double
    /// 起点纵向位置（画布坐标：树冠区域）。
    let startY: Double
    /// 全程横向漂移（pt）。
    let drift: Double
    /// 飘落时长（秒）。
    let duration: Double
    /// 叶长（pt）。
    let size: Double
    /// 全程自旋（度）。
    let spin: Double
}

/// 学习事件的树叶回应层：收词飘一片、练完一小阵、通关缤纷。
/// 纯装饰：不挡点击；`reduceMotion` 下一片都不生成（静止即安静）。
struct LeafFallLayer: View {
    let theme: ForestTheme
    var wordTick: Int = 0
    var practiceTick: Int = 0
    var ceremonyTick: Int = 0
    /// 点天空的可玩回应（批次六 · E）：两片，比收词多一点、比练完少一截。
    var skyTick: Int = 0
    /// 首次进入欢迎（批次八 · H）：四片，像树也挥了挥手。
    var welcomeTick: Int = 0

    @State private var leaves: [FallLeaf] = []
    @State private var counter = 0
    @Environment(\.appMotion) private var motion

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                ForEach(leaves) { leaf in
                    FallingLeafView(leaf: leaf, theme: theme, width: proxy.size.width)
                }
            }
        }
        .allowsHitTesting(false)
        // 纯装饰的落叶：读屏不该读到「一片飘着的叶子」。
        .accessibilityHidden(true)
        .onChange(of: wordTick) { _, tick in guard tick > 0 else { return }; spawn(1) }
        .onChange(of: practiceTick) { _, tick in guard tick > 0 else { return }; spawn(4) }
        .onChange(of: ceremonyTick) { _, tick in guard tick > 0 else { return }; spawn(12) }
        .onChange(of: skyTick) { _, tick in guard tick > 0 else { return }; spawn(2) }
        .onChange(of: welcomeTick) { _, tick in guard tick > 0 else { return }; spawn(4) }
    }

    /// 按脉冲生成 n 片叶子；每片自持生命周期（飘完自摘，父级无常驻计时器）。
    private func spawn(_ n: Int) {
        guard !motion.reduceMotion else { return }
        for _ in 0..<n {
            counter += 1
            let leaf = FallLeaf(
                id: counter,
                x: Double.random(in: 0.22...0.78),
                startY: Double.random(in: 90...250),
                drift: Double.random(in: -60...60),
                duration: Double.random(in: 2.2...3.4),
                size: Double.random(in: 10...15),
                spin: Double.random(in: -140...140)
            )
            leaves.append(leaf)
            let id = leaf.id
            let life = leaf.duration
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(life + 0.4))
                leaves.removeAll { $0.id == id }
            }
        }
    }
}

private struct FallingLeafView: View {
    let leaf: FallLeaf
    let theme: ForestTheme
    let width: CGFloat

    @State private var started = false

    var body: some View {
        LeafShape()
            // 季节说话的地方：秋天飘金叶、冬天飘雪花（同一套飘落动画换个颜色）
            .fill(theme.fallingFlake.opacity(0.9))
            .frame(width: leaf.size, height: leaf.size * 0.55)
            .rotationEffect(.degrees(started ? leaf.spin : 0))
            .position(
                x: width * leaf.x + (started ? leaf.drift : 0),
                y: leaf.startY + (started ? 620 : 0)
            )
            .opacity(started ? 0 : 0.95)
            .onAppear {
                withAnimation(.easeIn(duration: leaf.duration)) { started = true }
            }
    }
}

// MARK: - 通关烟花层

/// 通关烟花：`tick` 变化时放一次（约 3 秒后自动收），平时零开销。
/// 与黑板的烟花同一组件——那套是一次性动画，离屏渲染取得到稳定帧。
struct CeremonyFireworksLayer: View {
    let theme: ForestTheme
    var tick: Int = 0

    @State private var visible = false

    var body: some View {
        ZStack {
            if visible {
                CelebrationFireworks(tint: theme.accent, secondary: theme.glow)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .task(id: tick) {
            guard tick > 0 else { return }
            withAnimation(.app(.reveal)) { visible = true }
            try? await Task.sleep(for: .seconds(3.2))
            guard !Task.isCancelled else { return }
            withAnimation(.app(.reveal)) { visible = false }
        }
    }
}

