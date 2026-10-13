import AIDomain
import AppCore
import Foundation

// MARK: - AppState · 今日战绩海报（⑦-D）
extension AppState {

    /// 把今天的战绩导出成 PNG。
    ///
    /// ⚠️ 今天没练过**不给图**（`dailyPoster` 返回 nil，理由见 `DailyPoster` 文件头）：
    /// 那种情况下按钮本来也不该出现，这里是防一手 —— 快照在画完之后才变的那种。
    @MainActor
    public func exportDailyPoster(theme: ForestTheme) {
        guard let poster = dailyPoster else {
            posterNotice = AppNotice(text: "今天还没开口，先练两句再发")
            return
        }
        posterNotice = nil
        switch ReportExporter.exportDailyPosterPanel(poster: poster, theme: theme) {
        case .saved, .cancelled:
            // 存好了、或用户自己关了面板 —— 都不必再说一句。
            return
        case .failed:
            // ⚠️ 「重试」把同一张海报再存一次：失败多半是临时的（面板被抢占 /
            // 磁盘满一瞬间），让用户不用从头再点一遍导出。theme 在这层捕获 ——
            // 提示条只存一个闭包，别处拿不到当前主题。
            posterNotice = AppNotice(
                text: "导出今日战绩失败，请重试",
                action: .retry { [weak self] in
                    guard let self else { return }
                    self.exportDailyPoster(theme: theme)
                }
            )
        }
    }

    public func dismissPosterNotice() { posterNotice = nil }
}
