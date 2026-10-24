import AIDomain
import AppCore
import SwiftUI

// MARK: - 色板

public enum ForestPalette: String, CaseIterable, Sendable, Identifiable {
    case day
    case night

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .day: "白天森林"
        case .night: "夜晚森林"
        }
    }

    public var iconName: String {
        switch self {
        case .day: "sun.max.fill"
        case .night: "moon.stars.fill"
        }
    }
}

public extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// 统一语义色板。**禁止在 View 里写死颜色字面量**（AGENTS.md §10A）。
public struct ForestTheme: Sendable, Equatable {

    public let palette: ForestPalette
    /// 一天里的时刻（nil = 不跟随时间，用色板本来的天空）。
    ///
    /// ⚠️ 与 `season` 一样**只改插画层**：天空、山丘、叶色。下面那些
    /// `accent` / `warning` / `streak` / 文本与表面色一个都不看它 ——
    /// 它们被 `ThemeContrastTests` 用对比度和 ΔE 钉住，随时刻漂会当场失真。
    public let moment: ForestMoment?
    /// 季节（nil = 不分季节）。同样只改插画层。
    public let season: ForestSeason?
    /// 天气（nil = 不跟随天气）。同样只改插画层：多云多几朵云、雨天多一层雨丝，
    /// 天空渐变**本色不变**（ThemeContrastTests 钉的语义色与对比度更是一概不看它）。
    public let weather: ForestWeather?
    /// 学习节奏（#600；nil = 不跟随学习节奏）。只改插画层：
    /// `flourishing` 时叶色/山丘走「盛」档（`ForestAtmosphere.lush`），
    /// 且本地兜底天气偏晴（见 `ForestThemeResolver`）。**非惩罚性**：停滞档无任何效果。
    public let momentum: ForestMomentum?

    public init(palette: ForestPalette, moment: ForestMoment? = nil, season: ForestSeason? = nil,
                weather: ForestWeather? = nil, momentum: ForestMomentum? = nil) {
        self.palette = palette
        self.moment = moment
        self.season = season
        self.weather = weather
        self.momentum = momentum
    }

    public var isNight: Bool { palette == .night }

    // 天空
    //
    // 两层叠加，顺序不能反：
    // ① **时刻**给骨架（黎明偏暖 / 正午透亮 / 黄昏蜜橘）——这层说的是「几点钟」；
    // ② **季节**给色温（春淡青 / 夏原色 / 秋暖金 / 冬冷白）——这层说的是「几月」。
    //
    // 为什么不给四季各写一套渐变：4 季 × 6 时刻 = 24 组手搓色值，谁也说不清第二十四组
    // 为什么是那个数；而「骨架 + 一层色温」两句话就能讲完，还能同时守住两件事。
    //
    // ⚠️ 用户 2026-10-22 报障「整个界面的背景色始终是同一个颜色、不随季节变」——
    // 在此之前天空只认时刻，四季共用一片天，季节感全靠底部那一小块地面带撑着。
    // 天空是**整窗**的底（三栏面板都只有 62% 白压在它上面），它一变，整个界面跟着变；
    // 而它是背景层，压不到任何内容。夜档不掺和：夜里是同一片天（见 `seasonalSkyWash`）。
    public var sky: [Color] {
        momentSkyHex.map { hex in
            guard let wash = seasonalSkyWash else { return Color(hex: hex) }
            return Color(hex: ForestAtmosphere.blend(hex, toward: wash.tone,
                                                     amount: wash.amount))
        }
    }

    /// 季节压在天空上的那层色温（`nil` = 不上色）。
    ///
    /// 为什么是「往一个色调上混」而不是换色相：季节改的是**空气**（水汽、尘、雪光），
    /// 它做的是把整片天冲洗一遍，而不是把天换成另一个颜色。混色天然保留了
    /// 时刻给出的明暗骨架（黄昏那一档被压白之后仍然比正午暗、仍然偏暖）。
    ///
    /// ⚠️ 比例都很小（0.2~0.34）：再大一点，黄昏就被洗成灰，季节会把时刻吃掉。
    private var seasonalSkyWash: (tone: UInt32, amount: Double)? {
        guard !isNight, let season else { return nil }
        switch season {
        case .spring: return (0xC9EDD2, 0.24)   // 淡青绿：树刚发芽，天也被洗得嫩一档
        case .summer: return nil                // 原色：夏天的天本来就是最透的那一片
        case .autumn: return (0xE8B87A, 0.26)   // 暖金：一层薄薄的秋阳
        case .winter: return (0xDFEDF7, 0.36)   // 冷白蓝：雪把天压淡、压冷
        }
    }

    /// 时刻给的天空底色（**未**按季上色）。夜档不看时刻：夜里就是夜里的天空。
    private var momentSkyHex: [UInt32] {
        if isNight {
            return [0x0A1230, 0x152347, 0x24405A]
        }
        guard let moment else {
            return [0x7FD4F0, 0xB6EAFA, 0xE9F8DE]
        }
        switch moment {
        case .dawn:
            // 上头还蓝着、地平线已经暖起来
            return [0x8FB6DE, 0xD6DCF0, 0xFFD9AE]
        case .morning:
            return [0x7FD4F0, 0xB6EAFA, 0xE9F8DE]
        case .noon:
            return [0x6BCDF2, 0xA6E6FB, 0xDCF6E6]
        case .afternoon:
            return [0x86CBEE, 0xC2E6F5, 0xF5F3DA]
        case .dusk:
            // 太阳压到山脊上：整片天被染成蜜橘色
            return [0x5A7CA8, 0xE08A5A, 0xF7C97C]
        case .night:
            return [0x0A1230, 0x152347, 0x24405A]
        }
    }

    /// 插画层的季节取色：夜里一律用色板原色（夜里看不出叶色，改了只会把夜景改坏），
    /// 白天才按季节换 —— 春嫩 / 夏盛（= 原色）/ 秋黄 / 冬雪。
    ///
    /// 丰季（`momentum == .flourishing`，#600）在选好的颜色上再「养盛」一档：
    /// 同色相、更饱和、更深（`ForestAtmosphere.lush`）。判据是 `flourishing` 一档 ——
    /// 成长 / 休憩不掺和，非惩罚性（休憩不会让叶色变衰）。
    private func seasonal(day: UInt32, night: UInt32,
                          spring: UInt32, autumn: UInt32, winter: UInt32) -> Color {
        if isNight { return Color(hex: night) }
        guard let season else { return Color(hex: day) }
        let chosen: UInt32
        switch season {
        case .spring: chosen = spring
        case .summer: chosen = day
        case .autumn: chosen = autumn
        case .winter: chosen = winter
        }
        if momentum == .flourishing { return Color(hex: ForestAtmosphere.lush(chosen)) }
        return Color(hex: chosen)
    }

    // 远景山丘 / 林冠
    public var hillFar: Color {
        seasonal(day: 0xA8DCC0, night: 0x16324A,
                 spring: 0xBCE7C6, autumn: 0xCFC294, winter: 0xDCEBF2)
    }
    public var hillMid: Color {
        seasonal(day: 0x74C79A, night: 0x143B38,
                 spring: 0x8AD3A2, autumn: 0xC2A863, winter: 0xC9DCE6)
    }
    public var hillNear: Color {
        seasonal(day: 0x3F9E67, night: 0x0F2E2B,
                 spring: 0x4FB072, autumn: 0x9E8B45, winter: 0xAFCBD8)
    }

    // 树
    public var trunk: Color { isNight ? Color(hex: 0x4A3626) : Color(hex: 0xA9743F) }
    public var trunkShade: Color { isNight ? Color(hex: 0x33251A) : Color(hex: 0x7E5228) }
    public var foliage: Color {
        seasonal(day: 0x4FA96B, night: 0x1E5346,
                 spring: 0x6CC476, autumn: 0xC08A3E, winter: 0x7FA8A0)
    }
    public var foliageDeep: Color {
        seasonal(day: 0x2E7D55, night: 0x143A31,
                 spring: 0x3E9B5C, autumn: 0x8E6428, winter: 0x5F8A84)
    }

    /// 飘落物的颜色（收词飘的那片叶子 / 通关时的落叶缤纷）。
    ///
    /// 秋天是金的、冬天是雪白的 —— 同一套飘落动画换个颜色，季节就自己说出来了。
    public var fallingFlake: Color {
        switch season {
        case .autumn: return Color(hex: isNight ? 0x6E4A22 : 0xE9A23C)
        case .winter: return Color(hex: 0xE8F4FA)
        default: return foliage
        }
    }

    /// 雨丝的颜色（#418-A，插画层专用）。夜里换暗一档 —— 夜雨不该比星星还亮。
    /// 雨丝的颜色。
    ///
    /// ⚠️ 判据是「与当时天空的**对比度**」（2026-10-01 修）：原先白天用 `0x8FB9DC`，
    /// 与晴空渐变（顶部 `0x7FD4F0`）几乎同色 —— 实测对比约 1.1:1，再透过树面板
    /// 那层半透明底色就更低了。结果是「设置里写着今天是雨，画面毫无变化」。
    /// 白天压深、夜里提亮（夜空本身很暗，暗雨丝同样看不见）。
    public var rainColor: Color {
        isNight ? Color(hex: 0xBFD6EC) : Color(hex: 0x3E6A8F)
    }

    // 雪花（2026-10-21 重写雪层时拆成三档）
    //
    // ⚠️ 一把尺还是「与当时天空的对比度」（2026-10-01 那次修的教训：雨丝与晴空
    // 只差 1.1:1 时，「设置里写着下雨、画面毫无变化」）。雪更难：它必须**是白的**
    // 才像雪，可白天的天空 / 雪地都是近白（`0xE9F8DE` / `0xEDF4FA`）——
    // 实心纯白等于看不见（用户 2026-10-21：「雪花几乎看不见」）。
    // 解法不是把雪染黑，而是**白芯 + 柔边 + 柔影**：轮廓靠阴影立住，本体还是软的。
    // 反过来（白芯 + 实心深边）会变成满屏小白珠（第一版出图实测）。

    /// 雪花的外圈（轮廓）：极淡一层，只负责把白芯从浅底上「描」出来。
    public var snowRim: Color { isNight ? Color(hex: 0xDCEBF4) : Color(hex: 0x9FB6CC) }
    /// 雪花的白芯：一眼读出「这是雪」，不是一颗灰点。
    public var snowCore: Color { isNight ? Color(hex: 0xFFFFFF) : Color(hex: 0xFBFDFF) }
    /// 雪花的柔影：压在任何底色上都能立起来。夜里反过来发一点白光晕。
    public var snowHalo: Color {
        isNight ? Color(hex: 0xFFFFFF).opacity(0.10) : Color(hex: 0x6E8AA3).opacity(0.16)
    }

    // 春：天空里的风筝（#620，插画层专用）
    //
    // 白天鲜艳（沙燕靛蓝 / 三角朱红 / 金鱼橘金），夜里整体压暗一档 ——
    // 夜里不该有三只比星星还亮的彩色风筝，但也不能暗到看不见
    // （夜空 `0x0A1230` 很暗，压暗后的 0x2C4A6E 对比度仍够）。
    public var kiteSwallow: Color { isNight ? Color(hex: 0x2C4A6E) : Color(hex: 0x3A6EA5) }
    public var kiteDiamond: Color { isNight ? Color(hex: 0x7C3A34) : Color(hex: 0xD9503E) }
    public var kiteGoldfish: Color { isNight ? Color(hex: 0x7A5A22) : Color(hex: 0xF0A03A) }
    /// 提线与尾飘带：比本体淡一档（线是「有东西牵着」的暗示，不是主体）。
    public var kiteString: Color { isNight ? Color(hex: 0x51657A) : Color(hex: 0x93A9BD) }
    /// 风筝上的高光 / 眼白 / 骨架。
    public var kiteAccent: Color { isNight ? Color(hex: 0x8FA3B6) : Color(hex: 0xFFFFFF) }

    // 春：草地上的蝴蝶与蒲公英（#621，插画层专用）
    //
    // 白天淡黄（最常见的白粉蝶那一挂），夜里压成暗金 —— 夜里的蝴蝶不该比
    // 萤火虫还亮（`ForestMotes` 的萤火虫才是夜里唯一该发光的东西）。
    public var butterflyWing: Color { isNight ? Color(hex: 0x6E6A4E) : Color(hex: 0xF7E6A2) }
    /// 翅脉与翅缘（比翅面深，翅膀才有「纹」）。
    public var butterflyEdge: Color { isNight ? Color(hex: 0x4A4630) : Color(hex: 0xC98F3C) }
    /// 蝶身与触角。
    public var butterflyBody: Color { isNight ? Color(hex: 0x2A2A22) : Color(hex: 0x5A4632) }
    /// 蒲公英的白绒球与飘絮（夜里偏冷白：夜里的白是月光白，不是纸白）。
    public var dandelionPuff: Color { isNight ? Color(hex: 0xB9C6D0) : Color(hex: 0xFFFFFF) }

    // 夏：远处草场上的风车（#622，插画层专用）
    //
    // 塔身是石砌的、顶是红瓦、叶片是帆布、支架是木色 —— 四件各有各的色，
    // 远看才读得出「一座风车」，而不是一团灰影子。夜里整体压暗并偏冷。
    //
    // ⚠️ 2026-10-22 塔身由「刷白」改成**暖褐色**：白塔 + 白帆叶压在淡绿的远坡上
    // 只差 1.1:1，用户看到的是「一团白雾里几根白棍子」（原话：「过于虚化了，
    // 要有明确的实体」）。远处的实物不是越远越白，而是**越远越灰、越不自带光**；
    // 给塔身一点深度，帆叶留白才有地方站。夜里反过来：帆叶要提亮，
    // 不然就是深色帆压在深色天上（与雁阵、雨丝同一条「对比度」纪律）。
    public var windmillTower: Color { isNight ? Color(hex: 0x41506B) : Color(hex: 0xB98A5E) }
    public var windmillRoof: Color { isNight ? Color(hex: 0x5A3536) : Color(hex: 0x9E4A38) }
    public var windmillBlade: Color { isNight ? Color(hex: 0x9AA6BC) : Color(hex: 0xFBF6E9) }
    public var windmillFrame: Color { isNight ? Color(hex: 0x1F2433) : Color(hex: 0x5E4530) }

    // 夏：草地上的叶隙光斑与夏夜流萤（#623，插画层专用）
    //
    // 光斑是**被树冠筛过的阳光**（暖黄，只有白天有）；流萤是夏夜贴着草尖飞的
    // 那几只（黄绿，只有夜里、只有夏天）——两者不同时出现，正是一天两副样子。
    public var dappleLight: Color { isNight ? Color(hex: 0x2A2F3A) : Color(hex: 0xFFE98F) }
    public var fireflyGlow: Color { isNight ? Color(hex: 0xC8E08A) : Color(hex: 0x8FA86A) }

    // 夏：草尖上的蜻蜓（#635，插画层专用）
    //
    // ⚠️ 取**蓝**不取绿：夏天白天那一片是 `hillNear` 的绿草地（`0x3F9E67`），
    // 绿身子压在绿草上等于没有（与雨丝压在晴空上同一个毛病，实测对比约 1.1:1
    // 时就是「写着有、看着没有」）。蓝是草地上唯一没有的色相，20pt 也能读出来。
    /// 身子（胸 + 细长的腹部）。
    public var dragonflyBody: Color { isNight ? Color(hex: 0x1E4E66) : Color(hex: 0x2E7FA8) }
    /// 翅膀（半透明：蜻蜓的翅是膜的，实心一片就成了四片塑料片）。
    public var dragonflyWing: Color { isNight ? Color(hex: 0x8FA8B8) : Color(hex: 0xDCEFF6) }
    /// 复眼（比身子深：蜻蜓的脑袋就是那两颗大眼）。
    public var dragonflyEye: Color { isNight ? Color(hex: 0x14272F) : Color(hex: 0x1E4658) }

    // 秋：大树脚下那片小果园（#624，插画层专用）
    //
    // 果树只有两个半小动物高，取色要能在一地秋黄里**认得出是另一棵树**：树皮
    // 偏红褐（果树的皮比大树浅、更红），树冠留住夏末的黄绿（结着果子的树不会
    // 满树枯黄），果子三色 —— 一棵只结一种，才读得出「这是棵苹果树」。
    public var orchardTrunk: Color { isNight ? Color(hex: 0x3E2A1C) : Color(hex: 0x8A5A3A) }
    public var orchardTrunkShade: Color { isNight ? Color(hex: 0x2A1C12) : Color(hex: 0x6A4326) }
    public var orchardCanopy: Color { isNight ? Color(hex: 0x1E4432) : Color(hex: 0x7FA653) }
    /// 背光那几团叶（比冠面深，树冠才有「厚」）。
    public var orchardCanopyDeep: Color { isNight ? Color(hex: 0x14301F) : Color(hex: 0x5B8340) }
    /// 迎光那一侧的亮边（太阳钉在右上，见 `ForestLighting`）。
    public var orchardCanopyWarm: Color { isNight ? Color(hex: 0x2C5238) : Color(hex: 0xA8C264) }
    public var orchardApple: Color { isNight ? Color(hex: 0x6A2A24) : Color(hex: 0xD8402E) }
    public var orchardPeach: Color { isNight ? Color(hex: 0x6E4440) : Color(hex: 0xF2A0A0) }
    public var orchardCitrus: Color { isNight ? Color(hex: 0x6E4A1E) : Color(hex: 0xF09A2E) }
    /// 果子上的高光（比果色淡，果子才有「圆」）。
    public var orchardFruitSheen: Color { isNight ? Color(hex: 0x8A9A9C) : Color(hex: 0xFFFFFF) }

    // 秋：草地上的落叶堆与南瓜（#625，插画层专用）
    //
    // 一堆落叶是**三色混着**的（金 / 铁锈 / 褐）：只一色读不出「落叶堆」，像一摊
    // 色块；三色交错才像不同树上落下来的。夜里整体压暗并偏冷 —— 夜里没有阳光，
    // 落叶该是「被夜色泡过的褐」，不是白天那片金。
    public var autumnLeafGold: Color { isNight ? Color(hex: 0x6B5220) : Color(hex: 0xE0A43A) }
    public var autumnLeafRust: Color { isNight ? Color(hex: 0x5E3218) : Color(hex: 0xC4632A) }
    public var autumnLeafBrown: Color { isNight ? Color(hex: 0x412A16) : Color(hex: 0x8E5A2E) }
    /// 叶缘与叶脉（比叶面深，一片片叶子才分得开）。
    public var autumnLeafEdge: Color { isNight ? Color(hex: 0x2A1B0E) : Color(hex: 0x6E3F1C) }
    /// 南瓜的果身（比落叶更饱和：它是画面里唯一还「鲜」着的东西）。
    public var pumpkinBody: Color { isNight ? Color(hex: 0x6E3A12) : Color(hex: 0xE9761F) }
    /// 南瓜的棱（比果身深 —— 南瓜是被棱分成一瓣瓣的，不是一颗圆球）。
    public var pumpkinRib: Color { isNight ? Color(hex: 0x5A2E0E) : Color(hex: 0xBE4E12) }
    /// 南瓜蒂（还带点青，刚摘下来那种）。
    public var pumpkinStem: Color { isNight ? Color(hex: 0x2E3A1C) : Color(hex: 0x5E7A34) }
    /// 南瓜上的高光（比果身淡，果身才有「圆」）。
    public var pumpkinSheen: Color { isNight ? Color(hex: 0x8A8272) : Color(hex: 0xFFD9A0) }

    // 秋：南飞的雁阵（#634，插画层专用）
    //
    // 雁是**逆着天光看的剪影**：白天压在亮天上就该是深色（浅色雁在晴空
    // `0x7FD4F0` 上会化掉，与雨丝那次「写着下雨、画面毫无变化」同一个毛病）；
    // 夜里反过来 —— 夜空本身 `0x0A1230` 极暗，深剪影等于没有，所以夜里提亮成
    // 被月光勾了一道边的灰蓝。翅膀比身子浅一档：一对翅膀与一枚身子要分得开。
    public var gooseBody: Color { isNight ? Color(hex: 0x5A6E82) : Color(hex: 0x38434E) }
    public var gooseWing: Color { isNight ? Color(hex: 0x6E8296) : Color(hex: 0x4A5A66) }

    // 冬：积起来的雪（#626，插画层专用）
    //
    // 雪是**画面里最亮的东西**，但它不是纯白：纯白在暖色叶子上会「发光」，
    // 反而把树冠烧出一个洞。白里带一点天空的冷（白天偏日光、夜里偏月光），
    // 雪才像被光照着，而不是自己亮着。
    public var snowCover: Color { isNight ? Color(hex: 0x9FB4C6) : Color(hex: 0xF7FAFC) }
    /// 雪的暗部（雪帽下沿 / 雪堆根部）：雪自己也有厚度，全一色就是贴纸。
    public var snowShade: Color { isNight ? Color(hex: 0x6E8296) : Color(hex: 0xCBDCE9) }
    /// 草地上的雪（比冠上的雪更冷一点：它照不到太阳，反射的是天光）。
    public var snowGround: Color { isNight ? Color(hex: 0x8FA3B4) : Color(hex: 0xEDF4FA) }
    /// 雪堆的顶面（比雪地亮一档）：整片雪地上要读出「堆」，靠的就是顶面更亮 + 根部一道冷影。
    public var snowDrift: Color { isNight ? Color(hex: 0xA9BDCB) : Color(hex: 0xFFFFFF) }

    // 冬：草地上的雪人（#627，插画层专用）
    //
    // ⚠️ 雪人的**雪身**不另取色：它就该是 `snowDrift`（比脚下的雪地亮一档），
    // 否则雪人会在雪地里"隐身"。这里只补它身上那些**不属于雪**的零件。
    /// 尖顶帽（深炭）：纯黑在夜里会糊成一个洞，留一点冷灰才看得出是顶帽子。
    public var snowmanHat: Color { isNight ? Color(hex: 0x2A2F36) : Color(hex: 0x3A4048) }
    /// 帽檐（比帽身浅一档）：一色黑的锥体读成一个三角块。
    public var snowmanHatBand: Color { isNight ? Color(hex: 0x59636E) : Color(hex: 0x757F8A) }
    /// 红围巾
    public var snowmanScarf: Color { isNight ? Color(hex: 0x7E3A3E) : Color(hex: 0xC2453F) }
    /// 围巾的暗面（垂下来那一角背光）
    public var snowmanScarfDeep: Color { isNight ? Color(hex: 0x5E2A2E) : Color(hex: 0x96322E) }
    /// 胡萝卜鼻子
    public var snowmanNose: Color { isNight ? Color(hex: 0x8A5A2C) : Color(hex: 0xE08A34) }
    /// 煤球（眼睛 / 纽扣）
    public var snowmanCoal: Color { isNight ? Color(hex: 0x1A1E24) : Color(hex: 0x2B3038) }
    /// 枝桠手臂
    public var snowmanTwig: Color { isNight ? Color(hex: 0x3E2E22) : Color(hex: 0x6B4A32) }

    // 冬：枝下沿的冰柱（#628，插画层专用）
    //
    // 冰柱比雪更冷更透：它是**水冻出来的**，不是积起来的雪粉 ——
    // 所以它的主体比 `snowCover` 更偏蓝，暗侧压得更深（半透明才读得出「锥」）。
    public var icicleBody: Color { isNight ? Color(hex: 0x8FA9BC) : Color(hex: 0xDDECF5) }
    /// 冰柱的暗侧（背光那半边，比本体宽一圈探出来）：一色白的锥读成一片纸。
    public var icicleShade: Color { isNight ? Color(hex: 0x4E6478) : Color(hex: 0xAFC6D8) }
    /// 冰柱上的高光（左侧一道）：冰面反光总在一侧。
    public var icicleGlint: Color { isNight ? Color(hex: 0xC2D4E2) : Color(hex: 0xFFFFFF) }

    // 强调
    /// 主强调色（琥珀金）：用于**文字 / 图标 / 描边 / 淡底**。
    ///
    /// ⚠️ 白档的亮度有**两条硬上限**（都不是审美，是算出来的）：
    ///
    /// 1. 它还要压在自己 `opacity(0.12)` 的淡底上当字用（「回到最初」那种描边胶囊），
    ///    黄一调亮、那层淡底跟着一起亮，有效对比度反而往下掉 —— 卡在亮度 ≈0.213；
    /// 2. 旁边那颗紫按钮（`accentCool`）在白卡片上是 **4.80:1**，用户是拿它当
    ///    「看得清」的参照说的，黄不许落后太多 —— 卡在亮度 ≈0.183。
    ///
    /// 第 2 条更紧，所以白档的黄**提不了多少**：这是「黄字压在白底上」这件事本身的
    /// 死结 —— 对比度要够，黄就必须深，而深黄在 sRGB 里就是褐色。
    ///
    /// ⚠️ 这一档改了三轮，三轮的诉求各不相同，只看最后一轮会再踩回去：
    ///
    /// - 起点 `0xFFB703`：白卡上只有 1.75:1，用户说「白天看不清」；
    /// - 09-16 压到 `0x937008`（色相 45° 金黄）：对比度达标了，但用户说
    ///   「已经变成棕色了」；
    /// - 09-21 用户要**橘色**，色相从 45° 挪到 24°（`0xBE4E04`）。
    ///
    /// ⚠️ 为什么「压暗」在黄身上必然发褐，而这不是调参能解决的：
    /// 黄在 sRGB 里亮度一旦掉到 0.18 以下，**饱和度再高也读成土黄/褐** ——
    /// 人对低亮度黄绿区的感知就是「脏」。同一个亮度下，只有把色相往橙红推
    /// （把黄绿成分退出去），低亮度才不会显脏。09-21 这一轮走的正是这条路：
    /// 亮度不动（0.164），只把色相 45°→24°、饱和度提到 96%。
    ///
    /// 两条硬上限仍然成立（都不是审美，是算出来的）：
    ///
    /// 1. 它还要压在自己 `opacity(0.12)` 的淡底上当字用（「回到最初」那种描边胶囊），
    ///    底色跟着它一起走，有效对比度会掉一截；
    /// 2. 旁边那颗紫按钮（`accentCool`）在白卡片上是 **4.80:1**，用户是拿它当
    ///    「看得清」的参照说的 —— 橙不许落后太多。
    ///
    /// | 场景 | 原色 `0xFFB703` | `0x937008`（褐） | 现在 `0xBE4E04`（橘） |
    /// |---|---|---|---|
    /// | 白天：压在白卡片上 | 1.75:1 | 4.60:1 | **4.91:1**（紫是 4.80） |
    /// | 白天：压在自己的 0.12 淡底上 | 1.73:1 | 3.97:1 | **4.16:1** |
    /// | 夜晚：压在暗底上 | 11.78:1（刺眼） | 6.86:1 | **6.24:1** |
    ///
    /// 想真正亮起来的橙只能走 `accentFill`（它上压深墨字，不受这两条约束）。
    public var accent: Color { isNight ? Color(hex: 0xE08F52) : Color(hex: 0xBE4E04) }

    /// 橙底胶囊的**填充色** —— 它上面压的是 `onAccentFill`（白档深墨、夜档暖白）。
    ///
    /// ⚠️ 别和 `accent` 合成一个令牌：同一个橙既要当「暗底上的前景」（得亮），
    /// 又要当「字脚下的底」，这俩在白档直接打架 —— 硬合成的结果就是旧的 `0xB07C12`
    /// （亮度 0.24、色相 40°），用户看了直说「已经变成棕色了」。
    ///
    /// ⚠️ 更要紧的一条：**橙底上压纯白字，等于把橙底钉死**。白字要求底够暗，而
    /// 「够暗的橙」在 sRGB 里就是褐色 —— 这是色彩空间层面的死结，调参解不开。
    /// 白档因此是**亮橙底 + 深墨字**（`0xF0A24A` 承 `0x3D2B00`，实测 6.46:1）。
    ///
    /// ⚠️ 夜档 09-21 一并调整（用户反馈「胶囊里的白字太亮，看不清」）：
    /// 底 `0xA87B26`→`0x96551C`（加深），字 `#FFFFFF`→`#F2EBE0`（暖白）。
    /// **必须成对改**：只换字色会把对比度从 3.80:1 拉到 3.21:1（更糊）；
    /// 底一起加深之后是 **4.91:1** —— 白不刺眼，字反而更清楚。
    ///
    /// ⚠️ 反过来，白档这支也有**上限**，判据是「它和所在的白卡片还能不能分开」：
    /// 橙底越亮，那个实心胶囊就越像糊进白卡片里。守卫线设在 1.5:1（现 2.11:1），
    /// 再往上不是「更亮的橙」，是「看不清的块」。
    public var accentFill: Color { isNight ? Color(hex: 0x96551C) : Color(hex: 0xF0A24A) }

    /// 压在上面那支橙底上的**字色**。白档是深墨褐（底要亮，字就得深），夜档是暖白。
    ///
    /// ⚠️ 别在 View 里再写死 `.white`：白档会直接退化成读不出的白字；
    /// 夜档也要走这里 —— 09-21 起夜档不是纯白（`#FFFFFF`）而是暖白 `0xF2EBE0`，
    /// 配加深后的橙底是 4.91:1（纯白 5.75:1 更亮但刺眼，用户要的是「不刺眼且看得清」）。
    public var onAccentFill: Color { isNight ? Color(hex: 0xF2EBE0) : Color(hex: 0x3D2B00) }

    /// **只给背景插画**（太阳 / 月晕 / 星芒）的亮黄。
    ///
    /// 插画不承担信息传达，压暗它只会让太阳变成一颗土黄色的球。反过来，
    /// UI 里那份压暗的 `accent` 也**不能**拿去画太阳。两个用途，别互相借。
    public var glow: Color { isNight ? Color(hex: 0xFFD98A) : Color(hex: 0xFFB703) }

    public var accentAlt: Color { isNight ? Color(hex: 0x8AB6FF) : Color(hex: 0xFF8FA3) }
    /// **软警告**色（原来是散在四处硬编码的 `Color.orange`）。
    ///
    /// 为什么不直接拿 `accent` 顶上：它要占住「满分 / 良好 / 加油 / 重来」这类
    /// **分档**里的一档，和 `accent` 撞成同一个颜色就等于少了一档信息。
    ///
    /// ⚠️ 09-21 橘化时它**必须跟着挪**：`accent` 走到色相 24° 之后，原来那支
    /// `0xAC5A10`（色相 28°）与它只差 ΔE 14.0（`ThemeContrastTests` 要求 ≥15），
    /// 两处颜色会看起来是同一个。现在取更偏红的一支（白 `0x9E3410` 色相 13°、
    /// 夜 `0xC4682A`），白档 ΔE 16.5、夜档 15.4，都压在门槛之上，
    /// 分档仍然一眼能分开（白天 7.11:1，夜晚 4.07:1）。
    ///
    /// 注意它和 `danger`（正红、色相 6°）**不是**一回事：`danger` 表示
    /// 「不可逆危险操作」，`warning` 只是分档/风险提示，两者别互相借。
    public var warning: Color { isNight ? Color(hex: 0xC4682A) : Color(hex: 0x9E3410) }
    /// **打卡 / 连续天数**的红（首屏徽章那颗火苗）。
    ///
    /// 09-21 新增：用户要求「把 logo 右边的火苗及内外框改成红色」—— 火苗本来就是
    /// 红橙色的东西，之前借用 `accent`（黄/橘）反而怪。
    ///
    /// ⚠️ 为什么另立一支而不是复用 `danger`：`danger` 的语义是**不可逆危险操作**
    /// （清除学习记忆这类按钮），拿它画火苗会让人以为点一下会删东西。两支实测
    /// ΔE 15.8，看上去也确实是两种红（这支偏火焰橙红，`danger` 偏正红）。
    ///
    /// 亮度的选择跟 `warning` 同一把尺：白卡上它还要当 11pt 的文字色（「N 天」），
    /// 所以白天 5.07:1、夜晚压在深蓝面板上 5.44:1，两档都留足余量。
    ///
    /// ⚠️ 它与 `warning`（断签风险态）的 ΔE 是 24.1，两态不会看成一个颜色 ——
    /// 这是「安全 / 风险」两态唯一还剩下的区分手段，别把两者调到相近。
    public var streak: Color { isNight ? Color(hex: 0xF0705A) : Color(hex: 0xD42A1A) }

    /// 次要强调色（冷紫）：给「跳去别处」这类**次要但要看得见**的动作用，
    /// 与主 `accent`（琥珀）明确区分——同一行里两个按钮不该抢同一个颜色。
    /// 两档都取偏深的紫：胶囊里是白字，太浅（如 0xA79BFF）实测白字对比只有 2.5:1。
    public var accentCool: Color { isNight ? Color(hex: 0x7E6BEF) : Color(hex: 0x6F5CE8) }
    public var star: Color { Color(hex: 0xFFF3C4) }
    /// 危险操作（清除学习记忆这类**不可逆**动作）。
    ///
    /// 两档都压到偏深：胶囊里是白字，浅红实测白字对比度不足 3:1，
    /// 按钮会变成「看得出是红的、但读不清写了什么」。
    public var danger: Color { isNight ? Color(hex: 0xC9555F) : Color(hex: 0xC0392B) }
    /// 「做完了 / 达标了」的绿（今日任务的绿勾、气泡里的完成关键字）。
    ///
    /// 与 `danger` 成对：一个是「还差」，一个是「做到了」，两个都得能在
    /// 侧栏底（`surfaceAlt`）与气泡底（`panel`）上读清 —— 所以两档都取偏深的绿，
    /// 白天 5.1:1、夜晚 9.2:1。
    ///
    /// ⚠️ 别再在 View 里写 `Color(hex: 0x8FD694)`：那是「浅绿」，只在白卡片上成立，
    /// 夜档压在深蓝面板上会糊掉。
    public var success: Color { isNight ? Color(hex: 0x7BD69A) : Color(hex: 0x2E7D3A) }

    // 文本 / 表面
    public var primaryText: Color { isNight ? Color(hex: 0xEAF4EE) : Color(hex: 0x22331F) }
    public var secondaryText: Color { isNight ? Color(hex: 0x9FB6AE) : Color(hex: 0x5B6B54) }
    public var surface: Color { isNight ? Color(hex: 0x152238, opacity: 0.92) : Color(hex: 0xFFFFFF, opacity: 0.92) }
    public var surfaceAlt: Color { isNight ? Color(hex: 0x1D2C46, opacity: 0.85) : Color(hex: 0xF3F7EF, opacity: 0.9) }

    /// 中间对话栏的底色（2026-10-23，需求：中间栏背景跟着季节一起变）。
    ///
    /// ⚠️ 原先这里用的是 `surfaceAlt.opacity(0.55)` —— 一层**不随季节变**的近白面纱，
    /// 把最外层那片跟着季节变的天空（`ForestSky`）整个盖住。症状：右栏（成长之树）
    /// 的背景明显跟着季节走，中间栏却是同一个灰白，两栏接不上。
    ///
    /// 做法不是把天空原样搬过来（那会让聊天气泡底下的蓝太跳），而是
    /// **季节天空的浅档压一层面纱**：天空占比够高（四季一眼分得出），
    /// 面纱占比保证文字对比度。夜档不掺和季节（与 `seasonalSkyWash` 同一条约定：
    /// 夜里是同一片天）。
    public var chatBackdrop: Color {
        Color(hex: chatBackdropHex)
    }

    /// 中间栏底色的不透明度：**白天透、夜里实**。
    ///
    /// 白天这一档要透：季节底色之上还有一层飞鸟（`ForestSeasonBirds`，画在最底层
    /// 的天空之上、内容之下）—— 鸟群是贯穿中间栏与右栏的，底色不透就只看得见
    /// 右栏那半截。夜里反过来收实：夜空的对比度本来就低，文字可读性优先。
    public var chatBackdropOpacity: Double {
        isNight ? 0.78 : 0.62
    }

    /// 中间栏底色的十六进制（与 `chatBackdrop` 同一条算式，单测直接钉它）。
    ///
    /// ⚠️ 故意不是 `private`：`ThemeContrastTests` 要按四季逐个数这串色值
    /// （「四季两两不同」），private 的话只能退化成渲染像素判据，慢且钝。
    var chatBackdropHex: UInt32 {
        // 取天空**最浅那一档**（地平线附近）而不是顶部那档：顶部是深蓝，
        // 拿来做面板底色会比右栏暗一截，两栏接不上。
        let sky = momentSkyHex[momentSkyHex.count - 1]
        let washed = seasonalSkyWash.map {
            ForestAtmosphere.blend(sky, toward: $0.tone, amount: $0.amount)
        } ?? sky
        return ForestAtmosphere.blend(washed, toward: surfaceVeilHex, amount: 0.42)
    }

    /// 底色那层「面纱」：与 `surfaceAlt` 同一个色相，只取它的不透明值。
    private var surfaceVeilHex: UInt32 {
        isNight ? 0x1D2C46 : 0xF3F7EF
    }
    public var bubbleUser: Color { isNight ? Color(hex: 0x3A5B7A) : Color(hex: 0xDFF3E4) }
    public var bubbleCoach: Color { isNight ? Color(hex: 0x24405A) : Color(hex: 0xFFFFFF) }
    public var divider: Color { isNight ? Color(hex: 0x2A3A57) : Color(hex: 0xDCE7D6) }

    /// **短行程**分隔线：多列排布里两列之间那一条（快捷键中心的三列）。
    ///
    /// 为什么不能直接用 `divider`：它是给「横跨整张卡的长横线」用的（Section 之间），
    /// 那种线长、量大，做淡一点才不抢内容；而两列之间这条只有一格高，再用那个色
    /// 就淡得看不见了（白卡上 1.2:1）。这条取到 1.8:1 —— 够分出「这是两列」，
    /// 又不至于像描边那样把界面切成方格。
    ///
    /// ⚠️ 只给**短**分隔线用。整条横贯的关注 `divider`。
    public var columnDivider: Color { isNight ? Color(hex: 0x3A5075) : Color(hex: 0xB4C2AE) }

    /// 浮层遮罩 / 浮层面板。**任何浮层都必须用这两个语义色**，否则日夜切换会漏。
    public var scrim: Color { isNight ? Color.black.opacity(0.5) : Color(hex: 0x16301B).opacity(0.22) }
    public var panel: Color { isNight ? Color(hex: 0x1A2A45, opacity: 0.98) : Color(hex: 0xF7FBF3, opacity: 0.98) }
    /// 侧边栏选中态 / 悬停态。
    public var selection: Color { isNight ? Color(hex: 0x2C4468) : Color(hex: 0xDCEFE0) }
    public var hover: Color { isNight ? Color(hex: 0x22334F) : Color(hex: 0xEAF3E8) }

    public var shadow: Color { isNight ? .black.opacity(0.45) : Color(hex: 0x2E4A32).opacity(0.18) }

    // MARK: - 词典封面

    /// 一本书封面的两档渐变色。
    public struct BookCover: Sendable, Equatable {
        public var top: Color
        public var bottom: Color

        public init(top: Color, bottom: Color) {
            self.top = top
            self.bottom = bottom
        }
    }

    /// 词典封面配色（六档令牌）。
    ///
    /// ⚠️ 这些**刻意压得比常规语义色深**：封面上压着白色书名，浅色配白字读不清。
    /// 六档在日夜两版都保持「深底 + 白字」，所以不跟着 `accent` 之类走。
    public func bookCover(_ style: DictionaryBook.CoverStyle) -> BookCover {
        switch style {
        case .forest:
            return isNight
                ? BookCover(top: Color(hex: 0x2A6B52), bottom: Color(hex: 0x14382C))
                : BookCover(top: Color(hex: 0x2F7D5C), bottom: Color(hex: 0x1B4D3A))
        case .ocean:
            return isNight
                ? BookCover(top: Color(hex: 0x1E5C86), bottom: Color(hex: 0x10304A))
                : BookCover(top: Color(hex: 0x1F6F9C), bottom: Color(hex: 0x14405E))
        case .sunset:
            return isNight
                ? BookCover(top: Color(hex: 0x9E4E33), bottom: Color(hex: 0x66281A))
                : BookCover(top: Color(hex: 0xB85C3A), bottom: Color(hex: 0x7E3320))
        case .plum:
            return isNight
                ? BookCover(top: Color(hex: 0x5C3F94), bottom: Color(hex: 0x35245C))
                : BookCover(top: Color(hex: 0x6A4BA8), bottom: Color(hex: 0x412C6E))
        case .slate:
            return isNight
                ? BookCover(top: Color(hex: 0x3E4C5C), bottom: Color(hex: 0x242E3A))
                : BookCover(top: Color(hex: 0x4A5A6B), bottom: Color(hex: 0x2C3846))
        case .sand:
            return isNight
                ? BookCover(top: Color(hex: 0x866A36), bottom: Color(hex: 0x584318))
                : BookCover(top: Color(hex: 0x9A7B3F), bottom: Color(hex: 0x6B5222))
        }
    }
}

// MARK: - 环境注入

private struct ForestThemeKey: EnvironmentKey {
    static let defaultValue = ForestTheme(palette: .day)
}

public extension EnvironmentValues {
    var forestTheme: ForestTheme {
        get { self[ForestThemeKey.self] }
        set { self[ForestThemeKey.self] = newValue }
    }
}

public extension View {
    func forestTheme(_ theme: ForestTheme) -> some View {
        environment(\.forestTheme, theme)
    }
}

// MARK: - 分辨率

public enum ForestThemeResolver {

    public static func resolve(mode: ThemeMode, systemIsDark: Bool) -> ForestTheme {
        switch mode {
        case .day: ForestTheme(palette: .day)
        case .night: ForestTheme(palette: .night)
        case .system: ForestTheme(palette: systemIsDark ? .night : .day)
        }
    }

    /// 「跟随时间」「跟随季节」「跟随天气」三个开关（2026-09-29 拆分，原来是绑在一起的；
    /// 2026-10 每个开关各配一个**手动**档位）下的主题（纯函数，便于单测）。
    ///
    /// - 跟随时间：**时刻说了算** —— 天黑了就切夜景、白天按小时挑天空色；
    /// - 跟随季节：按月份换叶色/落花，日夜档位仍由用户自己决定；
    /// - 跟随天气（#418-A）：按年内日序定晴 / 下雨 / 下雪，日夜档位不受它影响；
    /// - 跟随学习节奏（#600）：`momentum` 为 `flourishing` 时叶色走盛档、本地兜底天气偏晴；
    /// - 手动档（`seasonOverride` / `weatherOverride`）：对应开关**关着**时用它顶替
    ///   （开关开着 = 自动派生说了算，手动值只是存着，不参与）；两者都无 = nil；
    /// - 都关：与老行为逐字相同（`moment` / `season` / `weather` / `momentum` 都是 nil）。
    ///
    /// ⚠️ 手动点太阳/月亮走的是「收回到手动」那条路（见 `AppState.toggleDayNight`），
    /// 不是在这里跟自动打架 —— 否则开了自动之后那个按钮点了没反应。
    ///
    /// - Parameter weatherForecast: 真实天气预报的结论（#604，可以为 nil）。
    ///   跟着天气开着时**优先用它**；nil 表示这一步没取到（断网 / 服务没回应），
    ///   于是退回按日序的本地模拟 —— 「外层变好看」绝不能依赖一次网络请求成功。
    /// - Parameter momentum: 学习节奏（#600，可以为 nil；nil = 不跟随学习节奏）。
    ///   只影响两处、都**不覆盖真实天气**：① 叶色/山丘在丰季走盛档（仅白天）；
    ///   ② 取不到预报时的本地兜底模拟偏晴。真实预报拿到了就以它为准 ——
    ///   学业节奏是给森林的氛围奖励，不是给用户播报假天气的许可。
    public static func resolve(mode: ThemeMode, systemIsDark: Bool,
                               hour: Int, month: Int,
                               followsClock: Bool, followsSeason: Bool,
                               followsWeather: Bool = false, dayOfYear: Int = 1,
                               seasonOverride: ForestSeason? = nil,
                               weatherOverride: ForestWeather? = nil,
                               weatherForecast: ForestWeather? = nil,
                               momentum: ForestMomentum? = nil) -> ForestTheme {
        // 季节：自动开着 = 按月份派生（手动值存着不用）；关着 = 用手动值；都没有 = nil。
        let season: ForestSeason? = followsSeason
            ? ForestAtmosphere.season(month: month)
            : seasonOverride
        let base: ForestTheme
        if followsClock {
            let palette: ForestPalette = ForestAtmosphere.isNightHour(hour) ? .night : .day
            base = ForestTheme(palette: palette,
                               moment: ForestAtmosphere.moment(hour: hour),
                               season: season)
        } else if season != nil {
            // 不跟时间但有季节（自动或手动都一样）：日夜仍由档位决定，叶色随季节走。
            let manual = resolve(mode: mode, systemIsDark: systemIsDark)
            base = ForestTheme(palette: manual.palette, moment: manual.moment,
                               season: season)
        } else {
            base = resolve(mode: mode, systemIsDark: systemIsDark)
        }
        // 学习节奏（#600）：透传进主题（叶色盛档在 ForestTheme.seasonal 里判）。
        let themed = ForestTheme(palette: base.palette, moment: base.moment,
                                 season: base.season, momentum: momentum)
        // 天气：自动开着 = 真实预报优先，取不到再按日序本地模拟（丰季偏晴）；
        // 关着 = 用手动值；都无 = nil。关着又没手动时 theme 与旧版逐字相等（Equatable 钉得住）。
        //
        // ⚠️ `weatherForecast` 里可以有 `.clear`：预报说了「今天没降水」也是一条可信结论，
        // 必须照用 —— 不能因为它是 nil 的同义样子就去退本地模拟（那样真晴天会下假雨）。
        // 同理，`momentum` 只在这条兜底支路上偏晴，绝不覆盖上面那个真预报。
        let weather: ForestWeather? = followsWeather
            ? (weatherForecast ?? ForestAtmosphere.weather(dayOfYear: dayOfYear, momentum: momentum))
            : weatherOverride
        guard weather != nil else { return themed }
        return ForestTheme(palette: themed.palette, moment: themed.moment, season: themed.season,
                           weather: weather, momentum: momentum)
    }
}
