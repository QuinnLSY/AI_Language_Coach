import AIInfrastructure
import AIServices
import AppCore
import XCTest

/// 朗读文本处理的集成用例（纯函数，不依赖外部服务，可稳定在 CI 跑）。
///
/// 关于「预热 TTS」不再做集成测试：实测它的耗时完全由 MPS 显存状态决定，
/// LLM 刚跑完时单次预热可达 187s，作为测试既慢又不稳定；其行为已在
/// `VoiceService.warmUp` 的文档注释与 ~/AI_Models/README.md 中记录。
final class VoicePipelineIntegrationTests: XCTestCase {

    /// 分句后的文本片段都应是可朗读的自然语句（无残留 markdown / emoji / 链接）。
    func testSplitPiecesAreSpeakableClean() {
        let raw = """
        **Markdown** is a simple way to format text. 😊
        - Use plain text with symbols
        - Keep it readable for everyone
        See [the guide](https://example.com) for details!
        """
        let pieces = SentenceSplitter.split(raw)
        XCTAssertFalse(pieces.isEmpty)
        for piece in pieces {
            XCTAssertFalse(piece.contains("*"), "残留 markdown：\(piece)")
            XCTAssertFalse(piece.contains("http"), "残留链接：\(piece)")
            XCTAssertFalse(piece.contains("😊"), "残留 emoji：\(piece)")
            XCTAssertFalse(piece.hasPrefix("- "), "残留列表符号：\(piece)")
        }
        XCTAssertTrue(pieces.joined().contains("the guide"), "链接文字应保留")
    }

    /// 长回复必须被切成多句，这是「首句先出声」的前提。
    func testLongTeacherReplyIsSplitIntoSentences() {
        let reply = """
        That is a really good question! Let me explain how it works. \
        First, you need to listen carefully to the whole sentence. \
        Then, try to repeat it out loud two or three times. \
        Finally, write it down in your notebook so you remember it.
        """
        let pieces = SentenceSplitter.split(reply)
        XCTAssertGreaterThanOrEqual(pieces.count, 3, "应切成多句：\(pieces)")
        XCTAssertTrue(pieces.allSatisfy { !$0.isEmpty })
    }
}
