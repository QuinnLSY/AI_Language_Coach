import AppKit
import SwiftUI

/// 「这个窗口点被浮层盖住了吗」的**唯一登记处**。
///
/// 为什么非有它不可（用户实测报障，两件事同一个根因）：
/// SwiftUI 画的浮层**不是 `NSView`**，`NSView.hitTest` 命中的是它**底下**那个 AppKit 视图 ——
/// 于是出现了两个都「看不见浮层」的消费方：
/// ① 下方文本视图的 `NSTrackingArea` 照样收到 `mouseMoved`：鼠标明明停在划词卡片上，
///    却把卡片**挡住的单词**又查了一遍（穿透；只有答案卡片这种大片压住文字的地方才看得出来）；
/// ② 光标按命中测试裁决 → 卡片上显示的仍是底下文本视图的 I 型插入符。
/// 两边的判据其实是同一句话，所以在这里统一登记、统一回答，而不是各自再猜一次几何。
///
/// ⚠️ 坐标一律 **AppKit 窗口坐标**（原点左下），与 `NSEvent.locationInWindow`、
/// `CursorPolicy` 同源 —— 这个项目已经为「想当然的坐标系」交过五轮学费（#233）。
///
/// ⚠️ 矩形是**查询时现算**的（`convert(bounds, to: nil)`），不是登记时算好存着：
/// 气泡贴着文字走，页面一滚、窗口一拉伸就移位；存快照必然过期，
/// 而过期的矩形会让「光标变箭头」和「不认划词」出现在错误的区域。
@MainActor
enum WindowOverlayOcclusion {

    private final class WeakHost {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }

    private static var hosts: [ObjectIdentifier: WeakHost] = [:]

    /// 浮层报到：它的 `bounds` 就是「被盖住」的那块（同一块浮层重复报到会覆盖）。
    static func attach(_ view: NSView) {
        hosts[ObjectIdentifier(view)] = WeakHost(view)
    }

    static func detach(_ view: NSView) {
        hosts.removeValue(forKey: ObjectIdentifier(view))
    }

    /// 这个窗口点是不是被某块浮层盖住了。
    static func covers(_ windowPoint: CGPoint, in window: NSWindow?) -> Bool {
        guard let window else { return false }
        for host in hosts.values {
            guard let view = host.view, view.window === window else { continue }
            if view.bounds.contains(view.convert(windowPoint, from: nil)) { return true }
        }
        return false
    }

    /// 已登记的浮层块数（测试 / 诊断用）。
    static var registeredCount: Int { hosts.count }

    /// 测试 / 异常恢复用。
    static func removeAll() { hosts.removeAll() }
}

// MARK: - 浮层上的隐形观察者

/// 挂在浮层上、负责「报出自己盖住了哪一块」的观察者。
///
/// 探针只需「知道自己盖在哪」，**绝不能参与任何交互**：它骑在气泡上，
/// 一旦被 AppKit 的命中测试选中，气泡那几个按钮（朗读 / 收藏 / 查词典）的点击就收不到了。
///
/// 两道闸，**各自都够用**（离屏实测，2026-09-19）：
/// - `isHidden = true`：AppKit 默认跳过隐藏视图，`hitTest` 直接穿过；
/// - 调用点的 `.allowsHitTesting(false)`：SwiftUI 侧同样把它排除在命中之外。
/// 去掉**两道一起**才会真出事 —— 那时命中链是
/// `ProbeView < AppKitPlatformViewHost<WindowOverlayOcclusionProbe> < NSHostingView`，
/// 即探针把整块浮层的点击吞了（`ScrollWheelPassthrough` 是同一条账）。
/// 全留着的代价是零，所以不挑一道省。回归测试见
/// `WindowOverlayOcclusionTests.testOcclusionProbeNeverInterceptsHitTesting`。
///
/// ⚠️ 挂载位置有硬要求：写在 `.offset(...)` **之前**。反过来的话 SwiftUI 会把它塞进
/// 被平移过的坐标系，`convert` 出来的位置和鼠标点对不上 —— 静默失效
/// （`ScrollWheelPassthrough` 已为此留过记录，这里沿用同一套写法）。
struct WindowOverlayOcclusionProbe: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ProbeView: NSView {

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // 入窗 = 浮层出现；离窗 = 浮层收起。遮罩没有「快照」，所以这里只登记 / 注销身份。
            if window == nil {
                WindowOverlayOcclusion.detach(self)
            } else {
                WindowOverlayOcclusion.attach(self)
            }
        }
    }
}

extension View {
    /// 声明「这块浮层盖住了下面」（见 `WindowOverlayOcclusion`）。
    ///
    /// ⚠️ 调用点必须在 `.offset(...)` 之前。
    ///
    /// ⚠️ `allowsHitTesting(false)` 是两道闸里的一道（另一道是探针自己的 `isHidden`）：
    /// 探针只需「知道自己盖在哪」，不需要参与任何交互 —— 它一旦被命中，卡片上那几个按钮
    /// （朗读 / 收藏 / 查词典）的点击就被吞了。离屏实测：两道一起撤掉，命中链变成
    /// `ProbeView < AppKitPlatformViewHost<WindowOverlayOcclusionProbe> < NSHostingView`，
    /// 确实会抢；任留一道都不会（见 `WindowOverlayOcclusionProbe` 的说明与对应回归测试）。
    func windowOverlayOcclusion() -> some View {
        background(WindowOverlayOcclusionProbe().allowsHitTesting(false))
    }
}
