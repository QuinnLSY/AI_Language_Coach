import Foundation

// MARK: - 对话状态机（Implementation Plan §10 Phase 6 — Conversation Engine）
//
// 为什么要有它：在此之前「对话进行到哪一步」散落在 ChatService 的几个布尔量里
// （isGenerating / isThinking / isSpeaking…），谁也说不清「学员按下录音」到
// 「老师说完」之间到底经历过哪些阶段，更谈不上「暂停 / 恢复 / 安全结束」。
//
// 这里把这条流程收成一台**确定性状态机**：给定 (状态, 事件) 的转移结果永远相同，
// 非法事件一律 no-op（而不是把状态搅乱）。纯值类型、无副作用、可完整单测，
// 也不认识任何 Provider / LLM —— Agent 与 UI 都只是它的调用方。

/// 对话所处的阶段。
///
/// 对应计划的 `idle / listening / processing / responding / completed / error`，
/// 另加 `paused`（计划验收点要求可暂停 / 恢复）。
public enum ConversationState: String, Codable, Sendable, Equatable, CaseIterable {
    /// 空闲：等学员开口。
    case idle
    /// 正在收音（学员按住说话）。
    case listening
    /// 已拿到学员这句话，正在准备 / 等待模型（含推理模型的思考段）。
    case processing
    /// 老师的正文正在上屏（首字已到）。
    case responding
    /// 被暂停：不再自动推进，等待恢复。
    case paused
    /// 本轮对话正常收束。
    case completed
    /// 出错（模型不可用 / 请求失败）。
    case error

    /// 是否处于「正在进行」的状态（UI 据此显示生成中）。
    public var isActive: Bool {
        switch self {
        case .listening, .processing, .responding: true
        case .idle, .paused, .completed, .error: false
        }
    }

    /// 本轮是否已收束（正常结束或出错）。
    ///
    /// ⚠️ 它**不是「死掉」**：学员再开口 / 重试都能开新的一轮。
    /// 把它当终态拒绝一切事件，会造成「出一次错之后，状态机永远卡在 error」这种要命的表现。
    public var isSettled: Bool { self == .completed || self == .error }

    /// UI 文案（状态条 / 无障碍朗读用）。
    public var displayName: String {
        switch self {
        case .idle: "空闲"
        case .listening: "正在听"
        case .processing: "正在想"
        case .responding: "正在说"
        case .paused: "已暂停"
        case .completed: "已结束"
        case .error: "出错了"
        }
    }
}

/// 驱动状态机的事件。**只描述发生了什么**，不携带业务数据（业务数据在上下文里）。
public enum ConversationEvent: String, Sendable, Equatable, CaseIterable {
    /// 学员开始说话（按下录音 / 焦点进入输入）。
    case beginListening
    /// 拿到了学员的输入（识别结果或手打文本已入列）。
    case learnerSpoke
    /// 已向模型发出请求。
    case generationStarted
    /// 收到首个正文增量。
    case firstToken
    /// 生成正常结束。
    case generationFinished
    /// 生成失败。
    case generationFailed
    /// 用户暂停。
    case pause
    /// 用户恢复。
    case resume
    /// 安全结束本次对话（收尾，不丢数据）。
    case terminate
    /// 开新一轮（清状态）。
    case reset
}

/// 确定性状态机。值类型：拷一份就得到一个独立分支，便于测试与「时间旅行」调试。
///
/// 设计约束（都来自计划验收点）：
/// - **转移确定**：同样输入永远同样输出；非法事件不改状态（no-op）。
/// - **可暂停 / 恢复**：暂停时记住暂停前的状态，恢复回到原位而不是掉进 idle。
/// - **可安全终止**：`terminate` 从任何非终态落到 `completed`。
public struct ConversationStateMachine: Sendable, Equatable {

    public private(set) var state: ConversationState
    /// 暂停前的状态（恢复时回退到这里）。非暂停时为 nil。
    private var stateBeforePause: ConversationState?
    /// 转移轨迹（最近 32 步）。用于调试与断言「确实按预期路径走」。
    public private(set) var trail: [ConversationState]

    private static let trailLimit = 32

    public init(state: ConversationState = .idle) {
        self.state = state
        self.stateBeforePause = nil
        self.trail = [state]
    }

    /// 送回一个事件，返回转移后的状态。
    ///
    /// - Returns: 转移后的状态（非法事件返回**原状态**，便于调用方无脑链式使用）。
    @discardableResult
    public mutating func send(_ event: ConversationEvent) -> ConversationState {
        guard let next = Self.target(from: state, on: event, stateBeforePause: stateBeforePause) else {
            return state
        }
        if event == .pause, !state.isSettled {
            stateBeforePause = state
        }
        if event == .resume || event == .reset || event == .terminate {
            stateBeforePause = nil
        }
        state = next
        trail.append(next)
        if trail.count > Self.trailLimit { trail.removeFirst(trail.count - Self.trailLimit) }
        return next
    }

    /// 转移表（唯一真相源）：`(当前状态, 事件) -> 新状态`；nil = 非法 / 无意义，保持原样。
    ///
    /// 写成纯静态函数而不是散落在调用方，是为了「同样输入同样输出」这条能被测试钉死。
    static func target(
        from state: ConversationState,
        on event: ConversationEvent,
        stateBeforePause: ConversationState?
    ) -> ConversationState? {
        // 暂停态只认「恢复 / 结束 / 重置」——暂停期间任何生成事件都不该把它推走。
        if state == .paused {
            switch event {
            case .resume: return stateBeforePause ?? .idle
            case .terminate: return .completed
            case .reset: return .idle
            default: return nil
            }
        }
        // 收束态（completed / error）不是死掉：学员再开口 / 重试都能开新的一轮。
        if state.isSettled {
            switch event {
            case .reset: return .idle
            case .terminate: return .completed
            case .beginListening: return .listening
            case .learnerSpoke: return .processing
            case .generationStarted: return .processing
            case .pause: return .paused
            default: return nil
            }
        }

        switch (state, event) {
        case (_, .reset): return .idle
        case (_, .terminate): return .completed
        case (_, .pause): return .paused

        case (.idle, .beginListening): return .listening
        case (.idle, .learnerSpoke): return .processing
        case (.idle, .generationStarted): return .processing
        // 开场招呼那条路径不经 beginListening：老师在 idle 上直接开讲，失败要能落到 error。
        case (.idle, .generationFailed): return .error

        case (.listening, .beginListening): return .listening
        case (.listening, .learnerSpoke): return .processing

        case (.processing, .generationStarted): return .processing
        case (.processing, .firstToken): return .responding
        case (.processing, .generationFinished): return .idle
        case (.processing, .generationFailed): return .error

        case (.responding, .firstToken): return .responding
        case (.responding, .generationFinished): return .idle
        case (.responding, .generationFailed): return .error

        default: return nil
        }
    }
}
