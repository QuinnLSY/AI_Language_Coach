import AIDomain
import SwiftUI

/// 词典库里的一本书（封面 + 名字）。
///
/// 交互口径（用户原话）：鼠标移到封面上时 —— 边缘高亮 + 轻微放大，
/// 并在封面上出现**删除按钮**和**优先级选定框**。
///
/// 悬停状态由外部传入（`isHovered`）而不是组件自己管：
/// 组件内部自己 `onHover` 就没法在离屏渲染里验证「悬停时长什么样」——
/// 而这恰恰是这个组件最需要被验证的部分。
public struct DictionaryBookCard: View {

    @Environment(\.forestTheme) private var theme

    private let book: DictionaryBook
    /// 每日推荐词源里的名次（nil = 没被选作词源）。
    private let rank: Int?
    private let isHovered: Bool
    /// 处在「再点一次就真删」的确认态。
    private let isConfirmingDelete: Bool
    private let onHover: (Bool) -> Void
    private let onDelete: () -> Void
    /// 退出「确认删除」态。
    ///
    /// ⚠️ 没有这个出口时，确认态只能靠「再点一次」走出去 —— 那正是真删。
    /// 用户点错了（本意只是看看那按钮是什么）就再也退不回来。
    private let onCancelDelete: () -> Void
    private let onToggleSource: () -> Void

    public init(
        book: DictionaryBook,
        rank: Int?,
        isHovered: Bool,
        isConfirmingDelete: Bool = false,
        onHover: @escaping (Bool) -> Void,
        onDelete: @escaping () -> Void,
        onCancelDelete: @escaping () -> Void = {},
        onToggleSource: @escaping () -> Void
    ) {
        self.book = book
        self.rank = rank
        self.isHovered = isHovered
        self.isConfirmingDelete = isConfirmingDelete
        self.onHover = onHover
        self.onDelete = onDelete
        self.onCancelDelete = onCancelDelete
        self.onToggleSource = onToggleSource
    }

    /// 封面宽高比（书的样子）。
    public static let coverAspect: CGFloat = 3.0 / 4.0

    public var body: some View {
        VStack(spacing: 7) {
            cover
            // 封面的**下方**显示词典名称（用户口径）。
            VStack(spacing: 1) {
                Text(book.name)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onHover(perform: onHover)
    }

    private var subtitle: String {
        let count = "\(book.entryCount) 词"
        if book.isBuiltIn {
            return book.subtitle.isEmpty ? count : "\(count) · \(book.subtitle)"
        }
        return "\(count) · 导入"
    }

    // MARK: - 封面

    private var cover: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [theme.bookCover(book.coverStyle).top, theme.bookCover(book.coverStyle).bottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // 书脊：左侧一条半透明竖条，让封面看着像本书而不是一张色块。
            HStack {
                Rectangle()
                    .fill(Color.white.opacity(0.16))
                    .frame(width: 6)
                Spacer(minLength: 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(spacing: 5) {
                Text(book.coverLabel)
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Rectangle()
                    .fill(Color.white.opacity(0.5))
                    .frame(width: 24, height: 1)
                Text("\(book.entryCount)")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                    .monospacedDigit()
            }
            .padding(.horizontal, 6)
        }
        .aspectRatio(Self.coverAspect, contentMode: .fit)
        .overlay(alignment: .topTrailing) { deleteControl }
        .overlay(alignment: .bottomLeading) { sourceControl }
        // 轻微放大 + 边缘高亮（悬停时）。
        .scaleEffect(isHovered ? 1.04 : 1)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isHovered ? theme.accent : Color.clear, lineWidth: 2)
        )
        .shadow(color: theme.shadow, radius: isHovered ? 8 : 4, x: 0, y: isHovered ? 4 : 2)
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .help("\(book.name)（\(book.entryCount) 词）")
    }

    /// 删除按钮：只在悬停时出现（不悬停时封面上不该有「危险的红色」）。
    @ViewBuilder
    private var deleteControl: some View {
        if isHovered || isConfirmingDelete {
            HStack(spacing: 5) {
                Button(action: onDelete) {
                    HStack(spacing: 3) {
                        Image(systemName: isConfirmingDelete ? "checkmark" : "trash")
                        if isConfirmingDelete { Text("确认") }
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, isConfirmingDelete ? 7 : 5)
                    .frame(height: 20)
                    .background(Capsule().fill(Color.black.opacity(0.45)))
                    .overlay(
                        Capsule().strokeBorder(Color.white.opacity(0.55), lineWidth: 1)
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(deleteHelp)

                // 确认态的退路。两段式删除给的第二次点击是**不可逆**的，
                // 必须同时给一个「我不删了」的出口。
                if isConfirmingDelete {
                    Button(action: onCancelDelete) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.black.opacity(0.45)))
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 1))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("取消，不删了")
                }
            }
            .padding(6)
        }
    }

    private var deleteHelp: String {
        if isConfirmingDelete {
            return book.isBuiltIn
                ? "再点一次：把这本书从书架取下（内置词典不会丢，可以恢复）"
                : "再点一次：永久删除这本书（导入的词典文件会一起删掉）"
        }
        return book.isBuiltIn ? "从书架取下（可恢复）" : "删除这本词典（不可恢复）"
    }

    /// 优先级选定框：打勾 = 这本词典参与每日推荐，数字 = 优先级。
    ///
    /// 勾选后**不悬停也一直显示名次** —— 那是有意义的状态，
    /// 藏起来用户就得挨个悬停才知道推荐词是从哪来的。
    @ViewBuilder
    private var sourceControl: some View {
        if isHovered || rank != nil {
            Button(action: onToggleSource) {
                HStack(spacing: 4) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(rank == nil ? Color.white.opacity(0.25) : theme.accent)
                            .frame(width: 12, height: 12)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.8), lineWidth: 1)
                            .frame(width: 12, height: 12)
                        if let rank {
                            Text("\(rank)")
                                .font(.system(size: 8, weight: .heavy, design: .rounded))
                                .foregroundStyle(.black.opacity(0.75))
                        }
                    }
                    Text(rank == nil ? "推荐词源" : "优先级 \(rank ?? 0)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
                .frame(height: 20)
                .background(Capsule().fill(Color.black.opacity(0.45)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.5), lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(6)
            .help(rank == nil
                  ? "打勾：让这本词典参与每日推荐的选词"
                  : "优先级 \(rank ?? 0)。点一下取消（后面的名次自动补位）")
        }
    }
}

/// 词典列表末尾的「导入」按钮：与封面同尺寸，悬停高亮 + 放大。
///
/// 单独一个类型（不是一个 `if`）：导入入口和书封面是两码事，
/// 混在一起会让「悬停导入图标要显示格式气泡」这条逻辑无处安放。
public struct DictionaryImportTile: View {

    @Environment(\.forestTheme) private var theme

    private let isHovered: Bool
    private let isBusy: Bool
    private let onHover: (Bool) -> Void
    private let onTap: () -> Void

    public init(
        isHovered: Bool,
        isBusy: Bool = false,
        onHover: @escaping (Bool) -> Void,
        onTap: @escaping () -> Void
    ) {
        self.isHovered = isHovered
        self.isBusy = isBusy
        self.onHover = onHover
        self.onTap = onTap
    }

    public var body: some View {
        VStack(spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.surface)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isHovered ? theme.accent : theme.divider,
                        style: StrokeStyle(lineWidth: isHovered ? 2 : 1, dash: [5, 4])
                    )
                VStack(spacing: 6) {
                    if isBusy {
                        ProgressView().progressViewStyle(.circular).controlSize(.small)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(isHovered ? theme.accent : theme.secondaryText)
                    }
                    Text("导入词典")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(isHovered ? theme.accent : theme.secondaryText)
                }
            }
            .aspectRatio(DictionaryBookCard.coverAspect, contentMode: .fit)
            .scaleEffect(isHovered ? 1.04 : 1)
            .animation(.easeOut(duration: 0.16), value: isHovered)

            VStack(spacing: 1) {
                Text("导入新词典")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.primaryText)
                Text("JSON 文件")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .onTapGesture(perform: onTap)
        // 原生气泡：悬停约 1 秒后弹出，写全格式要求（页面上那颗提示胶囊只写一行）。
        .help(DictionaryFileFormat.tooltip)
    }
}

/// 导入词典的格式说明（**一处定义，两处用**：悬停气泡 + 原生 tooltip）。
public enum DictionaryFileFormat {

    /// 一行摘要（导入图标旁的提示胶囊用）。
    public static let summary = "JSON 数组：[{\"word\": \"nominal\", \"pos\": \"adj.\", \"zh\": \"名义上的\"}, …]"

    /// 完整说明（原生 tooltip）。
    public static let tooltip = """
    导入词典：选择一个 JSON 文件。

    格式（数组，一条一个词）：
    [{"word": "nominal", "phonetic": "/ˈnɒmɪnl/", "pos": "adj.", "zh": "名义上的"},
     {"word": "diesel", "pos": "n.", "zh": "柴油"}]

    - word 必填（英文单词或词组，最长 48 字符）。
    - phonetic / pos / zh 可省；zh 是中文义项，多个义项用「；」隔开。
    - difficulty 可省（1 简单 / 2 中等 / 3 困难 / 4 词组），默认按「中等」。
    - 也可以写成 {"name": "我的词表", "words": [...]}，name 会成为词典名。
    """
}
