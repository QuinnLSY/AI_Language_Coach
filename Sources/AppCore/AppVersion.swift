import Foundation

/// 应用版本号。
///
/// **唯一来源**是 `Scripts/version.env` —— 打包脚本把它写进 `.app/Contents/Info.plist`，
/// 应用运行时回读。这样「打包出来的版本」与「界面上显示的版本」不可能漂移。
///
/// ⚠️ `swift test` 的宿主进程是 xctest，`Bundle.main` 里没有本应用的 Info.plist，
/// 因此这里必须有一个**不报错的**回退值，而不是抛错或断言。
public enum AppVersion {

    /// 对外版本号（`CFBundleShortVersionString`），如 `1.0.0`。
    public static let marketing: String = string(for: "CFBundleShortVersionString") ?? "开发构建"

    /// 构建号（`CFBundleVersion`）。
    public static let build: String? = string(for: "CFBundleVersion")

    /// 展示用：发布版形如 `1.0.0 (1)`；开发环境为 `开发构建`。
    public static var display: String {
        guard marketing != "开发构建", let build else { return marketing }
        return "\(marketing) (\(build))"
    }

    private static func string(for key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
