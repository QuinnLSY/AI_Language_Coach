import XCTest

/// #664：大类拆分的**结构哨兵**。
///
/// #660–#663 把四个超载文件按域 / 主题拆成「主体 + 扩展」：
/// - `CoachServices`（#660）：3165 行单 actor → 248 行主体 + 17 个扩展
/// - `TreeCanvas`（#661）：→ 550 行主体 + 3 个扩展
/// - `SettingsView`（#662）：3227 行 → 233 行主体 + 10 个扩展
/// - `ChatView`（#663）：2896 行 → 575 行主体 + 10 个扩展
///
/// 纯移动拆分**不产生任何可测的行为差异**（同模块 extension，符号与语义逐字不变），
/// 所以编译、单测、渲染回归一律照绿 —— 唯一能守住成果的就是结构哨兵。三条判据：
///
/// 1. **行数预算**：任何单个源文件都不许再长回巨石（主体 ≤ 700、扩展 ≤ 600）；
/// 2. **扩展在位**：拆出来的文件不许被删、也不许被搬空后留成空壳；
/// 3. **主体不回收**：每个扩展钉一条**代表定义行**，它不许出现在主体文件里 ——
///    同时这条锚点必须还在家族里（锚点自己失踪也判红，防「锚点烂掉 = 永远绿」的假闸）。
///
/// ⚠️ 判据 3 的锚点是**硬编码**的，不是从扩展文件里现算的：现算的话，把某段搬回主体
/// 只会让锚点从扩展文件里消失，负面断言照样绿（#664 设计时的取舍）。代价是重命名
/// 要同步改锚点 —— 这正是「拆分结构被认可为一件事」的代价，值得。
final class SplitStructureTests: XCTestCase {

    // MARK: - 预算

    /// 主体文件的行数上限（当前最大 `ChatView.swift` 575 行 → 约 20% 余量）。
    private static let mainFileBudget = 700

    /// 单个扩展文件的行数上限（当前最大 `CoachServices+ModelLifecycle.swift` 462 行）。
    private static let extensionFileBudget = 600

    /// 扩展文件不算空壳的行数下限（当前最小 `CoachServices+Exam.swift` 63 行）。
    private static let extensionFloor = 30

    // MARK: - 家族声明

    private struct Family {
        let directory: String
        let prefix: String
        let mainFile: String
        /// 扩展文件名 → 代表定义行（判据 3 的锚点）。
        let extensions: [(file: String, anchor: String)]

        var mainPath: String { "\(directory)/\(mainFile)" }
    }

    private static let families: [Family] = [
        Family(
            directory: "Sources/AIServices",
            prefix: "CoachServices",
            mainFile: "CoachServices.swift",
            extensions: [
                ("CoachServices+Bootstrap.swift", "public func bootstrapLLM() async throws {"),
                ("CoachServices+Chat.swift", "public func importAttachment(from url: URL) async throws -> ChatAttachment {"),
                ("CoachServices+Course.swift", "public func generateCourse(_ request: CourseRequest) async throws -> CourseBlueprint {"),
                ("CoachServices+Diagnostics.swift", "public func llmHealth() async -> ProviderHealth {"),
                ("CoachServices+Dictionary.swift", "public func dictionarySearch(_ query: String) async -> [DictionaryWord] {"),
                ("CoachServices+Exam.swift", "public func examBlueprints() async -> [ExamBlueprint] {"),
                ("CoachServices+LearningMemory.swift", "public func clearLearningMemory() async throws -> MemoryClearance {"),
                ("CoachServices+Maintenance.swift", "public func cacheSnapshot() async -> CacheSnapshot {"),
                ("CoachServices+ModelLifecycle.swift", "public func isModelRunning(_ kind: AIProviderKind) -> Bool {"),
                ("CoachServices+ModelRegistry.swift", "public func healthTarget(for kind: AIProviderKind) async -> HealthTarget? {"),
                ("CoachServices+Progress.swift", "public func loadProgress() async -> LearnerProgress {"),
                ("CoachServices+Scenarios.swift", "public func availableScenarios() -> [Scenario] {"),
                ("CoachServices+Sessions.swift", "public var isPersistenceAvailable: Bool { learning != nil }"),
                ("CoachServices+Shadowing.swift", "public func shadowingDailyDrills(day: String? = nil) async throws -> [ShadowingDrill] {"),
                ("CoachServices+Vocabulary.swift", "public func importVocabularyFromReviews() async -> Int {"),
                ("CoachServices+VoiceCloning.swift", "public func ttsSupportsVoiceCloning() async -> Bool {"),
                ("CoachServices+Writing.swift", "public func reviewWriting(topic: WritingTopic, essay: String) async -> WritingReview? {"),
            ]
        ),
        Family(
            directory: "Sources/AppUI/Components",
            prefix: "TreeCanvas",
            mainFile: "TreeCanvas.swift",
            extensions: [
                ("TreeCanvas+AnnualRings.swift", "public struct TreeAnnualSummary: Sendable, Equatable {"),
                ("TreeCanvas+Events.swift", "struct LeafFallLayer: View {"),
                ("TreeCanvas+LevelNode.swift", "struct LevelNode: View {"),
            ]
        ),
        Family(
            directory: "Sources/AppUI/Views",
            prefix: "ChatView",
            mainFile: "ChatView.swift",
            extensions: [
                ("ChatView+Banners.swift", "func modelStoppedBanner(_ message: String) -> some View {"),
                ("ChatView+Briefing.swift", "func briefingStrip(_ briefing: ScenarioBriefing) -> some View {"),
                ("ChatView+Bubbles.swift", "func bubble(_ message: ChatMessage) -> some View {"),
                ("ChatView+Composer.swift", "var composer: some View {"),
                ("ChatView+ComposerInfo.swift", "func send() {"),
                ("ChatView+Header.swift", "var header: some View {"),
                ("ChatView+InputField.swift", "var inputField: some View {"),
                ("ChatView+Messages.swift", "var messageArea: some View {"),
                ("ChatView+Panels.swift", "struct ThinkingPanel: View {"),
                ("ChatView+Translation.swift", "func correctionCard(_ correction: GrammarCorrection) -> some View {"),
            ]
        ),
        Family(
            directory: "Sources/AppUI/Views",
            prefix: "SettingsView",
            mainFile: "SettingsView.swift",
            extensions: [
                ("SettingsView+Advanced.swift", "var shortcutCenterCard: some View {"),
                ("SettingsView+Appearance.swift", "var headerBar: some View {"),
                ("SettingsView+Cache.swift", "var cacheCard: some View {"),
                ("SettingsView+Learning.swift", "var learningCard: some View {"),
                ("SettingsView+Models.swift", "var modelCard: some View {"),
                ("SettingsView+Partner.swift", "var partnerCard: some View {"),
                ("SettingsView+Privacy.swift", "var privacyCard: some View {"),
                ("SettingsView+Runtime.swift", "var runtimeCard: some View {"),
                ("SettingsView+VoiceCenter.swift", "var voiceModelCenterCard: some View {"),
                ("SettingsView+VoiceCloning.swift", "var clonedVoiceControls: some View {"),
            ]
        ),
    ]

    // MARK: - 工具

    private nonisolated static func lineCount(of text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// 家族全部源文件（按文件名排序，顺序确定）。
    private nonisolated static func scannedFiles(_ family: Family) throws -> [(name: String, text: String)] {
        let names = try FileManager.default.contentsOfDirectory(atPath: family.directory)
            .filter { $0.hasSuffix(".swift") && $0.hasPrefix(family.prefix) }
            .sorted()
        XCTAssertFalse(names.isEmpty, "\(family.directory) 下没有 \(family.prefix)*.swift")
        return try names.map { ($0, try String(contentsOfFile: "\(family.directory)/\($0)", encoding: .utf8)) }
    }

    // MARK: - 判据 1：行数预算

    /// 拆完就不许再长回去：家族里任何单个文件超预算 = 有人把东西堆回去了。
    func testEverySplitFileStaysWithinLineBudget() throws {
        for family in Self.families {
            for (name, text) in try Self.scannedFiles(family) {
                let lines = Self.lineCount(of: text)
                let budget = name == family.mainFile ? Self.mainFileBudget : Self.extensionFileBudget
                XCTAssertLessThanOrEqual(
                    lines, budget,
                    "\(family.directory)/\(name) 已 \(lines) 行（预算 \(budget)）：拆分成果正在被重新堆回去"
                )
            }
        }
    }

    // MARK: - 判据 2：扩展在位

    /// 拆出来的文件必须在、且不是空壳 —— 被并回主体后留一个只剩 import 的文件也算回退。
    func testDeclaredExtensionFilesAreInPlace() throws {
        for family in Self.families {
            let onDisk = Set(try Self.scannedFiles(family).map(\.name))
            for ext in family.extensions {
                guard onDisk.contains(ext.file) else {
                    XCTFail("\(family.directory)/\(ext.file) 不在了：扩展被删或被改名，拆出去的东西回哪去了？")
                    continue
                }
                let text = try String(contentsOfFile: "\(family.directory)/\(ext.file)", encoding: .utf8)
                XCTAssertGreaterThanOrEqual(
                    Self.lineCount(of: text), Self.extensionFloor,
                    "\(ext.file) 只剩 \(Self.lineCount(of: text)) 行，疑似被搬空后留下的空壳"
                )
            }
        }
    }

    // MARK: - 判据 3：主体不回收

    /// 每个扩展的代表定义行：必须在家族里（锚点还在）、且**不在**主体文件里（没被搬回去）。
    ///
    /// 两条一起钉 —— 只钉「主体里没有」的话，锚点因改名/搬走而消失时负面断言永远绿。
    func testMainFilesDoNotReabsorbMovedSections() throws {
        for family in Self.families {
            let familyText = try Self.scannedFiles(family).map(\.text).joined(separator: "\n")
            let mainText = try String(contentsOfFile: family.mainPath, encoding: .utf8)
            for ext in family.extensions {
                XCTAssertTrue(
                    familyText.contains(ext.anchor),
                    "锚点已失效：\(ext.file) 里找不到「\(ext.anchor)」，判据 3 会永远绿 —— 请更新锚点"
                )
                XCTAssertFalse(
                    mainText.contains(ext.anchor),
                    "\(ext.file) 的「\(ext.anchor)」被搬回 \(family.mainFile) 了：这段不该回主体"
                )
            }
        }
    }
}
