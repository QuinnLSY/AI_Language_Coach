import AppKit
import SwiftUI

// MARK: - 判据（纯函数）

/// 「这一滚该交给哪个滚动视图」的规则。
///
/// 抽成纯函数，是因为它有一条很容易写错、错了又不易察觉的偏好：
/// **先要「能纵向滚」，再要「最深」**。气泡盖住的那个点下面往往同时压着两三个滚动容器 ——
/// 外层的纵向滚动区，里层只会横向滚的条（词典页的推荐词、聊天里横向排的 chip）。
/// 只按「最深」挑，就会把一次纵向滚轮丢给横向容器：**表现和「滚不动」一模一样**。
public enum ScrollWheelRouting {

    /// - Parameters:
    ///   - contains: 每个候选的可视区域是否盖住鼠标点
    ///   - scrollsVertically: 候选的内容是否比视口高（即它真的能纵向滚）
    ///   - depth: 候选在视图树里的层级，越深越「里面」
    /// - Returns: 该把滚轮交给哪个候选；返回 `nil` 表示**不要介入** ——
    ///   一个能纵向滚的目标都没有时，事件原样放行，免得把别人的滚动也吃掉。
    public static func bestIndex(
        contains: [Bool], scrollsVertically: [Bool], depth: [Int]
    ) -> Int? {
        var best: Int?
        for index in contains.indices {
            guard contains[index], scrollsVertically[index] else { continue }
            if best == nil || depth[index] > depth[best!] { best = index }
        }
        return best
    }
}

// MARK: - 浮层

/// 让「浮在上层的小卡片」下面的滚动区仍然能被滚轮滚到。
///
/// **为什么非做不可（用户实测报障）**：鼠标停在划词气泡上时，页面怎么滚都不动，只能先把鼠标挪开。
/// 根因不在 zIndex：气泡是挂在聊天列**顶层**的兄弟浮层 —— 它不在 `ScrollView` 里面
/// （句内 overlay 会被滚动容器裁掉，见 `WordLookupBubbleOverlay` 的说明）。
/// 于是滚轮事件落到浮层上就被消化掉了，**事件压根没往下走**，`ScrollView` 收不到。
///
/// 做法：给浮层挂一道 `scrollWheel` 的本地监视器 —— 只有当鼠标确实落在这块卡片范围内时，
/// 才把事件转交给它下方**能纵向滚**的那个 `NSScrollView`，并把事件吞掉（不吞会滚两次）。
/// 鼠标不在卡片上时一律放行，不碰任何东西。
///
/// ⚠️ **挂载位置有硬要求**：必须写在 `.offset(...)` **之前** ——
/// `<卡片>.background(ScrollWheelPassthrough()).offset(...)`。
/// 反过来（先 offset 再 background）时，SwiftUI 会把这个背景视图塞进被平移过的坐标系里，
/// 它 `convert(_:from:)` 出来的位置和鼠标点对不上，判据永远不成立 —— **转发静默失效**。
/// 这一条是实机实验测出来的（先 offset 的版本按下滚轮毫无反应）。
///
/// ⚠️ 视图本身 `isHidden = true`：它只是个「知道自己盖在哪」的观察者，
/// 不参与命中测试，否则会把卡片上那几个按钮的点击抢走。
struct ScrollWheelPassthrough: NSViewRepresentable {

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // 视图真正入窗发生在 `makeNSView` 返回之后，所以这里再试一次（幂等）。
        context.coordinator.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {

        /// 卡片所在的那块视图：靠它把鼠标点换算成「在不在卡片上」。
        private weak var view: NSView?
        private var monitor: Any?
        /// 视图已经拆掉（气泡收起）后不要再装监视器：`attach` 是延迟一轮才执行的。
        private var isDetached = false

        func attach(to view: NSView) {
            self.view = view
            guard monitor == nil, !isDetached else { return }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                guard !self.isDetached, self.monitor == nil, view.window != nil else { return }
                self.monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                    self?.handle(event) ?? event
                }
            }
        }

        func detach() {
            isDetached = true
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            view = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard event.type == .scrollWheel, let view, let window = view.window,
                  event.window === window else { return event }
            return route(event, at: event.locationInWindow, from: view) ? nil : event
        }

        /// 收点版本的核心判据。单独把窗口点显式传进来，是为了能在测试里精确指定「鼠标在哪」，
        /// 不必去造一个位置正确的合成事件。
        private func route(_ event: NSEvent, at windowPoint: NSPoint, from view: NSView) -> Bool {
            guard view.bounds.contains(view.convert(windowPoint, from: nil)) else { return false }
            guard let target = Self.scrollTarget(at: windowPoint, in: view.window) else { return false }
            target.scrollWheel(with: event)
            return true
        }

        /// 找到鼠标点下方那个**能纵向滚**的滚动视图（有多个就取最深的）。
        static func scrollTarget(at windowPoint: NSPoint, in window: NSWindow?) -> NSScrollView? {
            guard let root = window?.contentView else { return nil }
            var candidates: [NSScrollView] = []
            var contains: [Bool] = []
            var scrollsVertically: [Bool] = []
            var depth: [Int] = []

            func walk(_ node: NSView, _ level: Int) {
                if let scroll = node as? NSScrollView, node.window === window,
                   !scroll.isHidden, scroll.alphaValue > 0.01 {
                    let viewport = scroll.contentView.bounds.height
                    let content = scroll.documentView?.frame.height ?? 0
                    candidates.append(scroll)
                    contains.append(scroll.bounds.contains(scroll.convert(windowPoint, from: nil)))
                    scrollsVertically.append(content > viewport + 1)
                    depth.append(level)
                }
                for child in node.subviews { walk(child, level + 1) }
            }
            walk(root, 0)

            guard let index = ScrollWheelRouting.bestIndex(
                contains: contains, scrollsVertically: scrollsVertically, depth: depth
            ) else { return nil }
            return candidates[index]
        }
    }
}

extension View {
    /// 让这块浮层下面的滚动区在鼠标停在它上面时也能被滚轮滚到（详见 `ScrollWheelPassthrough`）。
    ///
    /// ⚠️ 调用点必须在 `.offset(...)` 之前。
    func scrollWheelPassthrough() -> some View {
        background(ScrollWheelPassthrough().allowsHitTesting(false))
    }
}
