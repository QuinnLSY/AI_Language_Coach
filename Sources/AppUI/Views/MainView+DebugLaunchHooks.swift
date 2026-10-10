import SwiftUI

// ⚠️ 本文件整体只在 **DEBUG 构建**里编译（#S2-7）。
//
// 这些是「送参验证」的钩子（离屏渲染 / 截图 / 端到端），**不是产品功能**。
// 原先它们直接写在 `MainView.body` 里，于是发布版也带着走，两个真实风险：
// ① `--import-backup <路径>` **跳过确认框**直接导入备份 —— 任何能启动这个应用的人
//    都能静默换掉配置（配置里还带着启停命令，见 #S2-6）；
// ② 它们把调试产物写到**固定** `/tmp/alc-hook-debug*.txt`，那个路径可被预先放符号链接，
//    应用就会把内容写到别处的文件上。
//
// 验证用的 .app 是 debug 构建（`launch-app.swift` 送参走的就是它），所以照常可用。
#if DEBUG

extension MainView {

    /// 启动后的验证钩子（DEBUG 构建）。
    ///
    /// ⚠️ 只被 `MainView.body` 的 `.task` 在 `#if DEBUG` 里调一次；生产构建里
    /// 这个方法根本不存在，生产包也读不到任何命令行参数。
    @MainActor
    func runDebugLaunchHooks() async {
            // 验证辅助：--export-report <路径> 把年度学习记录卡直接导出成 PNG（跳过保存面板）。
            if let index = CommandLine.arguments.firstIndex(of: "--export-report"),
               index + 1 < CommandLine.arguments.count {
                await state.reloadProgress()
                if let data = ReportExporter.annualRecapPNG(recap: state.annualRecap, theme: state.theme) {
                    try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                } else {
                }
            }
            // 验证辅助：--import-backup <路径> 走完整导入流程（校验 → 确认 → 暂存），跳过确认框。
            if let index = CommandLine.arguments.firstIndex(of: "--import-backup"),
               index + 1 < CommandLine.arguments.count {
                await state.inspectBackup(at: CommandLine.arguments[index + 1])
                if state.backupImportPlan != nil {
                    await state.confirmBackupImport()
                    state.showingSettings = true
                }
            }
            // 验证辅助：--import-material <路径> 导入材料正文并生成拆解（真实模型调用）。
            if let index = CommandLine.arguments.firstIndex(of: "--import-material"),
               index + 1 < CommandLine.arguments.count {
                state.importMaterialFile(at: CommandLine.arguments[index + 1])
                await state.generateMaterialFromDraft()
                state.showingScenarios = true
            }
            // 截图/验证辅助：--open-records 启动时直接进入学习记录页
            if CommandLine.arguments.contains("--open-records") {
                Task { await state.openRecords() }
            }
            // 截图/验证辅助：--open-progress 启动时直接进入学习进度页（第 25 步 Dashboard）
            // --progress-days N 指定统计窗口（7/14/30）
            if CommandLine.arguments.contains("--open-progress") {
                if let index = CommandLine.arguments.firstIndex(of: "--progress-days"),
                   index + 1 < CommandLine.arguments.count,
                   let days = Int(CommandLine.arguments[index + 1]) {
                    state.progressWindowDays = min(max(days, 7), 90)
                }
                await state.openProgress()
            }
            // 截图/验证辅助：--open-shadowing 启动时直接进入跟读页
            if CommandLine.arguments.contains("--open-shadowing") {
                await state.openShadowing()
            }
            // 段落级跟读（#232）：--open-shadowing-passage 直接进整段模式，
            // 省掉一次手工点选（本机 UI 自动化对 SwiftUI 不可靠）。
            if CommandLine.arguments.contains("--open-shadowing-passage") {
                await state.openShadowing()
                state.setShadowingMode(.passage)
            }
            // 截图/验证辅助：--open-vocabulary 启动时直接进入词汇本页
            // （--daily-flip / --vocabulary-tail 自带进页，见 VocabularyView 的验证钩子）
            if CommandLine.arguments.contains("--open-vocabulary")
                || CommandLine.arguments.contains("--daily-flip")
                || CommandLine.arguments.contains("--vocabulary-tail") {
                await state.openVocabulary()
            }
            // 截图/验证辅助：--open-dictionary 启动时直接进入词典页（空查询态 → 推荐词一排）
            if CommandLine.arguments.contains("--open-dictionary") {
                await state.openDictionary()
            }
            // 截图/验证辅助：--dictionary-word "nominal" 进词典页并直接查这个词。
            // （观察固定搭配 / 例句的排版与划词气泡；本机 UI 自动化对 SwiftUI 不可靠。）
            if let index = CommandLine.arguments.firstIndex(of: "--dictionary-word"),
               index + 1 < CommandLine.arguments.count {
                await state.openDictionary()
                await state.lookUpDictionaryWord(CommandLine.arguments[index + 1], pushing: false)
            }
            // 截图/验证辅助：--define-vocabulary 进词汇本 + 给第一个每日推荐词查释义、
            // 给最新一条词条重新释义，并朗读「单词 + 例句」。
            // 一次跑完「提示词 → 解析 → 卡片排版 → 朗读」整条链路，
            // 不需要模拟点击（本机 UI 自动化对 SwiftUI 不可靠）。
            if CommandLine.arguments.contains("--define-vocabulary") {
                await state.openVocabulary()
                await state.loadDailyWordsIfNeeded()
                if let first = state.dailyWords.first {
                    await state.toggleDailyDefinition(word: first.word)
                    let example = state.dailyDefinitions[first.word]?.example ?? ""
                    let spoken = example.isEmpty ? first.word : "\(first.word). \(example)"
                    Task { await state.speak(spoken) }
                }
                if let newest = state.vocabularyEntries.first {
                    await state.redefineVocabulary(id: newest.id)
                }
            }
            // 截图/验证辅助：--shadowing-sample "识别文本" 用**同一条评测链路**预览反馈界面
            // （本机无法合成点击、也无法自动对麦克风说话；它不录音、不落库，
            //   发音卡用合成的演示波形驱动 —— 真实录音时走的是同一段纯函数）
            if let index = CommandLine.arguments.firstIndex(of: "--shadowing-sample"),
               index + 1 < CommandLine.arguments.count {
                await state.openShadowing()
                await state.previewShadowingResult(CommandLine.arguments[index + 1])
            }
            // 端到端验证辅助：--scenario <id> 启动后直接进入某个情景
            if let index = CommandLine.arguments.firstIndex(of: "--scenario"),
               index + 1 < CommandLine.arguments.count,
               let scenario = state.scenarios.first(where: { $0.id == CommandLine.arguments[index + 1] }) {
                await state.startScenario(scenario)
            }
            // 截图/验证辅助：--expand-scenario <id> 已在 `start()` 之前处理（见上）。
            // 截图/验证辅助：--free-talk 直接开一段随口练（观察学生主导的引导风格，需求 4）
            if CommandLine.arguments.contains("--free-talk") {
                await state.startFreeTalk()
            }
            // 端到端验证辅助：--exam <考卷 id> 启动后直接开一场考试（观察考场条 / 出题）
            if let index = CommandLine.arguments.firstIndex(of: "--exam"),
               index + 1 < CommandLine.arguments.count {
                await state.loadExamBlueprints()
                let wanted = CommandLine.arguments[index + 1]
                if let blueprint = state.examBlueprints.first(where: { $0.id == wanted }) {
                    await state.startExam(blueprint)
                } else {
                    // 没找到就说清楚是哪一套没找到，别静默什么都不发生。
                    state.practiceNotice = AppNotice(
                        text: "没有找到考卷 \(wanted)（可用："
                            + state.examBlueprints.map(\.id).joined(separator: "、") + "）"
                    )
                }
            }
            // 端到端验证辅助：--auto-finish-exam-after <秒> 等 N 秒后自动交卷（观察结算卡）
            if let index = CommandLine.arguments.firstIndex(of: "--auto-finish-exam-after"),
               index + 1 < CommandLine.arguments.count,
               let seconds = Double(CommandLine.arguments[index + 1]) {
                Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    await state.finishExam()
                }
            }
            // 端到端验证辅助：--send "文本" 启动后自动发送一条消息
            if let index = CommandLine.arguments.firstIndex(of: "--send"),
               index + 1 < CommandLine.arguments.count {
                let text = CommandLine.arguments[index + 1]
                Task {
                    // ⚠️ 必须**等老师开口生成结束**再发，不能固定 sleep：
                    // `ChatService.send` 里 `guard !isGenerating else { return }` 会**静默丢弃**
                    // 生成中抢话的消息。原来固定等 1 秒，在本机模型冷加载（几十秒）时必然踩空 ——
                    // 表现为「--send 传了文本，会话里却一句都没有」，很容易被误读成功能坏了。
                    for _ in 0..<90 where state.chat.isGenerating || state.chat.messages.isEmpty {
                        try? await Task.sleep(for: .seconds(1))
                    }
                    state.chat.send(text)
                }
            }
            // 端到端验证辅助：--auto-speak 启动即打开自动朗读（观察分句流水线时序）
            if CommandLine.arguments.contains("--auto-speak") {
                await state.setAutoSpeak(true)
            }
            // 端到端验证辅助：--auto-end-scenario 启动 12 秒后自动结束情景（观察星星结算）
            if CommandLine.arguments.contains("--auto-end-scenario") {
                Task {
                    try? await Task.sleep(for: .seconds(12))
                    await state.endScenario()
                }
            }
            // 端到端验证辅助：--auto-free-talk-after <秒> 等 N 秒后走**顶栏「开启新练习」的同一条路径**
            // （`startFreeTalk` 会先自动复盘上一段并清掉流水）。
            // 用它一箭三雕：观察「自动复盘回执」（需求 5）+「随口练开场白」（需求 4）。
            if let index = CommandLine.arguments.firstIndex(of: "--auto-free-talk-after"),
               index + 1 < CommandLine.arguments.count,
               let seconds = Double(CommandLine.arguments[index + 1]) {
                Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    await state.startFreeTalk()
                }
            }

        // 截图/验证辅助：--translate-last 等老师开口后，自动翻译最后一条消息（验证气泡翻译）。
        // ⚠️ 原本是一条独立的 `.task`（等首条消息出现再翻），这里并进来：同属验证钩子，
        // 拆成两处只会让人漏掉一处。
        guard CommandLine.arguments.contains("--translate-last") else { return }
        // 等首条消息出现且生成结束（老师主动打招呼需要几秒到几十秒）。
        for _ in 0..<60 where state.chat.messages.isEmpty || state.chat.isGenerating {
            try? await Task.sleep(for: .seconds(2))
        }
        guard !state.chat.messages.isEmpty else { return }
        // 学员与老师各翻一条：一个开关就能同时验两种译文对齐（学员右 / 老师左）。
        if let teacher = state.chat.messages.last(where: { $0.role == .assistant }) {
            await state.translateMessage(teacher.id)
        }
        if let learner = state.chat.messages.last(where: { $0.role == .user }) {
            await state.translateMessage(learner.id)
        }
    }
}

#endif
