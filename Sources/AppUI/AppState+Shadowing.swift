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
        await refreshShadowingStats()
    }

    /// 取今日跟读素材。`regenerate == true` 时忽略当天缓存重新生成（页面上有按钮）。
    public func loadTodayShadowingDrills(regenerate: Bool = false) async {
        if regenerate { await services.clearShadowingDailyCache() }

        // ① 今天已经生成过：直接用它（同一天内必须稳定，否则练到一半句子全换）。
        if !regenerate, let cached = await services.shadowingCachedDrills(day: nil), !cached.isEmpty {
            shadowingDrills = cached
            shadowingNotice = nil
            shadowingIsDailyGenerated = true
            resetShadowingProgress()
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
            resetShadowingProgress()
        } catch {
            shadowingNotice = generatedFailureMessage(error, hasFallback: !bundled.isEmpty)
        }
    }

    /// 换了一批素材：练到第几句、上一句的评测结果都得跟着清 ——
    /// 留着上一批的下标会让「第 7 / 20 句」指向另一句，评测卡也挂在无关的句子上。
    func resetShadowingProgress() {
        shadowingIndex = 0
        shadowingPassageIndex = 0
        shadowingComparison = nil
        shadowingPronunciation = nil
        shadowingPassageResult = nil
        shadowingPassagePronunciation = nil
        voiceTranscript = nil
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

    /// 换一句（顺序轮换，到底回到第一句）。换句即清掉上一句的结果。
    public func nextShadowingDrill() {
        guard !shadowingDrills.isEmpty else { return }
        shadowingIndex = (shadowingIndex + 1) % shadowingDrills.count
        shadowingComparison = nil
        shadowingPronunciation = nil
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
        // ⚠️ 真源而非界面快照（见 `isModelRunning` 的说明）：这就是用户报「设置里开着、
        // 一跟读就连接失败」的那一处——快照说还在跑，于是跳过了自动恢复。
        _ = (try? await services.resumeIfSuspended(.asr)) ?? false
        await syncModelRunStates()
        guard await services.isModelRunning(.asr) else {
            shadowingNotice = "\(await services.modelLabel(for: .asr)) 已关闭，请在设置里点绿色的「启动」后再跟读。"
            return
        }
        shadowingNotice = nil
        shadowingComparison = nil
        shadowingPronunciation = nil
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
