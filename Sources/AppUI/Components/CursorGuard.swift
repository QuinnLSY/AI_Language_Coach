import AppKit

// MARK: - 光标偏好

/// 视图可以自己声明「我这里该是什么光标」（优先于命中链上的其它规则）。
///
/// 用途：像自绘弹菜单命中区这种**用矩形声明过光标**的组件，改走命中链后
/// 由本协议把口径接回来，不必再依赖 `addCursorRect`。
@MainActor
protocol CursorPreferenceProviding: AnyObject {
    var desiredCursor: NSCursor { get }
}

// MARK: - 光标策略

/// 全窗口唯一的**光标裁决点**。
///
/// 为什么必须集中裁决（#233 四轮的血泪）：
/// `NSTextView` 默认给自己挂 I 型光标矩形，而 AppKit 在窗口级解析这些矩形时
/// **完全不理会视图遮挡** —— 划词气泡是 SwiftUI 浮层（不是 NSView），它悬在正文上方，
/// 光标却仍由底下正文文本视图的矩形决定：卡片上永远是插入符。
/// 在卡片里垫箭头矩形也没用：**兄弟视图不在 `cursorUpdate` 的响应链上**，
/// 命中链只沿祖先走（四轮实测无效）。
///
/// 因此口径改为「**命中谁，谁说话**」：命中测试天然自顶向下、尊重遮挡 ——
/// 鼠标在卡片上命中的就是卡片，在正文上命中的就是正文文本视图。
/// 裁决结果由 `CursorGuard` 在事件监视器里落到真实光标上。
@MainActor
enum CursorPolicy {

    /// 显式接管中（分裂条拖拽等系统光标）：策略不插手。
    private static var suspensionDepth = 0
    static var isSuspended: Bool { suspensionDepth > 0 }

    /// 进入显式接管。调用方负责配对 `resume()`（`onHover` 的进 / 出各一次）。
    static func suspend() { suspensionDepth += 1 }
    static func resume() { suspensionDepth = max(0, suspensionDepth - 1) }

    /// 上一次落下去的光标（同值不重复 set，避免无谓的光标刷新）。
    private static var lastApplied: NSCursor?

    /// 按命中视图决定光标（纯函数，可单测）。
    ///
    /// 规则自上而下：
    /// 1. 命中链上有人声明了偏好（弹菜单命中区）→ 听它的；
    /// 2. 划词文本视图 → 看它自己的开关（正文 I 型，其余箭头）；
    /// 3. 其它 `NSTextView` / `NSTextField`（输入框、富文本编辑器）→ I 型；
    /// 4. 其余（按钮、卡片、浮层、图形）→ 箭头。
    static func cursor(forHitView hitView: NSView?) -> NSCursor {
        var view: NSView? = hitView
        while let current = view {
            if let preference = current as? CursorPreferenceProviding {
                return preference.desiredCursor
            }
            if let lookup = current as? WordLookupTextView {
                return lookup.showsIBeamCursor ? .iBeam : .arrow
            }
            if current is NSTextView || current is NSTextField {
                return .iBeam
            }
            view = current.superview
        }
        return .arrow
    }

    /// 命中测试（把「窗口点」换算成 `hitTest` 真正要的那个坐标系的点）。
    ///
    /// ⚠️⚠️ 这是 #233 连修五轮都没生效的**真根因**：
    /// `NSView.hitTest(_:)` 的入参是**父视图的坐标系**，不是自己的 —— 与 UIKit 的
    /// `UIView.hitTest(_:with:)`（自己的坐标系）**恰好相反**，极易想当然写错。
    /// SwiftUI 的宿主内容视图是 flipped（y 从上往下），而它的父视图 `NSThemeFrame`
    /// 不是 —— 于是把「内容视图自身坐标」直接喂进 `hitTest` 会得到**沿竖直中线镜像**
    /// 的那个点：鼠标在题干上，命中的却是正文。表现就是「光标全靠运气」。
    /// 修正：先把窗口点换算到内容视图**父视图**的坐标系，再交 `hitTest`。
    static func hitTest(in content: NSView, atWindowPoint point: CGPoint) -> NSView? {
        // `from: nil` = 从窗口坐标换算。
        let inSuperview = content.superview?.convert(point, from: nil) ?? point
        return content.hitTest(inSuperview)
    }

    /// 最终裁决：**浮层优先**，其次才是命中视图。
    ///
    /// ⚠️ 为什么不能只靠命中测试：SwiftUI 画的浮层不是 `NSView`，
    /// `hitTest` 命中的是它**底下**那个视图 —— 划词卡片骑在正文上时，命中的是正文，
    /// 于是卡片上显示底下的 I 型插入符（用户实测报障）。有没有浮层压着只能问浮层自己
    /// （`WindowOverlayOcclusion`）。
    static func resolvedCursor(
        forHitView hitView: NSView?,
        windowPoint: CGPoint,
        in window: NSWindow?
    ) -> NSCursor {
        if WindowOverlayOcclusion.covers(windowPoint, in: window) { return .arrow }
        return cursor(forHitView: hitView)
    }

    /// 鼠标在窗口里动了 → 按策略落光标。
    static func apply(in window: NSWindow, atWindowPoint point: CGPoint, force: Bool = false) {
        guard !isSuspended else { return }
        guard let content = window.contentView else { return }
        let hit = hitTest(in: content, atWindowPoint: point)
        let wanted = resolvedCursor(forHitView: hit, windowPoint: point, in: window)
        // ⚠️ `force`：窗口自己也会按光标矩形表落一次光标（而且发生在本函数**之后**），
        // 所以要容许「对同一个点再落一次」，把那一次盖回去。
        guard force || lastApplied !== wanted else { return }
        lastApplied = wanted
        wanted.set()
    }

    /// 测试 / 异常恢复用：忘掉「上次落下的光标」，下一次一定会重新 set。
    static func resetAppliedMemory() { lastApplied = nil }
}

// MARK: - 事件监视器

/// 把 `CursorPolicy` 接到真实鼠标事件上。
///
/// ⚠️ 必须吞掉 `.cursorUpdate`：本地监视器跑在窗口派发**之前**，
/// 若放行，AppKit 随后仍会按自己的光标矩形把插入符盖回来（这正是前几轮
/// 「改了半天没生效」的最后一道坎）。吞掉之后，光标只由本策略说话。
/// `.mouseMoved` 放行（悬停划词、光标跟随都要它）。
@MainActor
final class CursorGuard {

    static let shared = CursorGuard()

    private var monitor: Any?
    /// 已经排了一次「事后补落」，避免鼠标每动一帧就堆一个任务。
    private var reapplyScheduled = false

    private init() {}

    /// 装监视器（幂等；`MainView` 启动钩子调用）。
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.cursorUpdate, .mouseMoved]) { [weak self] event in
            guard let window = event.window, window.contentView != nil else { return event }
            // ⚠️ 传**窗口坐标**（`locationInWindow`）而不是内容视图坐标：
            // `hitTest` 要的是内容视图父视图的坐标系，换算在 `CursorPolicy` 里统一做。
            CursorPolicy.apply(in: window, atWindowPoint: event.locationInWindow)
            self?.scheduleReapply(in: window, at: event.locationInWindow)
            // 光标更新事件一律吞掉：放行就等于把光标交还给 AppKit 的矩形表。
            return event.type == .cursorUpdate ? nil : event
        }
    }

    /// 窗口处理完这次移动（可能按矩形表落了光标）之后，再落一次我们的裁决。
    private func scheduleReapply(in window: NSWindow, at point: CGPoint) {
        guard !reapplyScheduled else { return }
        reapplyScheduled = true
        DispatchQueue.main.async { [weak self, weak window] in
            self?.reapplyScheduled = false
            guard let window else { return }
            CursorPolicy.apply(in: window, atWindowPoint: point, force: true)
        }
    }

    /// 拆监视器（测试用）。
    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
