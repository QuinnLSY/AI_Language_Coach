@testable import AppUI
import XCTest

/// 「开屏把学员摆到一眼看得见的位置」——右侧栏视口定位的纯函数。
///
/// 用户报障（09-18）：每次打开应用，右边栏大树没有把学员小动物摆到可见处，
/// 它缩在底部**林间地面带**后面只露个头顶。
///
/// 根子不在「有没有滚」，而在「滚得到不到」：锚点写死在视口 42% 处，可学员站在树底时
/// **内容底边把滚动钳住了**，视口最多滚到内容末尾 —— 学员于是停在「离视口底边 156pt」，
/// 而底部 150pt 正好被林带压着。所以两条断言都要有：
/// ① 目标位置得在林带之上（`learnerTargetY`）；② 这个目标得真的滚得到（`bottomPadding`）。
final class TreeViewportTests: XCTestCase {

    /// 内容顶部那 6pt 内边距（`MainView` 里 `TreeCanvas` 的 `.padding(.top, 6)`）。
    private let topPadding: CGFloat = 6

    private let heights: [CGFloat] = [300, 420, 735, 900, 1086, 1400]

    // MARK: - ① 目标位置必须在林带之上

    /// 不管视口多高，学员的目标位置都不能沉到「林间地面带」后面。
    func testLearnerNeverSinksBehindTheGroundBand() {
        for height in heights {
            let target = TreeViewport.learnerTargetY(viewportHeight: height)
            let bandTop = height - TreeViewport.groundBandHeight
            XCTAssertGreaterThanOrEqual(target, 0, "视口 \(height)：目标 y 算成了负数（\(target)）")
            XCTAssertLessThanOrEqual(
                target, bandTop,
                "视口 \(height)：学员的目标位置 \(target) 已经压进林带（林带上沿在 \(bandTop)）"
            )
            // 视口够高时还得留满呼吸位；矮到挤不出呼吸位时就只保证「露在林带之上」。
            let ideal = bandTop - TreeViewport.clearance
            if ideal >= TreeViewport.topMargin {
                XCTAssertLessThanOrEqual(
                    target + TreeViewport.clearance, bandTop + 0.001,
                    "视口 \(height) 够高，学员上方该留出完整的 \(TreeViewport.clearance)pt 呼吸位"
                )
            }
        }
    }

    /// 极矮的视口（几个控件挤在一起）也不能把学员顶到屏幕外。
    func testTinyViewportStaysInside() {
        for height in [CGFloat(180), 240, 270] {
            let target = TreeViewport.learnerTargetY(viewportHeight: height)
            XCTAssertGreaterThanOrEqual(target, 0)
            XCTAssertLessThanOrEqual(
                target, height,
                "视口 \(height)：目标 y \(target) 跑到视口外了"
            )
        }
    }

    /// 锚点 = 目标位置 ÷ 视口高度，且必须是合法 `UnitPoint`。
    func testAnchorMatchesTargetPosition() {
        for height in heights {
            let anchor = TreeViewport.anchorY(viewportHeight: height)
            XCTAssertGreaterThanOrEqual(anchor, 0)
            XCTAssertLessThanOrEqual(anchor, 1)
            XCTAssertEqual(
                anchor * height, TreeViewport.learnerTargetY(viewportHeight: height), accuracy: 0.001,
                "视口 \(height)：锚点 \(anchor) 与目标位置对不上"
            )
        }
    }

    // MARK: - ② 目标位置必须真的滚得到（这条才是这次报障的正主）

    /// 补了底部留白之后，滚到「学员停在目标位置」这件事**不会被内容底边钳住**。
    func testBottomPaddingMakesTheTargetReachable() {
        for height in heights {
            for climb in [0.0, 0.05, 0.3, 0.75, 1.0] {
                let padding = TreeViewport.bottomPadding(viewportHeight: height, climbFraction: climb)
                let contentHeight = topPadding + TreeCanvas.canvasHeight + padding
                let learnerContentY = topPadding + TreeCanvas.learnerY(for: climb)
                let desiredOffset = learnerContentY - TreeViewport.learnerTargetY(viewportHeight: height)
                guard desiredOffset >= 0 else { continue }   // 树比视口还矮，本来就不需要滚
                XCTAssertLessThanOrEqual(
                    desiredOffset, contentHeight - height + 0.001,
                    "视口 \(height)、进度 \(climb)：还差 \(desiredOffset - (contentHeight - height))pt 的底部留白，滚动会被内容底边钳住"
                )
            }
        }
    }

    /// 反证：**不补**底部留白时，全新学员（进度 0）就是会被钳住 —— 小动物沉进林带。
    ///
    /// 这条把报障现场钉成数字：钳住之后学员落在「视口底边往上 156pt」，
    /// 而林带盖住最下面 150pt。
    func testWithoutPaddingTheFreshLearnerEndsUpBehindTheBand() {
        let height: CGFloat = 735
        let unpaddedOffset = topPadding + TreeCanvas.canvasHeight - height
        let learnerViewportY = topPadding + TreeCanvas.learnerY(for: 0) - unpaddedOffset
        let bandTop = height - TreeViewport.groundBandHeight
        let bellyY = learnerViewportY + 32   // 64pt 高的小动物，+32 就是它的脚底

        XCTAssertGreaterThan(
            bellyY, bandTop,
            "不补留白时，学员的脚(\(bellyY))应当沉在林带上沿(\(bandTop))之下 —— 这条前提不成立说明算式变了"
        )
        XCTAssertGreaterThan(
            TreeViewport.bottomPadding(viewportHeight: height, climbFraction: 0), 0,
            "全新学员在树底，必须补底部留白，否则目标位置滚不到"
        )
    }

    /// 学员爬得够高时不该白白补一大块留白（树的上半段本来就滚得动）。
    func testNoWastedPaddingOnceTheLearnerClimbsHigh() {
        for height in [CGFloat(735), 900] {
            XCTAssertEqual(
                TreeViewport.bottomPadding(viewportHeight: height, climbFraction: 1),
                0, accuracy: 0.001,
                "学员已经在树顶，底部不该再有留白（视口 \(height)）"
            )
        }
    }

    // MARK: - ③ 学员在画布里的位置：与画出来的必须是同一套算式

    func testLearnerYMatchesTheCanvasGeometry() {
        // 树底（进度 0）：画布 1080，地面带 120 → 学员 y 落在树干底部。
        XCTAssertEqual(TreeCanvas.learnerY(for: 0), 924, accuracy: 0.001)
        // 树顶（进度 1）：画布顶部 210 再上抬 36。
        XCTAssertEqual(TreeCanvas.learnerY(for: 1), 174, accuracy: 0.001)
        // 越往上爬，y 越小（单调）。
        XCTAssertLessThan(TreeCanvas.learnerY(for: 0.8), TreeCanvas.learnerY(for: 0.2))
        // 越界的进度要被夹住，不能算到画布外去。
        XCTAssertEqual(TreeCanvas.learnerY(for: -1), TreeCanvas.learnerY(for: 0), accuracy: 0.001)
        XCTAssertEqual(TreeCanvas.learnerY(for: 3), TreeCanvas.learnerY(for: 1), accuracy: 0.001)
    }
}
