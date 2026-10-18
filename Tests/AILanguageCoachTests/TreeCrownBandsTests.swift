import AppKit
@testable import AppUI
import XCTest

/// 树冠几何的两组判据（用户 2026-10-18 两项报障）：
///
/// ① **下宽上窄 + 范围变大**：`envelope` 展幅包络、冠底半幅 > 冠顶半幅、
///    包围盒吃满画框（「树冠的范围可以再大三分之一……形成如真实大树
///    树冠下宽上窄的形态」）；
/// ② **风分层不丢内容**：`bands(in:)` 把叶团 / 碎叶 / 枝干分到四层，
///    三份内容必须与全量一一对应（少一团 = 那团在风里凭空消失），
///    且每根枝整根归一层（按中点归层，劈成两半会在接缝留一道硬折）。
///
/// 另外钉住 `leafMarks` 与 `clusters` **共用同一个帧**（`crownFrame`）：
/// 2026-10-18 之前 `leafMarks` 里还残留一枚被删掉的 `crownScale`，
/// 编译不过 —— 这类「四处各算一套帧」的事故，用「碎叶明暗跟着位置走」
/// 这条不变式来守。
@MainActor
final class TreeCrownBandsTests: XCTestCase {

    /// 树面板默认宽（`MainView.treePanelWidth` 初值）× 冠高。
    private let frame = CGSize(width: 380, height: 300)

    // MARK: - 工具

    /// 两个多重集必须相同（ Equatable 逐个配对，防「数量对但内容错」）。
    private func assertSameMultiset<T: Equatable>(
        _ lhs: [T], _ rhs: [T], _ message: String
    ) {
        XCTAssertEqual(lhs.count, rhs.count, "\(message)：数量不一致")
        var remaining = rhs
        for element in lhs {
            guard let index = remaining.firstIndex(of: element) else {
                XCTFail("\(message)：多出一个不该存在的元素")
                return
            }
            remaining.remove(at: index)
        }
    }

    // MARK: - ② 分层不丢内容（纯函数）

    func testBandsPartitionEveryPieceOfContent() {
        let bands = CanopyLayout.bands(in: frame)
        XCTAssertEqual(bands.clusters.count, CanopyLayout.bandCount)
        XCTAssertEqual(bands.marks.count, CanopyLayout.bandCount)
        XCTAssertEqual(bands.limbs.count, CanopyLayout.bandCount)

        assertSameMultiset(bands.clusters.flatMap { $0 }, CanopyLayout.clusters(in: frame),
                           "叶团分层后与全量不一致")
        assertSameMultiset(bands.marks.flatMap { $0 }, CanopyLayout.leafMarks(in: frame),
                           "碎叶分层后与全量不一致")
        assertSameMultiset(bands.limbs.flatMap { $0 }, CanopyLayout.limbs(in: frame),
                           "枝干分层后与全量不一致")
    }

    /// 每根枝**整根**只出现在一层：按中点归层，接缝处才不会一道硬折。
    func testEveryLimbLandsInExactlyOneBand() {
        let bands = CanopyLayout.bands(in: frame)
        let banded = bands.limbs.flatMap { $0 }
        for limb in CanopyLayout.limbs(in: frame) {
            let hits = bands.limbs.filter { $0.contains(limb) }.count
            XCTAssertEqual(hits, 1, "一根枝出现了 \(hits) 次（跨层 = 被劈成两半）")
        }
        XCTAssertEqual(banded.count, CanopyLayout.limbs(in: frame).count)
    }

    /// 层号自上而下递增、且钳在 [0, bandCount−1]（出界层 = 内容丢到虚空）。
    func testBandIndexIsClampedAndMonotonic() {
        XCTAssertEqual(CanopyLayout.bandIndex(atY: 0, in: frame), 0)
        XCTAssertEqual(CanopyLayout.bandIndex(atY: frame.height - 0.001, in: frame),
                       CanopyLayout.bandCount - 1)
        XCTAssertEqual(CanopyLayout.bandIndex(atY: -50, in: frame), 0, "负 y 钳到顶层")
        XCTAssertEqual(CanopyLayout.bandIndex(atY: frame.height + 50, in: frame),
                       CanopyLayout.bandCount - 1, "越界 y 钳到底层")
        var previous = -1
        var y: CGFloat = 0
        while y <= frame.height {
            let index = CanopyLayout.bandIndex(atY: y, in: frame)
            XCTAssertGreaterThanOrEqual(index, previous, "层号必须随 y 单调不减")
            previous = index
            y += 1
        }
    }

    // MARK: - ① 下宽上窄（纯函数）

    /// 展幅包络：朝下 ×(1+flare)、朝上 ×(1−flare)、左右不变，越界钳住。
    func testEnvelopeFlareIsSymmetricAndClamped() {
        let flare = CanopyLayout.flare
        XCTAssertEqual(CanopyLayout.envelope(0), 1, accuracy: 1e-6, "正左右不扩")
        XCTAssertEqual(CanopyLayout.envelope(1), 1 + flare, accuracy: 1e-6)
        XCTAssertEqual(CanopyLayout.envelope(-1), 1 - flare, accuracy: 1e-6)
        XCTAssertEqual(CanopyLayout.envelope(9), 1 + flare, accuracy: 1e-6, "钳住：越界不许无限外扩")
        XCTAssertEqual(CanopyLayout.envelope(-9), 1 - flare, accuracy: 1e-6)
        XCTAssertGreaterThan(flare, 0.1, "flare 太小就读不出下宽上窄")
        XCTAssertLessThan(flare, 0.5, "flare 太大顶部收成锥、冠腰被挤出画框")
    }

    /// **下宽上窄**：肩部（最宽处，在冠心偏下）的半幅必须明显大于顶部带的半幅。
    ///
    /// ⚠️ 分割线不能取包围盒中线：下宽上窄的冠**最宽点在冠心下方**，
    /// 中线分割会把肩部那簇算进「上半」，两边几乎一样宽（实测 186.7 vs 178.3，
    /// 比例只有 1.05）—— 那是判据选错了，不是冠形不对。
    /// 正确的比法：顶部带（上 22%）vs 肩部带（48%…86%）。
    func testBottomHalfIsWiderThanTopHalf() {
        let clusters = CanopyLayout.clusters(in: frame)
        let bounds = CanopyLayout.silhouetteBounds(in: frame)
        func halfWidth(of group: [LeafCluster]) -> CGFloat {
            group.map { abs($0.center.x - bounds.midX) + $0.radii.width }.max() ?? 0
        }
        let topBand = clusters.filter { $0.center.y < frame.height * 0.22 }
        let shoulderBand = clusters.filter {
            $0.center.y >= frame.height * 0.48 && $0.center.y <= frame.height * 0.86
        }
        XCTAssertFalse(topBand.isEmpty, "顶部带没有叶团")
        XCTAssertFalse(shoulderBand.isEmpty, "肩部带没有叶团")
        XCTAssertGreaterThan(halfWidth(of: shoulderBand), halfWidth(of: topBand) * 1.15,
                             "肩部半幅 \(halfWidth(of: shoulderBand)) 未明显大于顶部 \(halfWidth(of: topBand))")
    }

    /// 包围盒吃满画框：纵向跨幅 ≥ 85%（「范围再大三分之一」在画框内的兑现方式 ——
    /// 横向上不出去，盖住聊天区是硬禁），冠底探到 90% 以下（裙摆扎进树干中段）。
    func testCrownFillsItsFrame() {
        let bounds = CanopyLayout.silhouetteBounds(in: frame)
        XCTAssertGreaterThanOrEqual(bounds.height / frame.height, 0.85,
                                    "纵向跨幅只有 \(bounds.height / frame.height)")
        XCTAssertGreaterThanOrEqual(bounds.maxY / frame.height, 0.90,
                                    "冠底只到 \(bounds.maxY / frame.height)，裙摆没扎下去")
        XCTAssertGreaterThanOrEqual(bounds.width / frame.width, 0.85,
                                    "横向跨幅只有 \(bounds.width / frame.width)")
        XCTAssertLessThanOrEqual(bounds.width / frame.width, 0.97,
                                 "横向太满：风摆与茂密度缩放会把叶子推出面板")
    }

    /// 剪影不许出框（含碎叶外凸的那一截）：离屏渲染测试只算叶团并集，
    /// 碎叶刻意压在叶缘上（1.14 × 团半径），比 `maxLobeFactor` 还外一截。
    func testPaintedCrownStaysInsideFrameIncludingMarks() {
        let bounds = CanopyLayout.silhouetteBounds(in: frame)
        var minX = bounds.minX, maxX = bounds.maxX, minY = bounds.minY, maxY = bounds.maxY
        for mark in CanopyLayout.leafMarks(in: frame) {
            minX = min(minX, mark.center.x - mark.size.width * 0.5)
            maxX = max(maxX, mark.center.x + mark.size.width * 0.5)
            minY = min(minY, mark.center.y - mark.size.height * 0.5)
            maxY = max(maxY, mark.center.y + mark.size.height * 0.5)
        }
        XCTAssertGreaterThanOrEqual(minX, -2, "含碎叶的左边出框 \(minX)pt")
        XCTAssertLessThanOrEqual(maxX, frame.width + 2, "含碎叶的右边出框 \(maxX - frame.width)pt")
        XCTAssertGreaterThanOrEqual(minY, -2, "含碎叶的顶部出框 \(minY)pt")
        XCTAssertLessThanOrEqual(maxY, frame.height + 6, "含碎叶的底部出框 \(maxY - frame.height)pt")
    }

    /// 涂色范围**近似对称 + 受控微差**（不再严格相等）。
    ///
    /// 2026-10-18 实测：整环基相（`ringIndex·0.37`）让叶团系统性贴近 180°、
    /// 远离 0°，左肩比右肩外凸 ~19pt，整冠读作「往左歪」。修法是
    /// `clusters(in:)` 里**镜像成对**（θ → π−θ，抖动与种子按对共享）。
    ///
    /// 但严格镜像读作「复制粘贴的另一半」（用户 2026-10-18：「树冠不用
    /// 完全对称，左右稍微有一点区别」）→ 镜像侧加了受控微偏置
    /// `mirrorBias`（0.02 rad ≈ 2.3pt）。于是判据从「严格相等」换成
    /// **差值区间**：≤4pt 是受控微差，>4pt 就是 v6 那种系统性偏斜
    /// （19pt）回来了；同时差值必须 >0.5pt —— 归零说明微偏置被删，
    /// 又变回机械复制。
    ///
    /// 反证：mirrorBias ×5（0.02→0.10）→ 差 ~11pt → 红在超上限；
    /// mirrorBias 归 0 → 差 ~0 → 红在下限；自镜像相位改回整环基相 → 红。
    func testPaintedCrownStaysNearSymmetricWithControlledAsymmetry() {
        var minX = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        for cluster in CanopyLayout.clusters(in: frame) {
            minX = min(minX, cluster.center.x - cluster.radii.width * CanopyLayout.maxLobeFactor)
            maxX = max(maxX, cluster.center.x + cluster.radii.width * CanopyLayout.maxLobeFactor)
        }
        for mark in CanopyLayout.leafMarks(in: frame) {
            minX = min(minX, mark.center.x - mark.size.width * 0.5)
            maxX = max(maxX, mark.center.x + mark.size.width * 0.5)
        }
        let (_, _, center) = CanopyLayout.crownFrame(in: frame)
        let left = center.x - minX
        let right = maxX - center.x
        let skew = abs(left - right)
        XCTAssertLessThanOrEqual(skew, 4,
                                 "左右差 \(skew)pt —— 超出受控微差，读作往一侧歪（v6 教训：19pt 系统性偏斜）")
        XCTAssertGreaterThan(skew, 0.5,
                             "左右差 \(skew)pt ≈ 0 —— 微偏置没了，整冠又变机械复制（用户要「稍微有一点区别」）")
    }

    /// 枝尖必须**全部落在下 2/3，且没有一根被钳断**（用户 2026-10-18
    /// 两轮报障：「树枝要保持在下三分之二区域，现在太靠上，像被截断了
    /// 一样」「树枝的尖端分叉要画出来，树枝整体再往下移一点」）。
    ///
    /// 钉 `to` 与 `control` 两点：二次贝塞尔的 y 极值必在 from/control/to
    /// 三点里，to 与 control 都过线，整条曲线才整体过线。
    ///
    /// 「没有一根被钳断」由**严格大于**（`> minTopY + 0.01`）守：钳断的枝
    /// 会被按角度缩短到**恰好贴线**（`to.y == minTopY`），而自然收短的枝
    /// 都留有几 pt 余量。v6 的齐平钳断就是「五根主枝的尖全停在同一个 y」，
    /// taper 还停在母枝粗档 —— 读作被剪断。长度参数现在按垂直预算倒算
    /// （越陡越短），钳制只是兜底。
    ///
    /// 反证：primaries 长度回 v6 值（0.94/0.74/0.86/0.84/0.72）→ 主枝自然
    /// 探进上 1/3 被钳到恰好贴线 → 红。
    func testLimbTipsStayInTheLowerTwoThirds() {
        let minTopY = frame.height / 3
        let limbs = CanopyLayout.limbs(in: frame)
        XCTAssertFalse(limbs.isEmpty, "没有枝干 = 树冠挂在空气上")
        for limb in limbs {
            XCTAssertGreaterThan(limb.to.y, minTopY + 0.01,
                                 "枝顶贴线/探进上 1/3（y=\(limb.to.y)，线在 \(minTopY)）→ 被钳断的钝头")
            XCTAssertGreaterThan(limb.control.y, minTopY + 0.01,
                                 "枝腹贴线/鼓进上 1/3（y=\(limb.control.y)，线在 \(minTopY)）")
        }
    }

    /// 枝尖必须**分叉**：末端枝在 tip 前分出一簇细梢（用户 2026-10-18
    /// 第二轮：「树枝的尖端分叉要画出来」，截图四个红圈全是光秃秃的钝头；
    /// 第三轮：「树枝多画几个，末端有分叉……不符合参天大树的形象」）。
    ///
    /// 量化两根轴：① 枝总数 —— 9 主枝 × 三岔 × 三岔 × 三细梢 = 360；
    /// ② 存在足够多的**细梢**（rootWidth < 5pt）—— 末端叉的宽度是母枝的
    /// 0.34，主枝系下来的叉约 3.6pt，正好落在「看得见又不成一级枝」的区间。
    ///
    /// 反证：primaries 的 depth 2→1（末端层级少一级）→ 枝数回 117、
    /// 细梢回 81 → 红。
    func testLimbTipsForkIntoFineTwigs() {
        let limbs = CanopyLayout.limbs(in: frame)
        XCTAssertGreaterThanOrEqual(limbs.count, 250,
                                    "枝只有 \(limbs.count) 根 → 末端分叉没画出来 / 枝数不够参天大树的密度")
        let twigs = limbs.filter { $0.rootWidth < 5 }
        XCTAssertGreaterThanOrEqual(twigs.count, 150,
                                    "细梢只有 \(twigs.count) 根 → 枝尖是光秃秃的钝头，没有分叉")
    }

    /// 枝根必须埋在冠心下方足够深（用户 2026-10-18 第二轮「树枝整体再
    /// 往下移一点」→ 第四轮「上下延展宽一点，上下空间扩展为现在的两倍」）。
    /// origin 从冠心下方 0.34 半高一路挪到 0.75 —— 主枝从树干低段发出，
    /// 垂直跨度 ~104pt（原来 ~52pt）。
    ///
    /// 枝根 = 九根主枝共用的 `from`，即所有枝里 `from.y` 的**最大值**
    /// （子枝的 from 是母枝上的锚点，一定比 origin 高）。
    ///
    /// 反证：`limbs(in:)` 里 origin 的 0.75 回 0.40 → 枝根回到冠心下方
    /// 60pt < 0.70 半高的 105pt → 红。
    func testLimbRootsSitBelowTheCrownCentre() {
        let limbs = CanopyLayout.limbs(in: frame)
        let (_, _, center) = CanopyLayout.crownFrame(in: frame)
        let rootY = limbs.map(\.from.y).max() ?? 0
        let floor = center.y + 0.70 * frame.height * 0.5
        XCTAssertGreaterThanOrEqual(rootY, floor,
                                    "枝根（y=\(rootY)）没埋在冠心下方 0.70 半高（\(floor)）以下 → 枝干上下没延展开")
    }

    /// 枝干**垂直跨度**必须达到原来的两倍（用户 2026-10-18 第四轮原话：
    /// 「树枝的上下延展宽一点，上下空间扩展为现在的两倍」）。
    ///
    /// 跨度 = 枝根（origin，`from.y` 最大值）− 最高枝尖（`to.y` 最小值）。
    /// 第二、三轮跨度 ~52pt（origin 162、枝顶 ~110）；第四轮 origin 降到
    /// 0.75 半高（y≈214）后 ~99pt ≈ 1.9 倍。阈值取 90pt（1.75 倍）
    /// 给参数抖动留余量。
    ///
    /// 反证：origin 回 0.40 半高 → 跨度回 ~47pt → 红。
    func testLimbSpanReachesTwiceTheHeight() {
        let limbs = CanopyLayout.limbs(in: frame)
        let rootY = limbs.map(\.from.y).max() ?? 0
        let tipY = limbs.map(\.to.y).min() ?? 0
        let span = rootY - tipY
        XCTAssertGreaterThanOrEqual(span, 90,
                                    "枝干垂直跨度只有 \(span)pt（枝根 \(rootY)、枝尖 \(tipY)）→ 上下没延展开（要 ~104pt）")
    }

    /// 主枝必须**九根**（用户 2026-10-18 第三轮原话：「改成主枝 9 根」——
    /// 「树枝多画几个，末端有分叉，现在太少了，不符合参天大树的形象」）。
    ///
    /// 主枝的量化：`rootWidth ≥ 26pt`。主枝宽度系数 0.070…0.104 × 画框宽
    /// 380 = 26.6…39.5pt；二级枝是母枝的 0.52 = 13.8…20.5pt —— 两档之间
    /// 有空档，九根主枝一根不漏、二级枝一根不混。
    ///
    /// 反证：primaries 删掉两根副枝（±80° 那两根）→ 7 → 红。
    func testNinePrimaryBranchesCarryTheCrown() {
        let primaries = CanopyLayout.limbs(in: frame).filter { $0.rootWidth >= 26 }
        XCTAssertEqual(primaries.count, 9,
                       "主枝 \(primaries.count) 根 ≠ 9 → 树冠骨架不是参天大树的密度")
    }

    /// 九根主枝必须呈**扇形：中间最长、两边最短**（用户 2026-10-18 第四轮
    /// 原话：「九根树枝中间的长，两边的短，成一个扇形分布，延伸方向各不相同」）。
    ///
    /// 量化：主枝按 from→to 直线长排序，最长的必须落在**中央**
    /// （|to.x − 冠心.x| < 30pt），最短的必须落在**最外侧**（> 55pt）。
    /// 中央挑高、两侧递减 = 扇形；反过来（边长边短）整棵枝干读作
    /// 「两侧张牙舞爪、中央塌陷」—— 第三轮的「边长边短」表就是这么翻车的。
    ///
    /// 反证：primaries 换回「边长边短」表（中央 0.32、两侧 1.00+）→
    /// 最长的是 ±60° 平枝（offset > 55）→ 红。
    func testPrimaryBranchesFanOutLongestInTheMiddle() {
        let limbs = CanopyLayout.limbs(in: frame)
        let (_, _, center) = CanopyLayout.crownFrame(in: frame)
        let primaries = limbs.filter { $0.rootWidth >= 26 }
        XCTAssertEqual(primaries.count, 9, "主枝不是 9 根，扇形判据失去对象")
        let measured = primaries.map { limb -> (offset: CGFloat, len: CGFloat) in
            let dx = limb.to.x - center.x
            let dy = limb.to.y - limb.from.y
            return (abs(dx), hypot(dx, dy))
        }
        guard let longest = measured.max(by: { $0.len < $1.len }),
              let shortest = measured.min(by: { $0.len < $1.len }) else {
            XCTFail("主枝测量失败")
            return
        }
        XCTAssertLessThan(longest.offset, 30,
                          "最长的枝偏在边上（offset \(longest.offset)pt）→ 不是扇形（要中间长两边短）")
        XCTAssertGreaterThan(shortest.offset, 55,
                            "最短的枝不在最外侧（offset \(shortest.offset)pt）→ 不是扇形")
    }

    // MARK: - 共用同一处帧

    /// 碎叶的明暗跟着**位置**走（冠顶亮、冠底沉）—— 这条不变式守的是
    /// `leafMarks` 与 `clusters` 共用 `crownFrame`：各算一套帧时，
    /// 位置对但 `vertical` 错，整层碎叶的明暗会整体跑位。
    func testLeafMarkToneFollowsPositionNotClusterTone() {
        let marks = CanopyLayout.leafMarks(in: frame)
        let midY = CanopyLayout.silhouetteBounds(in: frame).midY
        let upper = marks.filter { $0.center.y < midY }
        let lower = marks.filter { $0.center.y >= midY }
        XCTAssertFalse(upper.isEmpty && lower.isEmpty)
        let meanUpper = upper.map(\.tone).reduce(0, +) / Double(max(upper.count, 1))
        let meanLower = lower.map(\.tone).reduce(0, +) / Double(max(lower.count, 1))
        XCTAssertGreaterThan(meanUpper, meanLower + 0.05,
                             "冠顶碎叶（\(meanUpper)）未明显亮于冠底（\(meanLower)）")
    }

    // MARK: - 风增益的层次（纯函数）

    /// 顶轻底重：冠顶是自由端摆得最多，裙摆兜住的叶子最多、几乎不动。
    func testBandWindGainDecreasesDownward() {
        let count = CanopyLayout.bandCount
        for band in 1..<count {
            XCTAssertLessThan(CanopyLayout.bandWindGain(band), CanopyLayout.bandWindGain(band - 1),
                              "第 \(band) 层不该比它上面那层摆得大")
            XCTAssertLessThan(CanopyLayout.bandWindRotationGain(band),
                              CanopyLayout.bandWindRotationGain(band - 1),
                              "第 \(band) 层不该比它上面那层转得大")
        }
        XCTAssertGreaterThan(CanopyLayout.bandWindGain(0), 0, "顶层增益为 0 = 树冠在风里聋了")
        XCTAssertGreaterThan(CanopyLayout.bandWindGain(count - 1), 0, "底层增益为 0 = 裙摆冻住了")
        // 越界层号钳到端值（不许崩、不许给 0）
        XCTAssertEqual(CanopyLayout.bandWindGain(-3), CanopyLayout.bandWindGain(0))
        XCTAssertEqual(CanopyLayout.bandWindGain(99), CanopyLayout.bandWindGain(count - 1))
        XCTAssertEqual(CanopyLayout.bandWindRotationGain(-3), CanopyLayout.bandWindRotationGain(0))
        XCTAssertEqual(CanopyLayout.bandWindRotationGain(99), CanopyLayout.bandWindRotationGain(count - 1))
    }

    /// 树冠的风高必须拿到 `WindField` 的最高档放大（≥ heightReference）——
    /// 树是全场最高的东西，摆得比草叶大是刻意的。
    func testCrownWindHeightTakesTheTopHeightFactor() {
        XCTAssertGreaterThanOrEqual(CanopyLayout.windHeight, WindField.heightReference)
        XCTAssertEqual(WindField.heightFactor(CanopyLayout.windHeight), 1 + WindField.heightGain,
                       accuracy: 1e-9)
    }

}
