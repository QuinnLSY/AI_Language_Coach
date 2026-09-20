import AIDomain
import AIInfrastructure
import AIServices
import XCTest

/// 老师人格档位（教学风格）。
///
/// 这里钉住三件事：
/// 1. **档位是参数的唯一来源** —— 回复长度 / 纠错强度 / 母语提示都由它推导，
///    不存在「档位说温和、强度存着严格」这种组合；
/// 2. **情景内只推一档** —— 场景自带的 `correctionMode` 是设计意图，不被整档覆盖；
/// 3. **标准档不改变既有行为** —— 默认配置下 Prompt 与决策结果与加档位之前一致。
final class TeacherPersonaTests: XCTestCase {

    // MARK: - 档位推导出的参数

    func testTiersDeriveTheirOwnParameters() {
        XCTAssertEqual(TeacherPersona.warm.responseLength, .brief)
        XCTAssertEqual(TeacherPersona.standard.responseLength, .normal)
        XCTAssertEqual(TeacherPersona.strict.responseLength, .detailed)

        XCTAssertEqual(TeacherPersona.warm.correctionStyle, .gentle)
        XCTAssertEqual(TeacherPersona.standard.correctionStyle, .balanced)
        XCTAssertEqual(TeacherPersona.strict.correctionStyle, .strict)

        XCTAssertTrue(TeacherPersona.warm.allowsNativeLanguageHints)
        XCTAssertTrue(TeacherPersona.standard.allowsNativeLanguageHints)
        XCTAssertFalse(TeacherPersona.strict.allowsNativeLanguageHints, "严格档的卖点就是尽量泡在英语里")
    }

    /// `TeacherPreference` 只存档位 —— 参数是算出来的，不是各存一份。
    func testPreferenceDerivesEverythingFromPersona() {
        let strict = TeacherPreference(persona: .strict)
        XCTAssertEqual(strict.responseLength, .detailed)
        XCTAssertEqual(strict.correctionStyle, .strict)
        XCTAssertFalse(strict.allowsNativeLanguageHints)

        XCTAssertEqual(TeacherPreference.standard, TeacherPreference(persona: .standard))
        XCTAssertEqual(TeacherPreference.standard.correctionStyle, .balanced)
    }

    // MARK: - 情景基线上的偏移

    func testScenarioBaselineShiftsAtMostOneNotch() {
        // 标准档 = 恒等（这正是「加档位不改变既有行为」的实现方式）
        for baseline in CorrectionIntensity.allCases {
            XCTAssertEqual(TeacherPersona.standard.shifted(baseline), baseline, "标准档不该偏移 \(baseline)")
        }
        // 严格档升一档，顶到 strict 就停
        XCTAssertEqual(TeacherPersona.strict.shifted(.gentle), .balanced)
        XCTAssertEqual(TeacherPersona.strict.shifted(.balanced), .strict)
        XCTAssertEqual(TeacherPersona.strict.shifted(.strict), .strict, "已经最严了不能溢出")
        // 温和档降一档，退到 gentle 就停
        XCTAssertEqual(TeacherPersona.warm.shifted(.strict), .balanced)
        XCTAssertEqual(TeacherPersona.warm.shifted(.balanced), .gentle)
        XCTAssertEqual(TeacherPersona.warm.shifted(.gentle), .gentle, "已经最温和了不能溢出")
    }

    // MARK: - 决策层接线

    private func decide(
        persona: TeacherPersona,
        proficiency: LearnerProfile.Proficiency = .intermediate,
        scenarioCorrection: ScenarioCorrectionMode? = nil,
        memory: LearningMemory = .empty
    ) -> TeacherDecision {
        let context = ConversationContext(
            scenario: scenarioCorrection.map {
                ScenarioFocus(id: "s", title: "S", correctionMode: $0, turnsRemaining: 5)
            },
            teacherPreference: TeacherPreference(persona: persona)
        )
        return TeacherAgent.decide(
            TeacherAgent.Input(
                profile: LearnerProfile(proficiency: proficiency),
                context: context,
                learnerText: "I go to school yesterday.",
                grammar: nil,
                memory: memory
            )
        )
    }

    /// 情景外：档位直接决定强度。
    func testPersonaDrivesIntensityOutsideScenario() {
        XCTAssertEqual(decide(persona: .warm).correctionLevel, .gentle)
        XCTAssertEqual(decide(persona: .standard).correctionLevel, .balanced)
        XCTAssertEqual(decide(persona: .strict).correctionLevel, .strict)
    }

    /// 情景内：场景强度是基线，档位只推一档。
    func testScenarioKeepsBaselineAndPersonaOnlyNudges() {
        XCTAssertEqual(decide(persona: .standard, scenarioCorrection: .balanced).correctionLevel, .balanced,
                       "标准档 + 情景 = 与加档位之前完全一致")
        XCTAssertEqual(decide(persona: .strict, scenarioCorrection: .balanced).correctionLevel, .strict)
        XCTAssertEqual(decide(persona: .warm, scenarioCorrection: .balanced).correctionLevel, .gentle)
        XCTAssertEqual(decide(persona: .warm, scenarioCorrection: .gentle).correctionLevel, .gentle)
        XCTAssertEqual(decide(persona: .strict, scenarioCorrection: .strict).correctionLevel, .strict)
    }

    /// 情景内仍然不受学员水平影响（既有铁律），档位也不该把它拉回来。
    func testProficiencyStillIgnoredInsideScenario() {
        XCTAssertEqual(
            decide(persona: .standard, proficiency: .beginner, scenarioCorrection: .strict).correctionLevel,
            .strict
        )
        XCTAssertEqual(
            decide(persona: .strict, proficiency: .beginner, scenarioCorrection: .balanced).correctionLevel,
            .strict,
            "档位是用户明选的，不该被「萌新」这个推断压低"
        )
    }

    /// 情景外：**只有标准档**才做学员水平校准。
    ///
    /// 用户明选过档位时，档位说了算 —— 一个选了「严格纠错」的人因为被推断成萌新
    /// 就再也没被纠过错，在他眼里就是「这个设置坏了」。明选优先于推断。
    func testProficiencyCalibrationOnlyAppliesToStandardPersona() {
        // 标准档：与加档位之前的行为逐字一致（萌新更松、熟练更严）
        XCTAssertEqual(decide(persona: .standard, proficiency: .beginner).correctionLevel, .gentle)
        XCTAssertEqual(decide(persona: .standard, proficiency: .intermediate).correctionLevel, .balanced)
        XCTAssertEqual(decide(persona: .standard, proficiency: .advanced).correctionLevel, .strict)

        // 明选档位：任何水平都听档位的
        for proficiency in LearnerProfile.Proficiency.allCases {
            XCTAssertEqual(decide(persona: .warm, proficiency: proficiency).correctionLevel, .gentle,
                           "温和档不该被 \(proficiency) 推严")
            XCTAssertEqual(decide(persona: .strict, proficiency: proficiency).correctionLevel, .strict,
                           "严格档不该被 \(proficiency) 推松")
        }
    }

    /// 反复错误仍会把强度顶上去 —— 这条链路没有被档位改掉。
    func testRecurringErrorsStillIntensify() {
        let memory = LearningMemory(recurringErrors: [
            RecurringError(original: "I go", corrected: "I went", explanation: "", count: 3, lastSeen: Date())
        ])
        XCTAssertEqual(decide(persona: .warm, memory: memory).correctionLevel, .balanced,
                       "温和档也该对反复犯的错提一档")
    }

    // MARK: - Prompt 注入

    private func block(_ persona: TeacherPersona) -> String {
        PromptBuilder.teacherPersonaBlock(persona, learningLanguage: "en-US", nativeLanguage: "zh-CN")
    }

    func testStandardPersonaInjectsNothing() {
        XCTAssertEqual(block(.standard), "", "默认档不注入 —— 否则默认配置的提示词会与加档位之前不一样")
    }

    func testNonStandardPersonaInjectsItsStyleAndClaimsPrecedence() {
        for persona in [TeacherPersona.warm, .strict] {
            let text = block(persona)
            XCTAssertTrue(text.contains(persona.promptLabel), "\(persona) 的块要带上档位名")
            XCTAssertTrue(text.contains(persona.instruction), "\(persona) 的块要带上风格指令")
            XCTAssertTrue(text.contains("follow this style instead"),
                          "必须声明优先级：基础人设写着「回复 2–4 句」「要鼓励」，不声明覆盖就形同虚设")
            XCTAssertFalse(text.contains("{"), "占位符必须全部替换（空行也要压掉）")
        }
    }

    /// `allowsNativeLanguageHints == false` 要真的落到 Prompt 上 —— 否则它就是我
    /// 自己批评过的「推导出来却没人消费」的死参数。而且必须给出替代动作。
    func testStrictPersonaBansNativeLanguageWithAnAlternative() {
        let strict = block(.strict)
        XCTAssertFalse(TeacherPersona.strict.allowsNativeLanguageHints)
        XCTAssertTrue(strict.contains("Stay in en-US"), "严格档要显式要求留在目标语")
        XCTAssertTrue(strict.contains("more simply"), "禁母语必须给出替代动作，否则学员卡住时老师没路可走")

        let warm = block(.warm)
        XCTAssertTrue(TeacherPersona.warm.allowsNativeLanguageHints)
        XCTAssertFalse(warm.contains("Stay in"), "温和档不该收紧母语兜底")
    }

    func testTiersAreDistinctInPrompt() {
        let labels = Set(TeacherPersona.allCases.map(\.promptLabel))
        XCTAssertEqual(labels.count, TeacherPersona.allCases.count, "三档的 Prompt 名不能重复")
        let instructions = Set(TeacherPersona.allCases.map(\.instruction))
        XCTAssertEqual(instructions.count, TeacherPersona.allCases.count, "三档的指令不能重复")
        XCTAssertTrue(TeacherPersona.allCases.allSatisfy { !$0.instruction.isEmpty })
        XCTAssertTrue(TeacherPersona.allCases.allSatisfy { !$0.summary.isEmpty })

        // 下拉里显示的就是 displayName：重名会让用户「选了半天其实没换」。
        let names = Set(TeacherPersona.allCases.map(\.displayName))
        XCTAssertEqual(names.count, TeacherPersona.allCases.count, "三档的显示名不能重复")
    }

    /// 严格档「讲得更细」必须给出新的句数上限，否则会被基础人设的「2–4 句」吃掉。
    func testStrictInstructionOverridesReplyLengthCap() {
        XCTAssertTrue(TeacherPersona.strict.instruction.contains("5 sentences"),
                      "严格档要显式放宽句数上限，否则基础人设的「2 to 4 sentences」更靠前、更难被推翻")
    }

    // MARK: - 引擎接线

    @MainActor
    func testEngineSyncsPreferenceBeforePlanning() {
        let engine = ConversationEngine()
        XCTAssertEqual(engine.context.teacherPreference.persona, .standard)

        engine.syncPreference(.strict)
        XCTAssertEqual(engine.context.teacherPreference.persona, .strict)
        XCTAssertEqual(engine.context.teacherPreference.correctionStyle, .strict)

        engine.syncPreference(.warm)
        XCTAssertEqual(engine.context.teacherPreference.persona, .warm)
    }
}
