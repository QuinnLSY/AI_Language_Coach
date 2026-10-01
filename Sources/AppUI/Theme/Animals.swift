import Combine
import Foundation
import SwiftUI

// MARK: - 物种

/// 每种动物都有**独立的解剖特征**（耳朵、口鼻、尾巴、纹样），而不是同一副身体换色。
public enum AnimalKind: String, CaseIterable, Sendable, Identifiable {
    case fox
    case panda
    case tiger
    case owl
    case rabbit
    case bear
    case squirrel
    case hedgehog

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fox: "小狐狸"
        case .panda: "小熊猫"
        case .tiger: "小老虎"
        case .owl: "猫头鹰"
        case .rabbit: "小兔子"
        case .bear: "小熊"
        case .squirrel: "小松鼠"
        case .hedgehog: "小刺猬"
        }
    }

    /// 每只动物 8~10 条符合自身特性的小语句（产品文案；树上的伙伴被点击时冒泡）。
    public var phrases: [String] {
        switch self {
        case .fox:
            return [
                "跟我读：The early bird catches the worm！",
                "嘘——我听见树叶在用英文聊天啦！",
                "小 trick 要不要？单词要大声说出来才有魔力！",
                "Practice makes perfect，我可是偷偷练过的！",
                "G-O-O-D，拼对了就奖励你一颗糖！",
                "树上有果子、地上有单词，快捡起来！",
                "你今天读的句子，风都帮你记着呢！",
                "跟着我念，舌头要翘一点点哦！",
                "别怕说错，说错了才有小惊喜！",
                "森林里最亮的，是你开口的声音！",
            ]
        case .panda:
            return [
                "Good job！今天的你比竹子还棒！",
                "别急，慢慢来，learning is a journey。",
                "这句话读得很好，给你一朵小红花。",
                "来，跟我读：I love learning English！",
                "累了就歇会儿，竹子分你一半～",
                "记住啦：little by little, day by day。",
                "你今天又长高了一点点，真替你高兴。",
                "发音很棒哦，比上次进步多啦！",
                "不懂就问，我最喜欢爱问问题的小朋友。",
                "坚持到这里的你，已经是森林小英雄啦！",
            ]
        case .tiger:
            return [
                "吼——跟我大声念：I can do it！",
                "声音再大一点，森林都听到你的勇气啦！",
                "单词怕什么，跟本大王一起拿下它！",
                "Roar！犯错也是超酷的尝试！",
                "今天的目标：吃掉十个新单词！",
                "大声朗读，把胆怯都吓跑！",
                "你是最棒的小勇士，再来一关！",
                "A for effort，努力本身就满分！",
                "快，趁太阳还在，多练一句！",
                "我会保护你，尽管开口说吧！",
            ]
        case .owl:
            return [
                "呜呼——悄悄告诉你，单词睡一觉记得更牢。",
                "关于发音，我书架上有三百本书可以借你。",
                "夜里安静，最适合跟读和回想。",
                "坚持复习，才是聪明的秘诀哦。",
                "这个语法点，让我翻翻我的智慧手册…",
                "A wise learner listens first, then speaks。",
                "你问的这个词，古树年轮里都刻着呢。",
                "晚上的你，也要像白天一样闪亮。",
                "复述一遍，就是知识发芽的声音。",
                "慢慢想，聪明的答案都爱迟到一会儿。",
            ]
        case .rabbit:
            return [
                "你…你说得好棒呀！（小声）",
                "跟…跟着我一起念，轻轻地说～",
                "这个单词好可爱，像胡萝卜一样讨人喜欢。",
                "慢慢来，我在旁边给你加油。",
                "嗯嗯，你说对了，奖励你一个抱抱。",
                "今天也要元气满满地跳跳学英语哦！",
                "bunny 就是我，carrot 是我最爱～",
                "别害羞，你的声音很好听呢。",
                "读错也没关系，胡萝卜不会笑话你。",
                "等你学会了，我们一起数星星学英语！",
            ]
        case .bear:
            return [
                "我…我也在学呢，我们一起加油！",
                "这句好难…但我会认真记住的！",
                "英语的蜂蜜，舔一口就甜甜的！",
                "老师夸我了！你也一定会被夸的！",
                "今天学到的新词，我要带回家给妈妈听。",
                "嘿嘿，我会背小星星，也会背 A B C。",
                "摔倒了就爬起来，我再念一遍！",
                "你读得真好听，像蜂蜜一样甜。",
                "我们的树，会随着单词越爬越高！",
                "别走太快，等等我这只小笨熊嘛～",
            ]
        case .squirrel:
            return [
                "这个单词我收进我的树洞宝库啦！",
                "蹦蹦跳跳学得快，跟我一起动起来！",
                "一天捡一个词，冬天就有好多好多！",
                "嗖——我把发音记住啦！",
                "来玩个游戏：我说 apple，你说苹果！",
                "藏起来的单词，都要记得复习哦。",
                "你的进步，我都悄悄攒进树洞里了。",
                "单词像松果，捡多了就是大丰收！",
                "尾巴一甩，难句跑光光！",
                "快夸我，我刚背下一个长句子！",
            ]
        case .hedgehog:
            return [
                "我…我慢慢说，你别着急嘛。",
                "每个单词，都值得被温柔对待。",
                "刺是我的保护壳，勇敢是我的超能力。",
                "你读对了！我开心得刺都软了。",
                "慢慢滚，也能滚到山顶哦。",
                "别碰我的刺…碰我的单词本可以。",
                "今天又比昨天多说了一句话，真好。",
                "小声音也没关系，清楚最重要。",
                "我背单词的样子，像不像在数星星？",
                "谢谢你听我说完，你是温柔的朋友。",
            ]
        }
    }
}

// MARK: - 配色（仅本文件使用；View 层禁止写字面量颜色）

private enum Fur {
    static let dark = Color(hex: 0x2A2018)
    static let nose = Color(hex: 0x4A3327)
    static let pink = Color(hex: 0xFFA8B6)
    static let cream = Color(hex: 0xFFF4E6)

    static let fox = Color(hex: 0xEF8438)
    static let foxLight = Color(hex: 0xFFF0DF)

    static let pandaBlack = Color(hex: 0x2E2C33)
    static let pandaWhite = Color(hex: 0xFDFBF6)

    static let tiger = Color(hex: 0xF5A13E)
    static let tigerStripe = Color(hex: 0x342A20)
    static let tigerCream = Color(hex: 0xFFF3E2)

    static let owl = Color(hex: 0x8B78AC)
    static let owlDeep = Color(hex: 0x6E5C90)
    static let owlFace = Color(hex: 0xF0E7F7)
    static let owlBeak = Color(hex: 0xF0A93B)

    static let rabbit = Color(hex: 0xF7E9E1)
    static let rabbitShade = Color(hex: 0xE4D2C8)

    static let bear = Color(hex: 0xB07F55)
    static let bearLight = Color(hex: 0xEACBA9)

    static let squirrel = Color(hex: 0xD0763B)
    static let squirrelLight = Color(hex: 0xF8DDC2)

    static let hedgehogSpike = Color(hex: 0x7E6045)
    static let hedgehogFace = Color(hex: 0xE8CBA6)
}

// MARK: - 角色配件

/// 身份配件：老师持教棍；小学员沿闯关进度换装（红领巾 → 小背包 → 望远镜 → 毕业帽，
/// 档位见 `StudentProgression`）。配件随动物缩放并参与日夜/跳动。
public enum AnimalAccessory: Equatable, Sendable {
    case none
    case teacher
    /// 红领巾（入门档，0 星起）。
    case student
    /// 小背包（出发档，攒够星就背上去远足）。
    case studentBackpack
    /// 望远镜（探索档，看得更远的学期）。
    case studentTelescope
    /// 毕业帽（学成档，森林里的最高荣誉）。
    case studentGraduation
}

// MARK: - 主体

/// 纯矢量绘制的可爱小动物。夜晚进入「睡觉」状态（闭眼 + Zzz），白天蹦跳眨眼。
public struct CuteAnimalView: View {

    public let kind: AnimalKind
    public let isSleeping: Bool
    public let size: CGFloat
    /// 角色配件（老师持教棍 / 小学员戴红领巾）。
    public var accessory: AnimalAccessory = .none
    /// 是否持续蹦跳；地面个体可关闭以获得「有的动、有的安静」的差异。
    public var bobbing: Bool = true
    /// 教棍敲击计数（+1 = 敲两下）。**默认 0**：森林里其它持教棍的老师不受影响。
    ///
    /// 只有「老师黑板」这一处会传 —— 那是唯一需要「敲黑板引起注意」的地方。
    public var knockTick: Int = 0

    /// **离屏渲染夹具专用总闸**：置 `false` 时动物不启动任何定时动画（眨眼 / 跳动）。
    ///
    /// 为什么非有它不可：`.repeatForever` 的跳动（1.5s 缓动、`bobbing` 默认开）一旦
    /// 生效画面就**永不静止**，眨眼又每 3.2s 关 0.14s。于是「同一份输入连出两次必须
    /// 逐像素相同」这类**确定性守卫在带动物的页面上永远无法成立** —— 帧落在哪一相，
    /// 全看当时机器有多忙（实测：单跑 5/5 绿，全量 3/3 红；差异就是两块 10×8 的方块
    /// —— 那两只眼睛）。靠「多等一会儿直到稳定」是治不好的：它根本不打算停。
    ///
    /// 产品行为**一个字节都不改**（默认 `true`），只有渲染夹具会在 setUp 里关掉它。
    /// 与 `forcedHoveredMessageID` / `DictionaryBookCard.isHovered` 是同一类接缝。
    public static var animationsEnabled = true

    @State private var isBlinking = false
    @State private var isHopping = false

    private let blinkTimer = Timer.publish(every: 3.2, on: .main, in: .common).autoconnect()

    public init(kind: AnimalKind, isSleeping: Bool = false, size: CGFloat = 64,
                accessory: AnimalAccessory = .none, bobbing: Bool = true, knockTick: Int = 0) {
        self.kind = kind
        self.isSleeping = isSleeping
        self.size = size
        self.accessory = accessory
        self.bobbing = bobbing
        self.knockTick = knockTick
    }

    public var body: some View {
        ZStack {
            animal
                .frame(width: size, height: size)

            if isSleeping {
                ZzzView(size: size * 0.28)
                    .offset(x: size * 0.38, y: -size * 0.38)
            }

            switch accessory {
            case .none: EmptyView()
            case .teacher: TeacherPointer(size: size, knockTick: knockTick)
            case .student: RedScarf(size: size)
            case .studentBackpack: LittleBackpack(size: size)
            case .studentTelescope: LittleTelescope(size: size)
            case .studentGraduation: GraduationCap(size: size)
            }
        }
        .frame(width: size, height: size)
        .offset(y: isSleeping ? size * 0.02 : (isHopping ? -size * 0.045 : 0))
        .loopAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: isHopping)
        .onAppear {
            guard bobbing, !isSleeping, Self.animationsEnabled else { isHopping = false; return }
            isHopping = true
        }
        .onChange(of: isSleeping) { _, sleeping in
            isHopping = (bobbing && !sleeping && Self.animationsEnabled) ? true : false
        }
        .onReceive(blinkTimer) { _ in
            guard !isSleeping, Self.animationsEnabled else { return }
            isBlinking = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { isBlinking = false }
        }
    }

    @ViewBuilder
    private var animal: some View {
        switch kind {
        case .fox: FoxAnimal(size: size, isSleeping: isSleeping, isBlinking: isBlinking)
        case .panda: PandaAnimal(size: size, isSleeping: isSleeping, isBlinking: isBlinking)
        case .tiger: TigerAnimal(size: size, isSleeping: isSleeping, isBlinking: isBlinking)
        case .owl: OwlAnimal(size: size, isSleeping: isSleeping, isBlinking: isBlinking)
        case .rabbit: RabbitAnimal(size: size, isSleeping: isSleeping, isBlinking: isBlinking)
        case .bear: BearAnimal(size: size, isSleeping: isSleeping, isBlinking: isBlinking)
        case .squirrel: SquirrelAnimal(size: size, isSleeping: isSleeping, isBlinking: isBlinking)
        case .hedgehog: HedgehogAnimal(size: size, isSleeping: isSleeping, isBlinking: isBlinking)
        }
    }
}

// MARK: - 眼睛

private struct AnimalEye: View {
    let diameter: CGFloat
    let isClosed: Bool
    var sclera: Color? = nil
    var pupil: Color = Fur.dark

    var body: some View {
        ZStack {
            if isClosed {
                Capsule()
                    .fill(pupil)
                    .frame(width: diameter * 0.82, height: max(1.4, diameter * 0.14))
            } else {
                if let sclera {
                    Circle().fill(sclera)
                    Circle().fill(pupil).frame(width: diameter * 0.62, height: diameter * 0.62)
                } else {
                    Circle().fill(pupil)
                }
                Circle()
                    .fill(.white)
                    .frame(width: diameter * 0.30, height: diameter * 0.30)
                    .offset(x: -diameter * 0.17, y: -diameter * 0.18)
                Circle()
                    .fill(.white.opacity(0.55))
                    .frame(width: diameter * 0.13, height: diameter * 0.13)
                    .offset(x: diameter * 0.17, y: diameter * 0.20)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - 小零件

private struct Whiskers: View {
    let size: CGFloat
    let side: CGFloat

    var body: some View {
        ZStack {
            ForEach(0..<2, id: \.self) { index in
                Capsule()
                    .fill(Color(hex: 0x6B5545).opacity(0.5))
                    .frame(width: size * 0.17, height: max(1, size * 0.011))
                    .rotationEffect(.degrees(side > 0 ? -14 + Double(index) * 22 : 14 - Double(index) * 22))
                    .offset(x: side * size * 0.17, y: size * (0.01 + Double(index) * 0.035))
            }
        }
    }
}

private struct Blush: View {
    let size: CGFloat
    let width: CGFloat
    let y: CGFloat

    var body: some View {
        ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
            Ellipse()
                .fill(Fur.pink.opacity(0.45))
                .frame(width: size * width, height: size * width * 0.62)
                .offset(x: side * size * 0.20, y: size * y)
        }
    }
}

// MARK: - 狐狸：尖耳 + 白胸 + 白色口鼻 + 白尖大尾巴

private struct FoxAnimal: View {
    let size: CGFloat
    let isSleeping: Bool
    let isBlinking: Bool

    var body: some View {
        ZStack {
            Capsule().fill(Fur.fox)
                .frame(width: size * 0.38, height: size * 0.19)
                .rotationEffect(.degrees(-42))
                .offset(x: size * 0.27, y: size * 0.24)
            Circle().fill(Fur.foxLight)
                .frame(width: size * 0.17, height: size * 0.17)
                .offset(x: size * 0.40, y: size * 0.08)

            Ellipse().fill(Fur.fox).frame(width: size * 0.50, height: size * 0.38).offset(y: size * 0.24)
            Ellipse().fill(Fur.foxLight).frame(width: size * 0.24, height: size * 0.20).offset(y: size * 0.29)
            Ellipse().fill(Fur.nose.opacity(0.9)).frame(width: size * 0.12, height: size * 0.08).offset(x: -size * 0.11, y: size * 0.41)
            Ellipse().fill(Fur.nose.opacity(0.9)).frame(width: size * 0.12, height: size * 0.08).offset(x: size * 0.11, y: size * 0.41)

            Circle().fill(Fur.fox).frame(width: size * 0.52, height: size * 0.52).offset(y: -size * 0.13)
            ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
                Triangle().fill(Fur.fox).frame(width: size * 0.21, height: size * 0.25)
                    .rotationEffect(.degrees(Double(side) * 15))
                    .offset(x: side * size * 0.18, y: -size * 0.34)
                Triangle().fill(Fur.nose).frame(width: size * 0.11, height: size * 0.14)
                    .rotationEffect(.degrees(Double(side) * 15))
                    .offset(x: side * size * 0.18, y: -size * 0.31)
            }
            // 白色口鼻 + 脸颊
            FoxSnout().fill(Fur.foxLight).frame(width: size * 0.34, height: size * 0.24).offset(y: -size * 0.02)
            Ellipse().fill(Fur.foxLight).frame(width: size * 0.46, height: size * 0.15).offset(y: -size * 0.07)
            Ellipse().fill(Fur.nose).frame(width: size * 0.075, height: size * 0.055).offset(y: -size * 0.075)
            ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
                AnimalEye(diameter: size * 0.105, isClosed: isSleeping || isBlinking)
                    .offset(x: side * size * 0.115, y: -size * 0.175)
            }
            Whiskers(size: size, side: -1).offset(x: -size * 0.02, y: -size * 0.06)
            Whiskers(size: size, side: 1).offset(x: size * 0.02, y: -size * 0.06)
        }
    }
}

private struct FoxSnout: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.18))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.18),
                       control: CGPoint(x: r.midX, y: r.minY - r.height * 0.20))
        p.addQuadCurve(to: CGPoint(x: r.midX, y: r.maxY),
                       control: CGPoint(x: r.maxX, y: r.minY + r.height * 0.90))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.18),
                       control: CGPoint(x: r.minX, y: r.minY + r.height * 0.90))
        return p
    }
}

// MARK: - 熊猫：黑白配色 + 黑眼圈 + 圆耳

private struct PandaAnimal: View {
    let size: CGFloat
    let isSleeping: Bool
    let isBlinking: Bool

    var body: some View {
        ZStack {
            Ellipse().fill(Fur.pandaBlack).frame(width: size * 0.16, height: size * 0.27)
                .rotationEffect(.degrees(-16)).offset(x: -size * 0.245, y: size * 0.22)
            Ellipse().fill(Fur.pandaBlack).frame(width: size * 0.16, height: size * 0.27)
                .rotationEffect(.degrees(16)).offset(x: size * 0.245, y: size * 0.22)
            Ellipse().fill(Fur.pandaBlack).frame(width: size * 0.21, height: size * 0.15).offset(x: -size * 0.13, y: size * 0.41)
            Ellipse().fill(Fur.pandaBlack).frame(width: size * 0.21, height: size * 0.15).offset(x: size * 0.13, y: size * 0.41)

            Ellipse().fill(Fur.pandaWhite).frame(width: size * 0.54, height: size * 0.44).offset(y: size * 0.22)

            Circle().fill(Fur.pandaWhite).frame(width: size * 0.56, height: size * 0.56).offset(y: -size * 0.14)
            Circle().fill(Fur.pandaBlack).frame(width: size * 0.20, height: size * 0.20).offset(x: -size * 0.21, y: -size * 0.36)
            Circle().fill(Fur.pandaBlack).frame(width: size * 0.20, height: size * 0.20).offset(x: size * 0.21, y: -size * 0.36)

            Ellipse().fill(Fur.pandaBlack).frame(width: size * 0.18, height: size * 0.22)
                .rotationEffect(.degrees(-22)).offset(x: -size * 0.115, y: -size * 0.165)
            Ellipse().fill(Fur.pandaBlack).frame(width: size * 0.18, height: size * 0.22)
                .rotationEffect(.degrees(22)).offset(x: size * 0.115, y: -size * 0.165)

            if isSleeping || isBlinking {
                Capsule().fill(Fur.dark).frame(width: size * 0.11, height: max(1.2, size * 0.016)).offset(x: -size * 0.115, y: -size * 0.165)
                Capsule().fill(Fur.dark).frame(width: size * 0.11, height: max(1.2, size * 0.016)).offset(x: size * 0.115, y: -size * 0.165)
            } else {
                ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
                    Circle().fill(.white).frame(width: size * 0.088, height: size * 0.088).offset(x: side * size * 0.115, y: -size * 0.168)
                    Circle().fill(Fur.dark).frame(width: size * 0.058, height: size * 0.058).offset(x: side * size * 0.118, y: -size * 0.163)
                }
            }

            RoundedTriangle().fill(Fur.dark).frame(width: size * 0.12, height: size * 0.085).offset(y: -size * 0.055)
            Capsule().fill(Fur.dark.opacity(0.75)).frame(width: size * 0.09, height: max(1, size * 0.012)).offset(y: size * 0.005)
            Blush(size: size, width: 0.10, y: -0.03)
        }
    }
}

private struct RoundedTriangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let radius = min(r.width, r.height) * 0.28
        p.move(to: CGPoint(x: r.midX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY + radius * 0.2))
        p.addQuadCurve(to: CGPoint(x: r.maxX - radius * 0.2, y: r.minY),
                       control: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + radius * 0.2, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + radius, y: r.minY + radius * 0.2),
                       control: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - 老虎：橙色 + 黑条纹 + 王字额纹 + 白口鼻

private struct TigerAnimal: View {
    let size: CGFloat
    let isSleeping: Bool
    let isBlinking: Bool

    var body: some View {
        ZStack {
            Capsule().fill(Fur.tiger).frame(width: size * 0.36, height: size * 0.13)
                .rotationEffect(.degrees(-38)).offset(x: size * 0.28, y: size * 0.25)
            ForEach(0..<2, id: \.self) { index in
                Capsule().fill(Fur.tigerStripe.opacity(0.85))
                    .frame(width: size * 0.055, height: size * 0.14)
                    .rotationEffect(.degrees(-38))
                    .offset(x: size * (0.24 + Double(index) * 0.09), y: size * (0.32 - Double(index) * 0.10))
            }

            Ellipse().fill(Fur.tiger).frame(width: size * 0.54, height: size * 0.44)
                .overlay(
                    ZStack {
                        ForEach(0..<3, id: \.self) { index in
                            Capsule().fill(Fur.tigerStripe.opacity(0.8))
                                .frame(width: size * 0.34, height: size * 0.045)
                                .rotationEffect(.degrees(-22))
                                .offset(x: -size * 0.11, y: size * (-0.10 + Double(index) * 0.10))
                        }
                        ForEach(0..<3, id: \.self) { index in
                            Capsule().fill(Fur.tigerStripe.opacity(0.8))
                                .frame(width: size * 0.34, height: size * 0.045)
                                .rotationEffect(.degrees(22))
                                .offset(x: size * 0.11, y: size * (-0.10 + Double(index) * 0.10))
                        }
                    }
                    .clipShape(Ellipse())
                )
                .offset(y: size * 0.22)
            Ellipse().fill(Fur.tigerCream).frame(width: size * 0.30, height: size * 0.24).offset(y: size * 0.27)

            Circle().fill(Fur.tiger).frame(width: size * 0.56, height: size * 0.56).offset(y: -size * 0.13)
            Circle().fill(Fur.tiger).frame(width: size * 0.21, height: size * 0.21).offset(x: -size * 0.21, y: -size * 0.35)
            Circle().fill(Fur.tiger).frame(width: size * 0.21, height: size * 0.21).offset(x: size * 0.21, y: -size * 0.35)
            Circle().fill(Fur.pink.opacity(0.75)).frame(width: size * 0.12, height: size * 0.12).offset(x: -size * 0.21, y: -size * 0.35)
            Circle().fill(Fur.pink.opacity(0.75)).frame(width: size * 0.12, height: size * 0.12).offset(x: size * 0.21, y: -size * 0.35)

            // 额头「王」字纹
            Capsule().fill(Fur.tigerStripe).frame(width: size * 0.035, height: size * 0.14).offset(y: -size * 0.31)
            Capsule().fill(Fur.tigerStripe).frame(width: size * 0.16, height: size * 0.032).offset(y: -size * 0.34)
            Capsule().fill(Fur.tigerStripe).frame(width: size * 0.16, height: size * 0.032).offset(y: -size * 0.29)

            // 白色口鼻（两瓣）
            Ellipse().fill(Fur.tigerCream).frame(width: size * 0.40, height: size * 0.20).offset(y: -size * 0.03)
            Ellipse().fill(Fur.tigerCream).frame(width: size * 0.15, height: size * 0.13).offset(x: -size * 0.065, y: -size * 0.045)
            Ellipse().fill(Fur.tigerCream).frame(width: size * 0.15, height: size * 0.13).offset(x: size * 0.065, y: -size * 0.045)
            RoundedTriangle().fill(Fur.pink).frame(width: size * 0.11, height: size * 0.075).offset(y: -size * 0.085)
            Capsule().fill(Fur.dark.opacity(0.7)).frame(width: size * 0.08, height: max(1, size * 0.011)).offset(y: -size * 0.02)

            ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
                AnimalEye(diameter: size * 0.105, isClosed: isSleeping || isBlinking)
                    .offset(x: side * size * 0.115, y: -size * 0.17)
            }
            Whiskers(size: size, side: -1).offset(x: -size * 0.02, y: -size * 0.07)
            Whiskers(size: size, side: 1).offset(x: size * 0.02, y: -size * 0.07)
        }
    }
}

// MARK: - 猫头鹰：大眼睛 + 面盘 + 耳簇 + 翅膀

private struct OwlAnimal: View {
    let size: CGFloat
    let isSleeping: Bool
    let isBlinking: Bool

    var body: some View {
        ZStack {
            Ellipse().fill(Fur.owlDeep).frame(width: size * 0.15, height: size * 0.34)
                .rotationEffect(.degrees(-10)).offset(x: -size * 0.235, y: size * 0.16)
            Ellipse().fill(Fur.owlDeep).frame(width: size * 0.15, height: size * 0.34)
                .rotationEffect(.degrees(10)).offset(x: size * 0.235, y: size * 0.16)

            Ellipse().fill(Fur.owl).frame(width: size * 0.52, height: size * 0.50).offset(y: size * 0.14)
            Ellipse().fill(Fur.owlFace).frame(width: size * 0.32, height: size * 0.30).offset(y: size * 0.20)

            // 脚
            ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
                Capsule().fill(Fur.owlBeak).frame(width: size * 0.06, height: size * 0.03)
                    .rotationEffect(.degrees(side > 0 ? 20 : -20))
                    .offset(x: side * size * 0.09, y: size * 0.38)
            }

            Circle().fill(Fur.owl).frame(width: size * 0.58, height: size * 0.58).offset(y: -size * 0.16)
            ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
                Triangle().fill(Fur.owl).frame(width: size * 0.17, height: size * 0.19)
                    .rotationEffect(.degrees(Double(side) * 14))
                    .offset(x: side * size * 0.17, y: -size * 0.42)
            }

            // 面盘
            Circle().fill(Fur.owlFace).frame(width: size * 0.28, height: size * 0.28).offset(x: -size * 0.085, y: -size * 0.18)
            Circle().fill(Fur.owlFace).frame(width: size * 0.28, height: size * 0.28).offset(x: size * 0.085, y: -size * 0.18)

            ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
                AnimalEye(diameter: size * 0.20, isClosed: isSleeping || isBlinking,
                          sclera: Color(hex: 0xFFD98A), pupil: Fur.dark)
                    .offset(x: side * size * 0.085, y: -size * 0.18)
            }

            Triangle().fill(Fur.owlBeak).frame(width: size * 0.11, height: size * 0.12).offset(y: -size * 0.06)
        }
    }
}

// MARK: - 兔子：长耳 + 粉内耳 + 门牙 + 圆尾巴

private struct RabbitAnimal: View {
    let size: CGFloat
    let isSleeping: Bool
    let isBlinking: Bool

    var body: some View {
        ZStack {
            Circle().fill(.white).frame(width: size * 0.18, height: size * 0.18).offset(x: -size * 0.28, y: size * 0.27)
            Ellipse().fill(Fur.rabbit).frame(width: size * 0.48, height: size * 0.40).offset(y: size * 0.23)
            Ellipse().fill(Fur.rabbitShade).frame(width: size * 0.18, height: size * 0.11).offset(x: -size * 0.12, y: size * 0.41)
            Ellipse().fill(Fur.rabbitShade).frame(width: size * 0.18, height: size * 0.11).offset(x: size * 0.12, y: size * 0.41)

            Circle().fill(Fur.rabbit).frame(width: size * 0.50, height: size * 0.50).offset(y: -size * 0.11)
            ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
                Capsule().fill(Fur.rabbit).frame(width: size * 0.135, height: size * 0.38)
                    .rotationEffect(.degrees(Double(side) * 9))
                    .offset(x: side * size * 0.145, y: -size * 0.45)
                Capsule().fill(Fur.pink.opacity(0.85)).frame(width: size * 0.07, height: size * 0.28)
                    .rotationEffect(.degrees(Double(side) * 9))
                    .offset(x: side * size * 0.145, y: -size * 0.45)
            }

            ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
                AnimalEye(diameter: size * 0.10, isClosed: isSleeping || isBlinking)
                    .offset(x: side * size * 0.11, y: -size * 0.15)
            }
            RoundedTriangle().fill(Fur.pink).frame(width: size * 0.08, height: size * 0.055).offset(y: -size * 0.055)
            Capsule().fill(Fur.dark.opacity(0.55)).frame(width: size * 0.06, height: max(1, size * 0.010)).offset(y: -size * 0.005)
            ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
                RoundedRectangle(cornerRadius: size * 0.012, style: .continuous)
                    .fill(.white)
                    .frame(width: size * 0.032, height: size * 0.055)
                    .offset(x: side * size * 0.026, y: size * 0.025)
            }
            Blush(size: size, width: 0.09, y: -0.05)
            Whiskers(size: size, side: -1).offset(x: -size * 0.01, y: -size * 0.08)
            Whiskers(size: size, side: 1).offset(x: size * 0.01, y: -size * 0.08)
        }
    }
}

// MARK: - 小熊：圆耳 + 大吻部 + 小眼睛

private struct BearAnimal: View {
    let size: CGFloat
    let isSleeping: Bool
    let isBlinking: Bool

    var body: some View {
        ZStack {
            Ellipse().fill(Fur.bear).frame(width: size * 0.56, height: size * 0.46).offset(y: size * 0.22)
            Ellipse().fill(Fur.bearLight).frame(width: size * 0.32, height: size * 0.25).offset(y: size * 0.28)
            Circle().fill(Fur.bear).frame(width: size * 0.16, height: size * 0.16).offset(x: -size * 0.25, y: size * 0.32)
            Circle().fill(Fur.bear).frame(width: size * 0.16, height: size * 0.16).offset(x: size * 0.25, y: size * 0.32)

            Circle().fill(Fur.bear).frame(width: size * 0.54, height: size * 0.54).offset(y: -size * 0.15)
            ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
                Circle().fill(Fur.bear).frame(width: size * 0.21, height: size * 0.21).offset(x: side * size * 0.21, y: -size * 0.37)
                Circle().fill(Fur.bearLight).frame(width: size * 0.12, height: size * 0.12).offset(x: side * size * 0.21, y: -size * 0.37)
            }

            Ellipse().fill(Fur.bearLight).frame(width: size * 0.28, height: size * 0.20).offset(y: -size * 0.05)
            Ellipse().fill(Fur.nose).frame(width: size * 0.11, height: size * 0.075).offset(y: -size * 0.105)
            Capsule().fill(Fur.dark.opacity(0.6)).frame(width: size * 0.08, height: max(1, size * 0.011)).offset(y: -size * 0.02)
            ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
                AnimalEye(diameter: size * 0.085, isClosed: isSleeping || isBlinking)
                    .offset(x: side * size * 0.115, y: -size * 0.195)
            }
            Blush(size: size, width: 0.09, y: -0.06)
        }
    }
}

// MARK: - 松鼠：蓬松大尾巴 + 门牙 + 尖耳

private struct SquirrelAnimal: View {
    let size: CGFloat
    let isSleeping: Bool
    let isBlinking: Bool

    var body: some View {
        ZStack {
            BushyTail().stroke(Fur.squirrel, style: StrokeStyle(lineWidth: size * 0.21, lineCap: .round))
                .frame(width: size * 0.46, height: size * 0.62)
                .offset(x: size * 0.28, y: size * 0.06)
            BushyTail().stroke(Fur.squirrelLight, style: StrokeStyle(lineWidth: size * 0.10, lineCap: .round))
                .frame(width: size * 0.38, height: size * 0.52)
                .offset(x: size * 0.28, y: size * 0.06)

            Ellipse().fill(Fur.squirrel).frame(width: size * 0.46, height: size * 0.42).offset(y: size * 0.25)
            Ellipse().fill(Fur.squirrelLight).frame(width: size * 0.26, height: size * 0.24).offset(y: size * 0.29)
            Ellipse().fill(Fur.squirrelLight).frame(width: size * 0.15, height: size * 0.10).offset(x: -size * 0.10, y: size * 0.42)
            Ellipse().fill(Fur.squirrelLight).frame(width: size * 0.15, height: size * 0.10).offset(x: size * 0.10, y: size * 0.42)

            Circle().fill(Fur.squirrel).frame(width: size * 0.50, height: size * 0.50).offset(y: -size * 0.12)
            ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
                Triangle().fill(Fur.squirrel).frame(width: size * 0.17, height: size * 0.19)
                    .rotationEffect(.degrees(Double(side) * 12))
                    .offset(x: side * size * 0.165, y: -size * 0.34)
                Triangle().fill(Fur.pink.opacity(0.8)).frame(width: size * 0.09, height: size * 0.11)
                    .rotationEffect(.degrees(Double(side) * 12))
                    .offset(x: side * size * 0.165, y: -size * 0.32)
            }

            ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
                AnimalEye(diameter: size * 0.115, isClosed: isSleeping || isBlinking)
                    .offset(x: side * size * 0.11, y: -size * 0.16)
            }
            Ellipse().fill(Fur.cream).frame(width: size * 0.20, height: size * 0.14).offset(y: -size * 0.045)
            Ellipse().fill(Fur.nose).frame(width: size * 0.07, height: size * 0.05).offset(y: -size * 0.075)
            ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
                RoundedRectangle(cornerRadius: size * 0.010, style: .continuous)
                    .fill(.white)
                    .frame(width: size * 0.030, height: size * 0.05)
                    .offset(x: side * size * 0.024, y: size * 0.005)
            }
            Blush(size: size, width: 0.085, y: -0.05)
        }
    }
}

private struct BushyTail: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 0.20, y: r.maxY))
        p.addCurve(
            to: CGPoint(x: r.maxX - r.width * 0.05, y: r.minY + r.height * 0.12),
            control1: CGPoint(x: r.minX - r.width * 0.62, y: r.maxY - r.height * 0.28),
            control2: CGPoint(x: r.maxX + r.width * 0.18, y: r.minY + r.height * 0.78)
        )
        return p
    }
}

// MARK: - 刺猬：尖刺背 + 尖嘴

private struct HedgehogAnimal: View {
    let size: CGFloat
    let isSleeping: Bool
    let isBlinking: Bool

    var body: some View {
        ZStack {
            SpikyDome().fill(Fur.hedgehogSpike)
                .frame(width: size * 0.76, height: size * 0.52)
                .offset(y: size * 0.10)
            SpikyDome().fill(Fur.hedgehogSpike.opacity(0.55))
                .frame(width: size * 0.52, height: size * 0.34)
                .offset(x: -size * 0.06, y: size * 0.02)

            Ellipse().fill(Fur.hedgehogFace).frame(width: size * 0.44, height: size * 0.40).offset(y: size * 0.20)
            Ellipse().fill(Fur.hedgehogFace).frame(width: size * 0.16, height: size * 0.13).offset(y: size * 0.35)
            Circle().fill(Fur.dark).frame(width: size * 0.07, height: size * 0.06).offset(y: size * 0.345)

            ForEach([CGFloat(-1), CGFloat(1)], id: \.self) { side in
                Circle().fill(Fur.nose).frame(width: size * 0.10, height: size * 0.10).offset(x: side * size * 0.155, y: size * 0.06)
                AnimalEye(diameter: size * 0.075, isClosed: isSleeping || isBlinking)
                    .offset(x: side * size * 0.075, y: size * 0.135)
            }
            Ellipse().fill(Fur.hedgehogSpike.opacity(0.9)).frame(width: size * 0.16, height: size * 0.09).offset(x: -size * 0.16, y: size * 0.38)
            Ellipse().fill(Fur.hedgehogSpike.opacity(0.9)).frame(width: size * 0.16, height: size * 0.09).offset(x: size * 0.16, y: size * 0.38)
            Blush(size: size, width: 0.075, y: 0.21)
        }
    }
}

private struct SpikyDome: Shape {
    func path(in r: CGRect) -> Path {
        let spikes = 12
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        for index in 0..<spikes {
            let t0 = Double(index) / Double(spikes)
            let t1 = Double(index + 1) / Double(spikes)
            let x0 = r.minX + r.width * t0
            let x1 = r.minX + r.width * t1
            let xm = (x0 + x1) / 2
            let h0 = domeHeight(t0)
            let h1 = domeHeight(t1)
            p.addLine(to: CGPoint(x: xm, y: r.maxY - r.height * h0))
            p.addLine(to: CGPoint(x: x1, y: r.maxY - r.height * (h0 + h1) / 2 + r.height * 0.16))
        }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }

    private func domeHeight(_ t: Double) -> Double {
        let centered = (t - 0.5) * 2
        return 0.42 + 0.58 * sqrt(max(0, 1 - centered * centered))
    }
}

// MARK: - 共用形状

public struct Triangle: Shape {
    public init() {}
    public func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

public struct ZzzView: View {
    let size: CGFloat
    @State private var offset: CGFloat = 0
    @State private var opacity: Double = 0.25

    @Environment(\.appMotion) private var motion

    public init(size: CGFloat) { self.size = size }

    public var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Text("z")
                    .appFont(size * (0.5 + Double(index) * 0.22), weight: .bold, design: .rounded)
                    .foregroundStyle(.white.opacity(0.85))
                    .offset(x: CGFloat(index) * size * 0.42, y: -CGFloat(index) * size * 0.40)
            }
        }
        .offset(y: offset)
        .opacity(opacity)
        .onAppear {
            // 开了「减弱动态效果」就让 zzz 静静留在原地：这一路 floating 纯粹是装饰
            // （睡觉气氛），动起来既干扰又白白占一次渲染。三个 z 会有一丁点 opacity，
            // 静止时看得出这是「睡了」，不会变成看不见。
            guard !motion.reduceMotion else { return }
            withAnimation(.easeOut(duration: 2.6).repeatForever(autoreverses: false)) {
                offset = -size * 0.9
                opacity = 0
            }
        }
    }
}

// MARK: - 配件：老师教棍 / 小学员红领巾
//
// 配件按「所有动物共用的身体比例」定位（头在画面上半部、身体居中），
// 因此对任意物种都贴合在脖子/身侧，不依赖某一物种的局部坐标。

private enum AccessoryPalette {
    static let wood = Color(hex: 0x9C6B3F)
    static let woodDark = Color(hex: 0x7A4E2B)
    static let scarf = Color(hex: 0xE8454B)
    static let scarfDark = Color(hex: 0xC22F38)
    static let tip = Color(hex: 0xFFD34D)
    // 成长线配饰：背包（草绿系）/ 望远镜（黄铜系）/ 毕业帽（墨黑 + 金穗）
    static let pack = Color(hex: 0x5FA05C)
    static let packDark = Color(hex: 0x477F48)
    static let strap = Color(hex: 0xE8DCC2)
    static let brass = Color(hex: 0xD9A441)
    static let brassDark = Color(hex: 0xA8792C)
    static let cap = Color(hex: 0x2E2C33)
    static let capDark = Color(hex: 0x1F1E23)
    static let tassel = Color(hex: 0xFFD34D)
}

/// 教棍的姿态（纯函数，方便钉住「往哪边敲」这件事）。
///
/// ⚠️ **符号约定**：`degrees` 是相对竖直的旋转角，SwiftUI 的 y 轴朝下，
/// 所以**正角 = 顺时针 = 棍梢往右**。用户看到「敲黑板时棍梢往左扫」后点名要改成往右，
/// 敲击角因此是正的 —— 改符号等于改方向，别当普通数值随手调。
struct PointerPose: Equatable {
    /// 棍身相对竖直的旋转角（度）。
    var degrees: Double
    /// 整根棍相对老师画框中心的位移（`size` 的倍数）。
    var xRatio: CGFloat
    var yRatio: CGFloat

    static let stickLengthRatio: CGFloat = 0.40

    /// 棍梢相对棍底的横向位移（`size` 的倍数）。正 = 往右。
    var tipOffsetXRatio: CGFloat {
        Self.stickLengthRatio * CGFloat(sin(degrees * .pi / 180))
    }

    /// 三种姿态：敲击 / 随手挥 / 立着。
    static func make(knocking: Bool, waving: Bool) -> PointerPose {
        // 敲黑板：往**右**上方抬起来敲两下（棍梢扫到画框右缘之外，看着才像真敲在板上）。
        if knocking { return PointerPose(degrees: 46, xRatio: 0.22, yRatio: -0.02) }
        // 随手挥：小幅、往左一点点（讲课的节奏感）。
        if waving { return PointerPose(degrees: -18, xRatio: 0.26, yRatio: 0.06) }
        return PointerPose(degrees: 6, xRatio: 0.26, yRatio: 0.06)
    }
}

/// 教棍：握在老师手边的木质小棍 + 金色圆头；比身体短一号，
/// 每隔几秒以棍身底端为轴小幅上下挥动一次（讲课的节奏感）。
private struct TeacherPointer: View {
    let size: CGFloat
    /// +1 → 敲两下（黑板展开时用：教棍点两下引起注意）。0 = 只保留原本的随手挥动。
    let knockTick: Int

    @State private var isWaving = false
    @State private var isKnocking = false
    private let waveTimer = Timer.publish(every: 4.2, on: .main, in: .common).autoconnect()

    private var pose: PointerPose { PointerPose.make(knocking: isKnocking, waving: isWaving) }

    var body: some View {
        ZStack {
            // 棍组（以底端为轴挥动）
            ZStack {
                // 棍身
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [AccessoryPalette.wood, AccessoryPalette.woodDark],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .frame(width: max(2.2, size * 0.042), height: size * PointerPose.stickLengthRatio)
                // 高光
                Capsule()
                    .fill(.white.opacity(0.35))
                    .frame(width: max(1, size * 0.012), height: size * 0.20)
                    .offset(x: -size * 0.012, y: -size * 0.04)
                // 金色圆头（棍梢）
                Circle()
                    .fill(AccessoryPalette.tip)
                    .frame(width: size * 0.085, height: size * 0.085)
                    .overlay(Circle().stroke(AccessoryPalette.woodDark.opacity(0.55), lineWidth: max(1, size * 0.01)))
                    .offset(y: -size * 0.20)
            }
            .rotationEffect(.degrees(pose.degrees), anchor: .bottom)
            .animation(isKnocking
                       ? .easeOut(duration: 0.11)
                       : .easeInOut(duration: 0.45), value: pose)
            .offset(x: size * pose.xRatio, y: size * pose.yRatio)
        }
        .frame(width: size, height: size)
        .onReceive(waveTimer) { _ in
            // 敲黑板的时候不随手挥：两个动作叠在一起会像抽筋
            guard !isKnocking else { return }
            // 挥一下再收回：小幅、不频繁
            isWaving = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { isWaving = false }
        }
        .onChange(of: knockTick) { _, _ in
            guard knockTick > 0 else { return }
            Task { @MainActor in
                // 敲两下，中间留一个能看清的间隔（0.11s 出去 / 0.13s 回来 / 停 0.17s）
                for _ in 0..<2 {
                    withAnimation(.easeOut(duration: 0.11)) { isKnocking = true }
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    withAnimation(.easeIn(duration: 0.13)) { isKnocking = false }
                    try? await Task.sleep(nanoseconds: 170_000_000)
                }
            }
        }
    }
}

/// 红领巾：脖子处一圈红色三角巾 + 结 + 飘带，贴合所有物种的颈线。
private struct RedScarf: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            // 颈圈（略弯，绕过脖子后侧）
            Capsule()
                .fill(AccessoryPalette.scarf)
                .frame(width: size * 0.46, height: size * 0.15)
                .offset(y: size * 0.10)
            Capsule()
                .fill(AccessoryPalette.scarfDark.opacity(0.55))
                .frame(width: size * 0.44, height: size * 0.05)
                .offset(y: size * 0.155)
            // 领结结
            Circle()
                .fill(AccessoryPalette.scarf)
                .frame(width: size * 0.13, height: size * 0.12)
                .offset(y: size * 0.16)
            // 两条飘带
            RoundedTriangle()
                .fill(AccessoryPalette.scarf)
                .frame(width: size * 0.11, height: size * 0.16)
                .rotationEffect(.degrees(-12))
                .offset(x: -size * 0.06, y: size * 0.23)
            RoundedTriangle()
                .fill(AccessoryPalette.scarf)
                .frame(width: size * 0.11, height: size * 0.16)
                .rotationEffect(.degrees(12))
                .offset(x: size * 0.06, y: size * 0.23)
        }
        .frame(width: size, height: size)
    }
}

/// 小背包：背上背的小圆角书包 + 两侧水壶袋 + 扣带，背上它就是「要出发远足」的学员。
private struct LittleBackpack: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            // 包身（圆角矩形，背在背后偏一侧，不挡脸）
            RoundedRectangle(cornerRadius: size * 0.07, style: .continuous)
                .fill(AccessoryPalette.pack)
                .frame(width: size * 0.34, height: size * 0.40)
                .offset(x: size * 0.26, y: size * 0.08)
            // 包盖
            RoundedRectangle(cornerRadius: size * 0.07, style: .continuous)
                .fill(AccessoryPalette.packDark)
                .frame(width: size * 0.34, height: size * 0.14)
                .offset(x: size * 0.26, y: size * -0.06)
            // 扣带
            Capsule()
                .fill(AccessoryPalette.strap)
                .frame(width: size * 0.035, height: size * 0.10)
                .offset(x: size * 0.26, y: size * 0.02)
            // 水壶袋
            Capsule()
                .fill(AccessoryPalette.packDark)
                .frame(width: size * 0.10, height: size * 0.20)
                .offset(x: size * 0.14, y: size * 0.12)
        }
        .frame(width: size, height: size)
    }
}

/// 小望远镜：举在眼前的小单筒望远镜（斜向上 25°，望向远处），探索档的象征。
private struct LittleTelescope: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            // 镜筒
            Capsule()
                .fill(AccessoryPalette.brass)
                .frame(width: size * 0.42, height: size * 0.13)
                .rotationEffect(.degrees(-25))
                .offset(x: size * 0.20, y: size * -0.16)
            // 物镜（粗端）
            Capsule()
                .fill(AccessoryPalette.brassDark)
                .frame(width: size * 0.12, height: size * 0.17)
                .rotationEffect(.degrees(-25))
                .offset(x: size * 0.36, y: size * -0.22)
            // 目镜（细端）
            Capsule()
                .fill(AccessoryPalette.brassDark)
                .frame(width: size * 0.08, height: size * 0.15)
                .rotationEffect(.degrees(-25))
                .offset(x: size * 0.04, y: size * -0.10)
            // 镜身高光
            Capsule()
                .fill(.white.opacity(0.30))
                .frame(width: size * 0.22, height: size * 0.03)
                .rotationEffect(.degrees(-25))
                .offset(x: size * 0.20, y: size * -0.19)
        }
        .frame(width: size, height: size)
    }
}

/// 毕业帽：方帽 + 帽穗，学成档的最高荣誉，稳稳戴在头顶。
private struct GraduationCap: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            // 帽顶（菱形板）
            RoundedRectangle(cornerRadius: size * 0.02, style: .continuous)
                .fill(AccessoryPalette.cap)
                .frame(width: size * 0.52, height: size * 0.52)
                .rotationEffect(.degrees(45))
                .scaleEffect(x: 1, y: 0.55)
                .offset(y: size * -0.30)
            // 帽座（梯形感的小圆台）
            Capsule()
                .fill(AccessoryPalette.capDark)
                .frame(width: size * 0.36, height: size * 0.10)
                .offset(y: size * -0.22)
            // 帽穗：从帽顶垂到一侧
            Capsule()
                .fill(AccessoryPalette.tassel)
                .frame(width: size * 0.03, height: size * 0.22)
                .rotationEffect(.degrees(18), anchor: .top)
                .offset(x: size * 0.14, y: size * -0.12)
            // 穗子坠
            Circle()
                .fill(AccessoryPalette.tassel)
                .frame(width: size * 0.07, height: size * 0.07)
                .offset(x: size * 0.19, y: size * 0.00)
        }
        .frame(width: size, height: size)
    }
}
