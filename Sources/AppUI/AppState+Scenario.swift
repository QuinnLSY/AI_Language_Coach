import AIDomain
import AIServices
import AppCore
import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - AppState · 情景对话 + 练习生命周期
// #267 自 AppState.swift 拆出（2026-09-20）：单文件 5136 行超载，按域切为扩展。
// 同模块 extension，语义与拆分前完全一致；成员访问级别已放宽到 internal。
extension AppState {
    // MARK: - 情景对话（Role Play，第 21 步）

    /// 进行中的情景（nil = 普通练习）。UI 只读。
    public var activeScenario: ScenarioProgress? { chat.scenarioProgress }

    /// 打开情景选择浮层（顺手加载场景列表）。
    ///
    /// 考卷与情景在同一张面板上，所以在这里一起加载 —— 分开加载会出现
    /// 「面板开了、考试那一段是空的」，而那正是资源读取失败时最难分辨的样子。
    public func openScenarios() async {
        await loadScenarios()
        await loadExamBlueprints()
        await loadMaterialKits()
        applySection(.scenarios)
    }

    public func closeScenarios() {
        showingScenarios = false
    }

    /// 加载用户材料（生成 / 删除之后由对应方法刷新，这里只在开面板时取一次）。
    public func loadMaterialKits() async {
        materialKits = await services.availableMaterials()
    }

    // MARK: 上传材料自动出题（#208）

    /// 打开「上传材料」浮层（材料列表顺带刷新）。
    public func openMaterialUpload() async {
        await loadMaterialKits()
        showingMaterialUpload = true
    }

    public func closeMaterialUpload() {
        showingMaterialUpload = false
        materialResult = nil
        lastGeneratedKit = nil
    }

    public func dismissMaterialResult() {
        materialResult = nil
    }

    /// 从文件导入材料正文（只认 txt / md；读不出来如实报错）。
    public func importMaterialFile(at path: String) {
        let ext = (path as NSString).pathExtension.lowercased()
        guard ["txt", "md"].contains(ext) else {
            materialResult = "只支持 txt / md 文本文件。"
            return
        }
        guard let content = try? String(contentsOfFile: path, encoding: .utf8), !content.isEmpty else {
            materialResult = "这个文件读不出文字内容（可能是空文件或编码不支持）。"
            return
        }
        materialDraft = MaterialKitRule.sanitized(content)
        materialResult = nil
    }

    /// 生成材料练习：一次生成 = 一次模型请求；成功后材料卡立即出现在面板「我的材料」分区。
    public func generateMaterialFromDraft() async {
        guard !isGeneratingMaterial else { return }
        materialResult = nil
        lastGeneratedKit = nil
        isGeneratingMaterial = true
        defer { isGeneratingMaterial = false }
        do {
            let kit = try await services.generateMaterialKit(from: materialDraft)
            lastGeneratedKit = kit
            await loadMaterialKits()
            materialResult = "拆好了：「\(kit.scenario?.titleZh ?? kit.title)」＋ \(kit.drills.count) 句跟读 ＋ \(kit.words.count) 个生词（生词已收进词汇本）。"
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            materialResult = reason
        }
    }

    /// 删除一份材料（已加进词汇本的词不回收——那已经是学员的词了）。
    public func deleteMaterialKit(id: String) async {
        await services.deleteMaterial(id: id)
        await loadMaterialKits()
    }

    /// 开始练材料拆出的情景（与内置情景同一条练习链路）。
    public func startMaterialScenario(_ kit: MaterialKit) async {
        guard let scenario = kit.scenario else { return }
        await startScenario(scenario)
    }

    /// 拿材料的跟读句去跟读页练（覆盖当批素材；重新打开跟读页恢复每日 20 句）。
    public func useMaterialDrills(_ kit: MaterialKit) {
        guard !kit.drills.isEmpty else { return }
        shadowingDrills = kit.drills
        shadowingIsDailyGenerated = false
        shadowingNotice = "正在练材料「\(kit.scenario?.titleZh ?? kit.title)」的 \(kit.drills.count) 句。"
        resetShadowingProgress()
        Task { await openShadowing() }
    }

    /// 加载内置场景（只读资源文件；失败时保持空列表，由 UI 提示）。
    public func loadScenarios() async {
        guard !didLoadScenarios else { return }
        scenarios = await services.availableScenarios()
        // 绑定表与情景一起加载：课程阶梯要把关卡挂到档上，缺了它只能显示「未挂关」。
        levelBindings = await services.levelBindings()
        didLoadScenarios = true
    }

    // MARK: - 练习生命周期（需求 3 / 4 / 5 / 6）

    /// 刷新主线任务进度缓存（情景卡片与大树节点用；避免每帧查库）。
    public func refreshQuestRecords() async {
        questRecords = await services.allQuestProgress()
    }

    /// 某情景的主线任务进度（没有记录时给一份「从零开始」的进度，界面不用判空）。
    public func questProgress(for scenario: Scenario) -> QuestProgress {
        ScenarioQuestRule.progress(
            plan: scenario.questPlan,
            utterances: [],
            alreadyDone: questRecords[scenario.id]?.doneStepSet ?? []
        )
    }

    /// 某情景对应的大树关卡（没绑定返回 nil）。
    /// **情景 ↔ 大树联动的唯一取数点**：情景卡片与树节点都走这里，两边不可能各说各的。
    public func boundLevel(for scenario: Scenario) -> TreeLevel? {
        progress.levels.first { $0.scenarioID == scenario.id }
    }

    /// 大树节点上的「情景 + 主线任务进度」说明（需求 2：情景与大树一眼看出关系）。
    ///
    /// 在 `AppState` 算而不是在树里算：树是纯渲染层，让它自己去查情景、跑任务进度，
    /// 就会出现「树上算一遍、情景卡片再算一遍」的两处真相。
    public var treeLevelNotes: [String: TreeLevelNote] {
        var notes: [String: TreeLevelNote] = [:]
        for level in progress.levels {
            guard let scenarioID = level.scenarioID,
                  let scenario = scenario(for: scenarioID)
            else { continue }
            let quest = questProgress(for: scenario)
            notes[level.id] = TreeLevelNote(
                scenarioTitle: scenario.titleZh,
                questSummary: quest.total > 0 ? "主线 \(quest.doneCount)/\(quest.total)" : ""
            )
        }
        return notes
    }

    /// 情景卡片展开/收起（需求 3：点卡片先展开信息，不直接进练习）。
    public func toggleScenarioExpansion(_ scenarioID: String) {
        expandedScenarioID = expandedScenarioID == scenarioID ? nil : scenarioID
    }

    /// 进入某个情景：**先自动复盘上一段练习并清掉流水**，再带着「前情提要」进任务。
    ///
    /// 与以前「点卡片直接开始」的区别（需求 3）：卡片只负责展开信息，
    /// 真正的开始由卡片里的「开始任务」按钮触发；进来以后先讲前情提要，再开始当前任务。
    public func startScenario(_ scenario: Scenario) async {
        applySection(.practice)
        // 换到别的事上 = 这场考试结束了（报告也不再挂着）：考卷状态留着只会
        // 让下一段对话继续按考官口径说话。
        clearExamState()
        chat.endExam()
        if product.practiceMode != .conversation {
            product.practiceMode = .conversation
            await persistProduct()
        }
        // 上一局的判定先收起来：新的一局开始，旧卡片的覆盖率就是错的数据。
        assessmentDismissTask?.cancel()
        assessmentDismissTask = nil
        lastAssessment = nil
        lastAssessedScenarioID = nil
        expandedScenarioID = nil

        // 已经在练同一个情景：直接续做，**不重开** ——
        // 否则「展开卡片看一眼 → 再点开始任务」就会把刚才说的都清掉。
        if chat.scenarioProgress?.scenario.id == scenario.id {
            await prepareBriefing(for: scenario)
            return
        }
        await concludeCurrentPractice()
        // 学员主动点卡片换情景：这一段是他要结束的，允许覆盖「本段已有内容」的守卫。
        chat.beginNewSession(allowWhenSessionHasContent: true)
        await beginScenario(scenario)
    }

    /// 开始（或续做）一个情景任务：备好前情提要，交给老师说第一句。
    public func beginScenario(_ scenario: Scenario) async {
        // 已通关的这一关再进来 = 重练：「主线任务从头走一遍」，
        // 否则进度条一进来就是满的，学员无事可做。
        if let record = await services.questProgress(scenarioID: scenario.id), record.isComplete {
            await services.clearQuestProgress(scenarioID: scenario.id)
        }
        guard let built = await prepareBriefing(for: scenario) else { return }
        chat.startScenario(scenario, briefing: built)
        chat.deliverOpener()
    }

    /// 组装前情提要（本地读库 + 纯函数，不发请求）并同步给对话服务。
    @discardableResult
    func prepareBriefing(for scenario: Scenario) async -> ScenarioBriefing? {
        var built = await services.scenarioBriefing(for: scenario)
        // 续做时把本局已经说过的话也算进去：界面上的进度条与老师看到的必须是同一份。
        if chat.scenarioProgress?.scenario.id == scenario.id {
            built = built.refreshed(utterances: chat.scenarioLearnerUtterances)
        }
        briefing = built
        chat.applyBriefing(built)
        await refreshQuestRecords()
        return built
    }

    /// 「开启新练习」（需求 4）：先复盘并清掉上一段，再进随口练。
    ///
    /// 与情景对话的区别：随口练**学员主导**，老师少引导、多建议与纠错；
    /// 所以这里不建主线任务、不讲前情提要，只把话头递出去。
    public func startFreeTalk() async {
        applySection(.practice)
        clearExamState()
        chat.endExam()
        assessmentDismissTask?.cancel()
        assessmentDismissTask = nil
        lastAssessment = nil
        lastAssessedScenarioID = nil
        expandedScenarioID = nil

        let previous = await concludeCurrentPractice()
        // 学员主动开一段随口练：允许覆盖「本段已有内容」的守卫。
        chat.beginNewSession(allowWhenSessionHasContent: true)
        if product.practiceMode != .freeTalk {
            product.practiceMode = .freeTalk
            await persistProduct()
        }
        briefing = nil
        chat.beginFreeTalk(review: previous ?? latestReview)
        chat.deliverOpener()
    }

}
