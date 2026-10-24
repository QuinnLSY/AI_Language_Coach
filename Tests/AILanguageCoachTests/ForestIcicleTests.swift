import CoreGraphics
@testable import AppUI
import XCTest

/// 枝下沿的冰柱（#628）的布局纯函数。
///
/// 每条判据配一句「反证」——把实现换回错写法，断言必须红在**这一条**上。
final class ForestIcicleTests: XCTestCase {

    private let crown = CGSize(width: 380, height: 300)

    /// 一棵标准树冠的全部枝（9 主枝 → 360 根，跨四层）。
    private var allLimbs: [LimbSpec] {
        CanopyLayout.bands(in: crown).limbs.flatMap { $0 }
    }

    /// 挂了冰柱的枝（够粗的那些）。
    private var icyLimbs: [(limb: LimbSpec, icicles: [ForestIcicle])] {
        allLimbs.compactMap { limb in
            let icicles = IcicleLayout.icicles(
                limb, seed: IcicleLayout.seed(of: limb), size: crown)
            return icicles.isEmpty ? nil : (limb, icicles)
        }
    }

    // MARK: - 站位

    /// 冰柱挂在枝的**下沿**：挂点必须在枝中心的下方（y 更大）。
    ///
    /// 反证：把 `anchor` 里的 `down` 取反（挂到上沿 = 雪线那一侧）→ 红。
    func testIciclesHangBelowTheBranch() {
        XCTAssertFalse(icyLimbs.isEmpty, "一根冰柱都没有（门槛太高了）")
        for entry in icyLimbs {
            for icicle in entry.icicles {
                let base = entry.limb.point(at: CGFloat(icicle.t))
                let anchor = IcicleLayout.anchor(icicle, on: entry.limb)
                XCTAssertGreaterThanOrEqual(
                    anchor.y, base.y - 0.001,
                    "冰柱挂到枝的上面去了（那是雪待的地方）")
                XCTAssertGreaterThan(
                    icicle.drop, 0, "挂点没探出枝面 —— 冰柱长在枝肚子里")
            }
        }
    }

    /// 冰柱只挂枝的**中段**（与枝上雪线同一段）：枝根太粗、枝梢太细。
    ///
    /// 反证：把 `spanTo` 改成 1.0（挂到枝梢）→ 红。
    func testIciclesSitOnTheBranchSpan() {
        for entry in icyLimbs {
            for icicle in entry.icicles {
                XCTAssertGreaterThanOrEqual(
                    icicle.t, IcicleLayout.spanFrom - 0.001, "冰柱挂到枝根上去了")
                XCTAssertLessThanOrEqual(
                    icicle.t, IcicleLayout.spanTo + 0.001, "冰柱挂到枝梢上去了")
            }
        }
    }

    /// 细梢不挂冰柱：360 根枝里绝大多数是末端细梢，全挂就是「一树糖丝」。
    ///
    /// 反证：把 `widthFloor` 改成 0（什么都挂）→ 红在第一条。
    func testThinTwigsHoldNoIcicles() {
        let withIcicles = Set(icyLimbs.map { ObjectIdentifier($0.limb as AnyObject) })
        XCTAssertLessThan(icyLimbs.count, allLimbs.count / 3,
                          "几乎每根枝都挂了冰柱 —— 糖丝挂满了")
        XCTAssertGreaterThan(icyLimbs.count, 3, "冰柱太少，读不出「挂了冰」")
        // 逐根核：细枝的返回必须是空
        for limb in allLimbs {
            let icicles = IcicleLayout.icicles(
                limb, seed: IcicleLayout.seed(of: limb), size: crown)
            let thickest = max(
                limb.width(at: CGFloat(IcicleLayout.spanFrom)),
                limb.width(at: CGFloat(IcicleLayout.spanTo)))
            if thickest <= crown.width * IcicleLayout.widthFloor {
                XCTAssertTrue(icicles.isEmpty, "一根细梢挂了冰柱")
            }
        }
        XCTAssertFalse(withIcicles.isEmpty)
    }

    // MARK: - 个头

    /// 冰柱的长度落在「一根冰柱」这个区间里：不是一条白线，也不是半根树枝。
    ///
    /// 判据是**视觉区间**（相对冠高的 2%…8%），不镜像 `lengthRatio` 的算式 ——
    /// 镜像了就等于没判（实现改多少都跟着飘）。
    ///
    /// 反证：把 `lengthRatio` 改成 0.4 → 红在第二条。
    func testIcicleLengthReadsAsAnIcicle() {
        for entry in icyLimbs {
            for icicle in entry.icicles {
                XCTAssertGreaterThan(icicle.length, crown.height * 0.02,
                                     "冰柱太短，读成一道白痕")
                XCTAssertLessThan(icicle.length, crown.height * 0.08,
                                  "冰柱太长，读成一根冰树枝")
                XCTAssertEqual(icicle.width, icicle.length * IcicleLayout.widthRatio,
                               accuracy: 1e-9, "冰柱的宽不是按长算的")
                XCTAssertLessThan(icicle.width, 5, "冰柱太粗，读成一滴白蜡")
            }
        }
    }

    /// 冰柱的倾角是「歪一点」而不是「横躺」：水顺着枝沿流下来。
    ///
    /// 反证：把 `tiltRange` 改成 -85...85 → 红在第二条。
    func testIcicleTiltIsAGentleLean() {
        for entry in icyLimbs {
            for icicle in entry.icicles {
                XCTAssertGreaterThanOrEqual(icicle.tilt, IcicleLayout.tiltRange.lowerBound - 0.001)
                XCTAssertLessThanOrEqual(icicle.tilt, IcicleLayout.tiltRange.upperBound + 0.001)
                XCTAssertLessThan(abs(icicle.tilt), 30, "冰柱横躺了（水不会横着流）")
            }
        }
    }

    // MARK: - 确定性

    /// 同种子同结果（重绘不许换一批冰柱）。
    func testLayoutIsDeterministic() {
        for limb in allLimbs {
            let first = IcicleLayout.icicles(
                limb, seed: IcicleLayout.seed(of: limb), size: crown)
            let second = IcicleLayout.icicles(
                limb, seed: IcicleLayout.seed(of: limb), size: crown)
            XCTAssertEqual(first, second, "同一根枝出了两批冰柱")
        }
    }

    /// 种子由枝的几何混出来，**不许走 `hashValue`**：Swift 的 `Hasher`
    /// 每次进程随机加盐，跨启动会换一批冰柱（用户看到「冰柱在抖」）。
    ///
    /// ⚠️ 先剔注释行再判：`seed(of:)` 的文档注释里就写着「不许用 hashValue」，
    /// 连注释一起数会被自己的话毙掉（假绿）。
    ///
    /// 反证：把 `seed(of:)` 改成 `UInt64(abs(limb.from.x.hashValue))` → 红。
    func testTheSeedDoesNotRelyOnHashValue() throws {
        let raw = try String(
            contentsOfFile: "Sources/AppUI/Components/ForestIcicles.swift", encoding: .utf8)
        let code = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertFalse(code.contains("hashValue"),
                       "种子走了 hashValue —— 跨启动会换一批冰柱")
        XCTAssertTrue(code.contains("truncatingIfNeeded"),
                      "种子没走位模式混制（换实现要连这条一起看）")
    }
}
