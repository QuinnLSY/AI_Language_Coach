import AIInfrastructure
import AppCore
import Foundation

/// 发布就绪检查命令行：`swift run alc-release-check`。
///
/// 把 Implementation Plan §34 的 Release checklist 跑一遍：
/// - 能自动验证的（静态扫描 / 迁移 / 备份导出 / 坏库隔离 / 基准产物 / 隐私口径）真跑；
/// - 只能人工验证的逐条列出**怎么做**，等着人来跑。
///
/// 退出码：**存在未通过的自动检查 → 1**（可以接进 CI 当门禁）；人工项不拦发布。
@main
struct ReleaseCheckCLI {

    static func main() async {
        let runner = ReleaseReadinessRunner()
        let report = await runner.evaluate()
        print(report.markdownSummary())

        do {
            let url = try ReleaseArtifactStore().write(report)
            print("")
            print("产物：\(url.path)")
        } catch {
            print("")
            print("⚠️ 报告落盘失败：\(error.localizedDescription)")
        }

        if !report.isReleaseReady {
            print("")
            print("存在未通过的自动检查，建议修复后重跑。")
            exit(1)
        }
        if !report.manualResults.isEmpty {
            print("")
            print("还有 \(report.manualResults.count) 项需要人工/实机验证（见上面的待办清单）。")
        }
    }
}
