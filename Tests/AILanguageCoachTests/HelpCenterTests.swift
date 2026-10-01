import XCTest

@testable import AppUI

/// 应用内帮助中心（#413）的内容与接线。
///
/// 判据两块：①内容本身站得住（每节都有能读的正文，不是占位）；
/// ②**不写会漂移的东西** —— 快捷键、路径、具体数字一旦写死，用户改完快捷键
/// 帮助页就成了错的说明书（这条比「有没有内容」更容易被忽略）。
final class HelpCenterTests: XCTestCase {

    func testEveryTopicIsReadableAndUniquelyIdentified() {
        let topics = HelpCenter.topics
        XCTAssertFalse(topics.isEmpty)
        XCTAssertEqual(Set(topics.map(\.id)).count, topics.count, "id 重复会让展开态串节")
        for topic in topics {
            XCTAssertFalse(topic.title.isEmpty)
            XCTAssertFalse(topic.summary.isEmpty, "\(topic.id) 缺收起态那句话：用户靠它决定要不要展开")
            XCTAssertGreaterThanOrEqual(topic.bullets.count, 3, "\(topic.id) 正文太短，等于没写")
            for bullet in topic.bullets {
                XCTAssertFalse(bullet.trimmingCharacters(in: .whitespaces).isEmpty, "\(topic.id) 有空条目")
            }
        }
    }

    func testFirstTopicIsHowToConnectAModel() {
        // 新用户最常见的一问是「为什么老师不说话」—— 第一节必须回答它。
        XCTAssertEqual(HelpCenter.topics.first?.id, "setup")
    }

    func testSearchFiltersByBodyText() {
        let hits = HelpCenter.topics(matching: "备份")
        XCTAssertFalse(hits.isEmpty, "「备份」是帮助里最常被找的一节")
        XCTAssertTrue(hits.contains { $0.id == "data" })
        XCTAssertFalse(hits.contains { $0.id == "setup" })
    }

    func testEmptyQueryReturnsEverything() {
        // 「什么都没输」不是「什么都不匹配」。
        XCTAssertEqual(HelpCenter.topics(matching: "   ").count, HelpCenter.topics.count)
    }

    func testNoHardcodedShortcutsOrPaths() throws {
        // 帮助页写死快捷键 / 路径，用户一改就成了错的说明书：
        // 快捷键在「设置 → 快捷键中心」可改，数据目录在「设置 → 存储与缓存」可打开，
        // 帮助页只该指路，不该抄一份。
        let banned = ["⌘", "Cmd", "cmd", "Application Support"]
        // 路径不写成 `/Users/` 这类字面量，改用「任意 POSIX 绝对路径」的通用判据：
        // ①发布静态检查会连测试目录一起扫硬编码绝对路径（规则表里的字面量），写死就判红；
        // ②通用规则反而更严——/usr/local、/var、/Applications 一并拦住。
        let absolutePath = try NSRegularExpression(pattern: "/[A-Za-z][A-Za-z0-9_.-]*/")
        for topic in HelpCenter.topics {
            let text = topic.searchableText
            for token in banned {
                XCTAssertFalse(text.contains(token),
                               "\(topic.id) 里写了「\(token)」：会漂移的内容不要在帮助页写死")
            }
            let range = NSRange(text.startIndex..., in: text)
            let hit = absolutePath.firstMatch(in: text, options: [], range: range)
            XCTAssertNil(hit, "\(topic.id) 里写了绝对路径：会漂移的内容不要在帮助页写死")
        }
    }

    /// 接线哨兵：设置页得真的有这张卡，否则帮助中心没有任何入口（等于白写）。
    func testSettingsHostsHelpCenterCard() throws {
        let raw = try String(contentsOfFile: "Sources/AppUI/Views/SettingsView.swift", encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let text = lines.joined(separator: "\n")
        XCTAssertTrue(text.contains("helpCenterCard"), "设置页没挂帮助中心卡片")
        XCTAssertTrue(text.contains("HelpCenterView"), "卡片上没接 HelpCenterView")
    }

    /// 帮助中心要**全局可达**（2026-10-01）：它第一节写的就是「新用户最常见的一问」，
    /// 恰恰是那批人最不知道说明藏在设置页第一张卡里 —— 菜单栏必须有入口。
    func testHelpCenterIsReachableWithoutOpeningSettings() throws {
        let main = try String(contentsOfFile: "Sources/AppMain/AppMain.swift", encoding: .utf8)
        let mainLines = main.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let mainText = mainLines.joined(separator: "\n")
        XCTAssertTrue(mainText.contains("CommandGroup(replacing: .help)"),
                      "菜单栏没有帮助入口（说明只能先打开设置才够得着）")
        XCTAssertTrue(mainText.contains("state.showingHelp = true"),
                      "菜单项没有开帮助中心")

        // 全局浮层挂在 MainView 上，与设置页那张卡共用同一个状态（两份就会各开各的）。
        let view = try String(contentsOfFile: "Sources/AppUI/Views/MainView.swift", encoding: .utf8)
        let viewLines = view.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let viewText = viewLines.joined(separator: "\n")
        XCTAssertTrue(viewText.contains("$state.showingHelp"), "MainView 没挂全局帮助浮层")

        let settings = try String(contentsOfFile: "Sources/AppUI/Views/SettingsView.swift",
                                  encoding: .utf8)
        XCTAssertFalse(settings.contains("@State private var showingHelp"),
                       "设置页不该再自己持有一份 showingHelp（与全局那份会打架）")
    }
}
