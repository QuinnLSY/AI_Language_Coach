import AppKit
import SwiftUI

// MARK: - 动效 token

/// 全应用统一的动效节奏（2026-09-25 第一批）。
///
/// **为什么要有这一层**：改之前全项目散着 15+ 种 `.spring(response:dampingFraction:)`
/// 和十几种 `.easeOut(duration:)`（0.1 / 0.12 / 0.14 / 0.16 / 0.18 / 0.2 / 0.22 / 0.25…），
/// 同一类动作在不同页面用不同曲线。结果就是同一个 macOS 应用里「有的地方按下去
/// 有反应、有的没有」—— 这是廉价感最主要的来源，而它与功能毫无关系，纯粹缺一层约定。
///
/// **分档依据是动作的语义，不是页面**：`press` 给所有即时回应，`reveal` 给所有
/// 出现消失，`panel` 给所有位移，`emphasis` 是唯一允许过冲的一档。
/// 同语义必须同曲线，否则视觉上仍然是「各页面各自为政」。
public enum AppMotion: String, CaseIterable, Sendable {

    /// 按压 / 悬停这类即时回应。慢一点点就变成「卡」，所以必须 ≤150ms。
    case press
    /// 卡片 / 浮层 / 提示条的出现与消失。
    case reveal
    /// 面板推进、侧栏收展这类**位移**。允许一点点回弹，但不能晃。
    case panel
    /// 成功 / 里程碑这类需要被看见的时刻。全项目唯一允许过冲的一档。
    case emphasis

    /// 名义时长（秒）。两个用途：
    /// ① reduceMotion 下用它当退化后的上界；
    /// ② **离屏渲染回归要「等动画走完」再取像素**（见技能 macos-ui-verify），
    /// 有了统一上界，用例就不必各自猜某一处动画到底多长。
    public var nominalDuration: Double {
        switch self {
        case .press: 0.12
        case .reveal: 0.22
        case .panel: 0.36
        case .emphasis: 0.55
        }
    }

    /// 常规曲线。走确切时长用 `easeOut`，走位移用 `spring` —— 位移用 easeOut
    /// 会显得「滑过去然后钉住」，缺少落位的实感。
    public var animation: Animation {
        switch self {
        case .press: .easeOut(duration: 0.12)
        case .reveal: .easeOut(duration: 0.22)
        case .panel: .spring(response: 0.32, dampingFraction: 0.86)
        case .emphasis: .spring(response: 0.5, dampingFraction: 0.66)
        }
    }

    /// 「减弱动态效果」开启后的曲线。位移类尤其要退化：系统偏好的语义是
    /// 「别让我看到东西飞来飞去」，不是「让它快一点」。
    public var reducedAnimation: Animation { .linear(duration: 0.12) }
}

/// 本次会话生效的动效档位，由环境注入（见 `.appMotionRoot()`）。
///
/// 为什么不直接各处读 `@Environment(\.accessibilityReduceMotion)`：那样每个
/// 调用点都得自己写一遍 `reduced ? A : B` 的三元表达式，早晚会漏一处。
/// 收成一份描述式实体，调用点只会写 `motion.animation(.reveal)`。
public struct AppMotionDescriptor: Sendable, Equatable {

    public var reduceMotion: Bool
    public var reduceTransparency: Bool

    public init(reduceMotion: Bool = false, reduceTransparency: Bool = false) {
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
    }

    /// 默认档（没注入环境时也是它 —— 保证任何时候都有一条确定的曲线）。
    public static let standard = AppMotionDescriptor()

    /// 某档动画在当前系统偏好下真正该用的曲线。
    public func animation(_ token: AppMotion) -> Animation {
        reduceMotion ? token.reducedAnimation : token.animation
    }

    /// 某档动画在当前系统偏好下的名义时长。
    public func duration(_ token: AppMotion) -> Double {
        reduceMotion ? min(token.nominalDuration, 0.12) : token.nominalDuration
    }

    /// 从**系统偏好**直接读档，不走 SwiftUI 环境。
    ///
    /// 给 `@Observable` class 用（例如 `AppState` 里的 `withAnimation`）：那里读不到
    /// `@Environment`，可它照样得跟着「减弱动态效果」走 —— 少了这条路，浮层的
    /// 出场动画就成了系统偏好的法外之地。
    ///
    /// ⚠️ View 内部请继续用环境那份：环境会**实时**响应偏好变化，而这一份只是
    /// 调用那一刻的快照（测试里注入的假档位也只对环境那份有效）。
    public static func current() -> AppMotionDescriptor {
        AppMotionDescriptor(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        )
    }

    /// 常驻循环动画（星星闪烁、树叶摇曳、丝带飘）。
    ///
    /// 为什么单独一条岔路：这些动画平时是「氛围」，一旦用户开了「减弱动态效果」，
    /// 它们就成了**持续不断的运动干扰**，而且它们还会和流式打字抢主线程
    /// （2026-09-25 掉帧预算：树摇曳 + 长列表滚动 + 流式输出三者并发）。
    ///
    /// reduceMotion 打开时返回 `nil` —— 值会直接跳到终值然后静止，
    /// 使用者不必再写一遍判断。
    public func loopAnimation(_ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }
}

private struct AppMotionDescriptorKey: EnvironmentKey {
    static let defaultValue: AppMotionDescriptor = .standard
}

public extension EnvironmentValues {

    /// 当前生效的动效档位。要用**.appMotionRoot() 在根上注入一次**才会跟着系统偏好变。
    var appMotion: AppMotionDescriptor {
        get { self[AppMotionDescriptorKey.self] }
        set { self[AppMotionDescriptorKey.self] = newValue }
    }
}

// MARK: - View 便捷入口

public extension View {

    /// 在**应用根注入一次**：读系统的「减弱动态效果 / 降低透明度」偏好，
    /// 让整棵子树所有 token 自动退化。
    ///
    /// ⚠️ Sheet / popover 挂在视图树的另一条分支上，根上注入不一定传得过去 ——
    /// 覆盖不到的地方要各自再写一次。忘了写不会报错，只会静默退回到默认档，
    /// 所以每次加 sheet 都要过一眼这里。
    func appMotionRoot() -> some View { modifier(AppMotionRootModifier()) }

    /// token 版的 `.animation(_:value:)`。
    func appAnimation<V: Equatable>(_ token: AppMotion, value: V) -> some View {
        modifier(AppMotionAnimationModifier(token: token, value: value))
    }

    /// 常驻循环动画版（`.repeatForever` 那几支）：「减弱动态效果」打开时整段失效，
    /// 画面静止。调用方不必自己写一遍 `reduceMotion ? nil : xxx`。
    func loopAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(AppMotionLoopModifier(animation: animation, value: value))
    }
}

private struct AppMotionRootModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.environment(
            \.appMotion,
            AppMotionDescriptor(
                reduceMotion: reduceMotion,
                reduceTransparency: reduceTransparency
            )
        )
    }
}

private struct AppMotionAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.appMotion) private var motion
    let token: AppMotion
    let value: V

    func body(content: Content) -> some View {
        content.animation(motion.animation(token), value: value)
    }
}

private struct AppMotionLoopModifier<V: Equatable>: ViewModifier {
    @Environment(\.appMotion) private var motion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(motion.loopAnimation(animation), value: value)
    }
}

// MARK: - 非 View 上下文

public extension Animation {

    /// token 版动画：`withAnimation(.app(.reveal)) { ... }`。
    ///
    /// 与 ViewModifier 那条路的区别：它每次调用都直接查系统偏好，所以 `@Observable`
    /// class 里也能用。**View 里优先用环境那份**（`.appAnimation(_:value:)`），
    /// 那份能被测试注入假档位，这一份不能。
    static func app(_ token: AppMotion) -> Animation {
        AppMotionDescriptor.current().animation(token)
    }
}
