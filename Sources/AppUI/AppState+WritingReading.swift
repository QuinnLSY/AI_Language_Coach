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
    public func openReading() async {
        applySection(.reading)
        let dayKey = WritingTopicPicker.dayKey(for: Date())
        // 内存里已是今天这批（页内来回切换不重查库）。
        if !readingEntries.isEmpty, readingEntries.first?.passage.dayKey == dayKey { return }
        let stored = await services.todaysReadings(dayKey: dayKey)
        if !stored.isEmpty {
            readingEntries = stored
            showReadingEntry(at: stored.count - 1)
            return
        }
        await loadReading()
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
