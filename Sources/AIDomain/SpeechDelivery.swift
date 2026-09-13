import AppCore
import Foundation

/// 朗读投递方式：**一段文本怎么交给 TTS 合成**。
///
/// 为什么要分两种（产品口径，2026-09-13 确认）：
///
/// - 本地 runtime 合成耗时 ≈ 2.6 × 音频时长且近似线性，整段一次合成会让用户干等几十秒。
///   因此切成短句做**流水线**：首句合成完立即出声，播放期间并行预取下一句。
/// - 云端 API 合成很快（通常与文本长度弱相关），此时分句反而有害——每句都是独立请求，
///   句与句之间的韵律、停顿、语调连不起来，听起来一顿一顿的。整段一次合成的衔接最自然。
///
/// 于是：**云端整段、本地分句**。这条判断是纯函数，不碰网络也不碰 runtime，可脱机测试。
public enum SpeechDelivery: String, Sendable, CaseIterable {
    /// 分句流水线：首句先出声，其余边播边合成。本地模型用。
    case segmented
    /// 整段一次合成：韵律连贯、衔接自然。云端模型用。
    case whole

    /// 按 runtime 决定投递方式。只有云端 API 走整段，其余（含 mock）都走分句。
    public static func forRuntime(_ runtime: RuntimeKind) -> SpeechDelivery {
        runtime == .remoteAPI ? .whole : .segmented
    }

    /// 单次送进模型的文本上限（字符）。
    ///
    /// 本地那 400 字符是为了控制**用户等待**（合成时长随文本线性增长）；
    /// 云端没有这个约束，放宽到 2000，让长段落也能一次读完、读出连贯的语调。
    public var maxCharacters: Int {
        switch self {
        case .segmented: 400
        case .whole: 2000
        }
    }

    /// 面向用户的一句话说明（设置页展示「当前按哪种方式朗读」）。
    public var explanation: String {
        switch self {
        case .segmented: "本地模型按句合成：首句先出声，其余边播边合成，减少等待。"
        case .whole: "云端模型整段合成：一次读完，老师朗读的语调与停顿更连贯。"
        }
    }
}
