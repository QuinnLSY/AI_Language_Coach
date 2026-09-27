import Foundation

/// 一段语音在输入框里的**位置记忆**。
///
/// 把输入框看成 `[prefix][本次语音]`。`prefix` 只回答一件事：
/// 「这段语音之前，用户手上已经有什么」—— 录音开始时的内容。
/// `lastVoice` 是服务端**上一次**给的整句（它每次都重识别整段音频，推的是全量文本）。
///
/// `userEdited` 是本段语音里**用户有没有动过手**。它一旦为真就再也不回退，
/// 因为那之后 `prefix + lastVoice` 已经拼不出用户眼前的内容了 ——
/// 用户改字之后，我们再也分不清哪几个字是他的、哪几个是识别的，
/// 唯一的正确做法就是不要再整段覆写他。
public struct VoiceMergeState: Equatable, Sendable {

    /// 语音段之前用户已有的内容（录音开始时定下）。
    public var prefix: String
    /// 服务端上一次给的整句识别文本。
    public var lastVoice: String
    /// 本段语音里用户是否手动改过输入框。
    public var userEdited: Bool

    public init(prefix: String = "", lastVoice: String = "", userEdited: Bool = false) {
        self.prefix = prefix
        self.lastVoice = lastVoice
        self.userEdited = userEdited
    }

    /// 输入框此刻「应该」还是我们上次留下的那个样子（只在用户没动过时才有意义）。
    public var expected: String { VoiceTranscriptMerge.merged(base: prefix, voice: lastVoice) }
}

/// 一次合并的结果。
public struct VoiceMergeOutcome: Equatable, Sendable {

    /// 推进后的位置记忆。
    public let state: VoiceMergeState
    /// 输入框应该变成的内容。
    public let text: String
    /// 这一次是否走了「保住用户手改、只追增量」的路线（测试与排障用）。
    public let preservedUserEdit: Bool

    public init(state: VoiceMergeState, text: String, preservedUserEdit: Bool) {
        self.state = state
        self.text = text
        self.preservedUserEdit = preservedUserEdit
    }
}

/// 语音流式识别结果与输入框内容的**合并规则**（纯函数，可脱机测）。
///
/// 服务层每一次推送带的都是「到目前为止听清的**整句**」（每轮都把整段音频重识别，
/// 返回全量文本而非增量），所以合并要同时守住两件事：
///
/// 1. **不覆盖用户手打的内容**。录音前输入框里可能已经有字（「打了半句 → 说话把后半句
///    说完」是最常见的用法），那段内容必须原样留着。
/// 2. **用户改过识别结果之后，识别还要能接着用**。2026-09-27 的报障就出在这里：
///    原先每一步都按 `voiceBase + 新识别` 重算，而 `voiceBase` 是**录音开始前**的快照 ——
///    用户在录音期间把识别错的字改掉，下一次推送立刻把改动整体冲回去。用户看到的是
///    「我改过的字自己变回去了」，改几次都留不住，主观感受就是「改完就没法接着识别了」。
///
/// 于是规则分两路：没动过就整段替换（最流畅、不会越滚越长）；动过就**保留用户的内容、
/// 只把识别的增量补在后面** —— 用户的字一个不动，识别继续往上加。
public enum VoiceTranscriptMerge {

    /// 增量长度不到整句一半时，判为「识别在抖」的阈值分母
    /// （见 `incremental` 的说明）：2 = 一半。
    private static let jitterDenominator = 2

    /// 把语音整句拼到「已有内容」后面。
    ///
    /// 空格规则：两边都非空、且前一段结尾不是空白时补一个空格 ——
    /// 英文口述接在英文打字后面，`"How are"` + `"you"` 直接贴起来会变成 `"How areyou"`。
    public static func merged(base: String, voice: String) -> String {
        let spoken = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty else { return base }
        guard !base.isEmpty else { return spoken }
        if let last = base.last, last.isWhitespace { return base + spoken }
        return base + " " + spoken
    }

    /// `incoming` 相对 `previous` **新增的尾部**。
    ///
    /// 两次推送的整句通常是「上一次的前缀 + 新听清的几个词」：`"How do I ask"`
    /// → `"How do I ask for directions"`，增量就是 `" for directions"`。
    ///
    /// ⚠️ 公共前缀之后的剩余部分**原样照抄**，不要自己补空格：分隔已经在 `next` 里了
    /// （`"How do I"` → `"How do I ask"` 的剩余是 `" ask"`）；而公共前缀停在词中间时
    /// （`"How ar"` → `"How are"` 的剩余是 `"e"`）补空格反而会把一个词拆成两个。
    ///
    /// ⚠️ **抖动保护**：识别改写句子中段时公共前缀会变得很短（`"I saw a dark"` →
    /// `"I see a dark"` 只共三格），照搬增量会把整句再贴一遍，在用户已经改过的内容后面
    /// 叠出 `"…duckee a dark"`。因此公共前缀短于整句一半时按「识别翻来覆去」处理，
    /// 这一轮不追加 —— 少写一句总好过写出一句乱的。
    public static func incremental(previous: String, incoming: String) -> String {
        let next = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.isEmpty else { return "" }
        guard !previous.isEmpty else { return next }
        let common = previous.commonPrefix(with: next)
        if common.isEmpty { return separator(before: previous) + next }
        let tail = String(next.dropFirst(common.count))
        guard !tail.isEmpty else { return "" }
        let shorter = min(previous.count, next.count)
        if common.count * jitterDenominator < shorter { return "" }
        return tail
    }

    /// 把一次推送落到输入框上 —— **唯一的写入入口**（流式与定稿都走这里）。
    ///
    /// - Parameters:
    ///   - state: 本段语音的位置记忆。
    ///   - incoming: 这一次的识别结果（整句）。
    ///   - current: 输入框现在的内容。
    public static func apply(
        _ state: VoiceMergeState,
        incoming: String,
        current: String
    ) -> VoiceMergeOutcome {
        let trimmed = incoming.trimmingCharacters(in: .whitespacesAndNewlines)

        // 这一轮什么都没听出来（还在等出声，或识别退化成空）→ 一个字都不动。
        // 用户改到一半的内容不能因为一次空推送被清掉。
        guard !trimmed.isEmpty else {
            return VoiceMergeOutcome(state: state, text: current, preservedUserEdit: state.userEdited)
        }

        // 用户把输入框清空了 = 这一整段推倒重来：旧前缀与旧语音段都不再作数。
        if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return VoiceMergeOutcome(
                state: VoiceMergeState(prefix: "", lastVoice: trimmed, userEdited: false),
                text: trimmed,
                preservedUserEdit: false
            )
        }

        // 用户没动过手，且输入框还是我们上次留下的样子 → **整段替换**最干净
        // （不会因为识别一轮轮变长而越滚越长）。
        if !state.userEdited, current == state.expected {
            return VoiceMergeOutcome(
                state: VoiceMergeState(prefix: state.prefix, lastVoice: trimmed, userEdited: false),
                text: merged(base: state.prefix, voice: trimmed),
                preservedUserEdit: false
            )
        }

        // 用户动过（改字 / 删字 / 换行）→ 他的手改是权威：留着，只把增量补在后面。
        // 注意这里**不再回到整段替换**：`prefix + lastVoice` 已经对不上他眼前的内容了，
        // 再覆写一次就是把他的改动第二次冲掉。
        let delta = incremental(previous: state.lastVoice, incoming: trimmed)
        return VoiceMergeOutcome(
            state: VoiceMergeState(prefix: state.prefix, lastVoice: trimmed, userEdited: true),
            text: current + delta,
            preservedUserEdit: true
        )
    }

    /// 两段文本之间该不该补空格（整句都被识别改写、无公共前缀时）。
    private static func separator(before text: String) -> String {
        guard let last = text.last, !last.isWhitespace else { return "" }
        return " "
    }
}
