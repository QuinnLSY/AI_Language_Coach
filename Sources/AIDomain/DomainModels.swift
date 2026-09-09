import AppCore
import Foundation

// MARK: - 对话

public enum ChatRole: String, Codable, Sendable, CaseIterable {
    case system
    case user
    case assistant
}

public struct ChatMessage: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var role: ChatRole
    public var content: String
    public var createdAt: Date

    public init(id: UUID = UUID(), role: ChatRole, content: String, createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

// MARK: - 闯关（大树）

public enum LevelState: String, Codable, Sendable, CaseIterable {
    case locked
    case unlocked
    case inProgress
    case completed
}

/// 树上的一个关卡节点。UI 只渲染，不内置业务数据。
public struct TreeLevel: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var title: String
    public var subtitle: String
    /// 0...1 的相对高度，0=树根，1=树冠。
    public var heightFraction: Double
    /// 树枝朝向：左 / 右，用于左右交错布局。
    public var branch: BranchSide
    public var state: LevelState
    public var requiredStars: Int
    public var earnedStars: Int

    public enum BranchSide: String, Codable, Sendable, CaseIterable { case left, right }

    public init(
        id: String,
        title: String,
        subtitle: String,
        heightFraction: Double,
        branch: BranchSide,
        state: LevelState = .locked,
        requiredStars: Int = 3,
        earnedStars: Int = 0
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.heightFraction = heightFraction
        self.branch = branch
        self.state = state
        self.requiredStars = requiredStars
        self.earnedStars = earnedStars
    }
}

public struct LearnerProgress: Codable, Sendable, Equatable {
    public var totalStars: Int
    /// 0...1 大树攀登进度。
    public var climbFraction: Double
    public var levels: [TreeLevel]

    public init(totalStars: Int = 0, climbFraction: Double = 0, levels: [TreeLevel] = []) {
        self.totalStars = totalStars
        self.climbFraction = climbFraction
        self.levels = levels
    }
}

// MARK: - 学习者

public struct LearnerProfile: Codable, Sendable, Equatable {
    public var displayName: String
    public var learningLanguage: String
    public var nativeLanguage: String
    public var proficiency: Proficiency
    public var focusAreas: [String]

    public enum Proficiency: String, Codable, Sendable, CaseIterable {
        case beginner, intermediate, advanced
        public var displayName: String {
            switch self {
            case .beginner: "萌新"
            case .intermediate: "进阶"
            case .advanced: "熟练"
            }
        }
    }

    public init(
        displayName: String = "小探险家",
        learningLanguage: String = "en-US",
        nativeLanguage: String = "zh-CN",
        proficiency: Proficiency = .beginner,
        focusAreas: [String] = []
    ) {
        self.displayName = displayName
        self.learningLanguage = learningLanguage
        self.nativeLanguage = nativeLanguage
        self.proficiency = proficiency
        self.focusAreas = focusAreas
    }
}

// MARK: - 纠错 / 会话总结

public struct GrammarCorrection: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var original: String
    public var corrected: String
    public var explanation: String

    public init(id: UUID = UUID(), original: String, corrected: String, explanation: String) {
        self.id = id
        self.original = original
        self.corrected = corrected
        self.explanation = explanation
    }
}

public struct SessionSummary: Codable, Sendable, Equatable {
    public var sessionID: UUID
    public var startedAt: Date
    public var endedAt: Date
    public var messageCount: Int
    public var newStars: Int
    public var corrections: [GrammarCorrection]

    public init(
        sessionID: UUID = UUID(),
        startedAt: Date = Date(),
        endedAt: Date = Date(),
        messageCount: Int = 0,
        newStars: Int = 0,
        corrections: [GrammarCorrection] = []
    ) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.messageCount = messageCount
        self.newStars = newStars
        self.corrections = corrections
    }
}

// MARK: - 会话

public struct ChatSession: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var startedAt: Date
    public var mode: PracticeMode
    public var messages: [ChatMessage]

    public init(id: UUID = UUID(), startedAt: Date = Date(), mode: PracticeMode = .conversation, messages: [ChatMessage] = []) {
        self.id = id
        self.startedAt = startedAt
        self.mode = mode
        self.messages = messages
    }
}
