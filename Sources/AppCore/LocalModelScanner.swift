import Foundation

/// 本地模型目录扫描：用户把模型统一部署在 `~/AI_Models/<模块>/` 下，
/// 应用按约定自动发现。目录约定（README 同步说明）：
///
///     ~/AI_Models/
///     ├── asr/models/ggml-small.en.bin     # 识别：models/ 下的模型文件
///     ├── tts/Qwen3-TTS-12Hz-0.6B-.../    # 合成：模块目录下的每个子目录 = 一个模型
///     ├── vad/<模型目录>/                  # 说话检测（同 TTS 约定）
///     ├── embedding/<模型目录>/            # 记忆索引（同 TTS 约定）
///     └── pronunciation/<模型目录>/        # 发音评测（同 TTS 约定）
public struct LocalModel: Sendable, Equatable, Identifiable {
    public var id: String { path }
    /// 展示名（文件去扩展名 / 目录名）。
    public var name: String
    /// 绝对路径。
    public var path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

public enum LocalModelScanner {

    /// 统一部署根目录。
    public static var root: String {
        NSString(string: "~/AI_Models").expandingTildeInPath
    }

    /// 扫描某能力模块下可用的本地模型。目录不存在或为空时返回 []。
    public static func scan(kind: AIProviderKind) -> [LocalModel] {
        scan(kind: kind, root: root)
    }

    /// 可注入根目录的扫描实现（测试用）。
    public static func scan(kind: AIProviderKind, root: String) -> [LocalModel] {
        let fm = FileManager.default
        let folder = NSURL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(kind.rawValue, isDirectory: true)?.path
        guard let folder, fm.fileExists(atPath: folder) else { return [] }

        // 排除的内部目录名（部署脚本/服务/日志不属于模型）
        let excluded: Set<String> = ["venv", ".venv", "services", "bin", "logs", "models_meta", ".DS_Store"]

        if kind == .asr {
            // 识别模型：约定在 models/ 子目录下的文件；退化也接受模块根下的模型文件。
            var models: [LocalModel] = []
            let modelsDir = (folder as NSString).appendingPathComponent("models")
            let searchDirs = fm.fileExists(atPath: modelsDir) ? [modelsDir, folder] : [folder]
            for dir in searchDirs {
                guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for item in items where !item.hasPrefix(".") && !excluded.contains(item) {
                    let full = (dir as NSString).appendingPathComponent(item)
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue else { continue }
                    let name = (item as NSString).deletingPathExtension
                    if !models.contains(where: { $0.name == name }) {
                        models.append(LocalModel(name: name, path: full))
                    }
                }
            }
            return models.sorted { $0.name < $1.name }
        }

        // 其余模块：每个子目录 = 一个模型（根下的单文件也算，兼顾宽松布局）
        var models: [LocalModel] = []
        guard let items = try? fm.contentsOfDirectory(atPath: folder) else { return [] }
        for item in items where !item.hasPrefix(".") && !excluded.contains(item) {
            let full = (folder as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                models.append(LocalModel(name: item, path: full))
            } else if item.contains(".") && kind == .tts {
                // 宽松：单文件也接受（如单文件模型包）
                let name = (item as NSString).deletingPathExtension
                models.append(LocalModel(name: name, path: full))
            }
        }
        return models.sorted { $0.name < $1.name }
    }

    /// 按名字找已扫描模型的路径（展示「当前模型来自哪里」用）。
    public static func path(of name: String, kind: AIProviderKind, root: String? = nil) -> String? {
        scan(kind: kind, root: root ?? Self.root).first { $0.name == name }?.path
    }
}
