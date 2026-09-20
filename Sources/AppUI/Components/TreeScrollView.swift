import AIDomain
import SwiftUI

/// 右侧栏那块**可上下滚动的成长之树**（不含底部固定的林间地面带）。
///
/// 为什么单独成视图：用户口径是「每次打开应用都要把学员小动物摆到一眼看得见的位置」，
/// 而这件事只有**真的滚一遍**才说得清（纯函数只能证明算式对不对，证明不了视图有没有照做）。
/// 拆出来之后测试就能把它挂进一个已知高度的窗口，直接读出滚动位置来断言 ——
/// 见 `TreeScrollViewTests`。
struct TreeScrollView: View {

    let theme: ForestTheme
    let progress: LearnerProgress
    var studentAnimal: AnimalKind = .bear
    var levelNotes: [String: TreeLevelNote] = [:]
    var onSelectLevel: (TreeLevel) -> Void = { _ in }

    /// 内容顶部内边距（算滚动位置时要带上它）。
    static let topPadding: CGFloat = 6

    var body: some View {
        // ⚠️ 视口高度是「把学员摆到哪儿」的自变量（见 `TreeViewport`），
        // 所以必须先把真实高度拿到手，不能再把 42% 那种百分比写死。
        GeometryReader { geo in
            let viewportHeight = geo.size.height
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    TreeCanvas(
                        theme: theme,
                        progress: progress,
                        studentAnimal: studentAnimal,
                        levelNotes: levelNotes
                    ) { level in
                        onSelectLevel(level)
                    }
                    .padding(.top, Self.topPadding)
                    // 底部留白：学员还压在树底时，不补这点留白，视口根本滚不到
                    // 目标位置（会被内容底边钳住 → 学员缩在林带后面）。
                    .padding(.bottom, TreeViewport.bottomPadding(
                        viewportHeight: viewportHeight,
                        climbFraction: progress.climbFraction
                    ))
                }
                // 一打开就停在**学员当前所在的位置**，不是树顶。
                // ⚠️ 进度是异步读回来的（`state.progress` 初值是种子数据），所以两条路都要跟：
                // 首帧滚一次，进度/攀爬位置变了再滚一次（那一次带动画，看得出是「往上爬」）。
                .task(id: Int(viewportHeight.rounded())) {
                    guard viewportHeight > 0 else { return }
                    scrollToLearner(proxy, viewportHeight: viewportHeight, animated: false)
                    // 首帧内容可能还没排完（锚点还没有 frame）→ 隔一拍再补一次；
                    // 第一次已经命中的话这次是幂等的。
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled else { return }
                    scrollToLearner(proxy, viewportHeight: viewportHeight, animated: false)
                }
                .onChange(of: treeScrollKey) { _, _ in
                    scrollToLearner(proxy, viewportHeight: viewportHeight, animated: true)
                }
            }
        }
    }

    /// 大树的滚动锚点签名：**学员爬到哪** + 关卡数量（进度从库里读回来时数量会补上）。
    ///
    /// 只认这两个量：别的字段（星数、标题）变了不该让视口自己跳走 ——
    /// 用户正上下翻看树的时候被拽回去会很难受。
    private var treeScrollKey: String {
        "\(progress.levels.count)-\(progress.climbFraction)"
    }

    /// 把视口滚到学员身上（位置按视口高度算，见 `TreeViewport`）。
    private func scrollToLearner(
        _ proxy: ScrollViewProxy, viewportHeight: CGFloat, animated: Bool
    ) {
        guard viewportHeight > 0 else { return }
        let anchor = UnitPoint(x: 0.5, y: TreeViewport.anchorY(viewportHeight: viewportHeight))
        if animated {
            withAnimation(.easeInOut(duration: 0.45)) {
                proxy.scrollTo(TreeCanvas.learnerAnchorID, anchor: anchor)
            }
        } else {
            proxy.scrollTo(TreeCanvas.learnerAnchorID, anchor: anchor)
        }
    }
}
