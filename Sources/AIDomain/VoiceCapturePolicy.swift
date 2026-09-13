import AppCore

/// 录音期间的**流式中间识别**要不要开（纯函数，脱机可测）。
///
/// 为什么必须按 runtime 分开（费用事故的教训）：
///
/// - **本地 ASR** 跑在自己机器上，不产生任何外部费用。每 ~1.2s 推一次中间结果
///   才能实现「边说边出字」，体验显著更好，所以本地开着。
/// - **云端 ASR** 的每一次中间识别都是**一次完整的计费请求**：把当时录到的整段音频
///   重新上传一遍。一句话说 10 秒会被打成 8 次请求——用户以为「只说了一句话」，
///   账单上却是一串调用。所以云端只在**松手那一刻**做一次识别，费用可预期。
///
/// 这条规则让「语音输入花多少钱」变得可推算：云端 1 次录音 = 1 次识别请求。
public enum VoiceCapturePolicy {

    /// 该 runtime 是否允许录音期间做流式中间识别。
    public static func allowsStreamingPartials(for runtime: RuntimeKind) -> Bool {
        runtime != .remoteAPI
    }

    /// 面向用户的一句话说明（设置页展示当前为什么没有「边说边出字」）。
    public static func explanation(for runtime: RuntimeKind) -> String {
        allowsStreamingPartials(for: runtime)
            ? "本地识别支持边说边出字（边录边出中间结果，不产生外部费用）。"
            : "云端识别只在松开麦克风时识别一次：中间结果同样要上传音频并计费，为避免一句话被计多次费用，已关闭边说边出字。"
    }
}
