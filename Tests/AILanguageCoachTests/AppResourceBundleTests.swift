import Foundation
@testable import AIInfrastructure
import XCTest

/// 资源 bundle 定位。
///
/// **背景（2026-09-10）**：SwiftPM 自动生成的 `Bundle.module` 只认 `.app` 根目录，
/// 而根目录放东西会让 `codesign` 报 `unsealed contents present in the bundle root`，
/// 导致整个应用无法签名 → TCC 没有稳定身份 → 麦克风授权每次启动都重弹。
/// 改成放进 `Contents/Resources` 后，必须由 `AppResourceBundle` 保证仍然找得到。
final class AppResourceBundleTests: XCTestCase {

    func testBundleNameMatchesSwiftPMTarget() {
        XCTAssertEqual(AppResourceBundle.bundleName, "AILanguageCoach_AIInfrastructure")
    }

    func testSearchOrderPutsStandardLocationFirst() {
        let directories = AppResourceBundle.searchDirectories()
        XCTAssertFalse(directories.isEmpty)
        if let resources = Bundle.main.resourceURL {
            // 发布环境（.app/Contents/Resources）只有它存在，必须排最前。
            XCTAssertEqual(directories.first, resources, "标准资源目录必须优先")
        }
        // 末位候选是 bundle 的上一级目录：swift test 时资源 bundle 与 .xctest 同级。
        XCTAssertEqual(directories.last, Bundle.main.bundleURL.deletingLastPathComponent())
    }

    func testLocateFindsBundleInGivenDirectory() throws {
        // 用临时目录搭一个假 bundle，验证「每个候选目录都按 <dir>/<name>.bundle 找」。
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("resource-bundle-\(UUID().uuidString)")
        let bundleURL = AppResourceBundle.bundleURL(in: root)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let missing = root.appendingPathComponent("not-here")
        XCTAssertNil(AppResourceBundle.locate(in: [missing]), "目录里没有该 bundle 时必须返回 nil")
        let found = AppResourceBundle.locate(in: [missing, root])
        XCTAssertNotNil(found, "首个命中的候选目录应被采用")
        XCTAssertEqual(found?.bundleURL.resolvingSymlinksInPath().path,
                       bundleURL.resolvingSymlinksInPath().path)
    }

    func testBundleURLAppendsBundleName() {
        let base = URL(fileURLWithPath: "/tmp/x")
        XCTAssertEqual(AppResourceBundle.bundleURL(in: base).lastPathComponent,
                       "AILanguageCoach_AIInfrastructure.bundle")
    }

    /// 资源读取统一走 `AppResourceBundle.url(...)`，不直接问 `module`：
    /// SwiftPM 6.4（Xcode 27）把资源放进了 `<bundle>/Resources/…`，
    /// `Bundle.url(forResource:)` 只认自己那套路径，问不到 —— 兼容层负责兜住。
    func testModuleResolvesBundledResources() {
        let bundle = AppResourceBundle.module
        XCTAssertTrue(bundle.bundleURL.lastPathComponent.hasSuffix(".bundle"))
        XCTAssertNotNil(AppResourceBundle.url(forResource: "Config/default-config", withExtension: "json"))
        XCTAssertNotNil(AppResourceBundle.url(forResource: "Scenarios", withExtension: nil))
        XCTAssertNotNil(AppResourceBundle.url(forResource: "Prompts/teacher_system", withExtension: "txt"))
        XCTAssertNotNil(AppResourceBundle.url(forResource: "Levels/level_bindings", withExtension: "json"))
    }

    /// 兼容层本身要被钉住：老布局走 `Bundle`，新布局走自拼，两条路都得能拿到同一个文件。
    func testResourcesRootPointsAtTheDirectoryThatReallyHasPayload() {
        let root = AppResourceBundle.resourcesRoot
        XCTAssertNotNil(root, "资源根拿不到，所有资源读取都会落空")
        guard let root else { return }
        // 现场那一层里必须真有东西——判据是「有没有」，不是「版本多少」。
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        XCTAssertFalse(entries.isEmpty, "资源根是空的：\(root.path)")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("Config", isDirectory: true).path),
            "资源根下面必须有 Config：\(root.path)"
        )
    }
}
