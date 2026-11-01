import Foundation

/// 远端与本机请求的**超时口径**（唯一定义处）。
///
/// 为什么要有这个枚举：改前 26 个调用点各自写 `timeout: config.requestTimeout ?? 15`，
/// 一共 9 种取值、零注释。于是「这个请求为什么 15 秒就断了」只能去翻 git blame，
/// 而调快调慢一个数字也不会有任何东西提醒你它影响的是哪一类请求。
///
/// 分组依据是**失败长什么样**，不是「哪个模块在用」：
/// - 探活类失败通常是 `connection refused`（服务没起），给再长也没用；
/// - 目录类失败可以是慢端点，给 20 秒；
/// - 生成类失败是模型真在算，必须给足。
///
/// ⚠️ 数值保持与改前逐字一致 —— 这一轮只做「有名字」，不顺手调快慢。
/// 调超时是行为变更，得单独一轮、单独验证。
public enum RemoteTimeouts {

    /// 本机服务可达性探测的**单次**超时（外层还有自己的轮询预算）。
    public static let probePing: TimeInterval = 2

    /// 本机 ASR 探活（whisper.cpp）。
    public static let voiceProbe: TimeInterval = 6

    /// 本机 TTS 探活与音色列表。
    public static let ttsProbe: TimeInterval = 8

    /// 本机 LLM / embedding 探活与轻量元数据（Ollama 冷启动也要在这里回话）。
    public static let localProbe: TimeInterval = 10

    /// 远端 LLM 探活。
    public static let modelProbe: TimeInterval = 15

    /// 远端目录（模型列表 / 音色列表 / 健康检查）。
    public static let catalog: TimeInterval = 20

    /// 发音评测（要传音频、跑音素对齐）。
    public static let evaluation: TimeInterval = 30

    /// 短的音频 / 文本一次性请求：转写、embedding、本机 ASR。
    public static let shortRequest: TimeInterval = 60

    /// 生成类：对话、本地大模型推理。
    public static let generation: TimeInterval = 120

    /// TTS 合成（长文本 + 慢端点，预算最宽）。
    public static let speechSynthesis: TimeInterval = 180

    /// 本机服务启动后的可达性等待上限。
    public static let serviceStartup: TimeInterval = 60
}
