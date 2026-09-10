import Foundation

/// SwiftPM 资源 bundle 的定位器。
///
/// **为什么不直接用 SwiftPM 自动生成的 `Bundle.module`**（2026-09-10）：
/// 生成的访问器只认 `.app` 的**根目录**（`Bundle.main.bundleURL`）。而 `.app` 根目录
/// 除了 `Contents` 之外放任何东西，`codesign` 都会报
/// `unsealed contents present in the bundle root` —— 整个应用**无法签名**。
/// 未签名 → TCC 拿不到稳定的代码身份 → 麦克风授权每次重启都要重新确认，
/// 而且每次启动都会再弹一次系统授权框。
///
/// 因此打包时把资源 bundle 放进标准的 `Contents/Resources/`，这里按
/// 「标准位置 → 历史位置 → 构建目录」的顺序查找，发布 / 开发 / 测试三种场景都能命中。
public enum AppResourceBundle {

    /// 资源 bundle 名（SwiftPM 由 target 名生成，改名需同步 Package.swift）。
    public static let bundleName = "AILanguageCoach_AIInfrastructure"

    /// 解析出的资源 bundle。所有资源读取都必须经由这里，不要再用 `Bundle.module`。
    public static let module: Bundle = locate(in: searchDirectories()) ?? Bundle.module

    /// 在候选目录中依次查找资源 bundle；全部落空返回 nil。
    ///
    /// 注意：`swift test` 由 Xcode 的 `xctest` 宿主进程启动，`Bundle.main` 指向
    /// `/Applications/Xcode.app/...`，三个候选目录都会落空，此时只能靠
    /// `Bundle.module` 里硬编码的构建目录兜底 —— 这是 SwiftPM 测试环境的固有约束。
    static func locate(in directories: [URL]) -> Bundle? {
        for directory in directories {
            if let bundle = Bundle(url: bundleURL(in: directory)) { return bundle }
        }
        return nil
    }

    /// 目录 → 资源 bundle 路径。
    static func bundleURL(in directory: URL) -> URL {
        directory
            .appendingPathComponent(bundleName)
            .appendingPathExtension("bundle")
    }

    /// 候选搜索目录，按优先级从高到低。
    static func searchDirectories() -> [URL] {
        var directories: [URL] = []
        // 1) .app/Contents/Resources —— 发布时的标准位置（唯一可签名的布局）
        if let resources = Bundle.main.resourceURL {
            directories.append(resources)
        }
        // 2) 可执行文件所在目录 —— `swift run` 产物，或 .app 根目录（历史布局）
        directories.append(Bundle.main.bundleURL)
        // 3) 上一级目录 —— 资源 bundle 与宿主 bundle 同级时的兜底
        directories.append(Bundle.main.bundleURL.deletingLastPathComponent())
        return directories
    }
}
