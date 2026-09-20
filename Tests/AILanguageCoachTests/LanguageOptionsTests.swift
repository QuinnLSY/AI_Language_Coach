import AIDomain
import AppCore
import XCTest

/// 语言候选清单（`LanguageOptions`）的纯函数回归。
///
/// 背景：设置页原来让用户手填 `en-US` / `zh-CN` 这种标识符 ——
/// 终端用户不可能知道该填什么格式，填错也不报错，只是识别、翻译、释义悄悄走偏。
/// 改成下拉之后，「清单里到底有没有当前值」就成了会直接决定界面表现（显示「未选择」还是显示真值）的契约，
/// 值得钉住。
final class LanguageOptionsTests: XCTestCase {

    // MARK: - 清单本身

    /// 当前版本只做英语：学习语言必须全是 `en-` 开头，别悄悄混进别的语种。
    func testLearningOptionsAreEnglishOnly() {
        XCTAssertFalse(LanguageOptions.learning.isEmpty)
        for option in LanguageOptions.learning {
            XCTAssertTrue(option.tag.hasPrefix("en-"), "学习语言里混进了非英语项：\(option.tag)")
        }
    }

    /// `tag` 就是下拉的 id，重复会让两个选项互相覆盖。
    func testOptionTagsAreUnique() {
        XCTAssertEqual(Set(LanguageOptions.learning.map(\.tag)).count, LanguageOptions.learning.count)
        XCTAssertEqual(Set(LanguageOptions.native.map(\.tag)).count, LanguageOptions.native.count)
    }

    /// 显示名不能等于标识符 —— 那说明这行漏写了中文名，界面会把给开发者看的东西露给用户。
    func testBuiltinOptionsHaveHumanTitles() {
        for option in LanguageOptions.learning + LanguageOptions.native {
            XCTAssertFalse(option.title.isEmpty)
            XCTAssertNotEqual(option.title, option.tag, "\(option.tag) 直接用标识符当了显示名")
        }
    }

    /// 配置里的默认值必须能在下拉里选中，否则一打开设置页看到的就是「未选择」。
    func testDefaultConfigurationValuesAreSelectable() {
        let defaults = ProductConfig()
        XCTAssertTrue(
            LanguageOptions.learning.contains { $0.tag == defaults.learningLanguage },
            "默认学习语言 \(defaults.learningLanguage) 不在候选清单里"
        )
        XCTAssertTrue(
            LanguageOptions.native.contains { $0.tag == defaults.nativeLanguage },
            "默认母语 \(defaults.nativeLanguage) 不在候选清单里"
        )
    }

    // MARK: - includingCurrent（把配置里的当前值补进候选）

    func testIncludingCurrentPrependsUnknownTag() {
        let result = LanguageOptions.includingCurrent("ja-JP", in: LanguageOptions.learning)
        XCTAssertEqual(result.count, LanguageOptions.learning.count + 1)
        XCTAssertEqual(result.first?.tag, "ja-JP")
        XCTAssertEqual(result.first?.title, LanguageOptions.displayName(for: "ja-JP"))
    }

    func testIncludingCurrentKeepsKnownTagUntouched() {
        XCTAssertEqual(
            LanguageOptions.includingCurrent("en-US", in: LanguageOptions.learning).map(\.tag),
            LanguageOptions.learning.map(\.tag)
        )
    }

    /// 大小写不同也算「已经在清单里」：配置里存 `EN-us` 时不该再多出一个重复项。
    func testIncludingCurrentIsCaseInsensitive() {
        XCTAssertEqual(
            LanguageOptions.includingCurrent("EN-us", in: LanguageOptions.learning).map(\.tag),
            LanguageOptions.learning.map(\.tag)
        )
    }

    func testIncludingCurrentIgnoresBlankValues() {
        XCTAssertEqual(
            LanguageOptions.includingCurrent("", in: LanguageOptions.native).map(\.tag),
            LanguageOptions.native.map(\.tag)
        )
        XCTAssertEqual(
            LanguageOptions.includingCurrent("   ", in: LanguageOptions.native).map(\.tag),
            LanguageOptions.native.map(\.tag)
        )
    }

    /// 带空白的旧值要**裁干净**再补进去：留着空白等于把一个坏值固化成选项。
    func testIncludingCurrentTrimsUnknownTag() {
        XCTAssertEqual(
            LanguageOptions.includingCurrent("  ko-KR ", in: LanguageOptions.learning).first?.tag,
            "ko-KR"
        )
    }
}
