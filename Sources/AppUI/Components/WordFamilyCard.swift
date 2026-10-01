import AIDomain
import SwiftUI

/// 词族树卡片（查词结果页最下面那一块）。
///
/// 回答的是「同一个词根底下还长着哪些词」：默认只列**词根的直接分支**，
/// 点右上角「展开关联词」才铺开每个分支下的关联词。
///
/// 三条口径：
/// 1. **没有分支就整张卡片不出现**（用户口径：没有就整段不出现，不留空壳）；
/// 2. 树上的每个词都能点 → 查那个词（与派生词 / 近义词同一套跳转）；
/// 3. 当前正在查的那个词在树上**标出来**（「当前」徽章 + 高亮描边）——
///    否则展开后满屏的词，用户不知道自己在整棵树的哪个位置。
public struct WordFamilyCard: View {

    @Environment(\.forestTheme) private var theme

    private let family: DictionaryWordFamily
    /// 当前正在查的词（用来标「当前」）。
    private let currentWord: String
    private let isSpeaking: (String) -> Bool
    private let isPreparing: (String) -> Bool
    private let onSpeak: (String) -> Void
    private let onStopSpeak: () -> Void
    private let onOpenRelated: (String) -> Void

    @State private var isExpanded = false
    @State private var hoveredWord: String?
    /// 外部传入的展开状态（**测试钩子**，产品代码不传）。
    ///
    /// ⚠️ 为什么要有这个钩子：展开/收起是卡片内部的 `@State`，而 SwiftUI 的按钮
    /// 收不到合成鼠标事件 —— 离屏渲染里**没有任何办法点它**。没有钩子就只能验证
    /// 「收起态画对了」，展开态（用户点开才看见的那棵树）就永远没有回归。
    /// 传进来就用外部的，不传就用自己那份 —— 产品行为一模一样。
    private let externalExpansion: Binding<Bool>?

    private var expansion: Binding<Bool> { externalExpansion ?? $isExpanded }

    public init(
        family: DictionaryWordFamily,
        currentWord: String = "",
        isSpeaking: @escaping (String) -> Bool = { _ in false },
        isPreparing: @escaping (String) -> Bool = { _ in false },
        onSpeak: @escaping (String) -> Void = { _ in },
        onStopSpeak: @escaping () -> Void = {},
        onOpenRelated: @escaping (String) -> Void = { _ in },
        expansion: Binding<Bool>? = nil
    ) {
        self.family = family
        self.currentWord = currentWord
        self.isSpeaking = isSpeaking
        self.isPreparing = isPreparing
        self.onSpeak = onSpeak
        self.onStopSpeak = onStopSpeak
        self.onOpenRelated = onOpenRelated
        self.externalExpansion = expansion
    }

    /// 树上的一个 ​**叶子位置**（把树拍平成列表后的一个元素）。
    ///
    /// ⚠️ 树必须用**拍平后的列表**画，不能用递归视图：
    /// SwiftUI 的 `some View` 不透明类型不允许「自身指回自己」（编译直接报
    /// `#OpaqueTypeInference`：opaque type 以自身定义）。先把树走一遍摊成 `[Row]`，
    /// 再用一次 `ForEach` 画完 —— 顺带也让 `ForEach` 的 id 稳定可控。
    private struct Row: Identifiable {
        let id: String
        let node: DictionaryFamilyNode
        let depth: Int
        let isLastChild: Bool
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    rowView(row)
                }
            }
        }        .appPadding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(theme.surfaceAlt.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.divider, lineWidth: 1)
        )
    }

    // MARK: - 表头

    private var header: some View {
        HStack(spacing: 8) {
            Text("词族树")
                .appFont(11, weight: .semibold, design: .rounded)
                .foregroundStyle(theme.secondaryText)

            if !family.root.isEmpty {
                HStack(spacing: 5) {
                    Text("词根")
                        .appFont(9, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.foliage)
                    Text(family.root)
                        .appFont(11, weight: .bold, design: .rounded)
                        .foregroundStyle(theme.primaryText)
                    if !family.rootMeaning.isEmpty {
                        Text(family.rootMeaning)
                            .appFont(10, design: .rounded)
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Capsule().fill(theme.surface))
                .overlay(Capsule().strokeBorder(theme.divider, lineWidth: 1))
            }

            Spacer(minLength: 0)

            // ⚠️ 这是**纯文字按钮**（没有底色，与右侧的胶囊按钮区分）：
            // 展开/收起是一次视图内的动作，不产生新内容，做成实心按钮会跟「添加复习」抢注意力。
            Button {
                withAnimation(.app(.reveal)) { expansion.wrappedValue.toggle() }
            } label: {
                HStack(spacing: 3) {
                    Text(expansion.wrappedValue ? "收起关联词" : "展开关联词")
                    Image(systemName: expansion.wrappedValue ? "chevron.up" : "chevron.down")
                        .appFont(9, weight: .semibold)
                }
                .appFont(11, weight: .semibold, design: .rounded)
                .foregroundStyle(theme.accentCool)
                .contentShape(Rectangle())
            }
            .buttonStyle(.appPressable)
            .help(expansion.wrappedValue ? "收起这一层的关联词" : "展开每个分支下的关联词")
        }
    }

    // MARK: - 树的每一行

    /// 按当前展开状态把列表摊平。**展开时才走进 `children`**，其余时候只留一层。
    private var rows: [Row] {
        var result: [Row] = []
        let expanded = externalExpansion?.wrappedValue ?? isExpanded
        func walk(_ node: DictionaryFamilyNode, depth: Int, isLastChild: Bool, prefix: String) {
            let id = "\(prefix)/\(node.id)"
            result.append(Row(id: id, node: node, depth: depth, isLastChild: isLastChild))
            guard expanded else { return }
            for (index, child) in node.children.enumerated() {
                walk(
                    child,
                    depth: depth + 1,
                    isLastChild: index == node.children.count - 1,
                    prefix: id
                )
            }
        }
        for (index, node) in family.branches.enumerated() {
            walk(node, depth: 0, isLastChild: index == family.branches.count - 1, prefix: "root")
        }
        return result
    }

    private func rowView(_ row: Row) -> some View {
        HStack(alignment: .top, spacing: 6) {
            connector(depth: row.depth, isLastChild: row.isLastChild)
            nodeCard(row.node, depth: row.depth)
                .appPadding(.bottom, 8)
        }
    }

    /// 左侧那根「树干 + 圆点」。圆点对在词条卡的首行（约 12pt 处），
    /// 线只在**不是最后一个孩子**时往下延伸 —— 最后一个还画下去，就成了没接头的悬空线。
    private func connector(depth: Int, isLastChild: Bool) -> some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(theme.divider)
                    .frame(width: 1, height: 13)
                if !isLastChild {
                    Rectangle()
                        .fill(theme.divider)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            Circle()
                .fill(theme.foliage.opacity(depth == 0 ? 0.9 : 0.55))
                .frame(width: 6, height: 6)
                .appPadding(.top, 10)
        }
        .frame(width: 16, alignment: .center)
        .padding(.leading, CGFloat(depth) * 18)
    }

    private func nodeCard(_ node: DictionaryFamilyNode, depth: Int) -> some View {
        let isCurrent = !currentWord.isEmpty
            && node.word.caseInsensitiveCompare(currentWord) == .orderedSame
        let tint = depth == 0 ? theme.accentCool : theme.foliage

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    onOpenRelated(node.word)
                } label: {
                    Text(node.word)
                        .appFont(13, weight: .semibold, design: .rounded)
                        .foregroundStyle(hoveredWord == node.word ? tint.opacity(0.65) : theme.primaryText)
                        .underline(hoveredWord == node.word, color: tint.opacity(0.65))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.appPressable)
                .onHover { hovering in
                    hoveredWord = hovering ? node.word : (hoveredWord == node.word ? nil : hoveredWord)
                }
                .help("查「\(node.word)」")

                speakButton(node.word, label: "朗读 \(node.word)")

                if isCurrent {
                    badge("当前", tint: theme.accentCool)
                } else if depth > 0 {
                    badge("关联词", tint: theme.secondaryText)
                }
                if !node.pos.isEmpty {
                    Text(node.pos)
                        .appFont(10, weight: .medium, design: .rounded, italic: true)
                        .foregroundStyle(theme.accent)
                }
                if !node.translation.isEmpty {
                    Text(node.translation)
                        .appFont(11, design: .rounded)
                        .foregroundStyle(theme.primaryText.opacity(0.85))
                }
                Spacer(minLength: 0)
            }

            if !node.morphology.isEmpty {
                morphologyRow(node.morphology)
            }
        }
        .padding(.horizontal, 10)
        .appPadding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isCurrent ? theme.selection : theme.surface.opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isCurrent ? theme.accentCool.opacity(0.55) : theme.divider, lineWidth: 1)
        )
    }

    /// 构词说明：按 ` + ` 拆成几段，每段一个浅底小块（与「构词拆分」那块的视觉同源）。
    /// 段内第一个空格之前是**词素本身**（`riv` / `-al`），加粗染色；后面是它的意思。
    private func morphologyRow(_ text: String) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(Self.segments(of: text).enumerated()), id: \.offset) { index, segment in
                if index > 0 {
                    Text("+")
                        .appFont(10, weight: .bold, design: .rounded)
                        .foregroundStyle(theme.secondaryText)
                }
                let pieces = Self.splitMorpheme(segment)
                HStack(spacing: 4) {
                    Text(pieces.morpheme)
                        .appFont(10.5, weight: .bold, design: .rounded)
                        .foregroundStyle(theme.foliage)
                    if !pieces.meaning.isEmpty {
                        Text(pieces.meaning)
                            .appFont(10, design: .rounded)
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .padding(.horizontal, 6)
                .appPadding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.surface.opacity(0.9))
                )
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 小件

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .appFont(9, weight: .semibold, design: .rounded)
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .appPadding(.vertical, 1)
            .background(Capsule().fill(tint.opacity(0.14)))
    }

    private func speakButton(_ text: String, label: String) -> some View {
        SpeakButton(
            isActive: isSpeaking(text),
            isPreparing: isPreparing(text),
            accessibilityLabel: label
        ) {
            if isSpeaking(text) { onStopSpeak() } else { onSpeak(text) }
        }
    }

    // MARK: - 构词串拆分（纯函数）

    /// 按 ` + ` / `+` 拆段（模型给的可能是半角加号两侧无空格）。
    nonisolated static func segments(of text: String) -> [String] {
        text
            .replacingOccurrences(of: " + ", with: "|")
            .replacingOccurrences(of: "+ ", with: "|")
            .replacingOccurrences(of: " +", with: "|")
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 段内拆「词素 + 它的意思」：`riv 河：溪流` → (`riv`, `河：溪流`)。
    nonisolated static func splitMorpheme(_ segment: String) -> (morpheme: String, meaning: String) {
        guard let space = segment.firstIndex(of: " ") else { return (segment, "") }
        let morpheme = String(segment[segment.startIndex..<space])
        let meaning = String(segment[segment.index(after: space)...])
            .trimmingCharacters(in: .whitespaces)
        // 只有一个空格且后面什么都没有：整段当词素。
        return meaning.isEmpty ? (segment, "") : (morpheme, meaning)
    }
}
