import AppCore
import SwiftUI

/// 侧边栏底部的「老师角落」：
/// - 老师背后挂一块小黑板，白色粉笔字显示**今日全局 token 用量**；
/// - 老师头顶按今日用量不时冒出小气泡：<100 万督促学习、100 万~500 万鼓励、>500 万提醒休息。
public struct TeacherCorner: View {

    @Environment(\.forestTheme) private var theme
    let kind: AnimalKind
    let isSleeping: Bool
    /// 今日整个应用累计使用的 token（估算）。
    let todayTokens: Int
    /// 老师气泡开关（设置可关）。
    var bubblesAllowed: Bool = true

    @State private var nudge: String?
    @State private var nudgeTick = 0
    private let nudgeTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    public init(kind: AnimalKind, isSleeping: Bool, todayTokens: Int, bubblesAllowed: Bool = true) {
        self.kind = kind
        self.isSleeping = isSleeping
        self.todayTokens = todayTokens
        self.bubblesAllowed = bubblesAllowed
    }

    public var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .top) {
                if let nudge {
                    SpeechBubble(text: nudge, maxWidth: 150)
                        .fixedSize()
                        .offset(y: -46)
                        .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .bottom)))
                        .zIndex(5)
                }

                ZStack(alignment: .bottom) {
                    // 小黑板：挂在老师背后偏左上
                    Blackboard(text: chalkText)
                        .offset(x: -34, y: -30)
                        .rotationEffect(.degrees(-3))
                        .zIndex(1)

                    CuteAnimalView(kind: kind, isSleeping: isSleeping, size: 84, accessory: .teacher)
                        .zIndex(2)
                }
                .frame(width: 176, height: 128)
            }

            Text(kind.displayName + "老师")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.primaryText)
            Text(theme.isNight ? "夜深了，明天再爬一棵树" : "今天也要一起加油哦")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 8)
        .task(id: nudgeTick) {
            guard nudge != nil else { return }
            try? await Task.sleep(nanoseconds: 3_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { nudge = nil }
        }
        .onReceive(nudgeTimer) { _ in
            // 不太频繁：每 15 秒Tick一次，约四成概率冒泡；正在显示时不打断；设置可关
            guard bubblesAllowed, nudge == nil, !isSleeping, Double.random(in: 0..<1) < 0.42 else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                nudge = Self.randomNudge(for: todayTokens)
            }
            nudgeTick += 1
        }
    }

    /// 黑板粉笔字：两行（「今日」+ 用量缩写）。
    private var chalkText: String { ChatView.tokenCount(todayTokens) }

    // MARK: - 气泡文案（按今日用量分档，随机抽取）

    /// < 100 万：督促学习。
    private static let urgeLines = [
        "今天还没开张呢，来读一句吧！",
        "单词们都想你了，快回来练两句～",
        "每日一句，胜过周末狂练！",
        "小树苗等你浇水呢，开口就是养分！",
        "今天的.first sentence 从哪里开始？就现在！",
        "别让我等太久哦，读一句我听听！",
        "魔法单词书还空着呢，填一个进去？",
        "五分钟就好，跟我念一句好不好？",
        "森林的清晨最适合朗读啦，来一段？",
        "你的椅子和小动物都坐好了，就差你！",
    ]

    /// 100 万 ~ 500 万：鼓励/奖励。
    private static let cheerLines = [
        "今天火力全开，森林为你骄傲！",
        "这个量，单词本都要给你颁勋章了！",
        "进步神速！奖励你摸摸小树苗🌳",
        "你就是今天的攀登之星，继续闪耀！",
        "老师们都私下夸你了，真的！",
        "这状态保持住，下周就是小高手！",
        "今天的努力，星星都记在账上啦⭐️",
        "读得越多，爬得越高，太棒啦！",
        "给你一朵小红花，今天的你超努力！",
        "照这个节奏，云雀高枝不在话下！",
    ]

    /// > 500 万：提醒休息。
    private static let restLines = [
        "练了这么多，让眼睛和耳朵歇会儿吧☕️",
        "学得多也要歇得好，去窗边看看远处？",
        "喝口水，伸个懒腰，森林等你回来。",
        "小动物们说：你辛苦啦，休息五分钟！",
        "大脑也要存档哦，休息巩固记得牢。",
        "今天已经非常棒了，别累着小嗓子～",
        "去揉揉小树、望望天空，再回来冲刺！",
        "休息不是偷懒，是为了爬得更高。",
        "合上眼睛听一段轻音乐吧，你值得。",
        "休息时间到！回来时给你讲新故事～",
    ]

    nonisolated public static func randomNudge(for tokens: Int) -> String {
        let pool: [String]
        switch tokens {
        case ..<1_000_000: pool = urgeLines
        case 1_000_000..<5_000_000: pool = cheerLines
        default: pool = restLines
        }
        return pool.randomElement() ?? pool[0]
    }
}

// MARK: - 小黑板（木框 + 墨绿板面 + 白色粉笔字）

private struct Blackboard: View {

    @Environment(\.forestTheme) private var theme
    let text: String

    private enum Palette {
        static let frame = Color(hex: 0x9C6B3F)
        static let frameDark = Color(hex: 0x7A4E2B)
        static let board = Color(hex: 0x2F4A3C)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.frame)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Palette.board)
                .padding(5)
            VStack(spacing: 1) {
                Text("今日")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                Text(text)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("tokens")
                    .font(.system(size: 8, design: .rounded))
            }
            .foregroundStyle(Color.white.opacity(0.92))
            .shadow(color: .white.opacity(0.25), radius: 1.2, x: 0, y: 0)
        }
        .frame(width: 74, height: 60)
        .shadow(color: theme.shadow, radius: 5, x: 0, y: 3)
    }
}
