import AIDomain
import Foundation

/// AI 排的课的落盘仓库：一条课一个 JSON，落在 `.workbuddy/app-config/courses/`。
///
/// 与 `CustomScenarioStore` 同构：一个 actor 管一个目录，写入只有一条路。
/// **坏文件不删**：单个 JSON 写坏只跳过那一份（并在 `corruptIDs` 里留个名），
/// 绝不悄悄清空整个目录 —— 一条课是学员拿自己攒下的错题、念不准的音和水平换来的。
///
/// ⚠️ 与 `CustomScenarioStore` 是**两个目录**：一条课是一**组**情景。
/// 把 6 节课塞进「我的情景」的话，那个分组会被一条课挤满，而且看不出哪几节是同一组的。
/// 两份互不污染，删掉整个 courses 目录只是回到「还没有 AI 排的课」。
public actor CourseStore {

    private let directory: URL
    /// 读坏了的文件名（诊断用，UI 不展示）。
    public private(set) var corruptIDs: [String] = []

    public init(directory: URL? = nil) {
        let base = AppPaths.userDataDirectory()
        self.directory = directory ?? base.appendingPathComponent("courses", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    /// 全部课（按排课时间倒序）。
    ///
    /// 每次从盘上读、不做进程内缓存：课是个位数规模，少一个缓存就少一个失效点
    /// （`CoachServices.availableCourses()` 那份缓存才是真正要刷的那个）。
    public func all() -> [CourseBlueprint] {
        corruptIDs = []
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> CourseBlueprint? in
                guard let data = try? Data(contentsOf: url) else {
                    corruptIDs.append(url.lastPathComponent)
                    return nil
                }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                guard let course = try? decoder.decode(CourseBlueprint.self, from: data) else {
                    corruptIDs.append(url.lastPathComponent)
                    return nil
                }
                return course
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// 落盘一条课（同 id 覆盖 —— 同一份状态重排是更新，不是堆积）。
    public func save(_ course: CourseBlueprint) throws {
        let url = directory.appendingPathComponent("\(course.id).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(course).write(to: url, options: .atomic)
    }

    /// 删除一条课（它那几节情景同时从「AI 排的课」里消失）。
    public func delete(id: String) {
        // id 是「course-<hex>」，只可能是文件名本身；仍拼一次前缀防手滑传绝对路径。
        let name = id.components(separatedBy: "/").last ?? id
        TrashItem.delete(directory.appendingPathComponent("\(name).json"))
    }
}
