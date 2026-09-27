import Foundation

/// 聊天区语音输入的**阶段**。
///
/// 为什么要把它建模成一个值，而不是两个布尔（`isRecording` + `isTranscribing`）：
///
/// 这两个布尔**天然互斥**（不可能同时录音又识别），但拆成两个变量后，
/// 「在哪一刻置哪一个」就成了散落在各处的约定。2026-09-27 的报障正是这么来的：
/// 停止录音后 `isTranscribing` 的读取点写在 `defer` 之后（恒读到 false），
/// 于是「识别中」这个状态在 UI 上**从未出现过** —— 用户点了一次麦克风，
/// 界面没有任何变化，只能再点一次；而第二次点击落进了「开始录音」分支
/// （此刻录音已经停了），麦克风被重新打开，前一次的识别结果被丢弃。
///
/// 单一枚举让「同一时刻只能是三者之一」成为类型事实，`switch` 也逼着每个
/// 使用点把三种情况都想清楚。
public enum VoiceInputPhase: String, Sendable, CaseIterable {
    /// 空闲：既没录音也没识别。
    case idle
    /// 正在采集麦克风（本地 ASR 时同时有流式中间结果）。
    case recording
    /// 已停止采集，正在把这段音频送去识别（本地 whisper 可能要数秒到数十秒）。
    case transcribing

    /// 是否有麦克风正在采集 —— 这正是「取消录音」该出现的窗口。
    public var isCapturing: Bool { self == .recording }

    /// 这一阶段里麦克风按钮是否应该显示「忙」（进度指示）。
    public var isBusy: Bool { self == .transcribing }

    /// 用户此刻点主按钮时，该做的事。
    public var primaryAction: VoiceInputPrimaryAction {
        switch self {
        case .idle: return .start
        case .recording: return .stopAndTranscribe
        case .transcribing: return .cancelTranscribe
        }
    }
}

/// 语音输入主按钮（麦克风 / 波纹）在某一阶段该做的事。
///
/// 单独抽出来是为了让「点一下会发生什么」可被脱机验证：
/// 报障的核心就是这条映射在「识别中」缺了一格 —— 那时点按钮落进了
/// `else`（开始录音），用户想「终止」，得到的却是「重新录」。
public enum VoiceInputPrimaryAction: String, Sendable, CaseIterable {
    /// 开始录音。
    case start
    /// 停止采集并送识别。
    case stopAndTranscribe
    /// 作废这次识别（识别已经开始，只能丢弃结果，不能再重开麦克风）。
    case cancelTranscribe
}
