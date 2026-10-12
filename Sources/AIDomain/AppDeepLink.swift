import Foundation

// MARK: - alc:// 深链（纯解析）
//
// 为什么要有它：应用自己能被拉起的方式已经够多（Dock / Spotlight / 双击），
// 但**别人**要把用户送到某一页只有这一条路：
//   - 定时练习提醒点了只能进「今天」，进不了「今天该练的那个词」；
//   - 快捷指令 / 终端 / 日历提醒想一步跳到复习；
//   - 之后如果要做「今日回顾」邮件或 URL 分享，也得先有地址。
//
// 设计取舍：
// - host 一律与 `AppSection.rawValue` 同名（`alc://vocabulary`），另加几个口语别名
//   （`alc://review`）—— 手写时不必查文档，猜一个往往就对。
// - **认不出的地址返回 nil，绝不静默跳首页**。跳到 practice 会让发链接的人
//   以为生效了，而收的人看到的页面和预期不符 —— 宁可不跳。
//
// ⚠️ 本文件是纯函数：不 import SwiftUI、不认识 AppState。
// 「点下去会怎么样」那一步在 `AppState+DeepLink`。
public enum AppDeepLink {

    /// scheme。短到能随手打出来，长到不会撞上别人。
    public static let scheme = "alc"

    /// 解析结果。
    public enum Route: Sendable, Equatable {
        /// 跳到某一页（并把窗口叫到前面来）。
        case section(AppSection)
        /// 跳到练习页，并把这句话直接发过去（`alc://ask?text=…`）。
        ///
        /// 「带一句话进来」的价值：外部给的是**想说的话**而不是「某个功能」，
        /// 落到首屏还要用户再敲一遍，那一步就是流失点。
        case ask(String)
    }

    /// 一句话的那个参数。`text` 是正式名，`q` 是手写时的短名。
    private static let textKeys = ["text", "q"]

    // MARK: 解析

    /// 解析一个 URL；不是本应用的深链 / 认不出 → nil。
    public static func parse(_ url: URL) -> Route? {
        // ⚠️ 不能直接用 `url.host`：它不做百分号解码，
        // `URLComponents` 才是拿解码后的 host / query 的正规通路。
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              components.scheme?.lowercased() == scheme
        else { return nil }
        return route(host: components.host, items: components.queryItems)
    }

    /// 解析一段地址字符串（手抄、粘贴进来都走这里）。
    public static func parse(_ raw: String) -> Route? {
        guard let url = URL(string: raw) else { return nil }
        return parse(url)
    }

    private static func route(host: String?, items: [URLQueryItem]?) -> Route? {
        guard let host, !host.isEmpty else { return nil }
        let key = host.lowercased()
        if key == "ask" {
            guard let text = Self.query(items) else { return nil }
            return .ask(text)
        }
        guard let section = AppSection(deepLinkHost: key) else { return nil }
        return .section(section)
    }

    /// 取那一句要说的话：先 `text` 再 `q`，值一律去首尾空白，**空白当没有**。
    private static func query(_ items: [URLQueryItem]?) -> String? {
        guard let items else { return nil }
        for key in textKeys {
            guard let raw = items.first(where: { $0.name.lowercased() == key })?.value else { continue }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }

    // MARK: 生成

    /// 跳到某一页的地址。
    public static func url(for section: AppSection) -> URL {
        URL(string: "\(scheme)://\(section.deepLinkHost)") ?? URL(string: "\(scheme)://practice")!
    }

    /// 「把这句话发出去」的地址；没话可说返回 nil（别生成一条点了没反应的链接）。
    public static func url(ask text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "ask"
        components.queryItems = [URLQueryItem(name: "text", value: trimmed)]
        return components.url
    }

    /// 一条路由的地址（`Route` 回到字符串；回显 / 自测用得上）。
    public static func url(for route: Route) -> URL? {
        switch route {
        case let .section(section): return url(for: section)
        case let .ask(text): return url(ask: text)
        }
    }
}

// MARK: - 页面 ↔ 深链 host

public extension AppSection {

    /// 这一页的深链 host。
    ///
    /// 就是 `rawValue`：地址与页面同名的好处是不用维护第二张表，
    /// 加一页自动多一个地址。
    var deepLinkHost: String { rawValue }

    /// host → 页面：先按同名认，认不出再查别名表。
    ///
    /// ⚠️ 别名是**只进不出**的：生成地址永远用 `rawValue`（上面的 `deepLinkHost`），
    /// 不写两套别名的原因是「short ps ↔ scenario」双向映射最容易漏一边。
    init?(deepLinkHost host: String) {
        if let exact = AppSection(rawValue: host.lowercased()) {
            self = exact
            return
        }
        switch host.lowercased() {
        case "today", "chat": self = .practice
        case "shadow": self = .shadowing
        case "review", "words": self = .vocabulary
        case "scenario": self = .scenarios
        case "stats", "dashboard": self = .progress
        case "history", "record": self = .records
        default: return nil
        }
    }

    /// 今日任务的种类 → 该去的那一页。
    ///
    /// ⚠️ 全仓**唯一**一处做这个换算：今日任务卡、学习计划的「重点」、菜单栏那几条建议
    /// 都必须从这里读，否则一定会出现「点了复习却跳到跟读」这种没人敢改的错位。
    init(_ kind: DailyTask.Kind) {
        switch kind {
        case .conversation: self = .practice
        case .shadowing: self = .shadowing
        case .review: self = .vocabulary
        }
    }
}
