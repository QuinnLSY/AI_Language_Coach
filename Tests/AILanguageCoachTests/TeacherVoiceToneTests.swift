import AIDomain
import AppCore
import XCTest

/// ② 朗读语气的**控件取舍**纯函数。
///
/// 这个纯函数存在的全部理由就是「真机上永远走空分支」：今天四条语音链路没有一条
/// 提供风格 / 情感字段位，所以设置页那一段恒不渲染 —— 把它写在视图里就等于
/// 一段只有供应商改协议那天才会被执行的代码，此前没人验证过它。纯函数用例
/// 是唯一能现在就把「供应商一支持就亮」这条路走通的地方。
final class TeacherVoiceToneTests: XCTestCase {

    private func controls(
        options: [VoiceCapability: [String]],
        style: String = "",
        emotion: String = ""
    ) -> [TeacherVoiceTone.Control] {
        TeacherVoiceTone.controls(options: options, selectedStyle: style, selectedEmotion: emotion)
    }

    /// 一个能力都没有 → 一个控件都不该出现（不是出现一个空的下拉）。
    func testNoOptionsMeansNoControls() {
        XCTAssertTrue(controls(options: [:]).isEmpty)
    }

    /// 只声明了风格 → 只出现风格那一行，不能顺手把情感的也画出来。
    func testOnlyDeclaredCapabilityAppears() {
        let result = controls(options: [.style: ["cheerful", "sad"]])
        XCTAssertEqual(result.map(\.capability), [.style])
        XCTAssertEqual(result.first?.title, "朗读风格")
    }

    /// 顺序固定「风格 → 情感」。
    ///
    /// ⚠️ 反证：改成遍历传入字典，同一份配置两次打开设置可能排出不同次序 ——
    /// 画面看起来像「设置页自己在动」，而每次都能对上一点，最难被当成 bug 报。
    func testDisplayOrderIsStableRegardlessOfDictionaryOrder() {
        let emotionFirst: [VoiceCapability: [String]] = [.emotion: ["calm"], .style: ["cheerful"]]
        XCTAssertEqual(controls(options: emotionFirst).map(\.capability), [.style, .emotion])
        // 再来一遍，次序必须完全一样。
        XCTAssertEqual(controls(options: emotionFirst).map(\.capability), [.style, .emotion])
    }

    /// 候选值全空白 = 供应商给了个空表，等于没给 → 不渲染该控件。
    func testBlankOptionsAreNotARealOption() {
        XCTAssertTrue(controls(options: [.style: ["   ", "\n"]]).isEmpty)
        // 空白项要逐项剔掉，不能把「有一个空白项」当成「有候选值」。
        let mixed = controls(options: [.style: ["cheerful", " ", "\t"]])
        XCTAssertEqual(mixed.first?.options, ["cheerful"])
    }

    /// 「不指定」的取值与配置里「没选」是同一个值 —— 不另造哨兵。
    func testUnspecifiedIsTheEmptyString() {
        XCTAssertEqual(TeacherVoiceTone.unspecified, "")
    }

    func testSelectedValueIsKeptWhenItIsARealOption() {
        let result = controls(options: [.style: ["cheerful", "sad"]], style: "sad")
        XCTAssertEqual(result.first?.selected, "sad")
    }

    /// ⚠️ 选中值必须**真在候选表里**：换了供应商之后旧取值可能已不存在。
    ///
    /// 反证：去掉这道过滤，下拉会显示一个候选表里根本没有的值 ——
    /// 用户看到的列表与控件显示的值对不上，且怎么点都「选不回去」，
    /// 看起来像控件坏了，实际是两边用的是两份事实。
    func testSelectedValueNotInOptionsFallsBackToUnselected() {
        let result = controls(options: [.style: ["sad"]], style: "cheerful")
        XCTAssertNil(result.first?.selected)
    }

    /// 空串选中值 = 没选（与 `unspecified` 同源），不当成「选中了一个叫空串的选项」。
    func testEmptySelectionIsTreatedAsUnselected() {
        XCTAssertNil(controls(options: [.style: ["cheerful"]], style: "").first?.selected)
    }

    /// 两个能力各自取自己那一份选中值 —— 不能串台。
    func testSelectionsDoNotCrossCapabilities() {
        let result = controls(
            options: [.style: ["cheerful"], .emotion: ["calm"]],
            style: "cheerful",
            emotion: ""
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].selected, "cheerful")
        XCTAssertNil(result[1].selected)
    }

    /// 控件 id 用能力标识 —— `ForEach` 靠它区分「哪一行」，用标题或下标都会在
    /// 候选值变化时错位复用视图。
    func testControlIdentityIsTheCapability() {
        let result = controls(options: [.style: ["a"], .emotion: ["b"]])
        XCTAssertEqual(result.map(\.id), [VoiceCapability.style.rawValue, VoiceCapability.emotion.rawValue])
    }

    /// 两条候选共用一个标题表，标题必须与能力对得上。
    func testTitlesMatchCapabilities() {
        let result = controls(options: [.style: ["a"], .emotion: ["b"]])
        XCTAssertEqual(result.map(\.title), ["朗读风格", "朗读情感"])
        XCTAssertTrue(result.allSatisfy { $0.help == TeacherVoiceTone.optionHelp })
    }

    /// 提示必须说清「取值由供应商定义」，否则用户会把它当应用功能缺失来报。
    func testHelpExplainsTheValuesComeFromTheSupplier() {
        XCTAssertTrue(TeacherVoiceTone.optionHelp.contains("供应商"))
        XCTAssertTrue(TeacherVoiceTone.optionHelp.contains("不指定"))
    }

    /// 不参与语气的两个能力（克隆 / 音高原生）**不该**出现在控件里 ——
    /// 它们各有自己的入口与实现路径，混进来就是两处真假源。
    func testCloningAndPitchNeverBecomeToneControls() {
        let result = controls(options: [
            .voiceCloning: ["x"],
            .pitchControl: ["y"],
            .style: ["cheerful"],
        ])
        XCTAssertEqual(result.map(\.capability), [.style])
    }
}
