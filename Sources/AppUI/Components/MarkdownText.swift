import SwiftUI

// MARK: - 轻量 Markdown 渲染
//
// 不引第三方依赖：围栏代码块手写解析，行内语法交给 Foundation 的
// AttributedString(markdown:)（粗体/斜体/行内代码/链接），失败降级纯文本。

/// 聊天卡片里的 Markdown 文本：标题 / 列表 / 引用 / 围栏代码块 / 行内样式。
///
/// 传入 `lookup` 时，**行内内容改由可划词的文本视图渲染**（划过单词看释义、拖选一段翻译），
/// 块级结构（标题 / 列表 / 引用 / 代码块）与行内样式（粗体 / 斜体 / 代码）照旧保留。
/// 不传就还是原来的 `Text`（离屏渲染与单测走这条路）。
public struct MarkdownText: View {

    let text: String
    let fontSize: CGFloat
    let color: Color
    let lookup: WordLookupContext?

    public init(
        _ text: String,
        fontSize: CGFloat = 14,
        color: Color,
        lookup: WordLookupContext? = nil
    ) {
        self.text = text
        self.fontSize = fontSize
        self.color = color
        self.lookup = lookup
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.parseBlocks(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let content):
            inlineView(content, extraSize: CGFloat(max(0, 3 - level)), bold: true)
                .font(.system(
                    size: fontSize + CGFloat(max(0, 3 - level)),
                    weight: .bold, design: .rounded
                ))
                .foregroundStyle(color)
                .appPadding(.top, 2)

        case .bullet(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Circle().fill(color.opacity(0.65))
                            .frame(width: fontSize * 0.28, height: fontSize * 0.28)
                            .padding(.top, fontSize * 0.42)
                        inlineView(item)
                            .appFont(fontSize, design: .rounded)
                            .foregroundStyle(color)
                    }
                }
            }

        case .quote(let content):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.35)).frame(width: 3)
                inlineView(content)
                    .appFont(fontSize, design: .rounded)
                    .foregroundStyle(color.opacity(0.85))
            }

        case .paragraph(let content):
            inlineView(content)
                .appFont(fontSize, design: .rounded)
                .foregroundStyle(color)

        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 4) {
                if let language, !language.isEmpty {
                    Text(language.uppercased())
                        .appFont(9, weight: .semibold, design: .monospaced)
                        .foregroundStyle(color.opacity(0.55))
                }
                Text(code)
                    .appFont(fontSize - 1.5, design: .monospaced)
                    .foregroundStyle(color)
                    .textSelection(.enabled)
            }
            .appPadding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(color.opacity(0.15), lineWidth: 1)
            )
        }
    }

    /// 行内内容：有划词上下文 → 可划词的文本视图；没有 → 原来的 `Text`。
    @ViewBuilder
    private func inlineView(_ content: String, extraSize: CGFloat = 0, bold: Bool = false) -> some View {
        if let lookup {
            WordLookupSentence(
                markdownInline: content,
                fontSize: fontSize + extraSize,
                weight: bold ? .bold : .regular,
                color: color,
                context: lookup
            )
        } else {
            inlineText(content)
        }
    }

    /// 行内 markdown（**粗体** / *斜体* / `代码` / [链接](url)）→ AttributedString。
    private func inlineText(_ content: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: content,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(content)
    }

    // MARK: - 块级解析（纯函数，可单测）

    public enum Block: Equatable {
        case heading(level: Int, content: String)
        case bullet([String])
        case quote(String)
        case paragraph(String)
        case code(language: String?, code: String)
    }

    nonisolated public static func parseBlocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraphLines: [String] = []
        var bulletItems: [String] = []

        func flushParagraph() {
            if !paragraphLines.isEmpty {
                blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
                paragraphLines = []
            }
        }
        func flushBullets() {
            if !bulletItems.isEmpty {
                blocks.append(.bullet(bulletItems))
                bulletItems = []
            }
        }

        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let raw = lines[index]
            let line = raw.trimmingCharacters(in: .whitespaces)

            // 围栏代码块
            if line.hasPrefix("```") {
                flushParagraph()
                flushBullets()
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                index += 1 // 跳过收尾 ```
                blocks.append(.code(language: language.isEmpty ? nil : language, code: codeLines.joined(separator: "\n")))
                continue
            }

            // 空行：段落分隔
            if line.isEmpty {
                flushParagraph()
                flushBullets()
                index += 1
                continue
            }

            // 标题
            if let heading = headingLine(line) {
                flushParagraph()
                flushBullets()
                blocks.append(heading)
                index += 1
                continue
            }

            // 列表（- / * / 1.）
            if let item = bulletItemLine(line) {
                flushParagraph()
                bulletItems.append(item)
                index += 1
                continue
            }

            // 引用
            if line.hasPrefix(">") {
                flushParagraph()
                flushBullets()
                blocks.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
                index += 1
                continue
            }

            flushBullets()
            paragraphLines.append(line)
            index += 1
        }
        flushParagraph()
        flushBullets()
        return blocks
    }

    private nonisolated static func headingLine(_ line: String) -> Block? {
        let hashes = line.prefix(while: { $0 == "#" })
        guard (1...3).contains(hashes.count),
              line.count > hashes.count,
              line[line.index(line.startIndex, offsetBy: hashes.count)] == " " else { return nil }
        let content = line.dropFirst(hashes.count + 1).trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }
        return .heading(level: hashes.count, content: String(content))
    }

    private nonisolated static func bulletItemLine(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            let item = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            if !item.isEmpty { return item }
        }
        // 有序列表 "1. xxx"
        let digits = line.prefix(while: { $0.isNumber })
        if !digits.isEmpty, line.count > digits.count + 1 {
            let after = line[line.index(line.startIndex, offsetBy: digits.count)]
            if after == ".", line.index(after: line.index(line.startIndex, offsetBy: digits.count + 1)) < line.endIndex {
                let item = line.dropFirst(digits.count + 2).trimmingCharacters(in: .whitespaces)
                if !item.isEmpty { return item }
            }
        }
        return nil
    }
}
