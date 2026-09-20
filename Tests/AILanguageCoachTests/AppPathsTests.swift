import XCTest
@testable import AIInfrastructure

/// 数据目录解析（发布级）：三级降级必须**真的按顺序落**，且每一档都要可写。
///
/// 这一组用例守的是一条真实事故线：`#filePath` 是编译期常量，打包分发后它指向构建机的
/// 源码树；旧实现只做字符串上溯、不校验存在性，于是别人机器上数据**一声不响地写不进去**。
final class AppPathsTests: XCTestCase {

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-path-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
    }

    /// 项目空间可用时排第一档：开发机上 `swift run` 与打包后的 .app 共用同一份数据。
    func testPrefersProjectSpaceWhenWritable() throws {
        let projectRoot = sandbox.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)

        let resolved = AppPaths.resolveDataDirectory(
            projectRoot: projectRoot,
            supportBase: sandbox,
            tempBase: sandbox.appendingPathComponent("tmp", isDirectory: true)
        )

        XCTAssertEqual(resolved.path, projectRoot.appendingPathComponent(".workbuddy/app-config").path)
        XCTAssertTrue(FileManager.default.isWritableFile(atPath: resolved.path))
    }

    /// 分发到别人机器：`projectRoot` 为 nil → 必须落到应用支持目录，而不是某个幻影路径。
    func testFallsBackToSupportDirectoryWithoutProjectRoot() throws {
        let support = sandbox.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let resolved = AppPaths.resolveDataDirectory(
            projectRoot: nil,
            supportBase: support,
            tempBase: sandbox.appendingPathComponent("tmp", isDirectory: true)
        )

        XCTAssertEqual(resolved.path, support.appendingPathComponent("AILanguageCoach").path)
        XCTAssertTrue(FileManager.default.isWritableFile(atPath: resolved.path))
    }

    /// 项目空间「存在但建不出目录」（权限/占用）也必须降级，而不是把坏路径当成功返回。
    func testFallsBackWhenProjectSpaceIsNotCreatable() throws {
        // 拿一个**普通文件**充当 projectRoot 的上级：它下面无论如何建不出目录。
        let blocker = sandbox.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blocker)
        let support = sandbox.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let resolved = AppPaths.resolveDataDirectory(
            projectRoot: blocker,
            supportBase: support,
            tempBase: sandbox.appendingPathComponent("tmp", isDirectory: true)
        )

        XCTAssertEqual(resolved.path, support.appendingPathComponent("AILanguageCoach").path)
    }

    /// 连应用支持目录都建不出来 → 退临时目录（数据会丢，但必须返回一个能用且已建好的路径）。
    func testFallsBackToTempDirectoryWhenNothingElseWorks() throws {
        let blockedSupport = sandbox.appendingPathComponent("support-blocker")
        try Data("not a directory".utf8).write(to: blockedSupport)
        let temp = sandbox.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let resolved = AppPaths.resolveDataDirectory(
            projectRoot: nil,
            supportBase: blockedSupport,
            tempBase: temp
        )

        XCTAssertEqual(resolved.path, temp.appendingPathComponent("AILanguageCoach").path)
        XCTAssertTrue(FileManager.default.isWritableFile(atPath: resolved.path), "最后一档也得真的可写")
    }

    /// 真机守护：本进程实际解析出来的数据目录必须可写（发布前跑一次就能拦住「静默写不进去」）。
    func testResolvedUserDataDirectoryIsWritable() {
        XCTAssertTrue(
            FileManager.default.isWritableFile(atPath: AppPaths.userDataDirectory().path),
            "数据目录不可写 = 配置 / 学习库 / 音色档案全写不进去，实测 \(AppPaths.userDataDirectory().path)"
        )
    }

    /// `projectRoot` 若解析成功，就必须在本机真实存在（`Sources/` 要在）。
    func testProjectRootExistsOnDiskWhenResolved() throws {
        guard let root = AppPaths.projectRoot else {
            throw XCTSkip("本机不是源码树环境（分发场景），跳过")
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources").path),
            "解析出的项目根必须在本机真实存在：\(root.path)"
        )
    }
}
