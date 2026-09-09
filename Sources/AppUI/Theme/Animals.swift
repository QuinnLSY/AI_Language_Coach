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

// MARK: - 主体

/// 纯矢量绘制的可爱小动物。夜晚进入「睡觉」状态（闭眼 + Zzz），白天蹦跳眨眼。
public struct CuteAnimalView: View {

    public let kind: AnimalKind
    public let isSleeping: Bool
    public let size: CGFloat

    @State private var isBlinking = false
    @State private var isHopping = false

    private let blinkTimer = Timer.publish(every: 3.2, on: .main, in: .common).autoconnect()

    public init(kind: AnimalKind, isSleeping: Bool = false, size: CGFloat = 64) {
        self.kind = kind
        self.isSleeping = isSleeping
        self.size = size
    }

    public var body: some View {
        ZStack {
            animal
                .frame(width: size, height: size)

            if isSleeping {
                ZzzView(size: size * 0.28)
                    .offset(x: size * 0.38, y: -size * 0.38)
            }
        }
        .frame(width: size, height: size)
        .offset(y: isSleeping ? size * 0.02 : (isHopping ? -size * 0.045 : 0))
        .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: isHopping)
        .onAppear {
            guard !isSleeping else { isHopping = false; return }
            isHopping = true
        }
        .onChange(of: isSleeping) { _, sleeping in
            isHopping = sleeping ? false : true
        }
        .onReceive(blinkTimer) { _ in
            guard !isSleeping else { return }
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

    public init(size: CGFloat) { self.size = size }

    public var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                Text("z")
                    .font(.system(size: size * (0.5 + Double(index) * 0.22), weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .offset(x: CGFloat(index) * size * 0.42, y: -CGFloat(index) * size * 0.40)
            }
        }
        .offset(y: offset)
        .opacity(opacity)
        .onAppear {
            withAnimation(.easeOut(duration: 2.6).repeatForever(autoreverses: false)) {
                offset = -size * 0.9
                opacity = 0
            }
        }
    }
}
