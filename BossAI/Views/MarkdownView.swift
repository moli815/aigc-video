import SwiftUI

/// Full answers by default. Only an explicit user action can collapse an answer.
struct MarkdownView: View, Equatable {
    let text: String
    let collapseDisabled: Bool
    @State private var collapsed = false
    @State private var blocks: [Block]
    init(_ text: String, collapseDisabled: Bool = false) {
        self.text = text; self.collapseDisabled = collapseDisabled
        _blocks = State(initialValue: Self.cache.object(forKey: text as NSString)?.blocks ?? [])
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.collapseDisabled == rhs.collapseDisabled
    }
    enum Block: Equatable, Sendable {
        case heading(Int, String), bullet(String), quote(String), code(String), paragraph(String)
        case table([[String]]), divider
    }
    private final class ParsedBox: NSObject {
        let blocks: [Block]
        init(_ blocks: [Block]) { self.blocks = blocks }
    }
    private static let cache: NSCache<NSString, ParsedBox> = {
        let cache = NSCache<NSString, ParsedBox>()
        cache.countLimit = 200; cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()
    // One worker prevents concurrent long-message parsing from multiplying peak memory.
    private actor Worker {
        func parse(_ text: String, cacheResult: Bool) throws -> [Block] {
            try Task.checkCancellation()
            if let box = MarkdownView.cache.object(forKey: text as NSString) { return box.blocks }
            let result = MarkdownView.parse(text)
            try Task.checkCancellation()
            // Do not retain every prefix of a streaming answer in the shared cache.
            if cacheResult {
                MarkdownView.cache.setObject(ParsedBox(result), forKey: text as NSString, cost: text.utf8.count * 4)
            }
            return result
        }
    }
    private static let worker = Worker()
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if blocks.isEmpty && !text.isEmpty {
                Text(text).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array((collapsed ? Array(blocks.prefix(1)) : blocks).enumerated()), id: \.offset) { index, block in
                    blockView(block, index: index)
                }
            }
            if !collapseDisabled && blocks.count > 6 {
                Button {
                    // No animation of thousands of table cells on the main thread.
                    collapsed.toggle()
                } label: {
                    Label(collapsed ? "展开完整回答" : "收起回答", systemImage: collapsed ? "chevron.down" : "chevron.up")
                        .font(.footnote)
                }
                .buttonStyle(.plain).accessibilityIdentifier("answer-collapse")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .task(id: text) {
            do {
                let result = try await Self.worker.parse(text, cacheResult: !collapseDisabled)
                try Task.checkCancellation()
                blocks = result
            } catch { /* A newer text or a dismissed view cancels obsolete work. */ }
        }
    }
    @ViewBuilder private func blockView(_ block: Block, index: Int) -> some View {
        switch block {
        case .heading(let level, let value):
            InlineMarkdown.text(value).font(level == 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let value):
            HStack(alignment: .top, spacing: 8) {
                Text("•").foregroundStyle(Color.accentColor)
                InlineMarkdown.text(value).fixedSize(horizontal: false, vertical: true)
            }
        case .quote(let value):
            InlineMarkdown.text(value).italic().foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Color(.separator)).frame(width: 3) }
        case .code(let value):
            ScrollView(.horizontal) {
                Text(value).font(.system(.subheadline, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: true).padding(10)
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        case .table(let rows): MarkdownTableView(rows: rows, identifier: "table-\(index)")
        case .paragraph(let value):
            InlineMarkdown.text(value).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        case .divider: Divider().padding(.vertical, 4)
        }
    }
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
                let width = rows.map(\.count).max() ?? columns
                rows = rows.map { $0 + Array(repeating: "", count: width - $0.count) }
                blocks.append(.table(rows)); continue
            }
            if line.isEmpty {
                flushParagraph()
                continue
            }
            if ["---", "***", "___"].contains(line) { flushParagraph(); blocks.append(.divider) }
            else if line.hasPrefix("### ") { flushParagraph(); blocks.append(.heading(3, String(line.dropFirst(4)))) }
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

/// Inline parsing is cached separately: unchanged cells are not reparsed during streaming.
enum InlineMarkdown {
    private final class Box: NSObject {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }
    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 2000; cache.totalCostLimit = 2 * 1024 * 1024
        return cache
    }()
    static func text(_ value: String) -> Text {
        // Most table cells are plain text and do not need the Markdown parser at all.
        guard value.contains("*") || value.contains("[") || value.contains("`") || value.contains("_") else { return Text(value) }
        let key = value as NSString
        if let box = cache.object(forKey: key) { return Text(box.value) }
        let parsed = (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value)
        cache.setObject(Box(parsed), forKey: key, cost: value.utf8.count * 4)
        return Text(parsed)
    }
}

struct MarkdownTableView: View {
    let rows: [[String]]
    let identifier: String
    private let widths: [CGFloat]
    @ScaledMetric(relativeTo: .subheadline) private var fontScale: CGFloat = 1
    init(rows: [[String]], identifier: String = "table") {
        self.rows = rows; self.identifier = identifier
        let columns = rows.map(\.count).max() ?? 0
        // Sampling affects only column width, never the number of displayed rows.
        widths = (0..<columns).map { column in
            let units = rows.prefix(80).map { row -> Int in
                guard row.indices.contains(column) else { return 0 }
                return row[column].unicodeScalars.reduce(0) { $0 + ($1.value > 0x2FFF ? 2 : 1) }
            }.max() ?? 8
            return CGFloat(min(260, max(88, units * 7 + 12)))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("表格可左右滑动查看全部列，共 \(max(0, rows.count - 1)) 行")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                // Explicit shared widths and top-aligned rows give wrapped text real height.
                // An eager VStack is deliberate: nested lazy vertical estimates caused jumps.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows.indices, id: \.self) { row in
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(widths.indices, id: \.self) { column in
                                InlineMarkdown.text(rows[row].indices.contains(column) ? rows[row][column] : "")
                                    .font(.subheadline.weight(row == 0 ? .semibold : .regular))
                                    .frame(width: widths[column] * fontScale, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 10).padding(.vertical, 10)
                                    .accessibilityIdentifier("\(identifier)-cell-\(row)-\(column)")
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .background(row == 0 ? Color.accentColor.opacity(0.10) : row % 2 == 0 ? Color.primary.opacity(0.025) : Color.clear)
                        if row != rows.count - 1 { Divider() }
                    }
                }
                .fixedSize(horizontal: true, vertical: true)
            }
            .accessibilityIdentifier("\(identifier)-scroll")
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
