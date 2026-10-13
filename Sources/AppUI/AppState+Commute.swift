import AIDomain
import Foundation

// MARK: - AppState · 通勤连播（⑦-D）
extension AppState {

    /// 连播队列的**入口预览**（没在连播时给界面画那张卡）。
    ///
    /// ⚠️ 段落模式返回 nil：段落本来就是一次读完一整段，再叠一层连播是重复盖楼
    /// （判据与 `startCommute` 共用同一个 `shadowingMode == .sentence`）。
    public var commutePreview: CommuteQueue? {
        guard shadowingMode == .sentence else { return nil }
        return CommuteQueue.build(drills: shadowingDrills, from: shadowingIndex)
    }

    /// 开始连播：从**当前这句**起，一路放到今天最后一句。
    ///
    /// 每句之间留 `gapSeconds` 给学员跟读 —— 那段留白才是连播的正文，
    /// 示范只是给它起个头。
    public func startCommute() async {
        guard shadowingMode == .sentence else { return }
        guard let queue = commutePreview else { return }
        // ⚠️ 真源而非界面快照（见 `isModelRunning` 的说明）：巡检挂起后快照会过期。
        // 连播要走几分钟，开头不查清楚就是「点下去没声音，还不知道为什么」。
        _ = (try? await services.resumeIfSuspended(.tts)) ?? false
        await syncModelRunStates()
        guard await services.isModelRunning(.tts) else {
            shadowingNotice = "\(await services.modelLabel(for: .tts)) 已关闭，请在设置里点绿色的「启动」后再连播。"
            return
        }
        shadowingNotice = nil
        commuteQueue = queue
        isCommuteRunning = true
        let token = UUID()
        commuteToken = token
        await runCommuteLoop(token: token)
    }

    /// 停在当前这一句。
    ///
    /// ⚠️ **不推进下标**：停在这里就是为了「再按开始还能从这句接着放」
    /// （刚放的那一句多半只听了个头，再听一遍才对）。
    /// 自然放完相反 —— 那一轮到头了，播放头复位到第一句，见
    /// `resetCommuteAfterNaturalCompletion`。
    public func stopCommute() async {
        // 令牌先作废：循环里那次 `playReference` 随后跑完时别再把状态写回来。
        commuteToken = nil
        isCommuteRunning = false
        await stopShadowingAudio()
    }

    /// 自然放完之后的复位：播放头回到第一句，下一轮「开始」放整批。
    ///
    /// ⚠️ 只有**自然放完**才走这里。`startCommute` 的队列是从 `shadowingIndex`
    /// 起排的，放完不复位的话它停在末句，再按「开始」只重播最后一句 ——
    /// 「连播」想再听一遍却只有 1 句。被「停止」叫停时走 `stopCommute`，
    /// 语义是「从这句接着放」，两者故意相反。
    func resetCommuteAfterNaturalCompletion() {
        commuteQueue = nil
        shadowingIndex = 0
        // 换句三件套的老规矩：下标变了，摆回界面的结果必须同属这一句。
        restoreShadowingResultForCurrentDrill()
        saveShadowingProgress()
    }

    // MARK: - 循环

    /// 连播主循环：放一句 → 留白 → 下一句，直到放完或被叫停。
    ///
    /// ⚠️ 每轮开头都查一次令牌：循环里有两个 await（朗读十几秒 + 留白几秒），
    /// 用户随时可能按「停止」。只在开头查一次的话，停止之后它还会继续放完剩下的。
    private func runCommuteLoop(token: UUID) async {
        while commuteToken == token, isCommuteRunning {
            // ⚠️ 只看 `currentDrill != nil` 就够：真正播放的是 `playShadowingExample()`
            // 自己取的那句（`shadowingDrills[shadowingIndex]`），这里提前判一次
            // 是为了别在「下标已经越界」的队列上空转一轮。
            guard var queue = commuteQueue, queue.currentDrill != nil else { break }
            // 让跟读页跟着走：连播期间用户在别的页面，切回来看见的必须是**正在放的**那一句。
            shadowingIndex = queue.index
            restoreShadowingResultForCurrentDrill()
            saveShadowingProgress()
            // 走 `playShadowingExample()` 而不是自己拼一次 `playReference`：
            // 音色（含克隆）、语速、调门、语气四样必须与单句「听示范」完全一致，
            // 各写一份迟早出现「连播里换了个老师」。
            await playShadowingExample()
            guard commuteToken == token, isCommuteRunning else { return }

            // 留白：给学员跟着复述一遍的时间。
            try? await Task.sleep(nanoseconds: UInt64(queue.gapSeconds * 1_000_000_000))
            guard commuteToken == token, isCommuteRunning else { return }

            guard queue.advance() else { break }
            commuteQueue = queue
        }
        // ⚠️ 收尾也要查令牌：被叫停时走的是 `stopCommute`，那一轮已经把状态收干净了，
        // 这里再写一遍会把「已停止」覆盖成「放完了」。
        guard commuteToken == token else { return }
        isCommuteRunning = false
        commuteToken = nil
        // 自然放完 ≠ 停止：播放头复位到第一句，再按「开始」放整批。
        resetCommuteAfterNaturalCompletion()
        shadowingNotice = "这一轮放完了，明天换一批新句子。"
    }
}
