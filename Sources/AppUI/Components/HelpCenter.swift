import AIDomain
import SwiftUI

/// 帮助中心的一节。
///
/// ⚠️ 正文里**不写会漂移的东西**：路径、快捷键、具体数字一律不写死 ——
/// 数据目录在设置页有「在 Finder 中打开」，快捷键在设置页有「快捷键中心」（还能改），
/// 这里写死一份，用户改完快捷键后帮助页就成了错的说明书。
public struct HelpTopic: Identifiable, Sendable, Equatable {

    public let id: String
    public let title: String
    public let systemImage: String
    /// 收起态也要看得见的一句话（用户靠它决定要不要展开）。
    public let summary: String
    public let bullets: [String]

    public init(id: String, title: String, systemImage: String, summary: String, bullets: [String]) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.summary = summary
        self.bullets = bullets
    }

    /// 搜索用的整段文本（标题 + 摘要 + 正文）。
    var searchableText: String {
        ([title, summary] + bullets).joined(separator: " ")
    }
}

public enum HelpCenter {

    /// 帮助中心的全部内容，**按用户会走的先后顺序**排，不按代码模块排。
    public static let topics: [HelpTopic] = [
        HelpTopic(
            id: "setup",
            title: "先接一个模型",
            systemImage: "cpu",
            summary: "老师靠模型说话。没接模型时，林子里会举个牌子告诉你缺什么。",
            bullets: [
                "两条路：本机 Ollama（免费、不出机器）或外部 API（自备密钥）。都在「设置 → 模型管理」里接。",
                "接好之后能力名旁边的小绿点才是「生效中」——它看的是当前真正在用的那一个，不是「填过密钥」。",
                "本机模型需要先把服务跑起来：设置页对应卡片上有「启动」按钮；闲置久了会自动挂起，用到时自己回来。",
                "语音（朗读 / 识别）是另一套模型，同样在设置页里接，不接也照样能打字练。",
            ]
        ),
        HelpTopic(
            id: "practice",
            title: "练习：自由对话",
            systemImage: "leaf.fill",
            summary: "开口说话，老师按你选的人格档位回应，说完给你纠错。",
            bullets: [
                "老师每次回完会顺手改你的句子，纠错卡单独挂在消息下面，不混进正文。",
                "看到不会的词：选中它就能查（划词卡片），查完可以直接收进词汇本。",
                "输入框支持多行、文件与图片；回车发送，换行用 Shift + 回车。",
                "老师会记得你：反复犯的错、练过的话题都记在学习记忆里，也可以在设置页清除。",
            ]
        ),
        HelpTopic(
            id: "scenarios",
            title: "情景对话：闯关",
            systemImage: "map.fill",
            summary: "选一个情景，完成主线任务和教学重点就能过关拿星。",
            bullets: [
                "每一关有明确的「主线任务」和几条「教学重点」，结算时按这两项判定，不是按聊了多久。",
                "练完会自动复盘：给了哪些纠错、说得怎么样，看完再决定要不要重来。",
                "复盘后练习流水会清理掉，所以记录里的对话条数以复盘快照为准——这是口径，不是丢了数据。",
                "大树上的关卡与情景是一一对应的，点到哪一关就跳哪一关。",
            ]
        ),
        HelpTopic(
            id: "skills",
            title: "听、说、读、写",
            systemImage: "square.stack.3d.down.right.fill",
            summary: "四个专项各自独立，练什么记什么。",
            bullets: [
                "跟读：每天一批句子，可逐句也可整段（影子跟读），会给发音评测和音素级反馈。",
                "听力：三种形式——精听默写、关键词捕捉、听句选义，素材和跟读同批生成。",
                "写作：每天一题，交卷后老师批改，改完可以留着回看。",
                "阅读：每天一篇短文，配理解题；正文里划词就能查生词，顺手收进词汇本。",
            ]
        ),
        HelpTopic(
            id: "vocabulary",
            title: "词汇本与词典",
            systemImage: "text.book.closed.fill",
            summary: "遇到生词随手收，到期自动来复习。",
            bullets: [
                "收词有三条路：划词卡片「加入词汇本」、每日推荐里挑、词汇本里手动加。",
                "复习按间隔重复排：快忘了的词自己会冒出来，出现在「今天」的任务里。",
                "内置词典（六级 / 雅思 / 牛津 / 常用搭配）直接查，查过的词留在「最近查过」里。",
                "不认识的词组也能查：划中的是变体（复数、过去式）会先还原成原形再解释。",
            ]
        ),
        HelpTopic(
            id: "progress",
            title: "记录、连续与这片林子",
            systemImage: "chart.line.uptrend.xyaxis",
            summary: "练过的都记着：今天、这周、这一年。",
            bullets: [
                "「今天」是三件事：对话轮数、跟读句数、到期复习。当天只增不减，跨天重算。",
                "连续天数看的是「有没有学过一天」，不是练了多久；忙的时候做完保底档也算数。",
                "年度记录是一整年的格子，颜色深浅表示那天练了多少，鼠标悬停看细节。",
                "右边那棵树跟着你长：果实是练出来的成果，小动物会在林子里活动，点它们有反应。",
            ]
        ),
        HelpTopic(
            id: "data",
            title: "数据与隐私",
            systemImage: "lock.fill",
            summary: "学习数据都在本机；什么会出机器，设置页里写得明明白白。",
            bullets: [
                "学习库、配置、调用留痕都在本机。设置页「存储与缓存」里有「在 Finder 中打开」，能看到它们在哪。",
                "备份：手动导出的是一个压缩包（含学习库和 -wal，缺了它恢复出来会少内容）。也可以在设置页开自动备份，按天补。",
                "恢复：导入备份会先校验，坏包当场拦下；确认后会先给当前数据留一份，重启时才真正替换。",
                "会不会外发，只看「数据出不出这台机器」：本机模型与本机语音不出机器；接了云端模型或云端语音，那一句话才会发给对方。设置页「隐私」里逐条列了谁发过什么。",
            ]
        ),
        HelpTopic(
            id: "more",
            title: "还有这些可以调",
            systemImage: "slider.horizontal.3",
            summary: "界面、提醒、动效、快捷键都在设置页。",
            bullets: [
                "快捷键：设置页「快捷键中心」可以自己改，改完立刻生效，撞键会当场告诉你被谁占了。",
                "动效：系统开了「减少动态效果」会自动跟随，也可以手动选档。",
                "提醒：可以定一个每天练一会儿的时间，到点本地通知（数据不出机器）。",
                "林子：可以设置跟随真实时间（天黑切夜景）和真实季节（叶色随月份）。",
            ]
        ),
    ]

    /// 关键词过滤（纯函数：标题 / 摘要 / 正文任一处命中就留下）。
    ///
    /// 空查询返回全部 —— 「什么都没输」不是「什么都不匹配」。
    public static func topics(matching query: String, in topics: [HelpTopic] = HelpCenter.topics) -> [HelpTopic] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return topics }
        return topics.filter { $0.searchableText.lowercased().contains(needle) }
    }
}

/// 应用内帮助中心（#413）。
///
/// 展开 / 收起沿用记录页那一套：**只淡入不位移**（见 `DisclosureBlock`）——
/// 从哪一条点开，内容就从哪一条下面长出来，不会从卡片上方滑进来。
public struct HelpCenterView: View {

    @Environment(\.forestTheme) private var theme
    @State private var query = ""
    /// 展开的章节。默认展开第一节（新用户最需要的就是「先接一个模型」）。
    @State private var expandedIDs: Set<String> = []
    var onClose: () -> Void = {}

    public init(onClose: @escaping () -> Void = {}) {
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.divider)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(HelpCenter.topics(matching: query)) { topic in
                        section(topic)
                    }
                    if HelpCenter.topics(matching: query).isEmpty {
                        Text("没有匹配「\(query)」的条目。试试「模型」「复习」「备份」。")
                            .appFont(12, design: .rounded)
                            .foregroundStyle(theme.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .appPadding(.vertical, 16)
                    }
                }
                .appPadding(16)
            }
        }
        .frame(width: 640, height: 560)
        .background(theme.panel)
        .onAppear {
            guard expandedIDs.isEmpty, let first = HelpCenter.topics.first else { return }
            expandedIDs = [first.id]
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "questionmark.circle.fill")
                .appFont(16)
                .foregroundStyle(theme.accent)
            Text("使用说明")
                .appFont(15, weight: .semibold, design: .rounded)
                .foregroundStyle(theme.primaryText)
            Spacer(minLength: 8)
            TextField("搜一下（比如「复习」「备份」）", text: $query)
                .textFieldStyle(.plain)
                .appFont(12, design: .rounded)
                .padding(.horizontal, 8)
                .frame(width: 220, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(theme.divider, lineWidth: 1)
                        )
                )
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .appFont(11, weight: .semibold)
                    .foregroundStyle(theme.secondaryText)
            }
            .buttonStyle(.appPressable)
            .help("关闭")
        }
        .padding(.horizontal, 16)
        .appPadding(.vertical, 12)
    }

    private func section(_ topic: HelpTopic) -> some View {
        let isExpanded = expandedIDs.contains(topic.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.app(.reveal)) {
                    if isExpanded { expandedIDs.remove(topic.id) } else { expandedIDs.insert(topic.id) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: topic.systemImage)
                        .appFont(12)
                        .foregroundStyle(isExpanded ? theme.accent : theme.secondaryText)
                        .frame(width: 16)
                    Text(topic.title)
                        .appFont(13, weight: .semibold, design: .rounded)
                        .foregroundStyle(theme.primaryText)
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .appFont(9, weight: .bold)
                        .foregroundStyle(theme.secondaryText)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.appPressable)

            if !isExpanded {
                Text(topic.summary)
                    .appFont(11, design: .rounded)
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .appPadding(.top, 4)
                    .padding(.leading, 24)
            }

            if isExpanded {
                DisclosureBlock {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(topic.bullets, id: \.self) { line in
                            HStack(alignment: .top, spacing: 6) {
                                Circle()
                                    .fill(theme.accent.opacity(0.55))
                                    .frame(width: 4, height: 4)
                                    .appPadding(.top, 5)
                                Text(line)
                                    .appFont(12, design: .rounded)
                                    .foregroundStyle(theme.primaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .appPadding(.top, 6)
                    .padding(.leading, 24)
                }
            }
        }
        .appPadding(.vertical, 8)
    }
}
