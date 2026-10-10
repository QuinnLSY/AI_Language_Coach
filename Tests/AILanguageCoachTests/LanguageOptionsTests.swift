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

    // MARK: - LearningLanguage（三套写法的唯一来源）

    /// 配置里存的是 `en-US`，语音 runtime 要的是 `English` —— 派生必须把它换掉，
    /// 否则 prompt 里就会渲染出 `practise en-US`（这正是要修的瑕疵）。
    func testDerivedServiceNameIsNeverTheRawTag() {
        let language = LearningLanguage(bcp47: "en-US")
        XCTAssertEqual(language.serviceName, "English")
        XCTAssertNotEqual(language.serviceName, language.bcp47, "派生退化成了原标签，瑕疵原样复活")
    }

    /// 地区变体只影响 `bcp47`（识别/评测选哪套模型），主标签与素材 key 都该是 `en`。
    func testEnglishVariantsSharePrimaryTagButKeepBCP47() {
        for option in LanguageOptions.learning {
            XCTAssertEqual(option.language.primaryTag, "en", "\(option.tag) 的主标签不是 en")
            XCTAssertEqual(option.language.contentKey, "en", "\(option.tag) 的素材 key 不是 en")
            XCTAssertEqual(option.language.serviceName, "English", "\(option.tag) 的语言名不是 English")
            XCTAssertEqual(option.language.bcp47, option.tag, "\(option.tag) 的 bcp47 没保真")
        }
    }

    /// 母语清单里的 `en-US` 同样要派生出 `English`（两个清单共用同一个类型）。
    func testNativeEnglishOptionAlsoDerivesEnglish() {
        let option = LanguageOptions.native.first { $0.tag == "en-US" }
        XCTAssertEqual(option?.language.serviceName, "English")
    }

    /// 便捷常量与默认配置必须是同一个语言，否则「默认值」就有了两种说法。
    func testEnglishConstantMatchesDefaultConfiguration() {
        XCTAssertEqual(LearningLanguage.english.bcp47, ProductConfig().learningLanguage)
        XCTAssertEqual(LearningLanguage.english.serviceName, "English")
        XCTAssertEqual(LearningLanguage.english.primaryTag, "en")
    }

    /// 空/纯空白配置值退化成 `en-US`（当前唯一语言），而不是崩掉或产出空服务名。
    func testBlankBCP47FallsBackToEnglish() {
        XCTAssertEqual(LearningLanguage(bcp47: "   ").bcp47, "en-US")
        XCTAssertEqual(LearningLanguage(bcp47: "").serviceName, "English")
    }

    // MARK: - resolving（宽容解析历史遗留的自由文本）

    /// ① 完整 BCP-47：能认出语言，且**故意不保留**地区变体
    /// （`resolving` 的职责是「认出是哪种语言」，地区只有配置路径 `init(bcp47:)` 才保真）。
    func testResolvingFullBCP47() throws {
        let language = try XCTUnwrap(LearningLanguage.resolving("en-US"))
        XCTAssertEqual(language.primaryTag, "en")
        XCTAssertEqual(language.bcp47, "en", "resolving 应当归一成主标签")
        XCTAssertEqual(language.serviceName, "English")
    }

    /// 对照：`init(bcp47:)` 是配置路径，必须保真地区变体（否则识别/评测会挑错口音的模型）。
    func testInitPreservesRegionVariant() {
        XCTAssertEqual(LearningLanguage(bcp47: "en-GB").bcp47, "en-GB")
        XCTAssertEqual(LearningLanguage(bcp47: "en-GB").primaryTag, "en")
    }

    /// ② 裸主标签。
    func testResolvingBarePrimaryTag() throws {
        XCTAssertEqual(try XCTUnwrap(LearningLanguage.resolving("en")).primaryTag, "en")
    }

    /// ③ 语言全名（调用方常常传 `English` 这种名字）。
    func testResolvingLanguageName() throws {
        let language = try XCTUnwrap(LearningLanguage.resolving("English"))
        XCTAssertEqual(language.primaryTag, "en")
        XCTAssertEqual(language.serviceName, "English")
    }

    /// ④ 音色 id：`zh-CN-XiaoxiaoNeural` 要能认出主标签 `zh`。
    func testResolvingVoiceIdentifier() throws {
        let language = try XCTUnwrap(LearningLanguage.resolving("zh-CN-XiaoxiaoNeural"))
        XCTAssertEqual(language.primaryTag, "zh")
        XCTAssertEqual(language.serviceName, "Chinese")
    }

    /// ⑤ 下划线写法归一成短横线。
    func testResolvingUnderscoreVariant() throws {
        XCTAssertEqual(try XCTUnwrap(LearningLanguage.resolving("zh_HK")).primaryTag, "zh")
    }

    /// ⑥ 大小写不敏感、外面带空白也要认。
    func testResolvingIsCaseInsensitiveAndTrims() throws {
        XCTAssertEqual(try XCTUnwrap(LearningLanguage.resolving("  EN-us ")).primaryTag, "en")
    }

    /// 认不出来的语言名返回 nil（不猜，也不过滤掉用户的选择）。
    func testResolvingUnknownNameReturnsNil() {
        XCTAssertNil(LearningLanguage.resolving("Klingon"))
    }

    func testResolvingBlankReturnsNil() {
        XCTAssertNil(LearningLanguage.resolving(""))
        XCTAssertNil(LearningLanguage.resolving("   "))
        XCTAssertNil(LearningLanguage.resolving(nil))
    }

    /// ⚠️ 关键回归：`xx` 是**未知的两字母语言代码**，必须原样保留，
    /// 绝不能被当成语言名去查表而悄悄别名成 `en`（那会让一个配错的语言静默变成英语）。
    func testResolvingUnknownCodeIsNotAliasedToEnglish() throws {
        let language = try XCTUnwrap(LearningLanguage.resolving("xx"))
        XCTAssertEqual(language.primaryTag, "xx")
        XCTAssertNotEqual(language.serviceName, "English")
    }
}
