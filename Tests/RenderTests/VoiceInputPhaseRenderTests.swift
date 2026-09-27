import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 语音输入三个阶段在界面上的**可见差异**回归（2026-09-27 报障）。
///
/// 用户口径：「识别期间手动改了识别内容，就再也停不掉、取消不了」。
/// 底层根因是状态机缺了「识别中」这一格（见 `VoiceInputPhase`），但**用户是靠界面
/// 判断的**：以前识别期间画面与录音期间一模一样 —— 主按钮还是那个红波纹、也没有
/// 任何进度迹象，于是用户以为自己第一次点击没生效，再点一次就落进了「重新录音」。
///
/// 所以这一组用例不测状态变量，测**画面**：
/// 三个阶段两两之间必须看得出区别，否则「识别中」在用户眼里就等于不存在。
///
/// ⚠️ 判据用**逐像素差异**并限定在按钮带（下方工具栏），不比色值 ——
/// 离屏位图会过一次色彩空间换算；限定区域是为了把消息区 / 引导行的无关差异排除掉。
/// ⚠️ `ProgressView` 是自旋转的，但**只有 transcribing 这一帧有它**，
/// 所以「有它 / 没它」的差异是稳定的（同一帧内部不做相位比较）。
@MainActor
final class VoiceInputPhaseRenderTests: XCTestCase {

    private var window: NSWindow?
    private let canvas = CGSize(width: 620, height: 520)

    // MARK: - 离屏渲染

    /// 夹具：一个 mock 对话服务（`RunLoop.run` 不能在 async 上下文调用，
    /// 所以准备与渲染必须分成两步）。
    private func makeChat() async throws -> ChatService {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("alc-voice-phase-\(UUID().uuidString).json")
        )
        try await store.updateProvider(
            ProviderConfig(id: "ollama.llm", kind: .llm, enabled: true, runtime: .mock, model: "mock-model")
        )
        try await store.selectModel("mock-model", for: .llm)
        return ChatService(services: CoachServices(config: store, databasePath: ":memory:"))
    }

    private func render(_ phase: VoiceInputPhase, chat: ChatService) throws -> NSBitmapImageRep {
        let saved = CuteAnimalView.animationsEnabled
        CuteAnimalView.animationsEnabled = false
        defer { CuteAnimalView.animationsEnabled = saved }

        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        let host = NSHostingView(rootView: AnyView(
            ChatView(
                chat: chat,
                modelName: "mock-model",
                health: .connected(model: "mock-model"),
                voicePhase: phase,
                onMicStart: {},
                onMicStop: { "" },
                onCancelVoiceInput: {},
                onSend: { _ in }
            )
            .forestTheme(theme)
            .frame(width: canvas.width, height: canvas.height)
            .clipped()
        ))
        host.frame = NSRect(origin: .zero, size: canvas)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        // 等弹簧动画与首帧布局走完（否则两帧的差异里混着入场动画）。
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    // MARK: - 像素度量（一律换算回**点**）

    private func scale(of rep: NSBitmapImageRep) -> Double {
        Double(rep.pixelsHigh) / Double(canvas.height)
    }

    /// 两帧在扫描区里差多少个**点**。`rows`/`columns` 都用点给。
    private func differencePoints(
        _ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep,
        rows: Range<Int>, columns: Range<Int>
    ) -> Int {
        let width = lhs.pixelsWide, height = lhs.pixelsHigh
        guard let a = lhs.bitmapData, let b = rhs.bitmapData else { return 0 }
        let s = scale(of: lhs)
        let colFirst = min(max(Int(Double(columns.lowerBound) * s), 0), width - 1)
        let colLast = min(max(Int(Double(columns.upperBound) * s), 0), width - 1)
        var count = 0
        for y in rows {
            let row = min(max(Int(Double(y) * s), 0), height - 1)
            for x in colFirst..<colLast {
                let o = (row * width + x) * 4
                if abs(Int(a[o]) - Int(b[o])) > 8
                    || abs(Int(a[o + 1]) - Int(b[o + 1])) > 8
                    || abs(Int(a[o + 2]) - Int(b[o + 2])) > 8 {
                    count += 1
                }
            }
        }
        return Int(Double(count) / (s * s))
    }

    /// 输入框下排按钮带（点）：composer 在底部，三个按钮 32pt 见方、右对齐。
    /// 横向取「取消 / 麦克风 / 发送」三颗按钮扫过的那一段，把中间的信息文字排除在外。
    private var buttonRow: Range<Int> { (Int(canvas.height) - 92)..<(Int(canvas.height) - 24) }
    private var buttonColumns: Range<Int> { 400..<(Int(canvas.width) - 20) }

    // MARK: - 用例

    /// **报障本体**：识别中与录音中的按钮带必须不同。
    ///
    /// 以前 `isTranscribing` 永远是 false（状态置得太晚），于是 ChatView 在识别期间
    /// 收到的还是「录音中」——两帧完全一样，用户看不出发生了什么。
    /// 反证：把 `voicePhase.isBusy` 换回 `false`（等价于旧的恒 false 状态）→ 本条精确红。
    func testTranscribingLooksDifferentFromRecording() async throws {
        let chat = try await makeChat()
        let recording = try render(.recording, chat: chat)
        let transcribing = try render(.transcribing, chat: chat)

        XCTAssertEqual(recording.pixelsWide, transcribing.pixelsWide, "两帧宽度不一致")

        let diff = differencePoints(recording, transcribing, rows: buttonRow, columns: buttonColumns)
        XCTAssertGreaterThan(
            diff, 20,
            "识别中与录音中的按钮带几乎没有区别（实测 \(diff) 点）—— 用户无从判断『正在识别』，"
                + "只会以为刚才那一下没生效"
        )
        try dump(recording, name: "round35-voice-recording.png")
        try dump(transcribing, name: "round35-voice-transcribing.png")
    }

    /// 识别中必须有**取消的出口**（按钮带与该阶段空闲时不同，且差异来自多出来的那颗按钮）。
    func testTranscribingOffersAWayOut() async throws {
        let chat = try await makeChat()
        let idle = try render(.idle, chat: chat)
        let transcribing = try render(.transcribing, chat: chat)

        let diff = differencePoints(idle, transcribing, rows: buttonRow, columns: buttonColumns)
        XCTAssertGreaterThan(
            diff, 40,
            "识别中与空闲态的按钮带差别太小（实测 \(diff) 点）—— 取消按钮没出现或进度不可见"
        )
    }

    /// 录音中同样要能取消（这是原有的能力，不能被这次改动弄丢）。
    func testRecordingOffersCancelToo() async throws {
        let chat = try await makeChat()
        let idle = try render(.idle, chat: chat)
        let recording = try render(.recording, chat: chat)

        let diff = differencePoints(idle, recording, rows: buttonRow, columns: buttonColumns)
        XCTAssertGreaterThan(diff, 40, "录音中与空闲态的按钮带差别太小（实测 \(diff) 点）")
        try dump(idle, name: "round35-voice-idle.png")
    }

    /// 落盘（人眼复核用）。
    private func dump(_ rep: NSBitmapImageRep, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]), "PNG 编码失败")
        try png.write(to: directory.appendingPathComponent(name))
    }
}
