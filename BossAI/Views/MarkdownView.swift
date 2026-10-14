//
//  MarkdownView.swift
//  BossAI
//
//  AI 回答的 Markdown 渲染界面（Views 层）：
//  - 职责：把流式/完整的 Markdown 文本解析为块级 Block 数组并渲染
//    （标题 / 列表 / 引用 / 代码块 / 表格 / 分隔线 / 段落），支持长答案折叠。
//  - 渲染管线：init 时先查 NSCache 拿到上次解析结果（无则空数组先渲染纯文本兜底），
//    然后 .task(id: text) 把解析丢给单例 actor Worker 在后台执行，
//    解析完成后再切回主线程更新 blocks。流式期间每来一段新文本都会触发重解析。
//  - 关键设计决策：
//    1) 解析必须离开主线程：超长答案逐字符解析会卡 UI，故用 actor 串行化、限制并发峰值内存。
//    2) 双层缓存：块级结果按全文缓存；行内（InlineMarkdown）按片段缓存——
//       流式追加时未变化的段落/表格单元格不必重新解析。
//    3) 流式前缀不写入块级缓存：每次追加都是新字符串，全部缓存会把内存打爆，
//       只缓存 collapseDisabled == false 的"最终完整答案"。
//    4) 默认展开完整答案；只有用户显式点击才允许折叠（防呆：不让系统替用户隐藏内容）。
//    5) Equatable 比较只看 text 与 collapseDisabled：text 未变就跳过整块 diff，
//       流式刷新历史消息时零成本。
//    6) 表格用采样估算列宽 + 共享宽度，配合固定 VStack 而非嵌套 Lazy 容器，
//       避免高度估算跳变造成的滚动抖动。
//

import SwiftUI
import UIKit

/// Full answers by default. Only an explicit user action can collapse an answer.
struct MarkdownView: View, Equatable {
    /// 待渲染的 Markdown 原文（流式期间会不断变化）
    let text: String
    /// true 时禁用折叠按钮：流式输出中或夹具等场景不允许收起
    let collapseDisabled: Bool
    /// 用户是否手动收起了长答案
    @State private var collapsed = false
    /// 解析后的块级结构；init 先从缓存取近似值，正式值由后台解析后覆盖
    @State private var blocks: [Block]
    init(_ text: String, collapseDisabled: Bool = false) {
        self.text = text; self.collapseDisabled = collapseDisabled
        // init 阶段同步查缓存：命中则首帧就能渲染解析结果，避免"纯文本→Markdown"的闪烁
        _blocks = State(initialValue: Self.cache.object(forKey: text as NSString)?.blocks ?? [])
    }
    /// 相等性只看原文与折叠开关：text 没变就跳过重渲染（流式刷新历史消息时的关键优化）
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.collapseDisabled == rhs.collapseDisabled
    }
    /// 块级语法树节点：一种 Swift enum case 对应一种 Markdown 块
    enum Block: Equatable, Sendable {
        case heading(Int, String), bullet(String), ordered(Int, String), quote(String)
        case code(language: String, String)
        case paragraph(String)
        case table([[String]]), divider
    }
    /// NSCache 的值包装（NSCache 要求 NSObject 类型；Sendable 块数组包在不可变盒子里）
    private final class ParsedBox: NSObject {
        let blocks: [Block]
        init(_ blocks: [Block]) { self.blocks = blocks }
    }
    /// 块级解析结果缓存：同一文本（如历史消息滚动重入）绝不解析第二次
    private static let cache: NSCache<NSString, ParsedBox> = {
        let cache = NSCache<NSString, ParsedBox>()
        // 上限 200 条 / 4MB：足够覆盖一次会话的可见消息，又不会常驻过大内存
        cache.countLimit = 200; cache.totalCostLimit = 4 * 1024 * 1024
        return cache
    }()
    // One worker prevents concurrent long-message parsing from multiplying peak memory.
    /// 单例解析 actor：串行执行保证同时最多只有一份解析中间状态，峰值内存可控
    private actor Worker {
        /// 解析文本为块数组；cacheResult=false 表示流式前缀，结果不入共享缓存
        func parse(_ text: String, cacheResult: Bool) throws -> [Block] {
            // 解析前后各检查一次取消：被新文本/被关闭的视图立即让旧工作作废
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
                // 缓存未命中时的兜底：先按纯文本渲染，后台解析完成后自动切换为富文本
                Text(text).fixedSize(horizontal: false, vertical: true)
            } else {
                // 折叠态只渲染第一个块（通常是标题/首段）作摘要；展开则渲染全部
                ForEach(Array((collapsed ? Array(blocks.prefix(1)) : blocks).enumerated()), id: \.offset) { index, block in
                    blockView(block, index: index)
                }
            }
            // 折叠开关只对足够长的答案（>6 块）出现，短答案收起没有意义
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
            // 渲染管线入口：文本每变化一次（流式增量）就调度一次后台解析
            do {
                let result = try await Self.worker.parse(text, cacheResult: !collapseDisabled)
                try Task.checkCancellation()
                blocks = result
            } catch { /* A newer text or a dismissed view cancels obsolete work. */ }
        }
    }
    /// 按块类型分发到对应子视图
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
        case .ordered(let number, let value):
            // 有序列表保留编号：检索答案里（来源 N）与第 N 条来源的对应关系靠它
            HStack(alignment: .top, spacing: 8) {
                Text("\(number).").monospacedDigit().foregroundStyle(Color.accentColor)
                InlineMarkdown.text(value).fixedSize(horizontal: false, vertical: true)
            }
        case .quote(let value):
            InlineMarkdown.text(value).italic().foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Color(.separator)).frame(width: 3) }
        case .code(let language, let value):
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(language.isEmpty ? "代码" : language)
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = value
                    } label: {
                        Image(systemName: "doc.on.doc").font(.caption2)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("复制代码")
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                Divider()
                ScrollView(.horizontal) {
                    Text(value).font(.system(.subheadline, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: true).padding(10)
                }
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        case .table(let rows): MarkdownTableView(rows: rows, identifier: "table-\(index)")
        case .paragraph(let value):
            InlineMarkdown.text(value).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        case .divider: Divider().padding(.vertical, 4)
        }
    }
    /// 手写的轻量 Markdown 解析器：只覆盖 AI 回答中实际出现的语法子集，
    /// 换取确定性的性能与流式友好的增量行为（不依赖第三方库）。
    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var codeBuf: [String] = []
        var codeLanguage = ""
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
            // 代码围栏开/闭：``` 行本身不进内容；未闭合时把余下内容整块当代码输出（容错）
            if line.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(language: codeLanguage, codeBuf.joined(separator: "\n")))
                    codeBuf = []
                    inCode = false
                } else {
                    flushParagraph()
                    inCode = true
                    codeLanguage = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            if inCode {
                codeBuf.append(raw)
                continue
            }
            // 表格识别：当前行含 "|"，且下一行是对齐分隔行、本行至少 2 列，才判定为表格头——
        // 三个条件同时满足防止单元格里的孤立 "|" 误判成表格
            if line.contains("|"), index < lines.count, MarkdownTableCore.isSeparator(lines[index]), MarkdownTableCore.cells(line).count >= 2 {
                flushParagraph()
                let columns = MarkdownTableCore.cells(line).count
                var rows = [MarkdownTableCore.cells(line)]
                index += 1
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    let cells = MarkdownTableCore.cells(lines[index])
                    // 短行右侧补空字符串，把所有行补齐到同一列数，方便表格视图按列取值
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
            else if line.hasPrefix("#### ") { flushParagraph(); blocks.append(.heading(4, String(line.dropFirst(5)))) }
            else if line.hasPrefix("### ") { flushParagraph(); blocks.append(.heading(3, String(line.dropFirst(4)))) }
            else if line.hasPrefix("## ") { flushParagraph(); blocks.append(.heading(2, String(line.dropFirst(3)))) }
            else if line.hasPrefix("# ") { flushParagraph(); blocks.append(.heading(1, String(line.dropFirst(2)))) }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flushParagraph(); blocks.append(.bullet(String(line.dropFirst(2))))
            } else if let r = line.range(of: #"^\d{1,3}[.、]\s*"#, options: .regularExpression) {
                // 有序列表：保留编号渲染，编号被剥掉会让「来源 N」失去指向
                flushParagraph()
                let digits = line.prefix { $0.isASCII && $0.isNumber }
                let rest = line[line.index(line.startIndex, offsetBy: digits.count)...]
                    .drop { $0 == "." || $0 == "、" || $0 == " " }
                blocks.append(.ordered(Int(String(digits)) ?? 0, String(rest)))
            } else if line.hasPrefix("> ") {
                flushParagraph(); blocks.append(.quote(String(line.dropFirst(2))))
            } else {
                paragraph.append(line)
            }
        }
        // 收尾：清掉残余段落；未闭合的代码围栏也整体输出，避免流式期间内容"消失"
        flushParagraph()
        if inCode && !codeBuf.isEmpty {
            blocks.append(.code(language: codeLanguage, codeBuf.joined(separator: "\n")))
        }
        return blocks
    }
}

/// 行内 Markdown（粗体/斜体/链接/行内代码）转 AttributedString，带独立缓存。
/// 流式追加时表格单元格与段落大多不变，缓存让它们零成本复用。
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
    /// 行内片段转 Text：先快判是否含 Markdown 记号，纯文本直接走 Text 构造（绝大多数单元格命中此快路径）
    static func text(_ value: String) -> Text {
        // Most table cells are plain text and do not need the Markdown parser at all.
        guard value.contains("*") || value.contains("[") || value.contains("`") || value.contains("_") else { return Text(value) }
        let key = value as NSString
        if let box = cache.object(forKey: key) { return Text(box.value) }
        // inlineOnlyPreservingWhitespace：只做行内语法且保留空白，避免把单元格换行吃掉
        let parsed = (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value)
        cache.setObject(Box(parsed), forKey: key, cost: value.utf8.count * 4)
        return Text(parsed)
    }
}

/// Markdown 表格视图：横向滚动 + 固定列宽 + 顶部对齐，供长表格在对话内可读地展示
struct MarkdownTableView: View {
    /// 表格数据（含表头行，rows[0] 为表头）
    let rows: [[String]]
    /// 无障碍标识前缀，供 UI 测试定位
    let identifier: String
    /// 各列固定宽度（init 内采样估算得出）
    private let widths: [CGFloat]
    /// 跟随系统动态字体的缩放系数，列宽随字体等比放大
    @ScaledMetric(relativeTo: .subheadline) private var fontScale: CGFloat = 1
    init(rows: [[String]], identifier: String = "table") {
        self.rows = rows; self.identifier = identifier
        let columns = rows.map(\.count).max() ?? 0
        // Sampling affects only column width, never the number of displayed rows.
        widths = (0..<columns).map { column in
            // 估算列宽：仅采样前 80 行的最宽单元格；CJK 字符按 2 个单位计宽，
            // 再钳制到 88–260pt——过窄挤压换行、过宽浪费横向空间
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
                // 共享列宽 + 顶部对齐让换行单元格有真实高度；刻意用急切 VStack，
                // 因为嵌套 Lazy 容器的高度估算不准会导致滚动跳变
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
