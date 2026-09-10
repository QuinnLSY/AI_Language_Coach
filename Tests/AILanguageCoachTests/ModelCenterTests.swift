import AppCore
import XCTest

/// 模型管理中心（本地扫描 + 新产品配置字段）的行为。
final class ModelCenterTests: XCTestCase {

    // MARK: 本地模型扫描

    func testScannerFindsASRModelFilesAndTTSModelDirectories() throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("alc-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        // asr: models/ 下的模型文件
        let asrModels = (root as NSString).appendingPathComponent("asr/models")
        try FileManager.default.createDirectory(atPath: asrModels, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: (asrModels as NSString).appendingPathComponent("ggml-small.en.bin")))
        try Data("x".utf8).write(to: URL(fileURLWithPath: (asrModels as NSString).appendingPathComponent("ggml-large-v3.bin")))
        // tts: 每个模型一个目录
        let ttsDir = (root as NSString).appendingPathComponent("tts")
        try FileManager.default.createDirectory(atPath: (ttsDir as NSString).appendingPathComponent("Qwen3-TTS-0.6B"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: (ttsDir as NSString).appendingPathComponent("Piper-EN"), withIntermediateDirectories: true)
        // tts 内部目录不算模型
        try FileManager.default.createDirectory(atPath: (ttsDir as NSString).appendingPathComponent("venv"), withIntermediateDirectories: true)

        let asr = LocalModelScanner.scan(kind: .asr, root: root)
        XCTAssertEqual(Set(asr.map(\.name)), ["ggml-small.en", "ggml-large-v3"])

        let tts = LocalModelScanner.scan(kind: .tts, root: root)
        XCTAssertEqual(Set(tts.map(\.name)), ["Qwen3-TTS-0.6B", "Piper-EN"])

        // 未部署模块返回空
        XCTAssertEqual(LocalModelScanner.scan(kind: .vad, root: root), [])
    }

    func testScannerPathLookupByName() throws {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("alc-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let asrModels = (root as NSString).appendingPathComponent("asr/models")
        try FileManager.default.createDirectory(atPath: asrModels, withIntermediateDirectories: true)
        let file = (asrModels as NSString).appendingPathComponent("ggml-tiny.bin")
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        XCTAssertEqual(LocalModelScanner.path(of: "ggml-tiny", kind: .asr, root: root), file)
        XCTAssertNil(LocalModelScanner.path(of: "nope", kind: .asr, root: root))
    }

    // MARK: 产品配置新字段

    func testNewProductFieldsDefaultAndRoundTrip() throws {
        // 旧编码缺字段时自动补默认值
        let legacy = #"{"learning_language":"en-US"}"#
        let decoded = try JSONDecoder().decode(ProductConfig.self, from: Data(legacy.utf8))
        XCTAssertTrue(decoded.animalActivityFrequency > 0)
        XCTAssertTrue(decoded.voicePreview)

        // 新字段编解码往返
        var product = ProductConfig()
        product.animalActivityFrequency = 0.85
        product.voicePreview = false
        let data = try JSONEncoder().encode(product)
        let back = try JSONDecoder().decode(ProductConfig.self, from: data)
        XCTAssertEqual(back.animalActivityFrequency, 0.85, accuracy: 0.0001)
        XCTAssertFalse(back.voicePreview)
    }

    func testActivityFrequencyClamped() {
        // init 时钳制到 0...1（运行中修改由 AppState.setAnimalActivityFrequency 负责钳制）
        XCTAssertEqual(ProductConfig(animalActivityFrequency: 5).animalActivityFrequency, 1)
        XCTAssertEqual(ProductConfig(animalActivityFrequency: -2).animalActivityFrequency, 0)
    }
}
