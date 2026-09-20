import CoreGraphics
import Foundation

/// 划词（悬停单词 / 拖选短语）查询的纯逻辑：**归一化 + 词/短语判别**。
///
/// 单独拿出来是为了能脱机单测 —— 这一层里全是「实测踩过」的判据，混进视图就没法守。
public enum WordLookupQuery {

    /// 划选文本里允许算作「词的一部分」的字符。
    ///
    /// ⚠️ 必须与 AppKit 那边找词边界的规则**同源**：`don't` / `check-in` / `B2B` 都是一个词，
    /// 任一侧放宽（比如这边允许撇号、那边不允许）都会出现「悬停到一半被切成两段」。
    public static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "'" || character == "-" || character == "’"
    }

    /// 去掉两端空白**以及两端不属于词的标点**（`snatch,` / `（rival）` / `"derive."`）。
    ///
    /// 只削两端、不动中间：`state-of-the-art` 与 `don't` 中间的连字符/撇号是词的一部分。
    public static func normalize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = text.first, !isWordCharacter(first) {
            text.removeFirst()
        }
        while let last = text.last, !isWordCharacter(last) {
            text.removeLast()
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 多词（短语 / 短句）：中间有空白。
    ///
    /// 短语**不问音标、不问词性** —— 那是单词才有的东西，硬给一个短语标音标是假信息。
    public static func isPhrase(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).contains { $0.isWhitespace }
    }

    /// 缓存 / 去重的键：大小写不敏感（`Snatch` 与 `snatch` 是同一个词）。
    public static func key(_ text: String) -> String {
        normalize(text).lowercased()
    }

    /// 从一段文字里取出光标处的那个词（用于「悬停」）。
    ///
    /// - Parameters:
    ///   - text: 整段文字
    ///   - index: 命中的字符下标（越界 → 空串）
    /// - Returns: 光标所在词的**原始写法**（保留大小写），光标处不是词字符时为空。
    public static func word(in text: String, at index: Int) -> String {
        let characters = Array(text)
        guard characters.indices.contains(index), isWordCharacter(characters[index]) else { return "" }
        var start = index
        while start > 0, isWordCharacter(characters[start - 1]) { start -= 1 }
        var end = index
        while end + 1 < characters.count, isWordCharacter(characters[end + 1]) { end += 1 }
        return String(characters[start...end])
    }
}

/// 划词气泡里要显示的一张卡（纯数据，视图只负责画）。
///
/// 没有任何字段是「必须有」的：词库里没有这个词时，卡上就只有词本身 + 一句话说明，
/// 而不是一个空壳（用户口径：没有的东西不要装样子）。
public struct WordLookupCard: Sendable, Equatable {
    /// 划出来的那个词 / 短语（原始写法）。
    public var text: String
    /// 音标（单词才有）。
    public var phonetic: String
    /// 词性（单词才有）。
    public var pos: String
    /// 中文翻译 / 释义。
    public var translation: String
    /// 正在取内容（气泡上转圈）。
    public var isLoading: Bool
    /// 多词（短语 / 短句）：卡上不出现音标与词性。
    public var isPhrase: Bool
    /// 一句话说明（词库里没有、模型没开、已加入复习…）。
    public var notice: String?
    /// 走的是模型翻译（短语）还是词典（单词）—— 页面据此决定「查单词」按钮有没有意义。
    public var isFromModel: Bool
    /// 划到的是变体时，它的**本体**（`subtitles` → `subtitle`）；本身就是原形则为空。
    ///
    /// ⚠️ 音标 / 词性 / 释义都是**本体**的，只有 `text` 是用户划到的那个写法 ——
    /// 用户要的就是「查本体 + 告诉我这是什么形式」。
    public var lemma: String
    /// 变体的语法名称（「复数形式」…）。拿不到就空着，绝不硬编一个。
    public var formLabel: String
    /// 变体相对本体的额外说明（模型给的，如「这里指影片的字幕」）。可为空。
    public var formNote: String

    public init(
        text: String,
        phonetic: String = "",
        pos: String = "",
        translation: String = "",
        isLoading: Bool = false,
        isPhrase: Bool = false,
        notice: String? = nil,
        isFromModel: Bool = false,
        lemma: String = "",
        formLabel: String = "",
        formNote: String = ""
    ) {
        self.text = text
        self.phonetic = phonetic
        self.pos = pos
        self.translation = translation
        self.isLoading = isLoading
        self.isPhrase = isPhrase
        self.notice = notice
        self.isFromModel = isFromModel
        self.lemma = lemma
        self.formLabel = formLabel
        self.formNote = formNote
    }

    /// 划到的是变体（查的是本体）——气泡据此多显示一行形态说明。
    public var isInflectedForm: Bool { !lemma.isEmpty && !formLabel.isEmpty }

    /// 「加入复习」/「去词典查」该用哪个词：**优先本体**。
    ///
    /// 把 `subtitles` 收进单词本，复习时抽到的是一张只出现过一次的变体卡 ——
    /// 记词要记 `subtitle`。
    public var lookupWord: String { lemma.isEmpty ? text : lemma }

    /// 同一个词（大小写不敏感）—— 用来判断「这次划的和卡上是不是同一个」。
    public func matches(_ other: String) -> Bool {
        text.caseInsensitiveCompare(other) == .orderedSame
    }
}

/// 气泡该摆在哪儿（**纯函数**）。
///
/// 判据来自用户口径「在单词周围合适的位置（避免屏幕限制展示不全）」：
/// 优先压在词的**下方**（不挡住刚划过的那一行）；下方放不下就翻到上方；
/// 上下都放不下就挑空间大的那侧，并把气泡**夹**进可视范围内（宁可贴着边，也不能被切掉）。
public enum WordBubblePlacement {

    /// 气泡与词之间的间距。
    public static let gap: CGFloat = 6
    /// 与可视区域边缘的最小留白。
    public static let margin: CGFloat = 6

    /// - Parameters:
    ///   - anchor: 被划过的那块文字（**视图自身坐标系**，左上原点）。
    ///   - bubble: 气泡尺寸。
    ///   - space: 锚点四周还能放多少（同样是视图自身坐标系，可能大于视图本身：
    ///            视图外面还有窗口空间，气泡不必被自己的卡片框住）。
    /// - Returns: 气泡左上角的偏移（同样是视图自身坐标系）。
    public static func origin(
        anchor: CGRect,
        bubble: CGSize,
        space: WordLookupSpace
    ) -> CGPoint {
        // 垂直：先下方（不挡词），再看上方，都不够就挑大的那侧。
        let below = space.bottomLimit - anchor.maxY - gap
        let above = anchor.minY - space.topLimit - gap
        var y: CGFloat
        if below >= bubble.height {
            y = anchor.maxY + gap
        } else if above >= bubble.height {
            y = anchor.minY - gap - bubble.height
        } else if below >= above {
            y = max(space.topLimit + margin, anchor.maxY + gap)
        } else {
            y = min(space.bottomLimit - margin - bubble.height, anchor.minY - gap - bubble.height)
        }
        // 夹回可视范围：气泡比可视区域还高时，贴住上边界（至少标题行看得见）。
        y = max(space.topLimit + margin, min(y, space.bottomLimit - margin - bubble.height))
        if bubble.height + margin * 2 > space.bottomLimit - space.topLimit {
            y = space.topLimit + margin
        }

        // 水平：以词为中心，再夹进左右边界。
        var x = anchor.midX - bubble.width / 2
        x = max(space.leftLimit + margin, min(x, space.rightLimit - margin - bubble.width))
        if bubble.width + margin * 2 > space.rightLimit - space.leftLimit {
            x = space.leftLimit + margin
        }
        return CGPoint(x: x, y: y)
    }
}

/// 锚点四周的可用空间（**视图自身坐标系，左上原点**）。
///
/// 四个 `…Limit` 是「可视区域的边界在哪」而不是「有多少空间」：
/// 页面嵌在 `ScrollView` 里时，视图自己的 `bounds` 并不是边界，窗口才是 ——
/// 所以这些值由 AppKit 侧按窗口算出来，可能落在视图 `bounds` 之外（负数 / 超过高度都合法）。
public struct WordLookupSpace: Sendable, Equatable {
    /// 可视区域上边界（视图坐标系里的 y）。
    public var topLimit: CGFloat
    /// 可视区域下边界。
    public var bottomLimit: CGFloat
    public var leftLimit: CGFloat
    public var rightLimit: CGFloat

    public init(topLimit: CGFloat, bottomLimit: CGFloat, leftLimit: CGFloat, rightLimit: CGFloat) {
        self.topLimit = topLimit
        self.bottomLimit = bottomLimit
        self.leftLimit = leftLimit
        self.rightLimit = rightLimit
    }

    /// 兜底：不知道边界时按视图自身尺寸当边界。
    public static func fallback(size: CGSize) -> WordLookupSpace {
        WordLookupSpace(topLimit: 0, bottomLimit: size.height, leftLimit: 0, rightLimit: size.width)
    }

    /// 锚点上方 / 下方各剩下多少（已扣掉气泡与词之间的间距）。
    public func remaining(_ anchor: CGRect) -> (above: CGFloat, below: CGFloat) {
        (
            above: anchor.minY - topLimit - WordBubblePlacement.gap,
            below: bottomLimit - anchor.maxY - WordBubblePlacement.gap
        )
    }

    /// 平移到另一个坐标系（同向、同尺度，只挪原点）。
    ///
    /// 气泡搬到浮层里画时，锚点与可视边界都要跟着挪一次，否则会把气泡钉在旧坐标系上。
    public func offsetBy(dx: CGFloat, dy: CGFloat) -> WordLookupSpace {
        WordLookupSpace(
            topLimit: topLimit + dy,
            bottomLimit: bottomLimit + dy,
            leftLimit: leftLimit + dx,
            rightLimit: rightLimit + dx
        )
    }
}

/// 气泡在**浮层坐标系**里的摆位（纯函数，可脱机单测）。
///
/// 为什么需要它：气泡原先挂在句子自己的 `overlay` 里，锚点与可视边界都用「句子自身坐标系」，
/// 直接就能算。但那样气泡会被 `ScrollView` 裁掉、被后面的兄弟视图（下一条消息）盖住 ——
/// `zIndex` 只在同一个父容器里比大小，跨到滚动列表这一层就失效了。
///
/// 于是气泡改到页面顶层的浮层里画，两者的原点不同，需要把锚点与边界整体平移一次。
public enum WordLookupLayerPlacement {

    /// - Parameters:
    ///   - anchor: 被划过的那块文字（**句子自身坐标系**，左上原点）。
    ///   - space: 锚点四周的可视边界（同样是句子自身坐标系）。
    ///   - sourceFrame: 句子在**浮层坐标系**里的位置（滚动时会实时变化，气泡因此跟着文字走）。
    ///   - bubble: 气泡尺寸。
    /// - Returns: 气泡左上角（**浮层坐标系**）。
    public static func origin(
        anchor: CGRect,
        space: WordLookupSpace,
        sourceFrameInLayer: CGRect,
        bubble: CGSize
    ) -> CGPoint {
        let dx = sourceFrameInLayer.minX
        let dy = sourceFrameInLayer.minY
        return WordBubblePlacement.origin(
            anchor: anchor.offsetBy(dx: dx, dy: dy),
            bubble: bubble,
            space: space.offsetBy(dx: dx, dy: dy)
        )
    }
}
