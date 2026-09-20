import Foundation

/// 老师人格档位（官方路线图 V1.2 的 *teacher personality*）。
///
/// 它是**教学风格参数的唯一来源**：回复长度、纠错强度、是否允许母语提示这三项
/// 现在都由档位推导（`TeacherPreference` 只存档位本身）。
/// 之前那三个字段各存一份的写法，迟早会出现「档位写着温和、强度却存着严格」这种
/// 自相矛盾的组合，而那种组合没有任何地方能判它错。
///
/// ⚠️ **与 `TeacherCorner` 的「督促 / 鼓励 / 休息」不是一回事**：那三个是按**今日 token
/// 用量**分档的氛围气泡（用得越多越催你休息），与教学风格无关，不要合并。
///
/// ⚠️ 档位只影响**教学口径**，不影响难度曲线（`ConversationContext.difficulty`）
/// 与星星 / 判定卡 —— 那两套评价体系各有自己的真源。
public enum TeacherPersona: String, Codable, Sendable, Equatable, CaseIterable, Identifiable {
    /// 温和鼓励：少纠错、回复短、允许母语解释。
    case warm
    /// 标准：与既有行为逐字一致（默认）。
    case standard
    /// 严格纠错：必纠、讲得更细、尽量泡在目标语里。
    case strict

    public var id: String { rawValue }

    /// 设置页里显示的名字。
    public var displayName: String {
        switch self {
        case .warm: "温和鼓励"
        case .standard: "标准"
        case .strict: "严格纠错"
        }
    }

    /// 设置页里的一句话说明 —— 说清「会怎么变」，不是形容词堆砌。
    public var summary: String {
        switch self {
        case .warm: "多肯定、少打断；小错放过去，回复更短。"
        case .standard: "该纠的纠、点到为止，保持对话顺畅。"
        case .strict: "每个明显错误都讲清楚，解释更细，尽量用英语。"
        }
    }

    // MARK: - 推导出的教学参数（唯一来源）

    public var responseLength: TeacherPreference.ResponseLength {
        switch self {
        case .warm: .brief
        case .standard: .normal
        case .strict: .detailed
        }
    }

    public var correctionStyle: CorrectionIntensity {
        switch self {
        case .warm: .gentle
        case .standard: .balanced
        case .strict: .strict
        }
    }

    /// 学员卡住时是否允许用母语解释。
    ///
    /// 严格档关掉是有意的：这一档的卖点就是「尽量泡在目标语里」，
    /// 若同时允许母语兜底，它就退化成了「标准档 + 语气凶一点」。
    public var allowsNativeLanguageHints: Bool { self != .strict }

    /// 在情景自带的纠错强度上再推一档。
    ///
    /// ⚠️ 情景数据里的 `correctionMode` 是**设计者对这个练习的意图**
    /// （温柔的看诊 vs 针锋相对的辩论），不该被用户偏好整档覆盖；
    /// 所以人格只做**最多一档的偏移**：严格档顶到 `strict` 就停，温和档退到 `gentle` 就停。
    public func shifted(_ baseline: CorrectionIntensity) -> CorrectionIntensity {
        switch self {
        case .warm: baseline.relaxed
        case .standard: baseline
        case .strict: baseline.intensified
        }
    }

    // MARK: - Prompt

    /// 注入 Prompt 用的英文档位名（`displayName` 是给用户看的中文，不进提示词）。
    public var promptLabel: String {
        switch self {
        case .warm: "warm and encouraging"
        case .standard: "balanced"
        case .strict: "strict and rigorous"
        }
    }

    /// 注入 Prompt 的英文指令片段。
    ///
    /// 与 `CorrectionIntensity.instruction` 同风格：**短指令表放代码里，长 Prompt 放
    /// `Resources/Prompts/`**。措辞里带上了具体句数上限，因为基础人设
    /// （`teacher_system.txt`）写着「Keep every reply short: 2 to 4 sentences」，
    /// 不给出新的上限，严格档的「讲得更细」会被那一条直接吃掉。
    public var instruction: String {
        switch self {
        case .warm:
            "Lead with what went well. Let small slips pass; only step in when the meaning "
                + "is lost. Keep replies to 1 to 2 sentences."
        case .standard:
            "Fix clear mistakes briefly, then move the conversation on. Keep the usual length."
        case .strict:
            "Correct every clear mistake and say in a few words why. When a correction needs "
                + "room, you may use up to 5 sentences — never more."
        }
    }
}
