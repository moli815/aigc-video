import SwiftUI

/// 自写 Markdown 渲染：支持标题、列表、引用、代码块、粗体、行内代码。
/// 解决系统 inlineOnly 渲染把段落/列表/代码全挤成一行的排版问题。
struct MarkdownView: View {
    let text: String

    @State private var expanded = false

    private let blocks: [Block]
    private let isCollapsible: Bool
    private let collapseDisabled: Bool

    private static let collapseLimit = 6

    init(_ text: String, collapseDisabled: Bool = false) {
        self.text = text
        self.collapseDisabled = collapseDisabled
        let parsed = collapseDisabled ? MarkdownView.parse(text) : MarkdownView.cachedParse(text)
        self.blocks = parsed
        self.isCollapsible = parsed.count > MarkdownView.collapseLimit && !collapseDisabled
    }

    private final class ParsedBox: NSObject {
        let blocks: [Block]
        init(_ blocks: [Block]) { self.blocks = blocks }
    }
    private static let cache: NSCache<NSString, ParsedBox> = {
        let cache = NSCache<NSString, ParsedBox>(); cache.countLimit = 200; cache.totalCostLimit = 2 * 1024 * 1024
        return cache
    }()
    private static func cachedParse(_ text: String) -> [Block] {
        let key = text as NSString
        if let box = cache.object(forKey: key) { return box.blocks }
        let parsed = parse(text); cache.setObject(ParsedBox(parsed), forKey: key, cost: text.utf8.count * 2)
        return parsed
    }

    // MARK: - 块定义

    enum Block {
        case heading(Int, String)
        case bullet(String)
        case quote(String)
        case code(String)
        case paragraph(String)
        case table([[String]])
    }

    var body: some View {
        if blocks.isEmpty {
            Text(text)
        } else {
            let visible = (expanded || !isCollapsible) ? blocks : Array(blocks.prefix(Self.collapseLimit))
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
                if isCollapsible {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                    } label: {
                        Label(expanded ? "收起" : "展开全文（共 \(blocks.count) 段）",
                              systemImage: expanded ? "chevron.up" : "chevron.down")
                            .font(.footnote)
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let content):
            switch level {
            case 1: inlineText(content).font(.title3.bold()).foregroundStyle(.primary)
            case 2: inlineText(content).font(.headline).foregroundStyle(.primary)
            default: inlineText(content).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            }
        case .bullet(let content):
            HStack(alignment: .top, spacing: 8) {
                Text("•").foregroundStyle(Color.accentColor)
                inlineText(content)
            }
        case .quote(let content):
            HStack(alignment: .top, spacing: 8) {
                Rectangle().fill(Color(.separator)).frame(width: 3)
                inlineText(content).italic().foregroundStyle(.secondary)
            }
            .padding(.leading, 4)
        case .code(let code):
            Text(code)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .table(let rows):
            MarkdownTableView(rows: rows)
        case .paragraph(let content):
            inlineText(content).lineSpacing(3)
        }
    }

    // MARK: - 行内：**粗体** 与 `行内代码`

    private func inlineText(_ s: String) -> Text {
        if let parsed = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) { return Text(parsed) }
        var result = Text("")
        var rest = s
        // 先处理 **粗体**
        while let open = rest.range(of: "**") {
            let before = String(rest[rest.startIndex..<open.lowerBound])
            result = result + inlineCodeSegments(before)
            let after = rest[open.upperBound...]
            if let close = after.range(of: "**") {
                let bold = String(after[after.startIndex..<close.lowerBound])
                result = result + Text(bold).bold()
                rest = String(after[close.upperBound...])
            } else {
                rest = String(after)
            }
        }
        result = result + inlineCodeSegments(rest)
        return result
    }

    /// 处理 `行内代码`（等宽 + 浅底）
    private func inlineCodeSegments(_ s: String) -> Text {
        var result = Text("")
        var rest = s
        while let tick = rest.range(of: "`") {
            let before = String(rest[rest.startIndex..<tick.lowerBound])
            result = result + Text(before)
            let after = rest[tick.upperBound...]
            if let close = after.range(of: "`") {
                let code = String(after[after.startIndex..<close.lowerBound])
                result = result + Text(code)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                rest = String(after[close.upperBound...])
            } else {
                rest = String(after)
            }
        }
        result = result + Text(rest)
        return result
    }

    // MARK: - 解析

    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var codeBuf: [String] = []
        var inCode = false
        var paragraph: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }

        let lines = text.components(separatedBy: .newlines)
        var index = 0
        while index < lines.count {
            let raw = lines[index]
            index += 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(codeBuf.joined(separator: "\n")))
                    codeBuf = []
                    inCode = false
                } else {
                    flushParagraph()
                    inCode = true
                }
                continue
            }
            if inCode {
                codeBuf.append(raw)
                continue
            }
            if line.contains("|"), index < lines.count, MarkdownTableCore.isSeparator(lines[index]), MarkdownTableCore.cells(line).count >= 2 {
                flushParagraph()
                let columns = MarkdownTableCore.cells(line).count
                var rows = [MarkdownTableCore.cells(line)]
                index += 1
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    let cells = MarkdownTableCore.cells(lines[index])
                    rows.append(cells + Array(repeating: "", count: max(0, columns - cells.count)))
                    index += 1
                }
                blocks.append(.table(rows)); continue
            }
            if line.isEmpty {
                flushParagraph()
                continue
            }
            if line.hasPrefix("### ") { flushParagraph(); blocks.append(.heading(3, String(line.dropFirst(4)))) }
            else if line.hasPrefix("## ") { flushParagraph(); blocks.append(.heading(2, String(line.dropFirst(3)))) }
            else if line.hasPrefix("# ") { flushParagraph(); blocks.append(.heading(1, String(line.dropFirst(2)))) }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flushParagraph(); blocks.append(.bullet(String(line.dropFirst(2))))
            } else if let r = line.range(of: #"^\d+[.、]\s*"#, options: .regularExpression) {
                flushParagraph(); blocks.append(.bullet(String(line[r.upperBound...])))
            } else if line.hasPrefix("> ") {
                flushParagraph(); blocks.append(.quote(String(line.dropFirst(2))))
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        if inCode && !codeBuf.isEmpty {
            blocks.append(.code(codeBuf.joined(separator: "\n")))
        }
        return blocks
    }
}


private struct MarkdownTableView: View {
    let rows: [[String]]
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    ForEach(Array((expanded ? rows : Array(rows.prefix(40))).enumerated()), id: \.offset) { row in
                        GridRow {
                            ForEach(Array(row.element.enumerated()), id: \.offset) { cell in
                                Text(cell.element).font(.subheadline.weight(row.offset == 0 ? .semibold : .regular))
                                    .frame(minWidth: 80, maxWidth: 220, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                        }
                    }
                }.padding(10)
            }
            .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            if rows.count > 40 {
                Button(expanded ? "收起表格" : "展开全部\(rows.count)行") { expanded.toggle() }.font(.footnote)
            }
        }
    }
}
