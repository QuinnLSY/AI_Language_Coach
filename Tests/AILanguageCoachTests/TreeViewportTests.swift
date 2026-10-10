import AIDomain
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
                let padding = TreeViewport.bottomPadding(viewportHeight: height, climbFraction: climb, progress: .seed())
                let contentHeight = topPadding + TreeCanvas.canvasHeight(for: .seed()) + padding
                let learnerContentY = topPadding + TreeCanvas.learnerY(for: climb, progress: .seed())
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
        let unpaddedOffset = topPadding + TreeCanvas.canvasHeight(for: .seed()) - height
        let learnerViewportY = topPadding + TreeCanvas.learnerY(for: 0, progress: .seed()) - unpaddedOffset
        let bandTop = height - TreeViewport.groundBandHeight
        let bellyY = learnerViewportY + 32   // 64pt 高的小动物，+32 就是它的脚底

        XCTAssertGreaterThan(
            bellyY, bandTop,
            "不补留白时，学员的脚(\(bellyY))应当沉在林带上沿(\(bandTop))之下 —— 这条前提不成立说明算式变了"
        )
        XCTAssertGreaterThan(
            TreeViewport.bottomPadding(viewportHeight: height, climbFraction: 0, progress: .seed()), 0,
            "全新学员在树底，必须补底部留白，否则目标位置滚不到"
        )
    }

    /// 学员爬得够高时不该白白补一大块留白（树的上半段本来就滚得动）。
    func testNoWastedPaddingOnceTheLearnerClimbsHigh() {
        for height in [CGFloat(735), 900] {
            XCTAssertEqual(
                TreeViewport.bottomPadding(viewportHeight: height, climbFraction: 1, progress: .seed()),
                0, accuracy: 0.001,
                "学员已经在树顶，底部不该再有留白（视口 \(height)）"
            )
        }
    }

    // MARK: - ③ 学员在画布里的位置：与画出来的必须是同一套算式

    func testLearnerYMatchesTheCanvasGeometry() {
        // 树底（进度 0）：画布 1080，地面带 120 → 学员 y 落在树干底部。
        XCTAssertEqual(TreeCanvas.learnerY(for: 0, progress: .seed()), 924, accuracy: 0.001)
        // 树顶（进度 1）：画布顶部 210 再上抬 36。
        XCTAssertEqual(TreeCanvas.learnerY(for: 1, progress: .seed()), 174, accuracy: 0.001)
        // 越往上爬，y 越小（单调）。
        XCTAssertLessThan(
            TreeCanvas.learnerY(for: 0.8, progress: .seed()),
            TreeCanvas.learnerY(for: 0.2, progress: .seed())
        )
        // 越界的进度要被夹住，不能算到画布外去。
        XCTAssertEqual(
            TreeCanvas.learnerY(for: -1, progress: .seed()),
            TreeCanvas.learnerY(for: 0, progress: .seed()), accuracy: 0.001
        )
        XCTAssertEqual(
            TreeCanvas.learnerY(for: 3, progress: .seed()),
            TreeCanvas.learnerY(for: 1, progress: .seed()), accuracy: 0.001
        )
    }

    // MARK: - ④ AI 课程关卡（③）：树长高了，正文那一段不许变形

    /// 树冠之上挂了课程关卡时，正文 8 关的**相对位置一根手指都不许动** ——
    /// 只是整棵树往下挪了（给上面腾地方）。
    func testCourseLevelsDoNotDistortTheBuiltInBand() {
        let plain = TreeCanvas.baseCanvasHeight - TreeCanvas.groundHeight - TreeCanvas.crownInset
        let grown = TreeCanvas.canvasHeight(for: .seed().withCourseLevels(3))
            - TreeCanvas.groundHeight - TreeCanvas.topInset(for: .seed().withCourseLevels(3))
        XCTAssertEqual(grown, plain, accuracy: 0.001,
                       "正文段跨度必须与课程功能之前一致，否则加一节课就把整棵树压扁或拉长")
    }

    /// 每一节课程都要落在**画布之内**，且彼此不重叠（这一条是被那行
    /// `min(max(fraction,0),1))` 教会的：夹住上界的话 6 节会叠成一个点）。
    func testEveryCourseLevelLandsInsideTheCanvasAtItsOwnHeight() {
        for count in 1...6 {
            let progress = LearnerProgress.seed().withCourseLevels(count)
            let height = TreeCanvas.canvasHeight(for: progress)
            let topInset = TreeCanvas.topInset(for: progress)
            let baseY = height - TreeCanvas.groundHeight
            var ys: [CGFloat] = []
            for level in progress.levels where level.isAboveCurriculum {
                let rank = TreeCanvas.courseRanks(in: progress)[level.id] ?? 0
                ys.append(TreeCanvas.y(
                    for: level.heightFraction, baseY: baseY, topInset: topInset, courseRank: rank
                ))
            }
            XCTAssertEqual(ys.count, count)
            XCTAssertEqual(Set(ys.map { Int($0.rounded()) }).count, count,
                           "\(count) 节课程里有关卡叠在同一高度")
            XCTAssertEqual(ys, ys.sorted(by: >), "课内序号越大越靠上（y 更小）")
            for y in ys {
                XCTAssertGreaterThanOrEqual(y, 0, "\(count) 节的某一格跑到画布顶端外面去了")
                XCTAssertLessThan(y, topInset, "\(count) 节的某一格没有排在树冠之上")
            }
            // 课程段整体还要留出画布顶部的余量（最高一格之上）。
            XCTAssertGreaterThanOrEqual(ys.min() ?? 0, 0)
        }
    }

    /// 没有课程关卡时画布高度**一个像素都不动** —— 滚动锚点与开屏定位都读它。
    func testCanvasHeightIsUntouchedWithoutCourses() {
        XCTAssertEqual(TreeCanvas.canvasHeight(for: .seed()), TreeCanvas.baseCanvasHeight)
        XCTAssertEqual(TreeCanvas.topInset(for: .seed()), TreeCanvas.crownInset)
    }
}
