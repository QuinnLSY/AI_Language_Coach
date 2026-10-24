import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 换季**交叉淡入淡出**的离屏渲染回归（#636）。
///
/// 判据不是「有没有画出来」，而是**换季中途那一帧既不等于换季前、也不等于换季后**
/// —— 只有真的在插值，才会存在这样的中间帧。瞬间跳变的画面里，中途帧
/// 必然与终帧逐像素相同（反证：删掉 `.appAnimation(.scene, value:)` →
/// 红在「中途已经是终态」那一条）。
///
/// 两个探针各管一半：
/// - 配色（山丘）：证明**颜色**在渐变，不是被替换；
/// - 装饰层（风筝 ↔ 雁阵）：证明 `if` 分支里的组件在淡入淡出，不是凭空插拔。
@MainActor
final class ForestSeasonFadeRenderTests: XCTestCase {

    private var window: NSWindow?
    private let canvas = CGSize(width: 420, height: 360)

    private struct Render {
        var rep: NSBitmapImageRep
        var scale: CGFloat
    }

    /// 季节由**外部**换：`@State` 在视图里、外面改不动，也就定不住取帧的时刻。
    /// ⚠️ 不能标 `private`：`@Observable` 展开出的 `extension …: Observable` 在文件域，
    /// 私有嵌套类型在那里不可见（编译期就红，不是运行期才炸）。
    @Observable
    final class SeasonBox {
        var season: ForestSeason?
        init(season: ForestSeason?) { self.season = season }
    }

    /// 配色探针：整块画布就是山丘那一档色（`hillNear` 按季换）。
    private struct ColorProbe: View {
        let box: SeasonBox
        var body: some View {
            Rectangle()
                .fill(ForestTheme(palette: .day, season: box.season).hillNear)
                // ⚠️ 与 `MainView` 根上那一行是同一条接线。
                //
                // 已实测的反证：注掉这一行 → 本条红在「中途已经是终态」（实测 0/10000）。
                .appAnimation(.scene, value: box.season)
                .frame(width: 420, height: 360)
        }
    }

    /// 装饰层探针：春天风筝 ↔ 秋天雁阵，`still: true`（冻结档，两帧可比）。
    private struct LayerProbe: View {
        let box: SeasonBox
        var body: some View {
            ZStack {
                Color.white
                if box.season == .spring {
                    ForestKites(theme: ForestTheme(palette: .day, season: .spring), still: true)
                        .seasonFade()
                }
                if box.season == .autumn {
                    ForestSeasonBirds(
                        theme: ForestTheme(palette: .day, season: .autumn),
                        kind: .goose, still: true, windowHeight: 360
                    )
                        .seasonFade()
                }
            }
            //
            // 已实测的反证：注掉这一行 → 装饰层那条红在「中途已经是终态」（实测 0/60）
            // —— 分支的插拔不落在带动画的事务里，`.seasonFade()` 就只是一句空话。
            .appAnimation(.scene, value: box.season)
            .frame(width: 420, height: 360)
        }
    }

    private func host(_ view: some View) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(origin: .zero, size: canvas)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        return host
    }

    private func pump(_ seconds: Double) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func capture(_ host: NSHostingView<AnyView>) throws -> Render {
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return Render(rep: rep, scale: CGFloat(rep.pixelsHigh) / max(canvas.height, 1))
    }

    /// 换季前 / 中途 / 换季后三帧。中途取在 0.45s（`.scene` 是 0.9s，
    /// 两头慢的 easeInOut 此刻大约在四成）。
    private func frames(_ view: some View, box: SeasonBox, flipTo: ForestSeason) throws ->
        (before: Render, mid: Render, after: Render) {
        let host = self.host(view)
        pump(0.15)
        let before = try capture(host)
        box.season = flipTo
        pump(0.45)
        let mid = try capture(host)
        pump(1.2)
        let after = try capture(host)
        return (before, mid, after)
    }

    /// 两帧之间的不同像素个数（换算回点）。
    private func differencePoints(_ lhs: Render, _ rhs: Render) -> Int {
        guard let a = lhs.rep.bitmapData, let b = rhs.rep.bitmapData else { return 0 }
        let width = min(lhs.rep.pixelsWide, rhs.rep.pixelsWide)
        let height = min(lhs.rep.pixelsHigh, rhs.rep.pixelsHigh)
        let scale = lhs.scale
        var count = 0
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                if abs(Int(a[o]) - Int(b[o])) > 8
                    || abs(Int(a[o + 1]) - Int(b[o + 1])) > 8
                    || abs(Int(a[o + 2]) - Int(b[o + 2])) > 8 {
                    count += 1
                }
            }
        }
        return Int(Double(count) / (scale * scale))
    }

    // MARK: - 配色渐变

    /// 山丘的颜色**在渐变**：中途那一帧既不是春绿也不是秋黄。
    ///
    /// 反证（已实测）：把 `.appAnimation(.scene, value:)` 删掉 → 中途帧等于终帧
    /// （实测 diff = 0）→ 红在第三条。
    func testHillColorInterpolatesAcrossTheSeasonSwitch() throws {
        let box = SeasonBox(season: .spring)
        let frames = try self.frames(ColorProbe(box: box), box: box, flipTo: .autumn)
        XCTAssertGreaterThan(differencePoints(frames.before, frames.after), 10_000,
                             "换季后画面没变（季节没接上或配色根本没换）")
        XCTAssertGreaterThan(differencePoints(frames.mid, frames.before), 10_000,
                             "换季中途画面还停在换季前（动画没起步）")
        XCTAssertGreaterThan(differencePoints(frames.mid, frames.after), 10_000,
                             "换季中途画面已经是终态 —— 颜色是瞬间跳变，不是渐变")
    }

    // MARK: - 装饰层交替

    /// 风筝 ↔ 雁阵**淡入淡出**：中途那一帧两层都在（各半透明）。
    ///
    /// 反证（已实测）：删掉探针里的 `.appAnimation(.scene, value:)` → 中途帧等于终帧
    /// （实测 diff = 0）→ 红在第三条。
    ///
    /// ⚠️ **只删两处 `.seasonFade()` 不会红** —— SwiftUI 的默认过渡本来就是
    /// `.opacity`（实测去掉后本条仍绿）。所以这一条钉的是「换季确实在渐变」，
    /// `.seasonFade()` 的价值是把「只淡不挪」这件事**写出来**（将来谁给它加了
    /// `.transition(.scale)`，接线哨兵会红）。
    func testSeasonLayersCrossFadeInsteadOfPoppingInAndOut() throws {
        let box = SeasonBox(season: .spring)
        let frames = try self.frames(LayerProbe(box: box), box: box, flipTo: .autumn)
        XCTAssertGreaterThan(differencePoints(frames.before, frames.after), 60,
                             "换季后画面没变（风筝 / 雁阵没接上）")
        XCTAssertGreaterThan(differencePoints(frames.mid, frames.before), 60,
                             "换季中途画面还停在换季前（过渡没起步）")
        XCTAssertGreaterThan(differencePoints(frames.mid, frames.after), 60,
                             "换季中途画面已经是终态 —— 装饰层是凭空插拔，不是淡入淡出")
    }

    // MARK: - 减弱动态效果

    /// 「减弱动态效果」下换季**不拖 0.9s**：0.45s 时已经换完了（退化成 0.12s 的一小段）。
    ///
    /// ⚠️ 单独看这条**不构成判据**（把动画整个删掉它也是绿的 —— 那时中途当然等于
    /// 终帧）。它钉的是与上一条的**对照**：同一个 0.45s，常规档还在变（上一条红不了）、
    /// 减弱档已经变完。把 `.appAnimation(.scene, …)` 换成写死的
    /// `.easeInOut(duration: 0.9)` 时，上一条绿、这一条红 —— 档位没接上会当场现形。
    func testReducedMotionSkipsTheLongCrossfade() throws {
        let box = SeasonBox(season: .spring)
        let probe = ColorProbe(box: box)
            .environment(\.appMotion, AppMotionDescriptor(reduceMotion: true))
        let frames = try self.frames(probe, box: box, flipTo: .autumn)
        XCTAssertGreaterThan(differencePoints(frames.before, frames.after), 10_000,
                             "减弱动态效果下换季照样要换（关动效 ≠ 关内容）")
        XCTAssertEqual(differencePoints(frames.mid, frames.after), 0,
                       "减弱动态效果下还在走 0.9s 的长渐变 —— 档位没接上")
    }
}
