import AIDomain
import AIServices
import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - AppState · 写作练习 + 阅读理解
// #267 自 AppState.swift 拆出（2026-09-20）：单文件 5136 行超载，按域切为扩展。
// 同模块 extension，语义与拆分前完全一致；成员访问级别已放宽到 internal。
extension AppState {
    // MARK: - 写作练习（#230）

    /// 进入写作页：取今天的题（同一天恒定，与每日推荐同口径）。
    public func openWriting() async {
        applySection(.writing)
        if writingTopic == nil || writingTopic?.dayKey != WritingTopicPicker.dayKey(for: Date()) {
            writingTopic = WritingTopicPicker.topic(for: Date())
        }
    }

    /// 草稿词数（与跟读同一把分词尺）。
    public var writingWordCount: Int { ShadowingScorer.words(writingDraft).count }

    /// 交给老师批改：**一次写作 = 一次模型请求**（闸门在服务装配层）。
    public func submitWriting() async {
        guard !isWritingReviewing, let topic = writingTopic else { return }
        let essay = writingDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ShadowingScorer.words(essay).count >= 30 else {
            writingNotice = "再多写几句再交 —— 至少 30 词（目标 80–120 词）。"
            return
        }
        isWritingReviewing = true
        writingNotice = ""
        defer { isWritingReviewing = false }
        guard let review = await services.reviewWriting(topic: topic, essay: essay) else {
            writingNotice = "批改没成功：老师现在联系不上（模型没启动或请求失败）。把模型跑起来后再交一次。"
            return
        }
        writingReview = review
        // 交卷即落一行写作记录（学习记录页 / 每周小结的「写作练习」口径）。
        await services.recordWritingSubmission(topic: topic, essay: essay, review: review)
        // 落库之后才通知森林：没记下来的事不该让小动物白高兴一场。
        forest.ingest(.moduleCompleted(module: .writing))
    }

    /// 收掉当前批改卡（改稿重写时用）。
    public func dismissWritingReview() {
        writingReview = nil
        writingNotice = ""
    }

    /// 把批改里值得记的词收进词汇本（已存在时不重复加）。
    public func addWritingWord(_ item: WritingWord) async {
        guard await services.vocabulary.add(word: item.word) != nil else {
            writingNotice = "「\(item.word)」没能加入词汇本。"
            return
        }
        writingNotice = "已把「\(item.word)」收进词汇本。"
        await reloadVocabulary()
    }

    // MARK: - 阅读理解（#231）

    /// 进入阅读页：**今天生成过就直接回看库里那批**（一天一次生成，重启也不重出题）；
    /// 今天一篇都没有才出第一份。
    ///
    /// - Parameters:
    ///   - dayKey: 要看哪一天的那批（跨页搜索点「阅读」结果时带进来；不传 = 今天）。
    ///   - title: 要停在哪一篇（按标题找；找不到就用最后一篇 —— 那是「接着看」的默认口径）。
    public func openReading(dayKey: Int? = nil, title: String? = nil) async {
        applySection(.reading)
        let key = dayKey ?? WritingTopicPicker.dayKey(for: Date())
        // 内存里已是这一批（页内来回切换不重查库）。
        if !readingEntries.isEmpty, readingEntries.first?.passage.dayKey == key {
            if let title, let index = readingEntries.firstIndex(where: { $0.passage.title == title }) {
                showReadingEntry(at: index)
            }
            return
        }
        // 开屏那次预生成**还在跑**：等它，别再发一次请求。
        //
        // ⚠️ 不等的话会生成出**今天第二篇** —— 两篇都要花一次请求，
        // 用户还会在「1 / 2」的编号里看到内容跳变。等它的时候把加载态点亮，
        // 界面因此显示的是正常的「在出题」，而不是一个空页面。
        // ⚠️ 任务**不清空** —— 不是为了挡住什么（清空也一样对：清的是等待**之后**，
        // 那时并发进来的第二个调用照样看得到它），只是 `await` 一个已经结束的任务是免费的，
        // 少一处可变状态就少一个能对不上的地方。
        if let prefetch = readingPrefetchTask {
            isReadingLoading = true
            await prefetch.value
            isReadingLoading = false
        }
        let stored = await services.todaysReadings(dayKey: key)
        if !stored.isEmpty {
            readingEntries = stored
            let index = title.flatMap { wanted in stored.firstIndex { $0.passage.title == wanted } }
            showReadingEntry(at: index ?? stored.count - 1)
            return
        }
        await loadReading()
    }

    // MARK: - 开屏后台预生成（#330）

    /// 开屏时在**后台**把今天那篇短文先出出来 —— 用户点「阅读」时是秒开。
    ///
    /// 三条边界，少一条都会变成新的毛病：
    /// ① **今天已经有了就绝不重出**。阅读是「一天一篇」的量，重出等于白花一次请求，
    ///    还会让用户昨天做过的那篇凭空变样（`openReading` 靠 `todaysReadings` 取当天那批）。
    /// ② **排在老师的开场白后面**。本机模型一次只伺候一个请求：抢在开场白前面，
    ///    会把「老师先开口」拖慢，而那是用户开屏第一眼要看的东西 ——
    ///    不能为了让他晚几秒点阅读，去动这半分钟。
    ///    （顺序也顺带解决了「模型还没热」：开场白那次调用已经把模型拉起来了。）
    /// ③ **只落库、不上屏**。预生成不该改任何界面状态 —— 用户还没进阅读页，
    ///    这时往 `readingEntries` 里塞东西，等于替他决定了「今天看第几篇」。
    ///    真进页面时 `openReading` 照旧从库里读、照旧决定展示哪一篇。
    ///
    /// ⚠️ 失败一律静默：这是**锦上添花**的后台活儿，用户并没有点任何东西，
    /// 弹一句「短文没取到」只会让人莫名其妙。真需要就在他点开阅读页时由 `loadReading` 报。
    func prefetchTodaysReading() async {
        // ② 先等开场白那一轮跑完（它可能跑上大半分钟 —— 冷启动要拉模型）。
        await openingTask?.value
        guard !Task.isCancelled else { return }
        // 模型被用户显式关掉了：预生成**不能**自己去把它拉起来
        // （那是「我关了它怎么自己开了」这类投诉的来源）。
        //
        // ⚠️ 问的是**服务层真源**，不是 `AppState.modelRunStates` 那份界面快照 ——
        // 快照会被资源巡检的挂起、设置页的开关改在后面（见 MEMORY.md 的同一条铁律：
        // 使用处一律问真源）。快照在这里过期一次的后果是**背地里把用户关掉的模型拉起来**。
        guard await services.isModelRunning(.llm) else { return }
        // ① 等开场白的这段时间里用户可能已经自己打开过阅读页、或者今天早就有一篇了。
        let dayKey = WritingTopicPicker.dayKey(for: Date())
        guard await services.todaysReadings(dayKey: dayKey).isEmpty else { return }
        // 用户此刻正在阅读页出题（翻页 / 换一篇）→ 别掺和，让他自己那一篇出完。
        guard !isReadingLoading else { return }

        guard let passage = await services.generateReading(level: effectivePlacementLevelText) else {
            return
        }
        guard !Task.isCancelled else { return }
        // 生成完再确认一次：这段时间里用户完全可能已经自己出了一篇（他在页面上等着，
        // 而这次生成排在最后）。落下去就会变成今天第二篇。
        guard await services.todaysReadings(dayKey: dayKey).isEmpty else { return }
        await services.saveReading(StoredReading(passage: passage, createdAt: Date()))
    }

    /// 出一篇短文：**一次阅读 = 一次模型请求**（首篇自动出；之后只由「换一篇」触发）。
    /// 难度档位优先取有把握的实测估计，其次取入学摸底的自测档位（`effectivePlacementLevelText`）——
    /// 两者都没有就交空串，由 Prompt 侧按「还在观察中」出 A2-B1。
    public func loadReading() async {
        guard !isReadingLoading else { return }
        isReadingLoading = true
        readingNotice = ""
        defer { isReadingLoading = false }
        let level = effectivePlacementLevelText
        guard let passage = await services.generateReading(level: level) else {
            readingNotice = "短文没取到：老师现在联系不上（模型没启动或请求失败）。把模型跑起来后再试一次。"
            return
        }
        let entry = StoredReading(passage: passage, createdAt: Date())
        readingEntries.append(entry)
        showReadingEntry(at: readingEntries.count - 1)
        await services.saveReading(entry)
    }

    /// 切到今天的第 `index` 篇（编号按钮；作答进度随篇恢复）。
    public func selectReadingEntry(at index: Int) {
        guard readingEntries.indices.contains(index), index != readingEntryIndex else { return }
        showReadingEntry(at: index)
    }

    /// 把「当前展示」的三件套（篇 / 选择 / 交卷态）指到某一篇。
    func showReadingEntry(at index: Int) {
        guard readingEntries.indices.contains(index) else { return }
        readingEntryIndex = index
        let entry = readingEntries[index]
        readingChoices = entry.choices
        isReadingReviewed = entry.isReviewed
        expandedReadingQuestions = entry.isReviewed ? Set(0..<entry.passage.questions.count) : []
        readingNotice = ""
    }

    /// 选一道题的选项（交卷后锁定；每一步选择都落库，中途退出也不丢）。
    public func chooseReadingOption(question: Int, option: Int) {
        guard !isReadingReviewed, readingEntries.indices.contains(readingEntryIndex) else { return }
        readingChoices[question] = option
        readingEntries[readingEntryIndex].choices = readingChoices
        let entry = readingEntries[readingEntryIndex]
        Task { await services.saveReading(entry) }
    }

    /// 是否每题都答了（交卷按钮的可用条件）。
    public var readingAllAnswered: Bool {
        guard let passage = readingPassage else { return false }
        return (0..<passage.questions.count).allSatisfy { readingChoices[$0] != nil }
    }

    /// 交卷：**判分纯本地零请求**（答案生成时已随文下发）——标对错、全展开解析、落库。
    public func submitReading() async {
        guard readingEntries.indices.contains(readingEntryIndex),
              !isReadingReviewed, readingAllAnswered else { return }
        isReadingReviewed = true
        // 全部展开：答对的看讲解，答错的看错因复盘 —— 需求要求对错都要溯源原文。
        let passage = readingEntries[readingEntryIndex].passage
        expandedReadingQuestions = Set(0..<passage.questions.count)
        let correct = ReadingGrader.correctCount(passage, choices: readingChoices)
        readingNotice = "交卷完成：答对 \(correct) / \(passage.questions.count)。"
        readingEntries[readingEntryIndex].isReviewed = true
        readingEntries[readingEntryIndex].choices = readingChoices
        let entry = readingEntries[readingEntryIndex]
        await services.saveReading(entry)
        // 同上：**落库之后**才让森林知道（读完了会有谁想听故事）。
        forest.ingest(.moduleCompleted(module: .reading))
        await refreshTodayPanel(force: true)
    }

    /// 收起 / 展开一道题的解析卡。
    public func toggleReadingQuestion(_ index: Int) {
        if expandedReadingQuestions.contains(index) {
            expandedReadingQuestions.remove(index)
        } else {
            expandedReadingQuestions.insert(index)
        }
    }

}
