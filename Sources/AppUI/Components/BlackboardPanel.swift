import AIDomain
import SwiftUI

/// 黑板的**粉笔墨绿**两档色。
///
/// 这些是「物件色」（木头 / 板面 / 粉笔），不是语义色 —— 板在日夜两档都是墨绿的，
/// 所以它**不跟着主题走**，跟着「这是一块黑板」这件事走。粉笔字同理：永远白。
enum BlackboardPalette {
    static let frame = Color(hex: 0x9C6B3F)
    static let board = Color(hex: 0x2F4A3C)
    /// 粉笔（正文）。
    static let chalk = Color.white.opacity(0.92)
    /// 粉笔（次要，擦过一遍的那种淡）。
    static let chalkSoft = Color.white.opacity(0.62)
    /// 粉笔（做完了）。
    static let chalkDone = Color(hex: 0x8FE3A8)
    /// 粉笔（还没做的空心圈）。
    static let chalkPending = Color.white.opacity(0.45)
    /// 粉笔（还差一点）。
    static let chalkWarn = Color(hex: 0xF0B95E)}

/// 展开后的大黑板：**今天要交的作业**。
///
/// 与收起态是同一块板，只是抬到了老师头顶、放大到侧栏宽。板上的四件事：
/// 1. 今天做这 N 件（标题 + 连续天数）；
/// 2. 三项任务，各带**可核对的进度**（「2 / 4 轮」不是形容词）；
/// 3. 到期词那一行（到期为 0 也要说清楚）；
/// 4. 一个跳去「学习进度」页看今日任务卡的小图标。
///
/// ⚠️ 高度**由内容决定**，但夹在 `maxHeight` 以内（超出就内部滚动）——
/// 用户要的是「高度按实际显示情况确定」，不是「塞满整条侧栏」。
struct BlackboardPanel: View {

    let theme: ForestTheme
    let plan: DailyPlan
    let streakDays: Int
    /// **今天起初**（0 点）到期的词数 —— 复习任务的固定指标（不是「此刻到期」）。
    let dueAtDayStart: Int
    /// 上面那批词里今天已经复习过的个数。
    let reviewedOfDue: Int
    /// 今天复习过的**不同**词数（含今天新加的词，只在今天起初没有到期词时兜个话）。
    let reviewedToday: Int
    let todayTokens: Int
    /// 今日全部完成 → 盖个章 + 放一次烟花。
    var isCelebrating: Bool = false
    /// 板能长到的最大高度（侧栏实测出来的）。
    var maxHeight: CGFloat = 420
    var onOpenTask: ((DailyTask.Kind) -> Void)? = nil
    var onOpenProgress: (() -> Void)? = nil
    var onCollapse: (() -> Void)? = nil

    /// 板内容的自然高度（量出来才知道，写死就会在长文案上截断）。
    @State private var contentHeight: CGFloat = 0

    /// 木框的宽度 = 侧栏内容宽度（展开宽度减掉两侧 12pt 内边距）。
    ///
    /// 这样板与导航项**左右对齐**，看起来就是「与左边栏同宽」，
    /// 又不会把阴影和木框顶到侧栏边缘、压住和中间栏的分隔线。
    static let frameWidth: CGFloat = AppSidebar.expandedWidth - 24
    /// 板面（木框里边那块墨绿）的宽度：木框每侧让出 5pt。
    static let surfaceWidth: CGFloat = frameWidth - 10

    var body: some View {
        ZStack {
            boardSurface

            // 烟花要飞到板外面才像烟花：不裁切、不吃点击。
            if isCelebrating {
                CelebrationFireworks(tint: theme.accent, secondary: theme.glow)
                    .padding(-48)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - 板面

    private var boardSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(BlackboardPalette.frame)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(BlackboardPalette.board)
                .padding(5)

            ScrollView(.vertical, showsIndicators: false) {
                content
                    .padding(11)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: BoardContentHeightKey.self,
                                value: proxy.size.height
                            )
                        }
                    )
            }
            // ⚠️ 滚动区宽度要按**板面**算，不能用木框宽度：用木框宽度的话内容会比板面宽 10pt，
            // 文字和点击区都会压到木框上（离屏字符图量出来的边界）。
            .frame(width: Self.surfaceWidth, height: panelHeight)
            .onPreferenceChange(BoardContentHeightKey.self) { contentHeight = $0 }

            if isCelebrating { stamp }
        }
        .frame(width: Self.frameWidth, height: panelHeight + 10)
        .shadow(color: theme.shadow, radius: 10, x: 0, y: 4)
        .animation(.spring(response: 0.34, dampingFraction: 0.85), value: panelHeight)
        // 板自己的矩形整块吃掉点击：板挡住的东西（侧栏入口）不该被点到，
        // 圆角外那几个像素和行与行之间的空隙也一样（板外才是穿透区）。
        .contentShape(Rectangle())
    }

    /// 板面高 = 内容自然高 + 一点呼吸位，夹在 [110, maxHeight]。
    ///
    /// ⚠️ 追加的那 4pt 是给「最后一行与板底」留的视觉呼吸 —— 以前是 22（外加木框 10），
    /// 板底会多出一大条空板（用户量出来的）。数值变了要连带看
    /// `BlackboardRenderTests` 里「板底留白」那条断言。
    private var panelHeight: CGFloat {
        guard contentHeight > 0 else { return 200 }
        return min(max(contentHeight + Self.bottomBreathing, 110), maxHeight)
    }

    /// 板底多留出来的呼吸位（内容自身已有 11pt 内边距，木框再加 5pt）。
    static let bottomBreathing: CGFloat = 4

    // MARK: - 板上的内容

    private var content: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if plan.tasks.isEmpty {
                emptyHint
            } else {
                VStack(spacing: 7) {
                    ForEach(plan.tasks) { task in
                        taskRow(task)
                    }
                }
            }
            dueRow
            if let remaining = TodayPanel.remainingLine(plan: plan) {
                remainingRow(remaining)
            }
            footerRow
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: plan.isAllDone ? "checkmark.seal.fill" : "scroll.fill")
                .font(.system(size: 11))
                .foregroundStyle(plan.isAllDone ? BlackboardPalette.chalkDone : BlackboardPalette.chalk)
            Text(TodayPanel.title(plan: plan))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(BlackboardPalette.chalk)
            Spacer(minLength: 4)
            Text("连续 \(streakDays) 天")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(BlackboardPalette.chalkSoft)
                .monospacedDigit()
            // 跳去「学习进度」看今日任务卡：板上放不下详情，但要留一条能去的地方。
            Button {
                onOpenProgress?()
            } label: {
                Image(systemName: AppSection.progress.systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(BlackboardPalette.chalkSoft)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Self.jumpHelp)
            .accessibilityLabel(Self.jumpHelp)
            Button {
                onCollapse?()
            } label: {
                Image(systemName: Self.collapseIcon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(BlackboardPalette.chalkSoft)
                    .frame(width: 16, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Self.collapseHelp)
            .accessibilityLabel(Self.collapseHelp)
        }
    }

    // MARK: - 右上角两个小按钮的文案与图标

    /// 跳转按钮的提示：说的是**跳哪儿**，不是「看什么东西」。
    ///
    /// ⚠️ 这两句以前写在 `.help` 里却没人看得见：整条侧栏被套了一层老师介绍的 `.help`，
    /// 停在按钮上弹出来的永远是那句介绍（用户实测）。现在外层那层撤了（见 `AppSidebar`），
    /// 这两句才真的说得出口 —— 别再把 `.help` 往上套。
    static let jumpHelp = "跳转到「学习进度」里的今日任务卡片"
    /// 收起按钮的提示。
    static let collapseHelp = "收起今日作业"
    /// 收起用**朝下**的箭头：板是往上长出来的，收起 = 落回去（用户点名要下三角，不是上三角）。
    static let collapseIcon = "chevron.down"

    private var emptyHint: some View {
        Text("今天还没有安排 —— 先开口说两句，或者去跟读一页，练完这里就会有进度。")
            .font(.system(size: 10, design: .rounded))
            .foregroundStyle(BlackboardPalette.chalkSoft)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func taskRow(_ task: DailyTask) -> some View {
        let done = task.isDone
        return Button {
            onOpenTask?(task.kind)
        } label: {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(done ? BlackboardPalette.chalkDone : BlackboardPalette.chalkPending)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(task.title)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(BlackboardPalette.chalk)
                            .strikethrough(done, color: BlackboardPalette.chalkSoft)
                        Spacer(minLength: 2)
                        Text(task.progressText)
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(done ? BlackboardPalette.chalkDone : BlackboardPalette.chalk)
                            .monospacedDigit()
                    }
                    Text(task.reason)
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(BlackboardPalette.chalkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(done ? 0.10 : 0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onOpenTask == nil)
        .help(done ? "已经完成：\(task.reason)" : "去做：\(task.title)")
    }

    private var dueRow: some View {
        HStack(spacing: 6) {
            Image(systemName: hasReviewWork ? "text.book.closed.fill" : "checkmark.circle")
                .font(.system(size: 9))
                .foregroundStyle(hasReviewWork ? BlackboardPalette.chalk : BlackboardPalette.chalkDone)
            Text(TodayPanel.dueLine(
                dueAtDayStart: dueAtDayStart,
                reviewedOfDue: reviewedOfDue,
                reviewedToday: reviewedToday
            ))
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(BlackboardPalette.chalkSoft)
            Spacer(minLength: 0)
        }
    }

    /// 今天起初到底有没有复习任务（图标左右都要用它，别再各写一遍条件）。
    private var hasReviewWork: Bool { dueAtDayStart > 0 }

    private func remainingRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "hourglass")
                .font(.system(size: 9))
                .foregroundStyle(BlackboardPalette.chalkWarn)
            Text(text)
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(BlackboardPalette.chalkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// 今日 token 用量**不因为展开就消失**：挪到板脚一行小字。
    private var footerRow: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            Text("今日 \(ChatView.tokenCount(todayTokens)) tokens")
                .font(.system(size: 8, design: .rounded))
                .foregroundStyle(BlackboardPalette.chalkPending)
                .monospacedDigit()
        }
    }

    /// 全部完成时盖在板上的章（粉笔手写的那种歪一点更自然，但别真做随机 —— 图对不上）。
    private var stamp: some View {
        Text("今日完成")
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(BlackboardPalette.chalkDone.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(BlackboardPalette.chalkDone.opacity(0.8), lineWidth: 1.2)
            )
            .rotationEffect(.degrees(-8))
            .transition(.scale.combined(with: .opacity))
    }
}

// MARK: - 量高

/// 板内容的自然高度（写在 `ScrollView` 里量，拿到之后再决定板多高）。
private struct BoardContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
