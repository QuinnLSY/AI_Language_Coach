import Foundation

/// 学习记录导出（② 数据安全闭环）：把库里攒的资产导出成**人类可读**的文件。
///
/// 为什么是 Markdown + CSV 两个文件：
/// - 会话与错题有叙述结构（谁说的、错在哪、为什么），Markdown 直读最好；
/// - 单词本是表格（释义 / 掌握度 / 复习次数），CSV 进 Excel / Numbers 直接能筛。
///
/// 纯函数：只做「数据 → 文本」的换算，不碰文件系统 —— 方便单测与上层自由落盘。
public enum LearningDataExporter {

    /// 一次导出产出的两段文本。
    public struct Output: Sendable, Equatable {
        /// 会话 + 错题，人类可读。
        public let markdown: String
        /// 单词本，表格软件可读。
        public let csv: String
    }

    /// 一个会话的摘要与完整流水。
    public struct SessionTranscript: Sendable, Equatable {
        public let summary: SessionSummary
        public let messages: [ChatMessage]

        public init(summary: SessionSummary, messages: [ChatMessage]) {
            self.summary = summary
            self.messages = messages
        }
    }

    /// 把会话流水、错题与单词本折成导出文本。
    ///
    /// 全空也照样出文件（标题 + 计数 0）：导出「空」本身就是如实回答
    /// 「这个库里有啥」，比弹「没有可导出的内容」更省事也更诚实。
    public static func export(
        sessions: [SessionTranscript],
        vocabulary: [VocabularyEntry],
        now: Date = Date()
    ) -> Output {
        Output(markdown: markdown(sessions: sessions, now: now), csv: csv(vocabulary: vocabulary))
    }

    // MARK: - Markdown（会话 + 错题）

    private static func markdown(sessions: [SessionTranscript], now: Date) -> String {
        var lines: [String] = [
            "# 学习记录导出",
            "",
            "导出时间：\(displayStamp(now))",
            "",
        ]

        lines.append("## 练习会话（\(sessions.count) 次）")
        lines.append("")
        if sessions.isEmpty {
            lines.append("（还没有练习会话）")
            lines.append("")
        }
        for transcript in sessions {
            let summary = transcript.summary
            let mode = summary.scenarioID.map { "情景 \($0)" } ?? "普通练习"
            lines.append("### \(displayStamp(summary.startedAt)) · \(mode) · \(summary.messageCount) 条消息")
            lines.append("")
            for message in transcript.messages where message.role != .system {
                let speaker = message.role == .user ? "我" : "老师"
                lines.append("- **\(speaker)**：\(message.content.replacingOccurrences(of: "\n", with: " "))")
            }
            if !summary.corrections.isEmpty {
                lines.append("")
                lines.append("本次纠错 \(summary.corrections.count) 条：")
                lines.append("")
                lines.append("| 原句 | 改正 | 说明 |")
                lines.append("| --- | --- | --- |")
                for correction in summary.corrections {
                    lines.append(
                        "| \(escapeCell(correction.original)) | \(escapeCell(correction.corrected)) | \(escapeCell(correction.explanation)) |"
                    )
                }
            }
            lines.append("")
        }

        let allCorrections = sessions.flatMap(\.summary.corrections)
        lines.append("## 错题汇总（\(allCorrections.count) 条）")
        lines.append("")
        if allCorrections.isEmpty {
            lines.append("（还没有纠错记录）")
        } else {
            lines.append("| 原句 | 改正 | 说明 |")
            lines.append("| --- | --- | --- |")
            for correction in allCorrections {
                lines.append(
                    "| \(escapeCell(correction.original)) | \(escapeCell(correction.corrected)) | \(escapeCell(correction.explanation)) |"
                )
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - CSV（单词本）

    private static let csvHeader = ["单词", "释义", "例句", "难度", "掌握度", "复习次数", "添加时间", "来源"]

    private static func csv(vocabulary: [VocabularyEntry]) -> String {
        var rows: [String] = [csvHeader.map(csvEscape).joined(separator: ",")]
        for entry in vocabulary {
            rows.append([
                entry.word,
                entry.meaning,
                entry.example,
                String(entry.difficulty),
                String(entry.mastery),
                String(entry.reviewCount),
                displayStamp(entry.createdAt),
                entry.source.rawValue,
            ].map(csvEscape).joined(separator: ","))
        }
        return rows.joined(separator: "\r\n") + "\r\n"
    }

    /// CSV 字段转义：含逗号 / 引号 / 换行的字段整段加引号，内部引号翻倍（RFC 4180）。
    static func csvEscape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Markdown 表格单元格：竖线会破表，换成全角。
    private static func escapeCell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "｜").replacingOccurrences(of: "\n", with: " ")
    }

    /// 时间戳：本地时区的 `yyyy-MM-dd HH:mm`（导出物是给人看的，秒级精度是噪音）。
    private static func displayStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
