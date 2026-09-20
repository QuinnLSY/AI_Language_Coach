import Foundation

// MARK: - 应用页面（侧栏导航的唯一定义）
//
// 为什么要有这个枚举：原先「当前在哪一页」是由 7 个独立布尔量拼出来的 ——
// 每个 `open*()` 自己手写一串 `showingXxx = false`，侧栏再用
// `!a && !b && !c && …` 去反推「练习是不是高亮」。
// 这种写法有两个必然的毛病，而且都在代码里真实发生了：
//
// 1. **漏写复位**：`openScenarios()` 只清了 `showingDictionary`，
//    于是从「学习记录」点「情景对话」，两个条目会同时高亮。
// 2. **快捷键 / 菜单无处可挂**：想加「跳转到第 N 页」时，
//    没有任何一处能一眼说清「第 3 页是什么」。
//
// 现在页面顺序就是 `allCases` 的顺序，侧栏文案、快捷键、菜单都从这里读，
// 三处不会各说各的。
//
// ⚠️ 这里是**纯数据**：不 import SwiftUI，也不认识 `AppState`。
// 它是「有哪几页」这个事实本身，不是页面怎么画。
public enum AppSection: String, CaseIterable, Sendable, Identifiable, Hashable {

    /// 练习（中间对话区，默认页）。
    case practice
    /// 跟读。
    case shadowing
    /// 写作（#230：每天一题 + 老师批改）。
    case writing
    /// 阅读（#231：每日短文 + 阅读理解四选一）。
    case reading
    /// 词典。
    case dictionary
    /// 词汇本。
    case vocabulary
    /// 情景对话选择。
    case scenarios
    /// 学习进度。
    case progress
    /// 学习记录。
    case records

    public var id: String { rawValue }

    /// 侧栏上显示的名字。侧栏与菜单共用，别在界面里另写一份字面量。
    public var title: String {
        switch self {
        case .practice: return "练习"
        case .shadowing: return "跟读"
        case .writing: return "写作"
        case .reading: return "阅读"
        case .dictionary: return "词典"
        case .vocabulary: return "词汇本"
        case .scenarios: return "情景对话"
        case .progress: return "学习进度"
        case .records: return "学习记录"
        }
    }

    /// SF Symbol 名字。放这里是为了让「侧栏图标」和「菜单图标」天然一致。
    public var systemImage: String {
        switch self {
        case .practice: return "leaf.fill"
        case .shadowing: return "waveform.badge.mic"
        case .writing: return "square.and.pencil"
        case .reading: return "book.fill"
        case .dictionary: return "character.book.closed.fill"
        case .vocabulary: return "text.book.closed.fill"
        case .scenarios: return "map.fill"
        case .progress: return "chart.line.uptrend.xyaxis"
        case .records: return "chart.bar.fill"
        }
    }

    /// 数字快捷键（从 1 起），等于它在侧栏里的位置。
    ///
    /// 从 `allCases` 推而不是手写常量：加一页时只要插进枚举，
    /// 侧栏顺序与快捷键编号一起跟着变，不会出现「侧栏第 4 项却是 Cmd+6」这种错位。
    public var shortcutDigit: Int {
        (Self.allCases.firstIndex(of: self) ?? 0) + 1
    }
}
