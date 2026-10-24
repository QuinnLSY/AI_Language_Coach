import SwiftUI

// MARK: - 冬：枝下沿的冰柱（#628）

/// 一根冰柱：挂在枝**下沿**的一根水冰锥。
///
/// 坐标与 `LimbSpec` **同一套**（画框像素）—— 冰柱是「这根枝的下沿」派生出来的，
/// 不是另排一张表：枝挪了、冰柱跟着挪，不可能对不上。
struct ForestIcicle: Identifiable, Equatable, Sendable {

    let id: Int
    /// 挂点在枝上的位置（0…1，`LimbSpec.point(at:)` 的参数）。
    let t: Double
    /// 挂点往下沿探出多少（pt）：冰柱挂在枝的**下沿**，不在枝中心。
    let drop: Double
    /// 长 / 宽（pt）。
    let length: Double
    let width: Double
    /// 倾角（度）：水是顺着枝沿流下来的，冰柱很少垂直。
    let tilt: Double
}

/// 冰柱的布局（纯函数 / 确定性，可单测）。
///
/// 与 `SnowCoverLayout.limbSnow` 是**一对**：雪积在枝的上表面，冰柱挂在枝的下沿 ——
/// 同一根枝的上下两侧，共用「挂哪一段」这组常数（改一处不会只改半边）。
enum IcicleLayout {

    /// 每根够粗的枝上挂几根。
    static let perLimb = 2

    /// 只挂枝的哪一段（沿枝比例，与枝上雪线同一段）：枝根太粗（那儿化不了水），
    /// 枝梢太细（挂不住）。
    static let spanFrom: Double = 0.18
    static let spanTo: Double = 0.66

    /// 冰柱长度 = 冠框高 × 这个系数（× 各自的抖动）。
    ///
    /// ⚠️ 不按枝粗定长：枝粗只决定**挂不挂**与**多宽**。按枝粗定长的话，
    /// 主枝上的冰柱会有小半个冠框长（实测第一版的算法），细梢上的又只有 2pt。
    static let lengthRatio: Double = 0.048
    static let lengthJitter: ClosedRange<Double> = 0.55...1.45

    /// 冰柱宽度 = 长度 × 这个系数（上粗下尖）。
    ///
    /// 0.17：真冰柱是 1:6 上下的锥。放到 0.24 时圆滚滚一团，
    /// 读成「枝上挂了几滴白蜡」（实测）。
    static let widthRatio: Double = 0.17

    /// 冰柱探出枝下沿多少（相对枝在该处的粗细）：挂在**下沿**，不是枝中心。
    static let dropRatio: Double = 0.42

    /// 倾角范围（度）。
    static let tiltRange: ClosedRange<Double> = -14...14

    /// 枝细到这个程度（相对冠宽）就不挂冰柱：枝梢比一根头发还细，
    /// 挂上去只会读出「枝上沾了糖丝」。360 根枝里绝大多数是这种细梢 ——
    /// 也是这个门槛让全冠的冰柱数维持在「几根」而不是「几百根」。
    ///
    /// 0.034：只留 9 根主枝 + 最粗的几根一级枝。放到 0.030 时一级枝也挂，
    /// 满冠都是白锥，反倒读不出「挂」这件事（实测）。
    static let widthFloor: Double = 0.034

    /// 这根枝上该有哪些冰柱。
    ///
    /// - `seed`：由枝的几何混出来（见 `seed(of:)`）—— 同一根枝永远同一批冰柱。
    /// - `size`：冠框尺寸（冰柱长度与粗细门槛都按它折算，树面板缩放时整体等比）。
    static func icicles(_ limb: LimbSpec, seed: UInt64, size: CGSize) -> [ForestIcicle] {
        guard size.width > 0, size.height > 0, perLimb >= 1 else { return [] }
        let floor = size.width * widthFloor
        // 先看这段里最粗的地方够不够格：整段都细的枝不挂
        var rng = SeededRandom(seed: seed)
        var result: [ForestIcicle] = []
        result.reserveCapacity(perLimb)
        for index in 0..<perLimb {
            let step = Double(perLimb - 1) == 0 ? 0.5
                : Double(index) / Double(perLimb - 1)
            let t = spanFrom + (spanTo - spanFrom) * step
                + (rng.next() - 0.5) * 0.06
            let clamped = min(max(t, spanFrom), spanTo)
            let thickness = Double(limb.width(at: CGFloat(clamped)))
            guard thickness > floor else { continue }
            let length = size.height * lengthRatio * rng.next(in: lengthJitter)
            result.append(ForestIcicle(
                id: index,
                t: clamped,
                drop: thickness * dropRatio,
                length: length,
                width: length * widthRatio,
                tilt: rng.next(in: tiltRange)
            ))
        }
        return result
    }

    /// 一根冰柱的挂点（画框坐标）：枝上 `t` 处，往下沿探 `drop`。
    static func anchor(_ icicle: ForestIcicle, on limb: LimbSpec) -> CGPoint {
        let base = limb.point(at: CGFloat(icicle.t))
        let normal = limb.normal(at: CGFloat(icicle.t))
        // 取「朝下」的那一侧（y 更大）：冰柱挂在枝的下沿（雪线在另一侧）
        let down = normal.dy >= 0 ? normal : CGVector(dx: -normal.dx, dy: -normal.dy)
        return CGPoint(
            x: base.x + down.dx * CGFloat(icicle.drop),
            y: base.y + down.dy * CGFloat(icicle.drop)
        )
    }

    /// 由枝的几何混一个种子出来（同一根枝永远同一批冰柱）。
    ///
    /// ⚠️ 不许用 `hashValue`：Swift 的 `Hasher` 每次进程随机加盐，
    /// 同一根枝跨启动会换一批冰柱（用户看到「冰柱在抖」）。
    static func seed(of limb: LimbSpec) -> UInt64 {
        var hash: UInt64 = 0x4943_4C45   // "ICLE"
        for value in [limb.from.x, limb.from.y, limb.control.x, limb.control.y,
                      limb.to.x, limb.to.y, limb.rootWidth, limb.tipWidth] {
            hash = hash &* 1_000_000_007 &+ UInt64(truncatingIfNeeded: value.bitPattern)
        }
        return hash
    }
}

// MARK: - 画法

/// 枝下沿的冰柱：一根根上粗下尖的水冰锥。
///
/// ⚠️ 与 `LimbSnow` 画在同一处（同一层 `WindSway` 里）：雪在枝上、冰在枝下，
/// 是同一根枝的上下两侧。分开挂层就会「枝动了、冰钉在半空」。
///
/// ⚠️ 裁边与枝干同一条（整冠轮廓）：冰柱从枝沿往下探，探出冠外的部分要留住 ——
/// 冰柱挂在枝的下沿，正该探到叶团外面、衬在天空前。所以这里**不套**叶团遮罩，
/// 只裁在地面带/树冠画框内（由调用方的 frame 收口）。
struct LimbIcicles: View {

    let theme: ForestTheme
    let limbs: [LimbSpec]
    let size: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(limbs.enumerated()), id: \.offset) { _, limb in
                let icicles = IcicleLayout.icicles(
                    limb, seed: IcicleLayout.seed(of: limb), size: size)
                ForEach(icicles) { icicle in
                    let anchor = IcicleLayout.anchor(icicle, on: limb)
                    IcicleFigure(
                        theme: theme,
                        width: icicle.width,
                        length: icicle.length
                    )
                    .rotationEffect(.degrees(icicle.tilt), anchor: .top)
                    .position(x: anchor.x, y: anchor.y + icicle.length / 2)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// 一根冰柱：暗底探出一圈当厚度，本体盖上，左侧一道高光。
private struct IcicleFigure: View {

    let theme: ForestTheme
    let width: CGFloat
    let length: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 暗底：比本体宽一圈 —— 冰有厚度，一色白就是片纸
            IcicleShape()
                .fill(theme.icicleShade)
                .frame(width: width * 1.22, height: length * 1.05)
                .offset(x: width * 0.08, y: 0)
            IcicleShape()
                .fill(theme.icicleBody)
                .frame(width: width, height: length)
            // 高光：左侧一道（冰面反光总在一侧）
            IcicleShape()
                .fill(theme.icicleGlint.opacity(0.85))
                .frame(width: width * 0.30, height: length * 0.80)
        }
        .frame(width: width, height: length, alignment: .topLeading)
    }
}

/// 一根冰柱的剪影：顶端贴枝（略圆），两侧收拢，底端收成一点。
private struct IcicleShape: Shape {

    func path(in rect: CGRect) -> Path {
        guard rect.width > 1, rect.height > 1 else { return Path() }
        var path = Path()
        let w = rect.width
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // 左侧：从中段开始往里收，底端收成一点
        path.addQuadCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control: CGPoint(x: rect.minX + w * 0.10, y: rect.maxY)
        )
        // 右侧：对称收回来
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - w * 0.10, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }
}
