import AppCore
import Foundation

/// 关卡 → 情景 绑定表：**只从数据文件读取**，代码里不写死任何绑定关系。
///
/// 依据 `Resources/Levels/level_bindings.json`（`{ "<level id>": "<scenario id>" }`）。
/// 成长之树上的关卡绑定情景后：点这一关直接进入该情景，情景结算的星星也记在这一关上。
public enum LevelBindingCatalog {

    /// 随包发布的绑定表（Bundle 资源）。资源缺失时返回空表（关卡退化为普通练习入口）。
    public static func bundled() -> [String: String] {
        if let url = AppResourceBundle.module.url(forResource: "Levels/level_bindings", withExtension: "json"),
           let loaded = parse(try? Data(contentsOf: url)) {
            return loaded
        }
        // 兜底：不同打包方式对子目录资源的处理略有差异。
        if let url = AppResourceBundle.module.url(forResource: "level_bindings", withExtension: "json"),
           let loaded = parse(try? Data(contentsOf: url)) {
            return loaded
        }
        AppLog.warning("未找到关卡绑定资源（Resources/Levels/level_bindings.json）", category: "scenario")
        return [:]
    }

    /// 解析 `{ level: scenario }`（单测 / 未来用户自定义绑定入口）。
    /// 非字符串值一律忽略；无法解析时返回 nil（由调用方决定提示还是静默）。
    public static func parse(_ data: Data?) -> [String: String]? {
        guard let data else { return nil }
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var result: [String: String] = [:]
        for (level, value) in raw {
            guard let scenario = value as? String, !scenario.isEmpty, !level.isEmpty else { continue }
            result[level] = scenario
        }
        return result
    }
}
