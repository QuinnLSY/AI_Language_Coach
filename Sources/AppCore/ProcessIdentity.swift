import Foundation

/// 进程身份：当前这个进程是**应用本体**还是**测试宿主**。
///
/// ⚠️ 它的用途是给「会动用户文件的路径」加一道闸，而不是拿来给业务逻辑分叉：
///
/// `TrashItem` 在拿不到废纸篓的进程里会回落到**永久删除**（文件一旦删掉就无处可捞）。
/// 测试宿主正是这种进程：它在沙盒里跑、拿不到用户的废纸篓，而它随手一句
/// `AttachmentStore.pruneOrphans()` 打到真实数据目录上，用户攒的素材就没了，
/// 且日志里留不下任何线索（2026-10-27 排障时专门验证过这条链）。
///
/// 与 `AppKitHost.isPackedApp` 的分工：那个闸问的是「有没有 AppKit 宿主」，
/// 这个闸问的是「是不是测试进程」—— 两道题的答案互不包含
/// （`swift build` 出来的产物两者都不是）。
public enum ProcessIdentity {

    /// 当前进程是否由 XCTest 驱动。
    ///
    /// 判据用环境变量 / 进程名，而不是「有没有加载 XCTest 类」：
    /// 后者依赖 dyld 里恰好有 XCTest，命令行工具与预览宿主同样不满足 ——
    /// 而我们要的是「这一个进程能不能写用户的废纸篓」这种是非题，越稳越好。
    public static var isRunningTests: Bool {
        let info = ProcessInfo.processInfo
        if info.environment["XCTestConfigurationFilePath"] != nil { return true }
        return info.processName == "xctest"
    }
}
