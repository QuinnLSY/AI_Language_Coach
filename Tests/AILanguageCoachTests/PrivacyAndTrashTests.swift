import XCTest
@testable import AIDomain
@testable import AppCore
@testable import AIInfrastructure

/// S2 第二批：隐私披露口径统一 + 用户资产删除进废纸篓。
///
/// 这批的价值全在**口径一致**：
/// - 界面说「不出机器」时，传输层就必须真的不经过任何能出机器的中转（系统代理）；
/// - 披露要列全**所有**会外发的能力，漏一项就等于那句断言是假的；
/// - 用户资产删除走废纸篓，而不是「点了就没了」。
final class PrivacyAndTrashTests: XCTestCase {

    // MARK: - 工具

    private nonisolated static func code(_ path: String) throws -> String {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private nonisolated static func declBody(matching marker: String, in source: String) throws -> String {
        guard let signature = source.range(of: marker) else {
            throw NSError(domain: "sentinel", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "找不到声明 \(marker)"])
        }
        guard let open = source.range(of: "{", range: signature.upperBound..<source.endIndex) else {
            throw NSError(domain: "sentinel", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "找不到 \(marker) 的声明体开头"])
        }
        var depth = 0
        var index = open.lowerBound
        while index < source.endIndex {
            let character = source[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return String(source[open.lowerBound..<index]) }
            }
            index = source.index(after: index)
        }
        throw NSError(domain: "sentinel", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "\(marker) 的声明体没有闭合"])
    }

    private func makeTempDirectory(function: String = #function) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("alc-privacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - S2-9 披露不许漏能力

    /// 嵌入服务收的就是错句与学习记忆原文 —— 早先它落到 `default: []`，披露里一个字都没有。
    func testEmbeddingAndPronunciationAreDisclosed() {
        XCTAssertEqual(PrivacyPolicy.outboundCategories(for: .embedding), [.learningMemory],
                       "嵌入的外发类别必须如实列出")
        XCTAssertFalse(PrivacyPolicy.outboundCategories(for: .pronunciation).isEmpty,
                       "发音评估会把音频发出去，不能算「不外发」")
        XCTAssertTrue(PrivacyPolicy.outboundCategories(for: .vad).isEmpty, "VAD 不外发数据")
        for kind in AIProviderKind.allCases {
            _ = PrivacyPolicy.outboundCategories(for: kind)  // 不许再有靠 default 兜底的分支
        }
    }

    /// 端点在公网上的嵌入/发音 Provider 必须出现在披露里。
    func testRemoteEmbeddingShowsUpInDisclosure() throws {
        var configuration = AppConfiguration()
        configuration.providers = [
            ProviderConfig(id: "remote.embed", kind: .embedding, enabled: true,
                           runtime: .remoteAPI, endpoint: "https://api.example.com/v1/embeddings"),
            ProviderConfig(id: "remote.tts", kind: .tts, enabled: true,
                           runtime: .remoteAPI, endpoint: "http://127.0.0.1:8856/v1/tts"),
        ]
        let disclosure = PrivacyPolicy.disclosure(for: configuration)
        let kinds = Set(disclosure.flows.map(\.kind))
        XCTAssertTrue(kinds.contains(.embedding), "公网嵌入服务必须在披露里：\(disclosure.summary)")
        // 回环 TTS 仍不算外发（数据没出机器）
        XCTAssertFalse(kinds.contains(.tts), "回环端点不算外发")
    }

    /// ⚠️ 排除断言：上面那条只钉「kinds 里有 embedding」。把列表换成
    /// `[.llm, .asr, .tts]` 再加一条「必须正好 5 项」，才防得住「又漏了一项」。
    func testDisclosureCoversEveryOutboundCapableKind() throws {
        let raw = try Self.code("Sources/AIDomain/PrivacyPolicy.swift")
        let body = try Self.declBody(matching: "public static func disclosure(for configuration:", in: raw)
        for kind in ["llm", "asr", "tts", "embedding", "pronunciation"] {
            XCTAssertTrue(body.contains(".\(kind)"), "披露清单漏了 \(kind)")
        }
        XCTAssertFalse(body.contains("AIProviderKind.allCases"),
                       "别用 allCases：vad 不外发数据，列进来会虚增一项")
    }

    // MARK: - S2-8 披露与传输层判同一件事

    /// 回环端点被判「不出机器」，传输层就必须真的绕过系统代理。
    ///
    /// ⚠️ 这条只能钉源码 —— 真发请求要么起服务、要么被代理劫持，都不是单测能构造的。
    func testLoopbackTargetsBypassTheSystemProxy() throws {
        let raw = try Self.code("Sources/AIInfrastructure/HTTPClient.swift")
        let body = try Self.declBody(matching: "private func makeSession(timeout: TimeInterval, target:", in: raw)
        XCTAssertTrue(body.contains("isLoopbackEndpoint"), "传输层要用与披露同一个判据")
        XCTAssertTrue(body.contains("if !useSystemProxy || isLoopback"), "回环必须无条件绕代理")
        // 判据不许换成「runtime 标签」或本地重写一份 → 必须是调用那个共用函数
        XCTAssertFalse(body.contains("runtime"), "判据是端点 host，不是 runtime 标签")
        XCTAssertTrue(raw.contains("let session = makeSession(timeout: timeout, target: request.url)"),
                      "URL 传不进去就判不了回环")
    }

    // MARK: - S2-13 用户资产删除进废纸篓

    /// 真实行为：删除后文件确实从原位消失。
    ///
    /// ⚠️ 判据只能到这里 —— 测试进程**没有查看废纸篓的权限**（TCC，Code=257），
    /// 「能在废纸篓里找到」这条在单测里没法验。改由哨兵钉住「先试废纸篓、失败才回落」。
    func testDeleteRemovesTheFileFromItsOriginalPath() throws {
        let directory = try makeTempDirectory()
        let file = directory.appendingPathComponent("用户资产.json")
        try Data("{}".utf8).write(to: file)

        XCTAssertTrue(TrashItem.delete(file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "文件应从原位移走")
    }

    /// 优先进废纸篓；不可用时回落永久删除但必须落日志（用户要能知道找不回来了）。
    func testTrashIsPreferredAndFallbackIsLoud() throws {
        let raw = try Self.code("Sources/AIInfrastructure/TrashItem.swift")
        let body = try Self.declBody(matching: "public static func delete(_ url: URL?) -> Bool", in: raw)
        let trashIndex = try XCTUnwrap(body.range(of: "manager.trashItem"))
        let removeIndex = try XCTUnwrap(body.range(of: "manager.removeItem"))
        XCTAssertLessThan(trashIndex.lowerBound, removeIndex.lowerBound, "必须先试废纸篓再回落")
        XCTAssertTrue(body.contains("AppLog.warning"), "回落要留痕（用户需要知道这条找不回来了）")
        XCTAssertFalse(body.contains("try?"), "废纸篓那一段不许静默吞错")
    }

    func testDeleteIsIdempotentAndTolerant() throws {
        let directory = try makeTempDirectory()
        let missing = directory.appendingPathComponent("不存在.json")
        XCTAssertFalse(TrashItem.delete(missing), "删不存在的文件不算失败")
        XCTAssertFalse(TrashItem.delete(nil), "nil 输入不算失败")
    }

    /// 四个删用户资产的地方都不许再直接 `removeItem`。
    func testUserAssetsNoLongerBypassTheTrash() throws {
        let targets = [
            "Sources/AIInfrastructure/AttachmentStore.swift": "public func remove(_ attachment: ChatAttachment) -> Bool",
            "Sources/AIInfrastructure/MaterialStore.swift": "public func delete(id: String)",
            "Sources/AIInfrastructure/CustomScenarioStore.swift": "public func delete(id: String)",
            "Sources/AIInfrastructure/DictionaryCatalog.swift": "public func removeBook(id: String) throws",
        ]
        for (path, marker) in targets {
            let body = try Self.declBody(matching: marker, in: try Self.code(path))
            XCTAssertFalse(body.contains("removeItem"), "\(path) 的删除不该再永久抹掉用户资产")
        }
    }
}