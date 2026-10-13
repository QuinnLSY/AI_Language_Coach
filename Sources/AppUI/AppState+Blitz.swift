import AIDomain
import Foundation

// MARK: - ⑦-C① 复习限时连击

extension AppState {

    /// 开一轮连击（跟着一轮复习一起开）。
    ///
    /// ⚠️ 只有**真有词要过**的时候才开：`startVocabularyReview` 判过队列非空之后才调它，
    /// 空队列上挂一条倒计时是在骗人（那一行永远不动，因为判不了词）。
    public func startReviewBlitz() {
        stopReviewBlitz()
        reviewBlitz = ReviewBlitz()
        reviewBlitzRemaining = ReviewBlitz.windowSeconds
        reviewBlitzIsNewRecord = false
        startReviewBlitzTicker()
    }

    /// 再来一轮（结算那格的按钮：同一轮复习里再抢一次 60 秒）。
    public func restartReviewBlitz() {
        startReviewBlitz()
    }

    /// 收掉这一轮（复习收起 / 走完都走这里）。
    ///
    /// ⚠️ 收之前先结算纪录：最后一秒连对的那一串，不能因为用户顺手点了「完成」就丢掉。
    public func stopReviewBlitz() {
        sealReviewBlitzRecord()
        reviewBlitzTask?.cancel()
        reviewBlitzTask = nil
        reviewBlitz = nil
        reviewBlitzRemaining = 0
    }

    /// 判一张卡时顺手记一笔连击。
    ///
    /// 返回**这一张有没有计入连击**（超时后判的不计），调用方拿它决定要不要刷新纪录 ——
    /// 界面与数据不许各走一半：判词（`services.vocabulary.grade`）已经在调用方那边落库了，
    /// 这里只管连击这一层。
    @discardableResult
    public func gradeReviewBlitz(remembered: Bool) -> Bool {
        guard reviewBlitz != nil else { return false }
        let counted = reviewBlitz?.grade(remembered: remembered) ?? false
        reviewBlitzRemaining = reviewBlitz?.remainingSeconds() ?? 0
        sealReviewBlitzRecord()
        return counted
    }

    /// 到了点就把纪录结掉（连击断了也要能结：最高连击是这一轮的成绩）。
    private func sealReviewBlitzRecord() {
        guard let blitz = reviewBlitz, blitz.bestCombo > 0 else { return }
        guard ReviewBlitzRecord.isNewRecord(best: reviewBlitzBest, combo: blitz.bestCombo) else { return }
        reviewBlitzBest = blitz.bestCombo
        reviewBlitzIsNewRecord = true
    }

    /// 倒计时那一拍：每秒把「还剩几秒」写进状态源。
    ///
    /// ⚠️ 每一拍都从 `Date()` 重新算（`ReviewBlitz.remainingSeconds`），**不累加**：
    /// 机器睡了一会儿、主线程卡了一下，累加出来的时间会漂，那条纪录就不作数了。
    /// ⚠️ 到点即收，不留一个 0 秒的空转循环。
    private func startReviewBlitzTicker() {
        reviewBlitzTask?.cancel()
        reviewBlitzTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                guard let blitz = self.reviewBlitz else { return }
                self.reviewBlitzRemaining = blitz.remainingSeconds()
                if blitz.isExpired() {
                    self.sealReviewBlitzRecord()
                    self.reviewBlitzTask?.cancel()
                    self.reviewBlitzTask = nil
                    return
                }
            }
        }
    }
}
