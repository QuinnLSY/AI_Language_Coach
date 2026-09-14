import AppCore
import SwiftUI
@testable import AppUI
import XCTest

/// 「下拉选择点不动」的回归测试（2026-09-14 用户实测：很难响应甚至不响应）。
///
/// 根因不是外观，而是**命中范围**：原先用 SwiftUI `Menu` + 透明 label，
/// 系统给空 label 的尺寸提案极小（无障碍实测 6×14），于是控件看着有 250×30，
/// 实际只有中间一小块能点。现在命中区是 AppKit 的 `PopUpHitView`，
/// 下面这些断言就是在钉住「整框范围内点哪儿都算点到」。
@MainActor
final class ForestSelectHitAreaTests: XCTestCase {

    /// 窗口必须被强引用保住：contentView 会随窗口释放而消失，宿主视图也就没了子视图。
    private var window: NSWindow?

    private func makeHost(_ view: AnyView, size: CGSize) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        self.window = window
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        return host
    }

    private func makeSelect(
        width: CGFloat = 250,
        options: [ForestSelectOption<String>] = [
            ForestSelectOption(value: "alpha-model", title: "alpha-model"),
            ForestSelectOption(value: "beta-model", title: "beta-model"),
        ],
        selection: Binding<String>
    ) -> AnyView {
        AnyView(
            ForestSelect(
                "模型", icon: "cpu", selection: selection, options: options, width: width
            )
        )
    }

    func testHitAreaCoversTheWholeField() throws {
        var model = "alpha-model"
        let host = makeHost(
            makeSelect(selection: Binding(get: { model }, set: { model = $0 })),
            size: CGSize(width: 520, height: 60)
        )
        let hit = try XCTUnwrap(host.firstDescendant(ofType: PopUpHitView.self), "没有命中区")

        // ⚠️ `hit.frame` 是相对它**自己的父视图**的；SwiftUI 中间会夹容器视图，
        // 所以必须换算到宿主视图坐标系再拿去做 hitTest。
        let field = hit.convert(hit.bounds, to: host)
        XCTAssertEqual(field.width, 250, accuracy: 0.5, "命中区宽度必须等于控件宽度")
        XCTAssertEqual(field.height, 30, accuracy: 0.5, "命中区高度必须等于控件高度")
        XCTAssertGreaterThan(field.minX, 20, "命中区应在左侧标签之外，标签不参与命中")

        // 四角与中心都要能点到 —— 这正是原实现失败的地方（只有中间极小区域响应）。
        let probes: [NSPoint] = [
            NSPoint(x: field.minX + 1, y: field.midY),
            NSPoint(x: field.maxX - 1, y: field.midY),
            NSPoint(x: field.midX, y: field.minY + 1),
            NSPoint(x: field.midX, y: field.maxY - 1),
            NSPoint(x: field.minX + 1, y: field.minY + 1),
            NSPoint(x: field.maxX - 1, y: field.maxY - 1),
            NSPoint(x: field.midX, y: field.midY),
        ]
        for point in probes {
            let landed = host.hitTest(point)
            let ok = landed === hit || landed?.isDescendant(of: hit) == true
            XCTAssertTrue(
                ok,
                "点 \(Int(point.x)),\(Int(point.y)) 没落在命中区上，实际落到 \(String(describing: landed))"
            )
        }
    }

    func testHitAreaExposesAccessibilityValue() throws {
        var model = "beta-model"
        let host = makeHost(
            makeSelect(selection: Binding(get: { model }, set: { model = $0 })),
            size: CGSize(width: 520, height: 60)
        )
        let hit = try XCTUnwrap(host.firstDescendant(ofType: PopUpHitView.self))

        XCTAssertEqual(hit.accessibilityRole(), .popUpButton)
        XCTAssertEqual(hit.accessibilityLabel(), "模型")
        XCTAssertEqual(hit.accessibilityValue() as? String, "beta-model")
        XCTAssertEqual(hit.menuTitles, ["alpha-model", "beta-model"])
    }

    func testSelectingAnItemUpdatesTheBinding() throws {
        var model = "alpha-model"
        let host = makeHost(
            makeSelect(selection: Binding(get: { model }, set: { model = $0 })),
            size: CGSize(width: 520, height: 60)
        )
        let hit = try XCTUnwrap(host.firstDescendant(ofType: PopUpHitView.self))

        hit.select(index: 1)
        XCTAssertEqual(model, "beta-model", "选中第二项后 binding 必须跟着变")

        hit.select(index: 0)
        XCTAssertEqual(model, "alpha-model", "选中第一项后 binding 必须回得来")

        // 越界索引不能崩、也不能改值。
        hit.select(index: 99)
        XCTAssertEqual(model, "alpha-model")
    }

    func testEmptyOptionsDisableInteraction() throws {
        var model = ""
        let host = makeHost(
            makeSelect(
                options: [],
                selection: Binding(get: { model }, set: { model = $0 })
            ),
            size: CGSize(width: 520, height: 60)
        )
        let hit = try XCTUnwrap(host.firstDescendant(ofType: PopUpHitView.self))

        // 没有可选项时：`acceptsFirstResponder` 为 false，且「按下」是空操作
        // （`accessibilityPerformPress` 会真的弹菜单，所以只在这个禁用态调用）。
        XCTAssertFalse(hit.acceptsFirstResponder)
        XCTAssertFalse(hit.accessibilityPerformPress())
        XCTAssertEqual(model, "")
    }

    /// 紧凑档（对话区「语速」）的宽度必须由**按实际字体的实测**决定，而不是写死。
    ///
    /// 2026-09-14 反馈「老师朗读的速率未正常显示」：原先写死 62pt，
    /// 值被压成省略号。这里钉住「量宽结果」与「声明的宽度」两件事。
    func testCompactRateChipWidthIsMeasuredNotHardcoded() throws {
        let labels = SpeechRate.allCases.map(\.label)
        let widest = labels.max { textWidth($0, size: 10) < textWidth($1, size: 10) } ?? "2.5×"
        let widestWidth = textWidth(widest, size: 10)
        let metrics = ForestSelect<Double>.Metrics.compact

        // ① 量宽结果必须真的装得下最宽的值（`widthFitting` 已含取整 + 2pt 余量）。
        let fitted = metrics.widthFitting(labels)
        XCTAssertGreaterThanOrEqual(
            fitted, metrics.minimumWidth(forValueWidth: widestWidth),
            "量出的宽度必须不小于「按最宽值算出的最小宽度」"
        )

        // ② 记录这是个真实回归：旧的写死 62pt 确实不够（否则本用例没有意义）。
        //    实测临界点是「0.5× 需要 >62、65 才完整」，见下一个渲染用例。
        XCTAssertGreaterThan(
            metrics.minimumWidth(forValueWidth: widestWidth), 62,
            "若 62pt 已够用，说明本用例已失效，应重新评估「值被截断」的假设"
        )

        // ③ 控件按调用方给的宽度渲染时，宽度不得被外层摊开或压缩。
        for label in [SpeechRate.x1.label, widest] {
            let rate = SpeechRate.allCases.first { $0.label == label }?.rawValue ?? 1
            let host = makeHost(
                AnyView(
                    ForestSelect(
                        icon: "speedometer",
                        selection: Binding(get: { rate }, set: { _ in }),
                        options: SpeechRate.allCases.map {
                            ForestSelectOption(value: $0.rawValue, title: $0.label)
                        },
                        metrics: .compact, width: fitted
                    )
                ),
                size: CGSize(width: 240, height: 40)
            )
            let hit = try XCTUnwrap(host.firstDescendant(ofType: PopUpHitView.self))
            let field = hit.convert(hit.bounds, to: host)

            XCTAssertEqual(field.height, 20, accuracy: 0.5, "紧凑档高度仍应是 20")
            XCTAssertEqual(field.width, fitted, accuracy: 0.5, "固定宽度不得被外层摊开或压缩")
        }
    }

    /// `isCircular` 命中区：圆内才算点到，矩形四角不算（否则圆形按钮会抢邻居的点击）。
    ///
    /// 输入区「+」换成 `MenuPopUpHitArea` 后靠它保持与旧 `Menu` label 上
    /// `.contentShape(Circle())` 等价的点击语义。
    func testCircularHitAreaIgnoresCorners() throws {
        let hit = PopUpHitView()
        hit.frame = NSRect(x: 33, y: 33, width: 34, height: 34)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        container.addSubview(hit)
        hit.apply(
            titles: ["添加图片", "添加视频", "添加文件"], selectedIndex: nil, isEnabled: true,
            accessibilityTitle: "添加附件", tooltip: nil, isCircular: true, onSelect: { _ in }
        )

        // `hitTest` 的点在**父视图**坐标系里。
        let center = NSPoint(x: 50, y: 50)     // 圆心
        let edge = NSPoint(x: 64, y: 50)       // 圆的右缘（距圆心 14 < 半径 17）
        let corner = NSPoint(x: 34, y: 34)     // 方框角（距圆心 ≈22.6 > 半径 17）

        XCTAssertTrue(hit.hitTest(center) === hit, "圆心必须点到")
        XCTAssertTrue(hit.hitTest(edge) === hit, "圆缘必须点到")
        XCTAssertNil(hit.hitTest(corner), "矩形四角不得算命中（会抢相邻按钮的点击）")
    }

    /// 值必须**真的被画出来** —— 不是靠公式推断，而是渲染后逐像素比对。
    /// 做法：同一枚控件渲染两次，一次把选项标题置空（只剩图标 / 箭头 / 底板）、
    /// 一次用真实标题；两张位图相减，差异区就是**文字字形**。再与「宽到不可能截断」
    /// 的同款渲染比墨迹宽度：相等 = 完整；明显更窄 = 被截成省略号。
    ///
    /// 为什么必须有这个用例：2026-09-14 的修复过程中，「按公式估算够宽」骗了我两次 ——
    /// 62pt 和 68pt 在几何上都还剩 30pt 以上空档，实际却只画出 7pt 宽的省略号
    /// （`Spacer` 与值同排时会把它挤掉）。只有像素才说真话。
    func testCompactRateChipReallyDrawsItsWidestValue() throws {
        let labels = SpeechRate.allCases.map(\.label)
        let widest = labels.max { textWidth($0, size: 10) < textWidth($1, size: 10) } ?? "2.5×"
        let fitted = ForestSelect<Double>.Metrics.compact.widthFitting(labels)

        for label in [widest, SpeechRate.x1.label] {
            let atFitted = try inkWidth(ofValue: label, chipWidth: fitted)
            let atLoose = try inkWidth(ofValue: label, chipWidth: fitted + 60)

            XCTAssertGreaterThan(atFitted, 0, "「\(label)」完全没画出来")
            XCTAssertEqual(
                atFitted, atLoose, accuracy: 0.5,
                "在 \(fitted)pt 下画出的「\(label)」比宽裕时窄 —— 值被截断了"
            )
        }
    }

    /// 用像素差分量出「值为 `label` 时画出来的字形墨迹宽度」。
    ///
    /// 控件摆在比自身宽得多的画布上（leading），避免箭头被画布裁掉而干扰。 
    private func inkWidth(ofValue label: String, chipWidth: CGFloat) throws -> CGFloat {
        let rate = try XCTUnwrap(SpeechRate.allCases.first { $0.label == label }?.rawValue)
        let blank = try render(chipWidth: chipWidth, rate: rate, title: "")
        let filled = try render(chipWidth: chipWidth, rate: rate, title: label)
        return try XCTUnwrap(diffInkWidth(blank, filled), "「\(label)」处没有任何差异像素")
    }

    private func render(chipWidth: CGFloat, rate: Double, title: String) throws -> NSBitmapImageRep {
        let options: [ForestSelectOption<Double>] = title.isEmpty
            ? [ForestSelectOption(value: rate, title: "")]
            : SpeechRate.allCases.map { ForestSelectOption(value: $0.rawValue, title: $0.label) }
        let size = CGSize(width: 240, height: 24)
        let host = NSHostingView(
            rootView: AnyView(
                ForestSelect(
                    icon: "speedometer",
                    selection: Binding(get: { rate }, set: { _ in }),
                    options: options,
                    metrics: .compact, width: chipWidth
                )
                .frame(width: size.width, height: size.height, alignment: .leading)
                .background(Color.white)
            )
        )
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// 两张位图的差异包围盒宽度（点）。差异即「文字字形」。
    private func diffInkWidth(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> CGFloat? {
        var minX = Int.max, maxX = Int.min
        for x in 0..<min(a.pixelsWide, b.pixelsWide) {
            for y in 0..<min(a.pixelsHigh, b.pixelsHigh) {
                guard let ca = a.colorAt(x: x, y: y), let cb = b.colorAt(x: x, y: y) else { continue }
                let delta = abs(ca.redComponent - cb.redComponent)
                    + abs(ca.greenComponent - cb.greenComponent)
                    + abs(ca.blueComponent - cb.blueComponent)
                if delta > 0.08 {
                    minX = min(minX, x); maxX = max(maxX, x)
                }
            }
        }
        guard minX <= maxX else { return nil }
        // 位图是 2x 备份：换算回点，并与宿主视图等宽（240pt）对应。
        let scale = CGFloat(a.pixelsWide) / 240
        return CGFloat(maxX - minX + 1) / scale
    }

    /// 与控件内文字同款字体的宽度测量（`.system(size:weight:.medium, design:.rounded)`）。
    /// 走 `ForestSelect.Metrics.roundedFont`，与控件共用同一处字体定义。
    private func textWidth(_ text: String, size: CGFloat) -> CGFloat {
        let font = ForestSelect<Double>.Metrics.roundedFont(size: size, weight: .medium)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }
}

private extension NSView {
    /// 深度优先找第一个指定类型的后代（命中区就在宿主视图的子树里）。
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T { return match }
            if let deeper = subview.firstDescendant(ofType: type) { return deeper }
        }
        return nil
    }
}
