import Foundation

/// 展示用时间格式化（纯函数，避免 DateFormatter 的 locale / 并发坑）。
public enum Timestamps {

    /// 每条对话上方的时间戳：`9月9日 周三 18:57`。
    public static func stamp(_ date: Date) -> String {
        let components = Calendar(identifier: .gregorian)
            .dateComponents([.month, .day, .weekday, .hour, .minute], from: date)
        let weekdays = ["", "周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let weekday = weekdays[max(0, min(components.weekday ?? 0, 7))]
        return String(
            format: "%d月%d日 %@ %02d:%02d",
            components.month ?? 0,
            components.day ?? 0,
            weekday,
            components.hour ?? 0,
            components.minute ?? 0
        )
    }
}
