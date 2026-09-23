import SwiftUI

/// 出现方式本体（泛型类型不能挂静态存储属性，单独放）。
/// 测试断言的就是这个语义（中途帧上内容不越过它的上边缘）。
public enum DisclosureBlockAppearance {
    public static var transition: AnyTransition { .opacity }
}

/// 记录页「展开块」的出现方式（复盘正文 / 空提示都从这里出现）。
///
/// ⚠️ 只淡入、**不位移**：原来用 `.move(edge: .top)`，它的位移量等于内容自身
/// 高度 —— 复盘很高时整块会从**别的卡片上方**滑进来，动画期间溢出自己的
/// 卡片边界，用户看到的就是「复盘内容穿透了卡片、从对话记录顶部冒出来」（#2）。
/// 淡入是原地出现：从哪一条点开，就从哪一条下面出现。
///
/// 独立成组件是因为这个「方式」要能被离屏渲染钉住
/// （`RecordsDisclosureRenderTests` 抓动画中途的那一帧来断言）。
struct DisclosureBlock<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .transition(DisclosureBlockAppearance.transition)
    }
}
