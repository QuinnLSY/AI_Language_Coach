import AIDomain
import XCTest

/// `alc://` 深链的**解析**（纯函数）。
///
/// 这一层钉的是「什么样的地址认、什么样的不认」：
/// - 页面同名地址与别名都要能走；
/// - **认不出就必须返回 nil** —— 一个默默跳到首页的地址，比跳不过去更糟，
///   因为它看起来「生效了」，用户却落在完全不相关的一页上。
final class AppDeepLinkTests: XCTestCase {

    // MARK: - 页面同名地址

    /// 每一页的地址都与 `rawValue` 同名：加一页自动多一个地址，不会两边各漏一处。
    func testEverySectionHasItsOwnAddress() {
        for section in AppSection.allCases {
            let parsed = AppDeepLink.parse(AppDeepLink.url(for: section))
            XCTAssertEqual(parsed, .section(section), "\(section.rawValue) 的地址该指回它自己")
        }
    }

    func testHostIsCaseInsensitive() {
        XCTAssertEqual(AppDeepLink.parse("ALC://Vocabulary"), .section(.vocabulary))
        XCTAssertEqual(AppDeepLink.parse("alc://WRITING"), .section(.writing))
    }

    // MARK: - 别名（手写时猜一个往往也要对）

    func testSpokenAliasesResolve() {
        XCTAssertEqual(AppDeepLink.parse("alc://today"), .section(.practice))
        XCTAssertEqual(AppDeepLink.parse("alc://chat"), .section(.practice))
        XCTAssertEqual(AppDeepLink.parse("alc://shadow"), .section(.shadowing))
        XCTAssertEqual(AppDeepLink.parse("alc://review"), .section(.vocabulary))
        XCTAssertEqual(AppDeepLink.parse("alc://words"), .section(.vocabulary))
        XCTAssertEqual(AppDeepLink.parse("alc://scenario"), .section(.scenarios))
        XCTAssertEqual(AppDeepLink.parse("alc://stats"), .section(.progress))
        XCTAssertEqual(AppDeepLink.parse("alc://history"), .section(.records))
    }

    /// 生成的地址永远用 `rawValue`，别名只进不出 —— 双向映射最容易漏一边。
    func testGeneratedURLsUseCanonicalHost() {
        XCTAssertEqual(AppDeepLink.url(for: .vocabulary).absoluteString, "alc://vocabulary")
        XCTAssertEqual(AppDeepLink.url(for: .scenarios).absoluteString, "alc://scenarios")
    }

    // MARK: - 不认：一律 nil，绝不退到首页

    func testUnknownHostIsRejected() {
        XCTAssertNil(AppDeepLink.parse("alc://nope"), "认不出的方向必须拒绝，不能默默跳首页")
    }

    /// 只认 host，后面带不带路径都不影响 —— 手写地址时多敲一个斜杠不该失效。
    func testExtraPathIsIgnored() {
        XCTAssertEqual(AppDeepLink.parse("alc://practice/extra/path"), .section(.practice))
    }

    func testForeignSchemeIsRejected() {
        XCTAssertNil(AppDeepLink.parse("https://example.com/vocabulary"))
        XCTAssertNil(AppDeepLink.parse("myapp://vocabulary"))
    }

    func testEmptyHostIsRejected() {
        XCTAssertNil(AppDeepLink.parse("alc://"))
        XCTAssertNil(AppDeepLink.parse("alc:/vocabulary"))
        XCTAssertNil(AppDeepLink.parse("not a url at all"))
        XCTAssertNil(AppDeepLink.parse(""))
    }

    // MARK: - 带一句话进来

    func testAskCarriesTheText() {
        XCTAssertEqual(AppDeepLink.parse("alc://ask?text=Hello%20world"), .ask("Hello world"))
        // 中文也要能带（别人给的句子常常是中文忘了删）。
        let chinese = AppDeepLink.url(ask: "今天过得好吗")
        XCTAssertEqual(AppDeepLink.parse(chinese!), .ask("今天过得好吗"))
    }

    func testShortQueryKeyWorks() {
        XCTAssertEqual(AppDeepLink.parse("alc://ask?q=Hi"), .ask("Hi"))
    }

    /// 没话可说的地址 = 无效地址。宁愿不跳，也别把用户丢到一个空的输入框前。
    func testAskWithoutTextIsRejected() {
        XCTAssertNil(AppDeepLink.parse("alc://ask"), "没有 text 的 ask 不该承认")
        XCTAssertNil(AppDeepLink.parse("alc://ask?text="))
        XCTAssertNil(AppDeepLink.parse("alc://ask?text=%20%20"), "纯空白也不算有话要说")
        XCTAssertNil(AppDeepLink.url(ask: "   "))
    }

    /// `text` 优先于 `q`：两个都给了就以正式名为准，不用猜。
    func testTextWinsOverShortKey() {
        XCTAssertEqual(AppDeepLink.parse("alc://ask?q=short&text=long"), .ask("long"))
    }

    func testAskRoundTrip() {
        let url = try? XCTUnwrap(AppDeepLink.url(ask: "What did you do today?"))
        XCTAssertEqual(AppDeepLink.parse(url!), .ask("What did you do today?"))
    }

    // MARK: - 今日任务 → 该去的那一页

    /// 这一张映射表是全仓唯一的（今日任务卡、学习计划、菜单栏都读它）。
    func testTaskKindMapsToSection() {
        XCTAssertEqual(AppSection(.conversation), .practice)
        XCTAssertEqual(AppSection(.shadowing), .shadowing)
        XCTAssertEqual(AppSection(.review), .vocabulary)
    }
}
