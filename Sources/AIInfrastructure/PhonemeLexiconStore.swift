import AIDomain
import AppCore
import Foundation

/// 音素词库（`Resources/Pronunciation/lexicon.json`）的加载器。
///
/// **数据来源**：CMU Pronouncing Dictionary（BSD-2-Clause），只保留本项目文本素材
/// 里出现过的词 —— 用户要读的句子本来就出自这些素材，覆盖足够，体积可控（约 120KB）。
///
/// 加载失败**不阻塞评测**：退化成空词库，所有词走规则 G2P（大差不差，仍然能对齐），
/// 与「发音模型缺席也要能评测」是同一条产品原则。
public enum PhonemeLexiconStore {

    /// 进程内缓存：词库是只读的静态资源，没必要每次评测重解析 12 万字节 JSON。
    private static let cached = Cache()

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var value: PhonemeLexicon?

        func get(_ make: () -> PhonemeLexicon) -> PhonemeLexicon {
            lock.lock()
            defer { lock.unlock() }
            if let value { return value }
            let made = make()
            value = made
            return made
        }
    }

    /// 随包发布的词库。
    public static func shared() -> PhonemeLexicon {
        cached.get { load() }
    }

    /// 指定文件加载（单测 / 未来的自定义词库）。
    public static func load(from url: URL) -> PhonemeLexicon {
        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(LexiconFile.self, from: data)
            return PhonemeLexicon(words: file.words)
        } catch {
            AppLog.warning(
                "音素词库不可用（退化为规则 G2P）\(url.lastPathComponent)：\(error.localizedDescription)",
                category: "pronunciation"
            )
            return .empty
        }
    }

    private static func load() -> PhonemeLexicon {
        // SwiftPM 把 `Resources` 整目录复制进资源 bundle，故词库在 `Pronunciation/` 子目录下。
        if let directory = AppResourceBundle.module.url(forResource: "Pronunciation", withExtension: nil) {
            let url = directory.appendingPathComponent("lexicon.json")
            if FileManager.default.fileExists(atPath: url.path) { return load(from: url) }
        }
        // 兜底：直接在资源 bundle 里按名字找（不同打包方式对目录资源的处理略有差异）。
        if let url = AppResourceBundle.module.url(forResource: "lexicon", withExtension: "json") {
            return load(from: url)
        }
        AppLog.warning(
            "未找到内置音素词库（Resources/Pronunciation/lexicon.json），音素评测将全部走规则 G2P",
            category: "pronunciation"
        )
        return .empty
    }

    private struct LexiconFile: Decodable {
        let words: [String: [String]]
    }
}
