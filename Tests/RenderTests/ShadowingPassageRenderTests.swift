import AppKit
@testable import AppUI
import AIDomain
import AIServices
import AIInfrastructure
import SwiftUI
import XCTest

/// 段落级跟读（#232）的**离屏渲染**回归。
///
/// 逻辑正确性由 `ShadowingPassageTests` 钉住；这里只回答另外两件测不出来的事：
/// ① 切到「整段跟读」后，页面上**真的多画出了整段**（而不是一个空卡）；
/// ② 评完分之后，逐句结果卡**真的插进了页面**（而不是算完了没显示）。
///
/// 判据只用**布局高度差**，不比对色值：离屏渲染过一次色彩空间换算，绝对色值本来就不可靠。
/// ⚠️ 全程不碰真实数据、不请求模型（素材由测试自造，识别文本同样由测试构造）。
@MainActor
final class ShadowingPassageRenderTests: XCTestCase {

    private var window: NSWindow?

    private func makeState() async throws -> AppState {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("passage-render-\(UUID().uuidString)", isDirectory: true)
        let store = ConfigStore(fileURL: directory.appendingPathComponent("config.json"))
        // ⚠️ 当日跟读缓存必须**单独一份**：`CoachServices` 默认的 `.shared` 读写
        // **真实用户数据目录**（`.workbuddy/app-config/shadowing-daily.json`），
        // 而 Ollama 在线时 `isModelRunning(.llm)` 为真 → 取数路径会真发模型请求
        // （temperature 0.9，每批句子都不同）→ 段落页高度掷硬币。
        // 2026-10-21 全量实测：同一份代码两次跑出 547.5 / 526.0，一红一绿；
        // 用户的真实当日缓存还被测试生成的那批覆盖过。
        let daily = ShadowingDailyStore(
            fileURL: directory.appendingPathComponent("shadowing-daily.json")
        )
        let state = AppState(services: CoachServices(
            config: store, databasePath: ":memory:", shadowingDailyStore: daily
        ))
        // 直接喂自造素材：句子完全确定，`loadShadowing` 见非空即跳过取数
        //（不请求模型、不读当天缓存）。段落下标指向第一段「不止一句」的段落 ——
        // 一句的段落与句子模式页高持平，测不出「整段摊开」。
        state.shadowingDrills = Self.cannedDrills()
        if let multi = state.shadowingPassages.firstIndex(where: { $0.drills.count > 1 }) {
            state.shadowingPassageIndex = multi
        }
        await state.loadShadowing()
        return state
    }

    /// 夹具自造的四句同情景素材（长句 + 释义 + 要点，与生成素材同规格）。
    ///
    /// 为什么不用内置素材：内置「点餐」那三句都短（一句一行），段落卡反而比句子卡
    /// **更矮**（491.5 < 505.5，2026-10-21 实测）——「整段摊开更高」这条判据依赖
    /// 句子长度，只有自造长句才钉得住。四句用词各不相同：第二条测试要「漏掉中间
    /// 一句后它最弱」，词汇重叠会让邻句的词被 LCS 认成它的。
    ///
    /// ⚠️ 为什么是**五句**而不是四句：离屏下句模式的 `WordLookupText`（AppKit 文本视图）
    /// 是固定高度（≈197.5pt 的卡，与文本长短无关），段落每多一句只 +34.5pt ——
    /// 4 句时余量只有 20.5pt，5 句才有 ≈55pt 的余量扛字体/环境差异。
    private static func cannedDrills() -> [ShadowingDrill] {
        let sentences = [
            "The doctor asked me to describe the pain in my lower back, especially whenever I climb the stairs slowly.",
            "I have been taking the prescribed medicine twice a day after meals for the past two weeks without problems.",
            "The nurse told me to come back next Monday morning so they could check my blood pressure again carefully.",
            "My pharmacist explained that this tablet might cause some drowsiness, so I should not drive afterward.",
            "We agreed to book a follow-up appointment before the end of this month if the pain has not eased."
        ]
        return sentences.enumerated().map { index, text in
            ShadowingDrill(
                id: "canned-\(index)",
                text: text,
                translation: "这是第 \(index + 1) 句自造的参考句，与其余几句用词不同。",
                topic: "看医生",
                difficulty: 2,
                focus: index == 0 ? "连读" : ""
            )
        }
    }

    /// 渲染整页，返回宿主视图（高度是可断言的「画了多少」的代理量）。
    private func renderPage(_ state: AppState) throws -> NSHostingView<AnyView> {
        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let host = NSHostingView(rootView: AnyView(
            ShadowingView(state: state).forestTheme(theme)
        ))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 1600)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// 段落模式要**比一句模式画出更多东西**：整段摊开 + 逐句结果卡。
    func testPassageModeDrawsMoreThanSentenceMode() async throws {
        let state = try await makeState()
        let sentenceHeight = try renderPage(state).fittingSize.height

        await state.setShadowingMode(.passage)
        let passage = try XCTUnwrap(state.currentShadowingPassage, "内置素材应能切出至少一个段落")
        let passageHeight = try renderPage(state).fittingSize.height

        XCTAssertGreaterThan(
            passage.drills.count, 1,
            "段落模式下这一段得有不止一句，否则这条测的不是段落（段内句数 \(passage.drills.count)）"
        )
        XCTAssertGreaterThan(
            passageHeight, sentenceHeight,
            "整段摊开后页面必须变高（一句 \(sentenceHeight) → 段落 \(passageHeight)），"
                + "一样高就说明整段根本没画出来"
        )
    }

    /// 评完分之后结果卡必须出现，而且**点名的是被漏掉的那句**。
    func testPassageResultCardAppearsAndNamesTheSkippedSentence() async throws {
        let state = try await makeState()
        await state.setShadowingMode(.passage)
        let passage = try XCTUnwrap(state.currentShadowingPassage)
        guard passage.drills.count >= 3 else {
            throw XCTSkip("这段只有 \(passage.drills.count) 句，造不出「漏掉中间一句」")
        }

        let beforeHeight = try renderPage(state).fittingSize.height

        // 漏掉中间那一句：其余照读。
        let skipped = passage.drills.count / 2
        var spoken = passage.sentences
        spoken.remove(at: skipped)
        await state.previewShadowingPassageResult(spoken.joined(separator: " "))

        let result = try XCTUnwrap(state.shadowingPassageResult, "段落预览钩子应产出结果")
        XCTAssertEqual(result.weakestIndex, skipped, "最弱的必须是被漏掉的那句（第 \(skipped + 1) 句）")

        let afterHeight = try renderPage(state).fittingSize.height
        XCTAssertGreaterThan(
            afterHeight, beforeHeight + 60,
            "结果卡要真的插进页面（评分前 \(beforeHeight) → 评分后 \(afterHeight)）"
        )
    }

    /// 结果卡必须**只有这一句真有分析时**才画（#331 的落点）。
    ///
    /// 跨天判据本身在 `ShadowingAnalysisAdoption`（有它自己的纯函数用例 + 真链路用例），
    /// 这一条守的是**判据到屏幕的那一段接线**：缓存里没有 ⇒ 页面上没有那张卡；
    /// 缓存里有 ⇒ 多出一张卡。少了它，「不跨天冒充」可以判得很对，而屏幕上该显示时仍然不显示。
    ///
    /// ⚠️ 反向也钉住：夹具先断言**这一句确实没有分析**（`shadowingComparison == nil`），
    /// 再拿这个状态当基线量高度 —— 否则「多出一张卡」可能只是拿两个都空的状态在比。
    func testAnalysisCardIsDrawnOnlyWhenTheSentenceHasOne() async throws {
        // ⚠️ `loadTodayShadowingDrills` 会落回「今天记住的那一句」（`shadowing.progress`），
        // 不隔离就随开发机的使用状态时红时绿。先清键，`defer` 原样放回。
        let key = AppState.shadowingProgressStorageKey
        let saved = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        let state = try await makeState()
        let drill = try XCTUnwrap(state.currentShadowingDrill, "夹具：今天应当有句子")

        // 夹具前提：这一句还没分析过（库里也没有 —— 临时库，一条记录都没有）。
        XCTAssertNil(
            state.shadowingComparison,
            "夹具：库里没有任何记录，这一句不该带着分析进页面"
        )
        let clean = try renderPage(state)
        let cleanHeight = clean.fittingSize.height
        try dump(clean, name: "round331-shadowing-no-analysis.png")

        // 给这一句放一份分析（走真入口，不碰私有字典）。
        let comparison = ShadowingScorer.compare(reference: drill.text, recognized: drill.text)
        state.rememberShadowingResult(
            ShadowingResult(comparison: comparison, pronunciation: nil), drillID: drill.id
        )
        state.restoreShadowingResultForCurrentDrill()
        XCTAssertNotNil(state.shadowingComparison, "夹具：这一步应当把分析摆进当前句")

        let withCard = try renderPage(state)
        let withCardHeight = withCard.fittingSize.height
        try dump(withCard, name: "round331-shadowing-with-analysis.png")

        XCTAssertGreaterThan(
            withCardHeight, cleanHeight + 60,
            "这一句有分析时页面上必须多出一张卡（无分析 \(cleanHeight) → 有分析 \(withCardHeight)）；"
                + "一样高就说明卡片根本没接上屏幕 —— 那样「不跨天冒充」对了也白搭"
        )
    }

    /// 出图：`.workbuddy/verify/`（与其它渲染用例同一处，人眼复核用）。
    private func dump(_ host: NSHostingView<AnyView>, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name))
    }
}
