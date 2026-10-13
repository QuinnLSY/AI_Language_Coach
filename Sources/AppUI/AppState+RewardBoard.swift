import AIDomain

// MARK: - ⑦-C② 成就墙 / ⑦-C③ 森林解锁预告

extension AppState {

    /// 成就墙上实际画的那几格（已达成全部 + 未达成里最接近的三条）。
    ///
    /// 纯派生：不缓存、不记账 —— `progressSnapshot` 一变它就跟着变。
    /// ⚠️ 刻意不做「达成时弹一次」这类一次性状态：那种状态重启就没了，
    /// 而墙上这一格是**此刻**的事实，该由此刻的数据说话。
    public var achievementWall: [Achievement] {
        AchievementWall.display(snapshot: progressSnapshot)
    }

    /// 墙头那一行（「3/9 项已解锁 · 下一个 开口 50 句，还差 12 句」）。
    public var achievementHeadline: String {
        AchievementWall.headline(snapshot: progressSnapshot)
    }

    /// 林子里现在有几位伙伴（按累计练习时长解锁，只增不减）。
    public var forestUnlockedCompanions: Int {
        ForestUnlock.companions(totalSeconds: progressSnapshot.totalSeconds)
    }

    /// 「林子里 5 位伙伴」。
    public var forestUnlockHeadline: String {
        ForestUnlock.headline(totalSeconds: progressSnapshot.totalSeconds)
    }

    /// 预告那句（满员之后不再挂倒计时，见 `ForestUnlock.previewText`）。
    public var forestUnlockPreview: String {
        ForestUnlock.previewText(totalSeconds: progressSnapshot.totalSeconds)
    }

    /// 已经在林子里的那几位（顺序 = `AnimalKind.unlockOrder` 的前 N 位，与地面带同源）。
    public var forestCompanions: [AnimalKind] {
        Array(AnimalKind.unlockOrder.prefix(forestUnlockedCompanions))
    }

    /// 下一位要来的是谁（nil = 满员了）。
    ///
    /// ⚠️ 下标来自 `ForestUnlock`，物种来自 `AnimalKind.unlockOrder` —— **两边必须同源**，
    /// 否则会出现「写着小刺猬要来，来的却是小狐狸」。顺序只有 `unlockOrder` 一处。
    public var forestNextCompanion: AnimalKind? {
        guard let index = ForestUnlock.nextIndex(totalSeconds: progressSnapshot.totalSeconds) else {
            return nil
        }
        let order = AnimalKind.unlockOrder
        return index < order.count ? order[index] : nil
    }
}
