import AIInterfaces
import AIDomain
import AIInfrastructure
import AIServices
import AppCore
import AppKit
@testable import AppUI
import SwiftUI
import XCTest

/// 气泡动作（删除 / 编辑 / 复制 / 重新生成）的**离屏渲染**回归。
///
/// 三条口径里，「点了会怎样」已经由 `ChatBubbleActionTests` 钉住（那是数据），
/// 这里只钉**用户眼睛能看见的那部分**：
/// ① 学员气泡的三颗**只在鼠标停上去时出现**，而且**不许把对话顶下去**（贴在上，不是插一行）；
/// ② 老师气泡的复制 / 重新生成**始终在场**（与悬停无关 —— 悬停到老师气泡上不该多出任何东西）；
/// ③ 点「编辑」时，气泡**整条换成一条更大的输入框**（不是塞一个单行框，也不会只多一颗图标）。
///
/// ⚠️ 一律**不碰真实数据**：配置写临时文件、库开 `:memory:`，也不写 `UserDefaults`。
/// ⚠️ 悬停 / 编辑都由 `forcedHoveredMessageID` / `forcedEditingMessageID` 注入 ——
/// 离屏没有鼠标，不给入口就只能靠人眼。这与 `DictionaryBookCard.isHovered` 是同一件事。
/// ⚠️ 断言只钉**几何**（差在哪、差多大），不钉色值：离屏过一次色彩空间换算。
@MainActor
final class BubbleActionsRenderTests: XCTestCase {

    private var window: NSWindow?

    private let canvas = CGSize(width: 820, height: 620)

    // MARK: - 夹具（mock 运行时；不联网、不写真实库）

    private func waitUntil(
        _ condition: @MainActor @escaping () -> Bool, timeout: TimeInterval = 6
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    /// 开一段「招呼 + 一轮问答」的对话（3 条：老师招呼 / 学员 / 老师回复）。
    private func makeChat() async throws -> ChatService {
        let store = ConfigStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("alc-bubble-render-\(UUID().uuidString).json")
        )
        try await store.updateProvider(
            ProviderConfig(
                id: "ollama.llm", kind: .llm, enabled: true, runtime: .mock, model: "mock-model"
            )
        )
        try await store.selectModel("mock-model", for: .llm)
        let chat = ChatService(services: CoachServices(config: store, databasePath: ":memory:"))
        chat.greetIfNeeded()
        await waitUntil { !chat.messages.isEmpty && chat.isGenerating == false }
        chat.send("I want to order a coffee, please.")
        await waitUntil { chat.isGenerating == false && chat.messages.count >= 3 }
        return chat
    }

    private func chatView(
        _ chat: ChatService,
        hovered: UUID? = nil,
        editing: UUID? = nil,
        draft: String? = nil,
        canMutate: Bool = true
    ) -> ChatView {
        ChatView(
            chat: chat,
            modelName: "mock-model",
            health: .connected(model: "mock-model"),
            onSpeakTap: { _ in },
            onSpeechRateChange: { _ in },
            onSend: { _ in },
            onDeleteMessage: { _ in },
            onResendEditedMessage: { _, _ in },
            onRegenerateReply: { _ in },
            canMutateMessages: canMutate,
            forcedHoveredMessageID: hovered,
            forcedEditingMessageID: editing,
            forcedEditingDraft: draft
        )
    }

    // MARK: - 出图

    private struct Render {
        var rep: NSBitmapImageRep
        var scale: CGFloat
        var size: CGSize
        /// 这几帧「稳定」下来用了几轮（见 `render` 的收敛循环）。
        /// 只为诊断：它顶到上限就说明当时有东西一直在动，别去怀疑断言本身。
        var settleRounds: Int = 0
    }

    private func render(_ view: some View, size: CGSize) throws -> Render {
        // ⚠️ **先关掉动物动画**（眨眼 3.2s / `.repeatForever` 跳动）—— 不关的话画面永不静止，
        // 「同一份输入连出两次必须逐像素相同」这条守卫**在物理上不可满足**。实测差异就是
        // 两块 10×8 的方块（x=65..74 与 85..94、同一行 y=41..48）—— 那两只眼睛。
        //
        // 只在这一个函数的生命周期内关：视图树、`onAppear`、计时器全都在它里面发生，
        // 出图后立刻还原，绝不外泄到别的用例（`UserDefaults` 那类跨用例污染吃过一次亏）。
        // 放在 `setUp/tearDown` 是不行的：那是**非隔离**上下文，碰主 actor 静态量会刷屏警告。
        let savedAnimalAnimations = CuteAnimalView.animationsEnabled
        CuteAnimalView.animationsEnabled = false
        defer { CuteAnimalView.animationsEnabled = savedAnimalAnimations }

        let theme = ForestThemeResolver.resolve(mode: .day, systemIsDark: false)
        // ⚠️ 必须把 frame 钉在**外层**：`MessageEditBox` 这类有天然高度的视图会让
        // `NSHostingView` 按内容自己长个子，出图尺寸就和请求的对不上（实测 120pt 变成 400pt）。
        let content = AnyView(
            view.forestTheme(theme)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .clipped()
        )
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()

        // ⚠️ **等到画面真的停下来再截，而不是死等一个固定时长。**
        //
        // 原来这里是 `RunLoop.run(until: +0.4)`：够走完 0.12s 的悬停淡入，所以在本机
        // 空载时一直是对的。但「预热之后两次出图必须逐像素相同」那条守卫在**满负载**下
        // 会红（本批实测差 127–237 像素、最大通道差只有 11–14 —— 抗锯齿量级，
        // 典型的「截在动画中途」）。同一份代码单跑该用例 5/5 全绿，全量跑 2/2 全红。
        //
        // 根因不在断言，在**固定时长在忙的时候不够**：`ChatView` 的每条气泡都挂着
        // `CuteAnimalView` —— 眨眼每 3.2s 来一次，`isHopping` 更是
        // `.repeatForever` 的 1.5s 缓动（一旦为真就**永不静止**）。两帧落在哪一相
        // 纯看当时机器有多忙；本批给 `CoachServices` 多接了一本 122KB 的词典 JSON、
        // 后台解析变重，就把这个潜伏问题顶出来了。
        //
        // ⚠️ 收敛判据**必须用本文件那把尺（逐通道容差 8），不能用逐字节相等**：
        // 动物一直在缓慢浮动，字节级永远是「不等」，实测 30 轮全部顶到上限、
        // 该文件从 18s 涨到 68s，而且并没有真的变确定。用 ±8 之后，循环要找的正是
        // 后面那些断言所依赖的那个性质（同一画面在 ±8 内不动），普通情况 2–3 轮就收敛。
        var settleRounds = 0
        var last: NSBitmapImageRep?
        // 先走完那段 0.12s 的悬停淡入（原来的固定预热就为它而设）—— 收敛循环虽然也能兜住，
        // 但让它从「已经不再淡入」起算，普通情况 2 轮就结束、不会平白多花几轮。
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        while settleRounds < Self.maxSettleRounds {
            host.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            let shot = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: shot)
            settleRounds += 1
            if let previous = last, Self.framesAgree(previous, shot) {
                last = shot
                break
            }
            last = shot
        }
        // 顶到上限也没稳 → 返回最后一帧，让调用方那条 baseline 断言如实报警（而不是挂住）。
        let frame = try XCTUnwrap(last)
        return Render(
            rep: frame,
            scale: CGFloat(frame.pixelsHigh) / size.height,
            size: size,
            settleRounds: settleRounds
        )
    }

    /// 收敛循环的上限（≈ 2.4s）。**别调大**：真有不歇的东西在动时，这里应该快点放弃并
    /// 由 baseline 断言报出来，而不是让整个渲染套件慢慢爬。
    private static let maxSettleRounds = 30

    /// 两帧在**本文件那把尺**下是否算「同一画面」（逐通道容差 8，与 `compare` 一致）。
    ///
    /// 不复用 `compare()`：它还要算连通块，逐帧调用太贵。这里只做一次线性扫描，
    /// 且**先试最快的 `memcmp`**（收敛时相邻两帧通常逐字节相同，一下就出去）。
    private static func framesAgree(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh,
              let pa = a.bitmapData, let pb = b.bitmapData
        else { return false }
        let count = a.bytesPerRow * a.pixelsHigh
        if memcmp(pa, pb, count) == 0 { return true }
        let lhs = UnsafeBufferPointer(start: pa, count: count)
        let rhs = UnsafeBufferPointer(start: pb, count: count)
        for index in 0..<count where abs(Int(lhs[index]) - Int(rhs[index])) > 8 { return false }
        return true
    }

    /// 先出一张废图。
    ///
    /// ⚠️ **头一次渲染和之后几次不是一回事**：`MarkdownText` 的文本排版要在第一次
    /// 才付那笔一次性开销，于是「同一份输入渲染两次」在进程的**头两次**能差 300+ 像素
    /// （实测 379），而第 3、4 次之间是 0。不预热的话，所有逐像素断言都得靠一个
    /// 巨大的容差苟活，等于没钉住 —— 顺便还会让「悬停不该有变化」这类断言永远成立。
    private func warmUp(_ chat: ChatService) throws -> Render {
        try render(chatView(chat), size: canvas)
    }

    // MARK: - 逐像素比较（走原始字节：`colorAt` 两百万次会慢到不可用）

    /// 一块差异像素的连通域（4 邻域）。
    private struct Blob {
        var count: Int
        var minX: Int, minY: Int, maxX: Int, maxY: Int
        func heightPt(scale: CGFloat) -> CGFloat { CGFloat(maxY - minY + 1) / scale }
        func minXPt(scale: CGFloat) -> CGFloat { CGFloat(minX) / scale }
    }

    private struct Diff {
        /// 全页差异像素总数（含零星散点）。
        var count: Int
        /// 单通道最大差（诊断用）。
        var maxDelta: Int
        /// 差异像素的连通块，**按像素数降序**。
        var blobs: [Blob]

        /// 最大的一块。
        ///
        /// ⚠️ 判「有没有多出图标 / 输入框」只看最大那块，**不看全页包围盒**：
        /// 这台机器上偶发会有几个像素在页头那一带动一下（同一份输入连出两次不出现，
        /// 隔几次渲染冒一次）。散点一多，全页包围盒就横跨整页 ——
        /// 于是「贴在气泡上、没把对话顶下去」这条永远判不出来（实测报 273pt）。
        var largest: Blob? { blobs.first }
        /// 只算**够大**的块：零星散点（页头偶发的那几个像素）不算数。
        var significantBlobs: [Blob] { blobs.filter { $0.count >= 40 } }
        var significantPixels: Int { significantBlobs.reduce(0) { $0 + $1.count } }
        var totalDescription: String { "共 \(count) 像素，\(blobs.count) 块" }
    }

    /// 统一重画成 RGBA8，让两张图可以按字节直接比。
    private func rgba(_ rep: NSBitmapImageRep) throws -> (bytes: [UInt8], width: Int, height: Int) {
        let width = rep.pixelsWide, height = rep.pixelsHigh
        let out = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        rep.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        let data = try XCTUnwrap(out.bitmapData)
        return (Array(UnsafeBufferPointer(start: data, count: width * height * 4)), width, height)
    }

    /// 字节级取样（RGBA8）。
    private func sample(
        _ image: (bytes: [UInt8], width: Int, height: Int), x: Int, y: Int
    ) -> (r: Int, g: Int, b: Int) {
        let offset = (y * image.width + x) * 4
        return (Int(image.bytes[offset]), Int(image.bytes[offset + 1]), Int(image.bytes[offset + 2]))
    }

    private func differs(
        _ pixel: (r: Int, g: Int, b: Int), from reference: (r: Int, g: Int, b: Int)
    ) -> Bool {
        abs(pixel.r - reference.r) > 8 || abs(pixel.g - reference.g) > 8
            || abs(pixel.b - reference.b) > 8
    }

    /// 在给定的 x 区间里，**最后一个「有内容」的像素行**（内容 = 与页面底色不同）。
    ///
    /// 用来找气泡的下沿：学员气泡靠右，验的那几列取动作行的横向范围，
    /// 那一带在 idle 图上只有气泡本身（图标此刻是全透明的）。
    ///
    /// ⚠️ 必须限定 `yRange`：底部那根**通栏输入框**也在这些列上，
    /// 不设上界的话「最后一个有内容的行」永远是输入框（实测 1219），气泡下沿就永远找不着。
    private func contentBottom(
        in render: Render,
        xRange: ClosedRange<Int>,
        yRange: Range<Int>,
        background: (r: Int, g: Int, b: Int)
    ) throws -> Int {
        let image = try rgba(render.rep)
        var last = 0
        for y in yRange.clamped(to: 0..<image.height) {
            for x in xRange where differs(sample(image, x: x, y: y), from: background) {
                last = y
            }
        }
        return last
    }

    /// 两张图的差异像素 + 连通块。
    ///
    /// ⚠️ 容差只能给到 8，**不能再往上加**：把「重新生成」置灰后，
    /// 那颗浅灰图标叠在近白气泡上，单通道差只有 20 上下 —— 容差一大就把它当噪声滤掉了，
    /// 于是「这一行到底渲染出来没有」这件事再也证不了（实测容差 24 时差为 0）。
    /// 之所以敢给这么小：`warmUp` 之后「同一份输入渲染两次」的差是 **0**。
    private func compare(_ a: Render, _ b: Render) throws -> Diff {
        let left = try rgba(a.rep), right = try rgba(b.rep)
        XCTAssertEqual(left.width, right.width)
        XCTAssertEqual(left.height, right.height)
        let width = left.width, height = left.height

        var mask = [Bool](repeating: false, count: width * height)
        var count = 0
        var maxDelta = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                var changed = false
                for channel in 0..<3 {
                    let delta = abs(
                        Int(left.bytes[offset + channel]) - Int(right.bytes[offset + channel])
                    )
                    maxDelta = max(maxDelta, delta)
                    if delta > 8 { changed = true }
                }
                guard changed else { continue }
                mask[y * width + x] = true
                count += 1
            }
        }

        // 连通块（4 邻域，显式栈 —— 递归版在 2M 像素的页面上会爆栈）。
        var visited = [Bool](repeating: false, count: width * height)
        var blobs: [Blob] = []
        for start in 0..<(width * height) where mask[start] && !visited[start] {
            var stack = [start]
            visited[start] = true
            var pixels = 0
            var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
            while let index = stack.popLast() {
                let x = index % width, y = index / width
                pixels += 1
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let next = ny * width + nx
                    guard mask[next], !visited[next] else { continue }
                    visited[next] = true
                    stack.append(next)
                }
            }
            blobs.append(Blob(count: pixels, minX: minX, minY: minY, maxX: maxX, maxY: maxY))
        }
        blobs.sort { $0.count > $1.count }
        return Diff(count: count, maxDelta: maxDelta, blobs: blobs)
    }

    private func dump(_ render: Render, name: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".workbuddy/verify", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(render.rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name))
    }

    // MARK: - ① 学员气泡：悬停才出现，且整个落在气泡下方

    func testLearnerActionsAppearOnHoverBelowTheBubble() async throws {
        let chat = try await makeChat()
        let user = try XCTUnwrap(
            chat.visibleMessages.first { $0.role == .user }, "夹具里应当有一条学员消息"
        )
        _ = try warmUp(chat)
        let idle = try render(chatView(chat), size: canvas)
        let hovered = try render(chatView(chat, hovered: user.id), size: canvas)
        let diff = try compare(idle, hovered)
        let blob = try XCTUnwrap(diff.largest, "悬停时一个像素都没变 —— 三颗图标根本没出来")
        let blocks = diff.significantBlobs

        XCTAssertGreaterThan(
            diff.significantPixels, 100,
            "悬停时必须真的多出东西（三颗图标），实测成块的墨只有 \(diff.significantPixels) 像素"
        )
        XCTAssertLessThan(
            blob.heightPt(scale: idle.scale), 26,
            "动作行只有 20pt 高的一行图标；实测 \(blob.heightPt(scale: idle.scale))pt"
                + " —— 更高说明它把气泡撑起来了，鼠标一进去整段对话就会跳"
        )
        XCTAssertGreaterThan(
            blob.minXPt(scale: idle.scale), canvas.width * 0.5,
            "学员的动作行**右对齐**（实测左边界 \(blob.minXPt(scale: idle.scale))pt）"
        )

        // 「不盖字」：这一行整个落在气泡**下方**，悬停不得动到气泡及其以上的任何像素。
        //
        // ⚠️ 判据走**连通块**而不是「差异像素的最小 y」：这台机器上页头偶发会有一两个像素
        // 跟着动（同一份输入连出两次不出现、隔几次冒一次），拿全页最小 y 去比会常年假警；
        // 而零星散点凑不出 40 像素的一块。
        let xRange = (blocks.map(\.minX).min() ?? 0)...(blocks.map(\.maxX).max() ?? 0)
        let iconBottom = blocks.map(\.maxY).max() ?? 0
        let midY = blocks.map { ($0.minY + $0.maxY) / 2 }.max() ?? 0
        let background = sample(try rgba(idle.rep), x: 20, y: midY)
        let bubbleBottom = try contentBottom(
            in: idle, xRange: xRange, yRange: 0..<(iconBottom + 1), background: background
        )

        let covering = blocks.filter { $0.minY <= bubbleBottom }
        XCTAssertTrue(
            covering.isEmpty,
            "动作行必须整个落在气泡下沿（y=\(bubbleBottom)）以下；实测有 \(covering.count) 块压在它上面"
                + "（\(covering.map { "\($0.minX),\($0.minY)-\($0.maxX),\($0.maxY)" }.joined(separator: " / "))）"
                + " —— 压在气泡上就是盖住了正文"
        )
        XCTAssertTrue(
            blocks.contains { $0.minY > bubbleBottom },
            "气泡下沿以下必须真的多出墨迹（三颗图标），实测一块都没有"
        )

        try dump(idle, name: "round307-bubble-idle.png")
        try dump(hovered, name: "round307-bubble-hovered.png")
    }

    // MARK: - ② 老师气泡：始终在场，与悬停无关

    func testCoachActionsAreAlwaysThereAndHoverAddsNothing() async throws {
        let chat = try await makeChat()
        let coach = try XCTUnwrap(chat.visibleMessages.last { $0.role == .assistant })
        _ = try warmUp(chat)


        // 悬停到老师气泡上：**不该**多出任何东西 —— 它的两颗本来就在那儿。
        //
        // ⚠️ 先量一次「同一份输入渲染两次」差多少当地板：`warmUp` 之后它应当是 **0**
        // （不是「接近 0」）。它一旦不是 0，说明这台机器上还有别的东西在动
        // （动画 / 计时器），那时后面每一条逐像素断言都不可信 —— 先修这个。
        let firstFrame = try render(chatView(chat), size: canvas)
        let secondFrame = try render(chatView(chat), size: canvas)
        let baseline = try compare(firstFrame, secondFrame)
        XCTAssertEqual(
            baseline.count, 0,
            "预热之后同一份输入两次出图必须逐像素相同"
                + "（实测差 \(baseline.count) 像素、最大通道差 \(baseline.maxDelta)；"
                + "两帧各收敛 \(firstFrame.settleRounds) / \(secondFrame.settleRounds) 轮"
                + "（上限 \(Self.maxSettleRounds)，**顶到上限**才说明当时还有东西一直在动）；"
                + "不是 0 就说明这台机器上还有动画/计时器在动，后面每条逐像素断言都不可信）"
        )

        let idle = try render(chatView(chat), size: canvas)
        let hovered = try render(chatView(chat, hovered: coach.id), size: canvas)
        let hoverDiff = try compare(idle, hovered)
        XCTAssertEqual(
            hoverDiff.significantPixels, 0,
            "老师气泡的动作行不靠悬停：悬停上去不该多出任何成块的东西"
                + "（实测 \(hoverDiff.significantPixels) 像素，\(hoverDiff.totalDescription)）"
        )

        // 但它在图上确实存在：把「重新生成」置灰，图上必须跟着有差 ——
        // 没有差就说明这一行压根没渲染出来（「始终显示」也就无从谈起）。
        let locked = try render(chatView(chat, canMutate: false), size: canvas)
        let lockedDiff = try compare(idle, locked)
        let lockedBlob = try XCTUnwrap(
            lockedDiff.largest,
            "把「重新生成」置灰后图上毫无变化 —— 这一行压根没渲染出来"
        )
        XCTAssertGreaterThan(
            lockedDiff.significantPixels, 40,
            "生成中 / 考试中「重新生成」会变淡，图上应当看得见这个变化"
                + "（实测 \(lockedDiff.significantPixels) 像素，最大通道差 \(lockedDiff.maxDelta)）"
        )
        XCTAssertLessThan(
            lockedBlob.heightPt(scale: idle.scale), 30,
            "变淡的只是一颗 20pt 的图标，不该牵动布局（最大一块高 \(lockedBlob.heightPt(scale: idle.scale))pt）"
        )

        try dump(locked, name: "round307-coach-locked.png")
    }

    // MARK: - ③ 编辑态：整条换成输入框

    func testEditingSwapsTheBubbleForALargerInputBox() async throws {
        let chat = try await makeChat()
        let user = try XCTUnwrap(chat.visibleMessages.first { $0.role == .user })
        _ = try warmUp(chat)
        let idle = try render(chatView(chat), size: canvas)
        let editing = try render(
            chatView(chat, editing: user.id, draft: user.content), size: canvas
        )
        let diff = try compare(idle, editing)

        let blob = try XCTUnwrap(diff.largest, "编辑态图上毫无变化 —— 气泡没有换成输入框")
        XCTAssertGreaterThan(
            diff.significantPixels, 500, "编辑态图上必须明显不同（实测 \(diff.significantPixels) 像素）"
        )
        XCTAssertGreaterThan(
            blob.heightPt(scale: idle.scale), 45,
            "输入框比一行气泡高一截（多出「后果说明 + 取消/发送」那一行），"
                + "实测最大一块高 \(blob.heightPt(scale: idle.scale))pt —— 与气泡同高说明只是个单行框"
        )

        try dump(editing, name: "round307-bubble-editing.png")
    }

    // MARK: - 组件级：几颗按钮就是几颗

    private struct Pixel { let r: Int, g: Int, b: Int
        var isInk: Bool { r + g + b < 600 }
    }

    private func pixel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Pixel {
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
            return Pixel(r: 255, g: 255, b: 255)
        }
        // ⚠️ 透明像素**不是墨**：`usingColorSpace(.sRGB)` 会把 alpha=0 解成 (0,0,0)，
        // 于是「画布上没被内容盖住的地方」会被当成一片黑 —— 固定尺寸出图时
        // 结果就是「到处都有墨」，按列数团数永远数出 1 团。
        guard color.alphaComponent > 0.5 else { return Pixel(r: 255, g: 255, b: 255) }
        return Pixel(
            r: Int(color.redComponent * 255),
            g: Int(color.greenComponent * 255),
            b: Int(color.blueComponent * 255)
        )
    }

    /// 横向数「几团墨」：按列聚合，两团之间要空出足够宽才拆开。
    private func inkClusters(_ rep: NSBitmapImageRep, gapPx: Int) -> Int {
        var inked = [Bool](repeating: false, count: rep.pixelsWide)
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh where pixel(rep, x, y).isInk {
                inked[x] = true
                break
            }
        }
        var clusters = 0
        var blanks = gapPx
        for x in 0..<rep.pixelsWide {
            if inked[x] {
                if blanks >= gapPx { clusters += 1 }
                blanks = 0
            } else {
                blanks += 1
            }
        }
        return clusters
    }

    /// 学员那三颗 = 三团墨（删除 / 编辑 / 复制）。
    func testLearnerRowDrawsThreeIcons() throws {
        let render = try render(
            ZStack {
                Color(hex: 0xE9EFE4)
                LearnerBubbleActionRow(text: "hello", onDelete: {}, onEdit: {})
            },
            size: CGSize(width: 120, height: 44)
        )
        let gap = max(2, Int(6 * render.scale))
        let clusters = inkClusters(render.rep, gapPx: gap)
        try dump(render, name: "round307-learner-row.png")
        XCTAssertEqual(
            clusters, 3,
            "学员气泡上是三颗（删除 / 编辑 / 复制）；团数不对说明有图标没画出来或被挤在一起"
        )
    }

    /// 老师那两颗 = 两团墨（复制 / 重新生成）。
    func testCoachRowDrawsTwoIcons() throws {
        let render = try render(
            ZStack {
                Color(hex: 0xE9EFE4)
                CoachBubbleActionRow(text: "hello", onRegenerate: {})
            },
            size: CGSize(width: 90, height: 44)
        )
        let gap = max(2, Int(6 * render.scale))
        let clusters = inkClusters(render.rep, gapPx: gap)
        try dump(render, name: "round307-coach-row.png")
        XCTAssertEqual(clusters, 2, "老师气泡上是两颗（复制 / 重新生成）")
    }

    // MARK: - 组件级：编辑框的边框看得见

    /// ⚠️ 这条是**自己给自己设的防**：编辑框是浅底上的浅底，
    /// 描边若选了 `theme.divider` 那种「白底 1.2:1」的颜色，框就等于不存在
    /// （同一个坑在阅读页的展开按钮上踩过一次）。
    func testEditBoxDrawsAVisibleBorderOnAllFourSides() throws {
        let size = CGSize(width: 520, height: 120)
        func box() -> some View {
            ZStack {
                Color(hex: 0xE9EFE4)
                MessageEditBox(
                    text: .constant("I want to order a coffee, please."), onCancel: {}, onSend: {}
                )
                .padding(16)
            }
        }
        // 同样先出一次废图（框里那个 `MultilineComposerField` 是 AppKit 的，第一次排版更慢）。
        _ = try render(box(), size: size)
        let render = try render(box(), size: size)
        let rep = render.rep
        try dump(render, name: "round307-edit-box.png")

        // 框在 16pt 内边距之内，取实际墨迹范围来定四条边（框宽由内容决定，最大 620）。
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh where pixel(rep, x, y).isInk {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        XCTAssertGreaterThan(minX, 0, "框应当出墨（连边框都没有就不必谈后面了）")
        XCTAssertGreaterThan(maxX - minX, Int(200 * render.scale), "框应当占满可用的宽度，而不是缩成一小条")

        // 内部基准色：从框内靠上取一点（避开描边本身与文字行）。
        let inner = pixel(rep, (minX + maxX) / 2, minY + Int(3 * render.scale))
        func maxDelta(on points: [(Int, Int)]) -> Int {
            points.map { point in
                let sample = pixel(rep, point.0, point.1)
                return abs(sample.r - inner.r) + abs(sample.g - inner.g) + abs(sample.b - inner.b)
            }.max() ?? 0
        }
        let inset = Int(6 * render.scale)
        let top = (0..<3).map { minX + inset + ($0 + 1) * (maxX - minX - inset * 2) / 4 }.map { ($0, minY) }
        let bottom = (0..<3).map { minX + inset + ($0 + 1) * (maxX - minX - inset * 2) / 4 }
            .map { ($0, maxY) }
        let left = (0..<3).map { minY + inset + ($0 + 1) * (maxY - minY - inset * 2) / 4 }
            .map { (minX, $0) }
        let right = (0..<3).map { minY + inset + ($0 + 1) * (maxY - minY - inset * 2) / 4 }
            .map { (maxX, $0) }

        XCTAssertGreaterThan(maxDelta(on: top), 60, "上边框看不见")
        XCTAssertGreaterThan(maxDelta(on: bottom), 60, "下边框看不见")
        XCTAssertGreaterThan(maxDelta(on: left), 60, "左边框看不见")
        XCTAssertGreaterThan(maxDelta(on: right), 60, "右边框看不见")

        try dump(render, name: "round307-edit-box.png")
    }

    /// 编辑框里那句「改完会发生什么」必须存在且说清两件事（数据，可测）。
    func testConsequenceHintNamesBothOutcomes() {
        let hint = MessageEditBox.consequenceHint
        XCTAssertTrue(hint.contains("重新开始对话"), "要讲清「后面聊过的会作废」：\(hint)")
        XCTAssertTrue(hint.contains("不会被删除"), "也要讲清「纠错 / 复盘这些产物不动」：\(hint)")
    }
}
