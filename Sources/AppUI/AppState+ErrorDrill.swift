import AIDomain
import Foundation

// MARK: - 改错练习（把记忆卡上的「反复犯的错」变成能练一遍的题）

extension AppState {

    /// 连对账本的持久化键（UserDefaults：一份几十字节的 [错 id: 连对次数]，不值得为此建表）。
    static let errorDrillStreakStorageKey = "errorDrill.streaks"

    static func loadErrorDrillStreaks() -> [String: Int] {
        guard let data = UserDefaults.standard.data(forKey: errorDrillStreakStorageKey),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return [:] }
        return decoded
    }

    private func saveErrorDrillStreaks() {
        guard let data = try? JSONEncoder().encode(errorDrillStreaks) else { return }
        UserDefaults.standard.set(data, forKey: Self.errorDrillStreakStorageKey)
    }

    /// 已攻克的错（连对次数到门槛的那些）—— 开新一轮时把它们排除在队列外。
    var conqueredErrorIDs: Set<String> {
        Set(errorDrillStreaks.filter { ErrorDrillProgress.isMastered(streak: $0.value) }.keys)
    }

    /// 开一轮改错练习。
    ///
    /// 队列来自**学习记忆里已有的** `recurringErrors`，不另起一套筛选 ——
    /// 记忆卡上排第一的错，练习里也就是第一题，两处必须说的是同一件事。
    public func startErrorDrill() async {
        // 记忆是进记录页时才加载的；直接点按钮时先补一次，别让人看到「没有可练的错」。
        if learningMemory.recurringErrors.isEmpty {
            await refreshLearningMemory()
        }
        let session = ErrorDrillSession(
            errors: learningMemory.recurringErrors,
            mastered: conqueredErrorIDs
        )
        guard !session.queue.isEmpty else {
            learningMemoryNotice = conqueredErrorIDs.isEmpty
                ? "还没有反复犯的错 —— 先去练几轮，老师记下来了才有得练。"
                : "反复犯的错都练过了。再犯新的，这里会自动补上。"
            return
        }
        errorDrill = session
        errorDrillLastOutcome = nil
        errorDrillSummary = nil
        // 开新一轮前把上一轮的回执清掉，否则「都练过了」这句会一直挂在记忆卡上。
        learningMemoryNotice = nil
    }

    /// 交答案并判分。**停在这一处**等回执（要用户点「下一处」才推进）。
    ///
    /// 判分不发起任何模型请求：`RecurringError` 自带正确答案，归一比对即可
    /// （口径见 `ErrorDrillMatcher`）。
    ///
    /// ⚠️ 账本**不在这里更新**：一轮只在结算 / 收起时统一记一次，
    /// 否则「同一轮里同一处被算了两次攻克」这类问题要靠调用方自觉去防。
    public func submitErrorDrill(answer: String) {
        guard var session = errorDrill, session.current != nil else { return }
        guard let outcome = session.submit(answer) else { return }
        errorDrill = session
        errorDrillLastOutcome = outcome
        errorDrillSummary = nil
    }

    /// 从回执推进到下一处；走完了就结算。
    public func advanceErrorDrill() {
        guard let session = errorDrill else { return }
        errorDrillLastOutcome = nil
        guard session.isFinished else { return }
        finishErrorDrill()
    }

    /// 收起这一轮（走完 / 提前退出都走这里）。
    ///
    /// 已判过的题**照样记进账本**：中途退出不该把这一轮练对的成果抹掉 ——
    /// 那是学员刚花了力气做的事。
    public func finishErrorDrill() {
        guard let session = errorDrill else { return }
        let (ledger, conquered) = ErrorDrillProgress.applied(session.outcomes, to: errorDrillStreaks)
        errorDrillStreaks = ledger
        saveErrorDrillStreaks()
        errorDrillSummary = session.summary(conquered: conquered)
        // ⚠️ 判据要在清空之前算：「推进到底」才走到这里（`advanceErrorDrill` 只在
        // `isFinished` 时才调），其余入口（学习记录页的取消）都是半路收场 ——
        // 半路收场时森林目送你走，不庆祝。
        forest.ingest(session.isFinished
                      ? .moduleCompleted(module: .errorDrill)
                      : .practiceAbandoned(module: .errorDrill))
        errorDrill = nil
        errorDrillLastOutcome = nil
    }

    /// 关掉结算卡。
    public func dismissErrorDrillSummary() {
        errorDrillSummary = nil
    }
}
