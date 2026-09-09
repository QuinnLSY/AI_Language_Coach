import SwiftUI

public enum AnimalKind: String, CaseIterable, Sendable, Identifiable {
    case fox
    case owl
    case rabbit
    case bear
    case squirrel
    case hedgehog

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fox: "小狐狸"
        case .owl: "猫头鹰"
        case .rabbit: "小兔子"
        case .bear: "小熊"
        case .squirrel: "小松鼠"
        case .hedgehog: "小刺猬"
        }
    }

    var fur: Color {
        switch self {
        case .fox: Color(hex: 0xF08A4B)
        case .owl: Color(hex: 0x9B7BB8)
        case .rabbit: Color(hex: 0xF3E4D6)
        case .bear: Color(hex: 0xB07C56)
        case .squirrel: Color(hex: 0xD2793F)
        case .hedgehog: Color(hex: 0xC9A06A)
        }
    }

    var belly: Color {
        switch self {
        case .fox: Color(hex: 0xFBE3CE)
        case .owl: Color(hex: 0xE7DDF2)
        case .rabbit: Color(hex: 0xFFFFFF)
        case .bear: Color(hex: 0xE7C9A9)
        case .squirrel: Color(hex: 0xF6DCC0)
        case .hedgehog: Color(hex: 0xEFDCC0)
        }
    }

    var earStyle: EarStyle {
        switch self {
        case .fox: .pointy
        case .owl: .tuft
        case .rabbit: .tall
        case .bear: .round
        case .squirrel: .pointy
        case .hedgehog: .tiny
        }
    }

    var hasTail: Bool {
        switch self {
        case .rabbit, .squirrel, .fox: true
        default: false
        }
    }
}

public enum EarStyle: Sendable {
    case pointy
    case tuft
    case tall
    case round
    case tiny
}

/// 纯矢量绘制的可爱小动物。夜晚自动进入「睡觉」状态（闭眼 + Zzz），白天蹦跳眨眼。
public struct CuteAnimalView: View {

    public let kind: AnimalKind
    public let isSleeping: Bool
    public let size: CGFloat

    @State private var isBlinking = false
    @State private var isHopping = false

    public init(kind: AnimalKind, isSleeping: Bool = false, size: CGFloat = 64) {
        self.kind = kind
        self.isSleeping = isSleeping
        self.size = size
    }

    public var body: some View {
        ZStack {
            if kind.hasTail { tail }
            ears
            bodyShape
            head
            face
            if isSleeping {
                ZzzView(size: size * 0.3)
                    .offset(x: size * 0.42, y: -size * 0.42)
            }
        }
        .frame(width: size, height: size)
        .offset(y: isSleeping ? 0 : (isHopping ? -size * 0.05 : 0))
        .onAppear {
            guard !isSleeping else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                isHopping = true
            }
            Timer.scheduledTimer(withTimeInterval: 3.4, repeats: true) { _ in
                guard !isSleeping else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.12)) { isBlinking = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                        withAnimation(.easeInOut(duration: 0.12)) { isBlinking = false }
                    }
                }
            }
        }
    }

    // MARK: - 部件

    private var bodyShape: some View {
        Ellipse()
            .fill(kind.fur)
            .frame(width: size * 0.60, height: size * 0.44)
            .overlay(
                Ellipse()
                    .fill(kind.belly)
                    .frame(width: size * 0.34, height: size * 0.26)
                    .offset(y: size * 0.04)
            )
            .offset(y: size * 0.20)
    }

    private var head: some View {
        Circle()
            .fill(kind.fur)
            .frame(width: size * 0.56, height: size * 0.56)
            .offset(y: -size * 0.12)
    }

    private var ears: some View {
        ZStack {
            switch kind.earStyle {
            case .pointy:
                ForEach([-1.0, 1.0], id: \.self) { side in
                    Triangle()
                        .fill(kind.fur)
                        .frame(width: size * 0.20, height: size * 0.24)
                        .offset(x: side * size * 0.17, y: -size * 0.34)
                }
            case .tall:
                ForEach([-1.0, 1.0], id: \.self) { side in
                    Capsule()
                        .fill(kind.fur)
                        .frame(width: size * 0.13, height: size * 0.32)
                        .offset(x: side * size * 0.15, y: -size * 0.40)
                }
            case .round:
                ForEach([-1.0, 1.0], id: \.self) { side in
                    Circle()
                        .fill(kind.fur)
                        .frame(width: size * 0.20, height: size * 0.20)
                        .offset(x: side * size * 0.20, y: -size * 0.34)
                }
            case .tuft:
                ForEach([-1.0, 1.0], id: \.self) { side in
                    Triangle()
                        .fill(kind.fur)
                        .frame(width: size * 0.16, height: size * 0.18)
                        .offset(x: side * size * 0.18, y: -size * 0.32)
                }
            case .tiny:
                ForEach([-1.0, 1.0], id: \.self) { side in
                    Circle()
                        .fill(kind.fur)
                        .frame(width: size * 0.11, height: size * 0.11)
                        .offset(x: side * size * 0.19, y: -size * 0.28)
                }
            }
        }
    }

    private var tail: some View {
        Circle()
            .fill(kind.belly)
            .frame(width: size * 0.22, height: size * 0.22)
            .offset(x: size * 0.30, y: size * 0.26)
    }

    private var face: some View {
        ZStack {
            if isSleeping {
                ForEach([-1.0, 1.0], id: \.self) { side in
                    Capsule()
                        .fill(Color(hex: 0x3B2A20).opacity(0.8))
                        .frame(width: size * 0.10, height: size * 0.022)
                        .offset(x: side * size * 0.11, y: -size * 0.13)
                }
            } else {
                ForEach([-1.0, 1.0], id: \.self) { side in
                    ZStack {
                        Ellipse()
                            .fill(Color(hex: 0x2C2118))
                            .frame(width: size * (isBlinking ? 0.02 : 0.075),
                                   height: size * (isBlinking ? 0.02 : 0.085))
                        Circle()
                            .fill(.white)
                            .frame(width: size * 0.026, height: size * 0.026)
                            .offset(x: -size * 0.014, y: -size * 0.018)
                            .opacity(isBlinking ? 0 : 1)
                    }
                    .offset(x: side * size * 0.11, y: -size * 0.13)
                }
            }

            // 口鼻
            Ellipse()
                .fill(kind.belly)
                .frame(width: size * 0.18, height: size * 0.12)
                .offset(y: -size * 0.02)

            Ellipse()
                .fill(Color(hex: 0x6B4A38))
                .frame(width: size * 0.055, height: size * 0.038)
                .offset(y: -size * 0.04)

            // 腮红
            ForEach([-1.0, 1.0], id: \.self) { side in
                Circle()
                    .fill(Color(hex: 0xFF9AA2).opacity(isSleeping ? 0.25 : 0.45))
                    .frame(width: size * 0.09, height: size * 0.06)
                    .offset(x: side * size * 0.19, y: -size * 0.05)
            }
        }
        .offset(y: -size * 0.06)
    }
}

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
    @State private var opacity: Double = 0.2

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
