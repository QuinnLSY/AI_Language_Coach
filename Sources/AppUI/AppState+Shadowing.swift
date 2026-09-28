import AIDomain
import AIInterfaces
import AIServices
import AppCore
import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - AppState · 跟读（Shadowing）
// #267 自 AppState.swift 拆出（2026-09-20）：单文件 5136 行超载，按域切为扩展。
// 同模块 extension，语义与拆分前完全一致；成员访问级别已放宽到 internal。
extension AppState {
    // MARK: - 跟读（Shadowing，第 22 步）

    /// 进入跟读页：加载素材 + 刷新统计。
    public func openShadowing() async {
        applySection(.shadowing)
        await loadShadowing()
    }

    /// 当前要跟读的句子（素材为空时 nil）。
    public var currentShadowingDrill: ShadowingDrill? {
        guard shadowingDrills.indices.contains(shadowingIndex) else { return nil }
        return shadowingDrills[shadowingIndex]
    }

    // MARK: 每句的分析常驻（切页 / 跳句 / 重启都不丢）

    /// 分析缓存的键：`dayKey#drillID`。
    ///
    /// ⚠️ 必须带 `dayKey`：素材每天换一批，而生成 id 是 `daily-<主题序>-<句序>`，
    /// 跨天重号但句子不同 —— 不带 dayKey 会把昨天的分析挂到今天的同一序号上。
    static func shadowingAnalysisKey(day: String, drillID: String) -> String {
        "\(day)#\(drillID)"
    }

    /// 「练到第几句」的持久化键（存 `dayKey|index` 一行）。
    ///
    /// ⚠️ 存成一行 `dayKey|index` 而不是 `[dayKey: index]` 字典：
    /// 字典会**只增不减**地攒下每一天，而跨天的旧值一个字都用不上
    /// （素材都换了）。一行的话自己就会作废。
    static let shadowingProgressStorageKey = "shadowing.progress"

    static func storedShadowingIndex(day: String) -> Int? {
        guard let raw = UserDefaults.standard.string(forKey: shadowingProgressStorageKey) else { return nil }
        let parts = raw.split(separator: "|", maxSplits: 1)
        guard parts.count == 2, String(parts[0]) == day, let value = Int(parts[1]), value >= 0 else { return nil }
        return value
    }

    private func saveShadowingProgress() {
        UserDefaults.standard.set(
            "\(ShadowingDailyRule.dayKey())|\(shadowingIndex)",
            forKey: Self.shadowingProgressStorageKey
        )
    }

    /// 当前这一句的最近一次分析（没有 = 这一句还没读过）。
    public var currentShadowingResult: ShadowingResult? {
        guard let drill = currentShadowingDrill else { return nil }
        return shadowingAnalyses[
            Self.shadowingAnalysisKey(day: ShadowingDailyRule.dayKey(), drillID: drill.id)
        ]
    }

    /// 记下这一句的分析（内存缓存；界面据此常驻显示）。
    func rememberShadowingResult(_ result: ShadowingResult, drillID: String) {
        shadowingAnalyses[
            Self.shadowingAnalysisKey(day: ShadowingDailyRule.dayKey(), drillID: drillID)
        ] = result
    }

    /// 把当前这一句的**已有分析**摆回界面（没有就清空）。
    ///
    /// ⚠️ 换句时不能再无脑清空：清了就等于「这一句没读过」，
    /// 而用户要的恰恰是「跳回去还能看到刚才的结果」。
    func restoreShadowingResultForCurrentDrill() {
        let result = currentShadowingResult
        shadowingComparison = result?.comparison
        shadowingPronunciation = result?.pronunciation
    }

    /// 从库里把今天这批句子的**最近一次**分析补回内存（跨重启常驻）。
    ///
    /// 对比结果不另存一份：`ShadowingScorer.compare` 是纯函数，
    /// 拿当时识别出来的文本重算一遍必然得到同一个结果 ——
    /// 另存一份反而多出一个「与原文对不上」的真源。
    ///
    /// ⚠️ 库里查到的记录**不等于**「今天这一句」的记录：`drill_id` 是
    /// `daily-<主题>-<序号>`，与内容无关，换天/换一批都会重用同一批 id
    /// （见 `ShadowingAnalysisAdoption`）。放行判据在那边，这里一律按它筛 ——
    /// 不筛的话，昨天的识别文本会被拿去对今天的参考句算匹配率，发音分也是昨天那次的。
    func rehydrateShadowingAnalyses() async {
        let drills = shadowingDrills
        guard !drills.isEmpty else { return }
        let day = ShadowingDailyRule.dayKey()
        let attempts = await services.latestShadowingAttempts(drillIDs: drills.map(\.id))
        guard !attempts.isEmpty else { return }
        for drill in drills {
            let key = Self.shadowingAnalysisKey(day: day, drillID: drill.id)
            // 内存里已有（刚读过）就不覆盖 —— 它比库里那条新。
            guard shadowingAnalyses[key] == nil, let attempt = attempts[drill.id] else { continue }
            // 认不出来 = 这一句还没读过（宁可重读一句，也不许把别人的成绩安在他头上）。
            guard ShadowingAnalysisAdoption.adopts(attempt, for: drill, dayKey: day) else { continue }
            shadowingAnalyses[key] = ShadowingResult(
                comparison: ShadowingScorer.compare(
                    reference: drill.text,
                    recognized: attempt.recognizedText
                ),
                pronunciation: attempt.pronunciation
            )
        }
    }

    // MARK: 段落（#232）

    /// 段落划分**从句子实时推导**，不另存一份 —— 存一份就多一个「换了一批句子但段落没跟着换」的失效点。
    public var shadowingPassages: [ShadowingPassage] {
        ShadowingPassageRule.passages(from: shadowingDrills)
    }

    /// 当前要跟读的段落（素材为空时 nil）。
    public var currentShadowingPassage: ShadowingPassage? {
        let passages = shadowingPassages
        guard passages.indices.contains(shadowingPassageIndex) else { return passages.first }
        return passages[shadowingPassageIndex]
    }

    /// 切换跟读粒度。切换时清掉上一次的结果 —— 旧粒度的结果留在新粒度下是指错对象。
    public func setShadowingMode(_ mode: ShadowingMode) {
        guard mode != shadowingMode else { return }
        shadowingMode = mode
        shadowingComparison = nil
        shadowingPronunciation = nil
        shadowingPassageResult = nil
        shadowingPassagePronunciation = nil
        shadowingNotice = nil
    }

    /// 换到下一段（段落模式下）。
    public func nextShadowingPassage() {
        let passages = shadowingPassages
        guard !passages.isEmpty else { return }
        shadowingPassageIndex = (shadowingPassageIndex + 1) % passages.count
        shadowingPassageResult = nil
        shadowingPassagePronunciation = nil
        shadowingNotice = nil
    }

    /// 加载今日素材（当天缓存 → 现生成）与跟读汇总。
    ///
    /// 两步走：**先让内置素材立刻上屏**（用户不会对着空页面等模型），
    /// 拿到今天生成的 20 句之后整批换掉。生成失败就把内置素材留在页面上，
    /// 并如实说明「今天的没生成出来」—— 而不是让页面变空。
    public func loadShadowing() async {
        if shadowingDrills.isEmpty { await loadTodayShadowingDrills() }
        // 汇总与顽固音素是两件各读各的取数，**并行**做 —— 串起来会让进页面等两遍查询。
        async let stats: Void = refreshShadowingStats()
        async let weaknesses: Void = refreshPhonemeWeaknesses()
        _ = await (stats, weaknesses)
    }

    /// 取今日跟读素材。`regenerate == true` 时忽略当天缓存重新生成（页面上有按钮）。
    public func loadTodayShadowingDrills(regenerate: Bool = false) async {
        if regenerate { await services.clearShadowingDailyCache() }

        // ① 今天已经生成过：直接用它（同一天内必须稳定，否则练到一半句子全换）。
        if !regenerate, let cached = await services.shadowingCachedDrills(day: nil), !cached.isEmpty {
            shadowingDrills = cached
            shadowingNotice = nil
            shadowingIsDailyGenerated = true
            resetShadowingProgress(restoreSavedIndex: true)
            // 库里已有的分析补回来：重启后回到这一页，之前读过的那几句照样有结果。
            await rehydrateShadowingAnalyses()
            restoreShadowingResultForCurrentDrill()
            return
        }

        // ② 内置素材先顶着。
        let bundled = await services.shadowing.drills()
        if shadowingDrills.isEmpty {
            shadowingDrills = bundled
            shadowingIsDailyGenerated = false
        }

        // ③ 模型没起：不报错弹窗，只留一句提示 —— 内置素材照样能练。
        guard isModelRunning(.llm) else {
            shadowingNotice = bundled.isEmpty
                ? "没有找到跟读素材（Resources/Shadowing/*.json），请检查安装包资源是否完整。"
                : "\(await services.modelLabel(for: .llm)) 已关闭，现在练的是内置素材；启动后回来就能练今天现生成的 20 句。"
            return
        }

        isShadowingLoading = true
        defer { isShadowingLoading = false }
        do {
            let generated = try await services.shadowingDailyDrills(day: nil)
            guard !generated.isEmpty else { return }
            shadowingDrills = generated
            shadowingIsDailyGenerated = true
            shadowingNotice = nil
            resetShadowingProgress(restoreSavedIndex: true)
            await rehydrateShadowingAnalyses()
            restoreShadowingResultForCurrentDrill()
        } catch {
            shadowingNotice = generatedFailureMessage(error, hasFallback: !bundled.isEmpty)
        }
    }

    /// 换了一批素材：练到第几句、上一句的评测结果都得跟着清 ——
    /// 留着上一批的下标会让「第 7 / 20 句」指向另一句，评测卡也挂在无关的句子上。
    ///
    /// - Parameter restoreSavedIndex: 是否落回**今天记住的那一句**。
    ///   只有「今天的素材」这一条路要走它（切页 / 重启回来接着上次那一句练）；
    ///   音素专项与材料跟读是**另一批素材**，记住的位置对它们没有意义，从第一句开始。
    func resetShadowingProgress(restoreSavedIndex: Bool = false) {
        shadowingIndex = 0
        shadowingPassageIndex = 0
        shadowingComparison = nil
        shadowingPronunciation = nil
        shadowingPassageResult = nil
        shadowingPassagePronunciation = nil
        voiceTranscript = nil
        guard restoreSavedIndex else { return }
        if let saved = Self.storedShadowingIndex(day: ShadowingDailyRule.dayKey()),
           shadowingDrills.indices.contains(saved) {
            shadowingIndex = saved
        }
        restoreShadowingResultForCurrentDrill()
    }

    func generatedFailureMessage(_ error: any Error, hasFallback: Bool) -> String {
        let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return hasFallback
            ? "今天的跟读句子没能生成（\(reason)），先在页面上练内置素材。"
            : "今天的跟读句子没能生成（\(reason)）。"
    }

    public func refreshShadowingStats() async {
        shadowingStats = await services.shadowing.stats()
    }

    /// 换到下一句（顺序轮换，到底回到第一句）。
    ///
    /// ⚠️ 不再清掉评测结果：换到的那一句若是**读过的**，它的分析要跟着回来
    /// （`restoreShadowingResultForCurrentDrill`）。以前这里一律置 nil，
    /// 于是「回头看看上一句」必须重读一遍才有结果。
    public func nextShadowingDrill() {
        guard !shadowingDrills.isEmpty else { return }
        shadowingIndex = (shadowingIndex + 1) % shadowingDrills.count
        saveShadowingProgress()
        restoreShadowingResultForCurrentDrill()
        shadowingNotice = nil
        voiceTranscript = nil
    }

    /// 换到上一句（已经是第一句时不动 —— 界面上那颗按钮根本不出现）。
    public func previousShadowingDrill() {
        guard shadowingDrills.indices.contains(shadowingIndex), shadowingIndex > 0 else { return }
        shadowingIndex -= 1
        saveShadowingProgress()
        restoreShadowingResultForCurrentDrill()
        shadowingNotice = nil
        voiceTranscript = nil
    }

    /// 听示范（老师的声音读这一句 / 这一整段）。再点一次 = 重读。
    public func playShadowingExample() async {
        guard hasShadowingMaterial else { return }
        // ⚠️ 真源而非界面快照（见 `isModelRunning` 的说明）：巡检挂起后快照会过期。
        _ = (try? await services.resumeIfSuspended(.tts)) ?? false
        await syncModelRunStates()
        guard await services.isModelRunning(.tts) else {
            shadowingNotice = "\(await services.modelLabel(for: .tts)) 已关闭，请在设置里点绿色的「启动」后再听示范。"
            return
        }
        shadowingNotice = nil
        isShadowingBusy = true
        // 单独标一个「正在放声音」：`isShadowingBusy` 还覆盖识别 / 评分，
        // 那段窗口里给用户一个「停止」按钮是错的（停的是声音，不是评分）。
        isShadowingPlaying = true
        let selection = await services.effectiveSpeechVoiceSelection()
        let rate = Float(product.speechRate)
        switch shadowingMode {
        case .sentence:
            guard let drill = currentShadowingDrill else {
                isShadowingBusy = false
                isShadowingPlaying = false
                return
            }
            await services.shadowing.playReference(
                drill, selection: selection, language: "English", rate: rate
            )
        case .passage:
            guard let passage = currentShadowingPassage else {
                isShadowingBusy = false
                isShadowingPlaying = false
                return
            }
            await services.shadowing.playPassage(
                passage, selection: selection, language: "English", rate: rate
            )
        }
        shadowingNotice = await services.shadowing.lastError()
        isShadowingBusy = false
        isShadowingPlaying = false
    }

    /// 当前粒度下有没有可跟读的东西（一句 / 一段）。
    ///
    /// 抽出来的原因：录音、评分、听示范三处都要判，各写一份就会出现
    /// 「段落模式下因为没有 `currentShadowingDrill` 而按不动开始跟读」。
    public var hasShadowingMaterial: Bool {
        switch shadowingMode {
        case .sentence: currentShadowingDrill != nil
        case .passage: currentShadowingPassage != nil
        }
    }

    /// 点一下开始跟读，再点一下停止并评分。
    public func toggleShadowingRecording() async {
        if isShadowingRecording {
            await finishShadowingRecording()
        } else {
            await startShadowingRecording()
        }
    }

    public func startShadowingRecording() async {
        guard hasShadowingMaterial else { return }
        // ⚠️ 识别 / 评分 / 放声音期间**不重开麦克风**（2026-09-27）：
        // 两次录音会让识别结果错位 —— 上一段的识别回来时写进 `shadowingComparison` 的
        // 是**别的句子**的分数，而用户正在读的是这一句。按钮那边同时被禁用，
        // 这里再加一道是因为按钮状态可能比状态机慢一帧。
        guard !isShadowingBusy else { return }
        // ⚠️ 真源而非界面快照（见 `isModelRunning` 的说明）：这就是用户报「设置里开着、
        // 一跟读就连接失败」的那一处——快照说还在跑，于是跳过了自动恢复。
        _ = (try? await services.resumeIfSuspended(.asr)) ?? false
        await syncModelRunStates()
        guard await services.isModelRunning(.asr) else {
            shadowingNotice = "\(await services.modelLabel(for: .asr)) 已关闭，请在设置里点绿色的「启动」后再跟读。"
            return
        }
        shadowingNotice = nil
        // ⚠️ 这里**不动** `shadowingComparison` / `shadowingPronunciation`：
        // 它们是「这一句**最近一次**的分析」，正在重读的这会儿它依然是最新的一次。
        // 清掉的话，这一遍没录上音（很常见）就会把上一次的结果一起弄丢 ——
        // 而用户可能只是想再看一眼刚才那张卡。
        shadowingPassageResult = nil
        shadowingPassagePronunciation = nil
        voiceTranscript = nil
        // 录音前先停掉示范，避免麦克风把老师的声音也录进去。
        await services.shadowing.stopAudio()
        await services.shadowing.startRecording(language: ShadowingService.practiceLanguage)
        isShadowingRecording = await services.voice.isRecording
        if let error = await services.shadowing.lastError() { shadowingNotice = error }
    }

    /// 停止录音 → **原始**识别（不做拼写纠正）→ 对齐 + 发音评测 → 落库。
    ///
    /// 两种粒度共用入口：段落模式把整段识别文本回填到每一句（见 `ShadowingPassageScorer`）。
    public func finishShadowingRecording() async {
        guard hasShadowingMaterial else { return }
        // 只有真的在录音时才谈得上「停止并评分」：重入拿到的是空音频，
        // 会换回一句假的「没有听清，凑近麦克风再说一次」。
        guard isShadowingRecording else { return }
        isShadowingRecording = false
        isShadowingBusy = true
        let recognized = await services.shadowing.finishRecording(language: ShadowingService.practiceLanguage)
        isShadowingBusy = false
        voiceTranscript = nil
        guard let recognized, !recognized.isEmpty else {
            shadowingNotice = await services.shadowing.lastError() ?? "没有听清，凑近麦克风再说一次"
            return
        }
        switch shadowingMode {
        case .sentence:
            guard let drill = currentShadowingDrill else { return }
            let result = await services.shadowing.evaluate(drill: drill, recognized: recognized)
            shadowingComparison = result.comparison
            shadowingPronunciation = result.pronunciation
            // 这一句的分析留在这句名下：待会儿跳到别的句子再跳回来，它还在。
            rememberShadowingResult(result, drillID: drill.id)
        case .passage:
            guard let passage = currentShadowingPassage else { return }
            let evaluation = await services.shadowing.evaluatePassage(passage, recognized: recognized)
            shadowingPassageResult = evaluation.result
            shadowingPassagePronunciation = evaluation.pronunciation
        }
        await refreshShadowingStats()
        // 跟读也是今日作业的一项：练完立刻刷新黑板/庆祝判定（force —— 练完的瞬间不许被节流吞掉）。
        // ⚠️ 以前这里不刷，跟读凑齐计划的最后一块时收尾仪式永远缺席（#227）。
        await refreshTodayPanel(force: true)
        // 只有真的评出结果才通知森林：没听清那次不算「练完」。
        forest.ingest(.moduleCompleted(module: .shadowing))
    }

    /// 听我的：回放刚才录的音，和示范对着听。
    public func replayShadowingRecording() async {
        guard await services.shadowing.hasRecording else {
            shadowingNotice = "还没有录音，先点「开始跟读」说一遍"
            return
        }
        shadowingNotice = nil
        isShadowingBusy = true
        isShadowingPlaying = true
        do {
            try await services.shadowing.replayRecording(rate: Float(product.speechRate))
        } catch {
            shadowingNotice = "回放失败：\(error.localizedDescription)"
        }
        isShadowingBusy = false
        isShadowingPlaying = false
    }

    /// 停掉跟读页面的一切声音（示范 / 回放）。
    ///
    /// 接在「听示范 / 听我的」两颗按钮上：正在放声音时它们变成「停止」。
    /// 这不是可有可无的小按钮 —— 示范音是**整段**朗读，等它读完才能开始跟读，
    /// 长句要等十几秒，用户唯一的选择原本是把音量关掉。
    public func stopShadowingAudio() async {
        await services.shadowing.stopAudio()
        isShadowingBusy = false
        isShadowingPlaying = false
    }

    /// 放弃这次跟读录音（丢掉，不评分）。
    ///
    /// 除了页面上的取消入口，**离开跟读页时也必须调用**（2026-09-27）：
    /// `MainView` 是 `if/else` 切页 —— 视图没了，`AppState` 里的录音状态还在，
    /// 麦克风会一直开着跟到下一个页面去。用户切去词典查个词，回来时还在录，
    /// 中间那几分钟的说话声全被采进去了：隐私与资源两头都不该这样。
    public func cancelShadowingRecording() async {
        guard isShadowingRecording else { return }
        isShadowingRecording = false
        await services.shadowing.cancelRecording()
    }

    public func dismissShadowingNotice() { shadowingNotice = nil }

    /// 截图/验证辅助：拿一段文本直接走**同一条评测链路**，预览反馈界面。
    /// 不录麦克风、不落库 —— 只为了在无法合成点击的环境里验证渲染。
    ///
    /// 发音评测（第 23 步）需要原始音频才能量出语速 / 停顿 / 音高；
    /// 这里按参考句的词数合成一段「演示波形」（有起伏、有换气）驱动同一套纯函数，
    /// 让发音卡片也能端到端渲染。真实录音走的完全是同一条链路。
    func previewShadowingResult(_ recognized: String) async {
        guard let drill = currentShadowingDrill else { return }
        let comparison = ShadowingScorer.compare(reference: drill.text, recognized: recognized)
        shadowingComparison = comparison
        shadowingPronunciation = await services.pronunciation.report(
            reference: drill.text,
            recognized: recognized,
            samples: Self.demoWaveform(for: drill.text),
            sampleRate: 16_000,
            comparison: comparison
        )
    }

    /// 段落模式的预览钩子（与上面单句那个同源）：拿一段文本直接走**同一条**段落评测链路。
    ///
    /// 不录麦克风、不落库。存在的理由和单句预览一样：合成不了真实点击与真实录音时，
    /// 得有一条路能把「整段反馈界面」渲染出来看（离屏回归也走它）。
    func previewShadowingPassageResult(_ recognized: String) async {
        guard let passage = currentShadowingPassage else { return }
        let result = ShadowingPassageScorer.evaluate(passage: passage, recognized: recognized)
        shadowingPassageResult = result
        shadowingPassagePronunciation = await services.pronunciation.report(
            reference: passage.text,
            recognized: recognized,
            samples: Self.demoWaveform(for: passage.text),
            sampleRate: 16_000
        )
    }

    /// 合成一段「像人说话」的演示波形：每个参考词一段带包络的浊音（基频句内起伏、
    /// 音量轻重交替），词间小间隙、句中一次换气。**确定性**（不用随机数），
    /// 同一句每次合成结果一致，评测分数因此可复现。
    nonisolated private static func demoWaveform(for text: String, sampleRate: Double = 16_000) -> [Float] {
        let words = ShadowingScorer.words(text)
        guard !words.isEmpty else { return [] }
        var samples: [Float] = Array(repeating: 0, count: Int(0.35 * sampleRate))
        for (index, _) in words.enumerated() {
            // 词长 0.38~0.50 秒（伪随机但确定）→ 折算约每分钟 135 词，落在理想语速带。
            let duration = 0.38 + Double((index * 7) % 5) * 0.03
            let count = Int(duration * sampleRate)
            // 基频 125~179Hz 循环上抬，让音高有起伏可测。
            let f0 = 125.0 + Double(index % 4) * 18.0
            // 轻重交替：重音节奏的代理量才有东西可量。
            let amplitude = index % 2 == 0 ? 0.55 : 0.85
            for position in 0..<count {
                let t = Double(position) / sampleRate
                let envelope = sin(.pi * Double(position) / Double(count))
                let vibrato = 1.0 + 0.03 * sin(2 * .pi * 5 * t)
                samples.append(Float(amplitude * envelope * sin(2 * .pi * f0 * vibrato * t)))
            }
            // 词间小间隙；句子过半处插一次 0.42 秒的换气（触发「停顿」维度）。
            let breathing = index == words.count / 2 && words.count >= 5
            samples.append(contentsOf: Array(repeating: Float(0), count: Int((breathing ? 0.42 : 0.06) * sampleRate)))
        }
        samples.append(contentsOf: Array(repeating: 0, count: Int(0.4 * sampleRate)))
        return samples
    }

}
