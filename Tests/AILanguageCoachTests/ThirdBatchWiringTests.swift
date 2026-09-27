import XCTest

@testable import AppUI

/// 第三批（2026-09-27）的接线哨兵：骨架屏 / 滚动回弹 / 阴影档位 / 浮层材质。
///
/// 这些线一断**不报错、只会静默回到旧行为**（浮层悄悄失去毛玻璃、某页悄悄恢复硬弹），
/// 只能扫源码。⚠️ 哨兵扫描的字符串不能出现在被扫文件的注释里（同款字符串会假绿）；
/// ⚠️ 反证必须**真删**——注释掉会被哨兵扫到同款字符串，照样绿（09-25 教训）。
final class ThirdBatchWiringTests: XCTestCase {

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOfFile: "Sources/\(relativePath)", encoding: .utf8)
    }

    private func allSources() throws -> [String] {
        let root = URL(fileURLWithPath: "Sources")
        var files: [String] = []
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                files.append(try String(contentsOf: url, encoding: .utf8))
            }
        }
        return files
    }

    private func count(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    // MARK: - #359 骨架屏 + 阶段条

    /// 阅读页加载态必须进骨架卡 —— 换回转圈卡是最容易发生的「顺手回退」。
    func testReadingLoadingUsesSkeleton() throws {
        let reading = try source("AppUI/Views/ReadingView.swift")
        XCTAssertTrue(reading.contains("SkeletonReadingCard()"), "阅读页加载态应是骨架卡")
        XCTAssertFalse(
            reading.contains("老师正在写今天的短文…"),
            "旧转圈卡文案应已删除（读屏语义由骨架卡的 accessibilityLabel 承接）"
        )
    }

    /// 跟读页在「素材还没到」时必须先给骨架，而不是落进空态引导。
    func testShadowingLoadingUsesSkeleton() throws {
        let shadowing = try source("AppUI/Views/ShadowingView.swift")
        XCTAssertTrue(
            shadowing.contains("SkeletonShadowingCard()"),
            "跟读页 isShadowingLoading 分支应是骨架卡"
        )
    }

    /// 等待卡必须有阶段参数，且 ChatView 传的是**真实信号**——
    /// 传成常量的话两阶段永远是同一帧，阶段条就是摆设。
    func testTeacherPreparingStageWiring() throws {
        let card = try source("AppUI/Components/TeacherPreparingCard.swift")
        XCTAssertTrue(card.contains("var stage: TeacherWaitStage"), "等待卡要收 stage 参数")
        let chat = try source("AppUI/Views/ChatView.swift")
        XCTAssertTrue(
            chat.contains(".booting : .greeting"),
            "ChatView 要把 isBooting 翻译成阶段"
        )
    }

    // MARK: - #360 滚动回弹

    /// 九个主滚动容器都挂了 basedOnSize。漏一页 = 那页内容不足一屏时照样硬弹。
    func testScrollBounceBehaviorWiredOnAllMainScrollContainers() throws {
        let files = [
            "AppUI/Views/ChatView.swift",
            "AppUI/Views/ReadingView.swift",
            "AppUI/Views/ShadowingView.swift",
            "AppUI/Views/VocabularyView.swift",
            "AppUI/Views/DictionaryView.swift",
            "AppUI/Views/SettingsView.swift",
            "AppUI/Views/ListeningView.swift",
            "AppUI/Views/LearningProgressView.swift",
            "AppUI/Views/WritingView.swift",
            "AppUI/Views/RecordsView.swift",
        ]
        for file in files {
            XCTAssertTrue(
                try source(file).contains(".scrollBounceBehavior(.basedOnSize)"),
                "\(file) 的滚动容器缺 .scrollBounceBehavior(.basedOnSize)"
            )
        }
    }

    // MARK: - #361 阴影档位 + 浮层材质

    /// 散落的裸阴影必须收编进档位：这些字符串再出现在 Sources 里 = 有人绕过了档位。
    /// （白名单见 `AppElevation` 文档：ModelToast 的 tint 光晕 / 插画装饰光不在档位系统里。）
    func testNoBareThemeShadowsOutsideTheElevationSystem() throws {
        let forbidden = [
            ".shadow(color: theme.shadow, radius: 8, x: 0, y: 3)",
            ".shadow(color: theme.shadow, radius: 10, x: 0, y: 4)",
            ".shadow(color: theme.shadow, radius: 14, x: 0, y: 6)",
            ".shadow(color: theme.shadow, radius: 6, x: 0, y: 2)",
            ".shadow(color: state.theme.shadow, radius: 30, x: 0, y: 14)",
            ".shadow(color: .black.opacity(0.14), radius: 8, y: 3)",
        ]
        let sources = try allSources()
        for needle in forbidden {
            for text in sources where text.contains(needle) {
                XCTFail("发现绕过档位的裸阴影：\(needle)（请改用 .appElevation(...)）")
            }
        }
    }

    /// 四档都有真实调用点：档位系统最怕「定义了没人用」——
    /// 每档至少一处，sheet 就是 MainView 那六个面板。
    func testEveryElevationLevelHasCallSites() throws {
        let sources = try allSources()
        let joined = sources.joined()
        XCTAssertGreaterThanOrEqual(count(".appElevation(.card)", in: joined), 15)
        XCTAssertGreaterThanOrEqual(count(".appElevation(.raised)", in: joined), 7)
        XCTAssertGreaterThanOrEqual(count(".appElevation(.overlay)", in: joined), 2)
        XCTAssertGreaterThanOrEqual(count(".appElevation(.sheet)", in: joined), 6)
    }

    /// 三个悬停在内容上方的浮层必须走材质表面 ——
    /// 材质体系的价值在「浮层与卡片的质感分界」，漏一处就静默退回实底。
    func testFloatingOverlaysUseTheMaterialSurface() throws {
        let overlays = [
            "AppUI/Components/RewardToast.swift",
            "AppUI/Components/StreakBadgeView.swift",
            "AppUI/Components/WordLookupBubble.swift",
        ]
        for file in overlays {
            XCTAssertTrue(
                try source(file).contains(".floatingSurface(in:"),
                "\(file) 是浮层，应走 .floatingSurface(in:)（材质 + reduceTransparency 兜底）"
            )
        }
    }
}
