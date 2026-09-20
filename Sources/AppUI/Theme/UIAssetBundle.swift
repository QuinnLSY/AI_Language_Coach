import Foundation

/// AppUI 自有资源包的定位器（品牌位图等界面资产）。
///
/// **为什么不直接用 `Bundle.module`**：SwiftPM 生成的访问器只认
/// `.app` 的**根目录**（`Bundle.main.bundleURL`）。而 `.app` 根目录除了
/// `Contents` 放任何东西，`codesign` 都会报
/// `unsealed contents present in the bundle root` —— 整个应用无法签名，
/// 进而 TCC 拿不到稳定代码身份、麦克风授权每次重启都重弹。
/// 所以打包时把资源 bundle 放进 `Contents/Resources/`，这里按
/// 「标准位置 → 可执行文件同级 → 上一级」的顺序查找，发布 / 开发 / 测试三种场景都能命中。
///
/// 与 `AIInfrastructure.AppResourceBundle` 是同一个套路、各自一个包：
/// AppUI 不依赖 AIInfrastructure（层级红线），只能自带一份。
enum UIAssetBundle {

    /// 资源 bundle 名（SwiftPM 由 target 名生成，target 改名需同步这里）。
    static let bundleName = "AILanguageCoach_AppUI"

    /// 解析出的资源 bundle。
    static let module: Bundle = locate(in: searchDirectories()) ?? Bundle.module

    static func locate(in directories: [URL]) -> Bundle? {
        for directory in directories {
            let url = directory
                .appendingPathComponent(bundleName)
                .appendingPathExtension("bundle")
            if let bundle = Bundle(url: url) { return bundle }
        }
        return nil
    }

    /// 候选搜索目录，优先级从高到低。
    static func searchDirectories() -> [URL] {
        var directories: [URL] = []
        // 1) .app/Contents/Resources —— 发布时的标准位置（唯一可签名的布局）
        if let resources = Bundle.main.resourceURL { directories.append(resources) }
        // 2) 可执行文件所在目录 —— `swift run` 产物，或 .app 根目录（历史布局）
        directories.append(Bundle.main.bundleURL)
        // 3) 上一级 —— 资源 bundle 与宿主 bundle 同级时的兜底
        directories.append(Bundle.main.bundleURL.deletingLastPathComponent())
        return directories
    }

    /// 取资源包里品牌位图的路径；找不到返回 nil（**不崩溃**：
    /// 图标缺失不该让整个应用起不来，调用方须准备降级外观）。
    ///
    /// ⚠️ 候选 `subdirectory` 必须写全：SwiftPM 的 `.copy("Resources")` 会把
    /// **目录名本身**也带进包里，于是源文件 `Resources/Brand/brand-logo.png`
    /// 在包里位于 `Resources/Brand/brand-logo.png`（不是 `Brand/...`）。
    /// 少写一层就静默取不到 → 侧栏退回旧矢量图，且不报任何错。
    static func brandAssetURL(_ name: String) -> URL? {
        let subdirectories: [String?] = ["Resources/Brand", "Brand", nil]
        for subdirectory in subdirectories {
            if let url = module.url(forResource: name, withExtension: "png", subdirectory: subdirectory),
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}
