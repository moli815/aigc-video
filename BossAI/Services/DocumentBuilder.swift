import Foundation
import UIKit
import CoreText

/// 文档生成：把 AI 输出的 Markdown 转成可直接使用的办公文件。
/// 全部用系统能力手写生成，不依赖任何第三方库：
/// - Word / PowerPoint / Excel：手写 OOXML + 自有 ZIP 打包
/// - PDF：UIGraphicsPDFRenderer
enum DocumentFormat: String, CaseIterable, Identifiable {
    case word, ppt, excel, pdf
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .word: return "Word 文档"
        case .ppt: return "PPT 演示"
        case .excel: return "Excel 表格"
        case .pdf: return "PDF 文档"
        }
    }

    var ext: String {
        switch self {
        case .word: return "docx"
        case .ppt: return "pptx"
        case .excel: return "xlsx"
        case .pdf: return "pdf"
        }
    }

    var symbol: String {
        switch self {
        case .word: return "doc.text.fill"
        case .ppt: return "rectangle.on.rectangle.fill"
        case .excel: return "tablecells.fill"
        case .pdf: return "doc.richtext.fill"
        }
    }
}

// MARK: - Markdown 解析

struct MarkdownBlock {
    enum Kind {
        case title
        case heading1
        case heading2
        case heading3
        case bullet
        case numbered
        case quote
        case paragraph
        case pageBreak
    }
    let kind: Kind
    let text: String
}

enum MarkdownParser {
    static func blocks(from markdown: String) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line == "---" || line == "***" || line == "___" {
                result.append(MarkdownBlock(kind: .pageBreak, text: ""))
                continue
            }
            if line.hasPrefix("#### ") {
                result.append(MarkdownBlock(kind: .heading3, text: inline(String(line.dropFirst(5)))))
            } else if line.hasPrefix("### ") {
                result.append(MarkdownBlock(kind: .heading3, text: inline(String(line.dropFirst(4)))))
            } else if line.hasPrefix("## ") {
                result.append(MarkdownBlock(kind: .heading2, text: inline(String(line.dropFirst(3)))))
            } else if line.hasPrefix("# ") {
                result.append(MarkdownBlock(kind: .heading1, text: inline(String(line.dropFirst(2)))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                result.append(MarkdownBlock(kind: .bullet, text: inline(String(line.dropFirst(2)))))
            } else if line.hasPrefix("> ") {
                result.append(MarkdownBlock(kind: .quote, text: inline(String(line.dropFirst(2)))))
            } else if let dotRange = line.range(of: ". "), line.distance(from: line.startIndex, to: dotRange.lowerBound) <= 2,
                      Int(line[line.startIndex..<dotRange.lowerBound]) != nil {
                result.append(MarkdownBlock(kind: .numbered, text: inline(String(line[dotRange.upperBound...]))))
            } else {
                result.append(MarkdownBlock(kind: .paragraph, text: inline(line)))
            }
        }
        return result
    }

    /// 去掉行内 Markdown 记号，保留可读纯文本
    static func inline(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "**", with: "")
        out = out.replacingOccurrences(of: "__", with: "")
        out = out.replacingOccurrences(of: "`", with: "")
        out = out.replacingOccurrences(of: "~~", with: "")
        // [文字](链接) → 文字
        while let open = out.firstIndex(of: "["), let close = out[open...].firstIndex(of: "]") {
            guard close < out.endIndex else { break }
            let afterClose = out.index(after: close)
            if afterClose < out.endIndex, out[afterClose] == "(" {
                if let parenClose = out[afterClose...].firstIndex(of: ")") {
                    let label = String(out[out.index(after: open)..<close])
                    out.replaceSubrange(open...parenClose, with: label)
                    continue
                }
            }
            break
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// PPT 分页：按 --- 或每个一级标题切页
    static func slides(from markdown: String) -> [(title: String, bullets: [String])] {
        var slides: [(String, [String])] = []
        var currentTitle = ""
        var currentBullets: [String] = []

        func flush() {
            if !currentTitle.isEmpty || !currentBullets.isEmpty {
                slides.append((currentTitle, currentBullets))
            }
            currentTitle = ""
            currentBullets = []
        }

        for block in blocks(from: markdown) {
            switch block.kind {
            case .pageBreak:
                flush()
            case .title, .heading1:
                flush()
                currentTitle = block.text
            case .heading2, .heading3:
                currentBullets.append(block.text)
            case .bullet, .numbered:
                currentBullets.append("• " + block.text)
            case .quote:
                currentBullets.append("“" + block.text + "”")
            case .paragraph:
                currentBullets.append(block.text)
            }
        }
        flush()
        if slides.isEmpty { slides = [("文档", ["（无内容）"])] }
        return slides
    }

    /// 表格解析：把 Markdown 表格转成二维数组
    static func table(from markdown: String) -> [[String]] {
        var rows: [[String]] = []
        var fenced = false
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { fenced.toggle(); continue }
            guard !fenced, line.contains("|"), !MarkdownTableCore.isSeparator(line) else { continue }
            let cells = MarkdownTableCore.cells(line).map(inline)
            if cells.count >= 2 { rows.append(cells) }
        }
        return rows
    }

    /// 把 Markdown 按「文本段 / 表格段」切分，供 Word 这类需要单独渲染表格的格式使用。
    /// 表格分隔行（|---|）属于表格结构，跳过不参与切分。
    static func splitTables(from markdown: String) -> [(markdown: String, isTable: Bool)] {
        var sections: [(String, Bool)] = []
        var currentText: [String] = []
        var currentTable: [String] = []

        func flushText() {
            if !currentText.isEmpty {
                sections.append((currentText.joined(separator: "\n"), false))
                currentText = []
            }
        }
        func flushTable() {
            if !currentTable.isEmpty {
                sections.append((currentTable.joined(separator: "\n"), true))
                currentTable = []
            }
        }

        var fenced = false
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { fenced.toggle(); flushTable(); currentText.append(line); continue }
            if !fenced && MarkdownTableCore.isSeparator(line) { continue }  // 表格分隔行
            if !fenced && line.contains("|") && MarkdownTableCore.cells(line).count >= 2 {
                flushText()
                currentTable.append(line)
            } else {
                flushTable()
                currentText.append(line)
            }
        }
        flushText()
        flushTable()
        return sections
    }
}

// MARK: - 生成入口


/// 文档主题（移植自 docgen skill 的四套场景主题）：按专家/场景切换配色与字体。
struct DocTheme: Sendable {
    let primary: String      // 主色（标题 / 色条 / 表头底纹）
    let secondary: String    // 次色（装饰）
    let light: String        // 浅色（副标题 / 浅底）
    let text: String         // 正文色
    let muted: String        // 弱化色（日期 / 页码）
    let headerFont: String
    let bodyFont: String

    static let business = DocTheme(primary: "1F4E79", secondary: "2E75B6", light: "DEEBF7", text: "222222", muted: "6E6E6E", headerFont: "微软雅黑", bodyFont: "微软雅黑")
    static let vivid    = DocTheme(primary: "E85D2A", secondary: "FFC24B", light: "FFE3CC", text: "3A2E26", muted: "8A7A6E", headerFont: "微软雅黑", bodyFont: "微软雅黑")
    static let formal   = DocTheme(primary: "C00000", secondary: "404040", light: "F2E7E7", text: "1A1A1A", muted: "595959", headerFont: "黑体", bodyFont: "仿宋")
    static let academic = DocTheme(primary: "14304D", secondary: "2F5D7A", light: "E6EEF2", text: "1B1B1B", muted: "5A6472", headerFont: "宋体", bodyFont: "宋体")

    static func forExpert(_ id: String) -> DocTheme {
        switch id {
        case "legal": return .formal
        case "marketing", "traffic": return .vivid
        case "speech": return .academic
        default: return .business
        }
    }

    static func named(_ name: String) -> DocTheme {
        switch name.lowercased() {
        case "vivid": return .vivid
        case "formal": return .formal
        case "academic": return .academic
        default: return .business
        }
    }
}

enum DocumentBuilder {
    enum BuildError: Error, LocalizedError {
        case emptyContent
        case pdfLayoutFailed
        var errorDescription: String? {
            switch self {
            case .emptyContent: return "文档内容为空"
            case .pdfLayoutFailed: return "PDF分页失败，未生成文件；请缩短异常段落后重试"
            }
        }
    }

    /// Heavy CPU work runs on a serialized actor, never the MainActor caller.
    private actor BuildWorker {
        func build(format: DocumentFormat, title: String, content: String, theme: DocTheme) throws -> Data {
            try Task.checkCancellation()
            let span = PerformanceTrace.begin("DocumentBuildBackground")
            defer { PerformanceTrace.end("DocumentBuildBackground", span) }
            let result = try autoreleasepool { try DocumentBuilder.build(format: format, title: title, content: content, theme: theme) }
            try Task.checkCancellation()
            return result
        }
    }
    private static let worker = BuildWorker()
    static func buildAsync(format: DocumentFormat, title: String, content: String, theme: DocTheme = .business) async throws -> Data {
        try await worker.build(format: format, title: title, content: content, theme: theme)
    }

    static func build(format: DocumentFormat, title: String, content: String, theme: DocTheme = .business) throws -> Data {
        let body = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw BuildError.emptyContent }
        switch format {
        case .word: return docx(title: title, markdown: body, theme: theme)
        case .ppt: return pptx(title: title, markdown: body, theme: theme)
        case .excel: return xlsx(title: title, markdown: body, theme: theme)
        case .pdf: return try pdf(title: title, markdown: body, theme: theme)
        }
    }

    // MARK: - Word (.docx)

    static func docx(title: String, markdown: String, theme: DocTheme) -> Data {
        var body = ""

        func runProps(size: Int, bold: Bool) -> String {
            "<w:rPr><w:rFonts w:ascii=\"\(theme.bodyFont)\" w:hAnsi=\"\(theme.bodyFont)\" w:eastAsia=\"\(theme.bodyFont)\"/>"
                + (bold ? "<w:b/>" : "")
                + "<w:sz w:val=\"\(size)\"/><w:szCs w:val=\"\(size)\"/></w:rPr>"
        }

        func paragraph(_ text: String, size: Int, bold: Bool, indent: Int = 0,
                       spacingBefore: Int = 0, spacingAfter: Int = 120,
                       color: String? = nil) -> String {
            var pPr = "<w:pPr><w:spacing w:before=\"\(spacingBefore)\" w:after=\"\(spacingAfter)\" w:line=\"320\" w:lineRule=\"auto\"/>"
            if indent > 0 { pPr += "<w:ind w:left=\"\(indent)\"/>" }
            pPr += "</w:pPr>"
            var rPr = runProps(size: size, bold: bold)
            if let color {
                rPr = rPr.replacingOccurrences(of: "</w:rPr>", with: "<w:color w:val=\"\(color)\"/></w:rPr>")
            }
            return "<w:p>\(pPr)<w:r>\(rPr)<w:t xml:space=\"preserve\">\(xmlEscape(text))</w:t></w:r></w:p>"
        }

        // 标题 + 主题色分隔线 + 日期
        body += paragraph(title, size: 44, bold: true, spacingAfter: 120)
        body += "<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"18\" w:space=\"1\" w:color=\"\(theme.primary)\"/></w:pBdr><w:spacing w:after=\"240\"/></w:pPr></w:p>"
        body += paragraph(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none),
                          size: 18, bold: false, spacingAfter: 360, color: "\(theme.muted)")

        // F03 修复：旧版把 Markdown 表格行当普通段落，`|` 符号残留、表格结构丢失。
        // 现在按「文本段 / 表格段」切分，表格段单独渲染成 <w:tbl>。
        for section in MarkdownParser.splitTables(from: markdown) {
            if section.isTable {
                body += wordTable(MarkdownParser.table(from: section.markdown), theme: theme)
                continue
            }
            for block in MarkdownParser.blocks(from: section.markdown) {
                switch block.kind {
                case .title, .heading1:
                    body += paragraph(block.text, size: 32, bold: true, spacingBefore: 320, spacingAfter: 160, color: "\(theme.primary)")
                case .heading2:
                    body += paragraph(block.text, size: 26, bold: true, spacingBefore: 240, spacingAfter: 120)
                case .heading3:
                    body += paragraph(block.text, size: 22, bold: true, spacingBefore: 200, spacingAfter: 100)
                case .bullet:
                    body += paragraph("• " + block.text, size: 21, bold: false, indent: 360, spacingAfter: 80)
                case .numbered:
                    body += paragraph(block.text, size: 21, bold: false, indent: 360, spacingAfter: 80)
                case .quote:
                    body += paragraph("“" + block.text + "”", size: 21, bold: false, indent: 360, spacingAfter: 120, color: "555555")
                case .paragraph:
                    body += paragraph(block.text, size: 21, bold: false, spacingAfter: 120)
                case .pageBreak:
                    body += "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
                }
            }
        }

        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body>\(body)<w:sectPr><w:footerReference w:type="default" r:id="rIdFooter"/><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1418" w:bottom="1440" w:left="1418" w:header="851" w:footer="992" w:gutter="0"/></w:sectPr></w:body></w:document>
        """

        var zip = ZipWriter()
        zip.add("[Content_Types].xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/></Types>
        """)
        zip.add("_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """)
        zip.add("word/_rels/document.xml.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rIdFooter" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/></Relationships>
        """)
        zip.add("word/footer1.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:rPr><w:sz w:val="16"/><w:color w:val="888888"/></w:rPr><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:rPr><w:sz w:val="16"/><w:color w:val="888888"/></w:rPr><w:instrText xml:space="preserve"> PAGE </w:instrText></w:r><w:r><w:rPr><w:sz w:val="16"/><w:color w:val="888888"/></w:rPr><w:fldChar w:fldCharType="end"/></w:r></w:p></w:ftr>
        """)
        zip.add("word/document.xml", document)
        return zip.finalize()
    }

    /// Word 表格渲染：二维数组 → <w:tbl>，首行加粗当表头
    private static func wordTable(_ rows: [[String]], theme: DocTheme) -> String {
        var xml = "<w:tbl><w:tblPr><w:tblW w:w=\"0\" w:type=\"auto\"/><w:tblBorders>"
        for edge in ["top", "left", "bottom", "right", "insideH", "insideV"] {
            xml += "<w:\(edge) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"BBBBBB\"/>"
        }
        xml += "</w:tblBorders></w:tblPr>"
        for (rowIndex, row) in rows.enumerated() {
            xml += "<w:tr>"
            for cell in row {
                if rowIndex == 0 {
                    // 表头：主题蓝底 + 白字加粗
                    xml += "<w:tc><w:tcPr><w:shd w:val=\"clear\" w:fill=\"\(theme.primary)\"/></w:tcPr><w:p><w:r><w:rPr><w:rFonts w:ascii=\"\(theme.bodyFont)\" w:hAnsi=\"\(theme.bodyFont)\" w:eastAsia=\"\(theme.bodyFont)\"/><w:b/><w:color w:val=\"FFFFFF\"/><w:sz w:val=\"20\"/><w:szCs w:val=\"20\"/></w:rPr><w:t xml:space=\"preserve\">\(xmlEscape(cell))</w:t></w:r></w:p></w:tc>"
                } else {
                    xml += "<w:tc><w:p><w:r><w:rPr><w:rFonts w:ascii=\"\(theme.bodyFont)\" w:hAnsi=\"\(theme.bodyFont)\" w:eastAsia=\"\(theme.bodyFont)\"/><w:sz w:val=\"20\"/><w:szCs w:val=\"20\"/></w:rPr><w:t xml:space=\"preserve\">\(xmlEscape(cell))</w:t></w:r></w:p></w:tc>"
                }
            }
            xml += "</w:tr>"
        }
        xml += "</w:tbl>"
        // 表格后补一个空段，避免与后续正文粘连
        xml += "<w:p><w:r><w:rPr><w:sz w:val=\"10\"/></w:rPr></w:r></w:p>"
        return xml
    }

    // MARK: - PowerPoint (.pptx)

    static func pptx(title: String, markdown: String, theme: DocTheme) -> Data {
        var deck = MarkdownParser.slides(from: markdown)
        if deck.first?.title.isEmpty ?? true {
            deck.insert((title, []), at: 0)
        }

        // Bound estimated lines, not just bullet count; preserve every character on continuation pages.
        var expanded: [(String, [String])] = []
        for slide in deck {
            var segments: [String] = []
            for bullet in slide.bullets {
                let characters = Array(bullet)
                if characters.isEmpty { segments.append(""); continue }
                for start in stride(from: 0, to: characters.count, by: 80) {
                    segments.append(String(characters[start..<min(start + 80, characters.count)]))
                }
            }
            var page: [String] = []; var lines = 0; var number = 1
            func flush() {
                let title = number == 1 ? slide.title : "\(slide.title)（续 \(number)）"
                expanded.append((title, page)); number += 1; page = []; lines = 0
            }
            for segment in segments {
                let cost = max(1, Int(ceil(Double(segment.count) / 40)))
                if page.count >= 8 || (!page.isEmpty && lines + cost > 12) { flush() }
                page.append(segment); lines += cost
            }
            if !page.isEmpty || segments.isEmpty { flush() }
        }
        deck = expanded

        var zip = ZipWriter()
        var contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/><Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/><Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/><Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>
        """
        var presentationRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>
        """
        var slideIdList = ""
        var slideRelsExtra = ""

        for (index, slide) in deck.enumerated() {
            let n = index + 1
            let relId = "rId\(n + 1)"
            slideIdList += "<p:sldId id=\"\(256 + index)\" r:id=\"\(relId)\"/>"
            presentationRels += "<Relationship Id=\"\(relId)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide\(n).xml\"/>"
            slideRelsExtra += "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/>"

        contentTypes += "<Override PartName=\"/ppt/slides/slide\(n).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
            zip.add("ppt/slides/slide\(n).xml", slideXML(slide.title, slide.bullets, pageIndex: n, totalPages: deck.count + 2, theme: theme))
            zip.add("ppt/slides/_rels/slide\(n).xml.rels", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(slideRelsExtra)</Relationships>
            """)
            slideRelsExtra = ""
        }

        // 封面页与结尾页（slide 文件名任意，显示顺序由 sldIdLst 决定）
        let slideLayoutRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/></Relationships>
        """
        zip.add("ppt/slides/cover.xml", coverSlideXML(theme: theme, title: title, dateLine: DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none)))
        zip.add("ppt/slides/_rels/cover.xml.rels", slideLayoutRels)
        zip.add("ppt/slides/closing.xml", closingSlideXML(theme: theme))
        zip.add("ppt/slides/_rels/closing.xml.rels", slideLayoutRels)
        contentTypes += "<Override PartName=\"/ppt/slides/cover.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
        contentTypes += "<Override PartName=\"/ppt/slides/closing.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"

        contentTypes += "</Types>"
        presentationRels += "<Relationship Id=\"rIdTheme\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme\" Target=\"theme/theme1.xml\"/></Relationships>"
        presentationRels = presentationRels.replacingOccurrences(
            of: "</Relationships>",
            with: "<Relationship Id=\"rIdCover\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/cover.xml\"/><Relationship Id=\"rIdClosing\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/closing.xml\"/></Relationships>")

        zip.add("[Content_Types].xml", contentTypes)
        zip.add("_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/></Relationships>
        """)
        zip.add("ppt/presentation.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" saveSubsetFonts="1"><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst><p:sldId id="2147483000" r:id="rIdCover"/>\(slideIdList)<p:sldId id="2147483001" r:id="rIdClosing"/></p:sldIdLst><p:sldSz cx="12192000" cy="6858000" type="screen16x9"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>
        """)
        zip.add("ppt/_rels/presentation.xml.rels", presentationRels)
        zip.add("ppt/slideMasters/slideMaster1.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:bg><p:bgPr><a:solidFill><a:schemeClr val="bg1"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld><p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/><p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle><a:lvl1pPr algn="l"><a:defRPr sz="4000" b="1"/></a:lvl1pPr></p:titleStyle><p:bodyStyle><a:lvl1pPr><a:defRPr sz="2000"/></a:lvl1pPr></p:bodyStyle><p:otherStyle/></p:txStyles></p:sldMaster>
        """)
        zip.add("ppt/slideMasters/_rels/slideMaster1.xml.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/></Relationships>
        """)
        zip.add("ppt/slideLayouts/slideLayout1.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank" preserve="1"><p:cSld name="空白"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
        """)
        zip.add("ppt/slideLayouts/_rels/slideLayout1.xml.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/></Relationships>
        """)
        zip.add("ppt/theme/theme1.xml", themeXML(theme))
        return zip.finalize()
    }

    private static func slideXML(_ title: String, _ bullets: [String], pageIndex: Int, totalPages: Int, theme: DocTheme) -> String {
        var contentRuns = ""
        let shown = Array(bullets.prefix(8))
        for (index, bullet) in shown.enumerated() {
            let isSub = bullet.hasPrefix("• ")
            let text = isSub ? String(bullet.dropFirst(2)) : bullet
            let size = isSub ? 1600 : 1800
            let indent = isSub ? 342900 : 0
            let spaceBefore = index == 0 ? 0 : 600
            contentRuns += "<a:p><a:pPr marL=\"\(indent + 285750)\" indent=\"-285750\"><a:spcBef><a:spcPts val=\"\(spaceBefore)\"/></a:spcBef><a:buClr><a:srgbClr val=\"\(theme.primary)\"/></a:buClr><a:buFont typeface=\"Arial\"/><a:buChar char=\"•\"/></a:pPr><a:r><a:rPr lang=\"zh-CN\" sz=\"\(size)\" dirty=\"0\"><a:solidFill><a:schemeClr val=\"tx1\"/></a:solidFill><a:latin typeface=\"\(theme.bodyFont)\"/><a:ea typeface=\"\(theme.bodyFont)\"/></a:rPr><a:t>\(xmlEscape(text))</a:t></a:r></a:p>"
        }
        if contentRuns.isEmpty {
            contentRuns = "<a:p><a:r><a:rPr lang=\"zh-CN\" sz=\"1800\" dirty=\"0\"><a:latin typeface=\"\(theme.bodyFont)\"/><a:ea typeface=\"\(theme.bodyFont)\"/></a:rPr><a:t></a:t></a:r></a:p>"
        }
        // 页脚页码（右下角）
        let pageFooter = "<p:sp><p:nvSpPr><p:cNvPr id=\"5\" name=\"页码\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"10972800\" y=\"6400800\"/><a:ext cx=\"1000000\" cy=\"320000\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:pPr algn=\"r\"/><a:r><a:rPr lang=\"zh-CN\" sz=\"1100\" dirty=\"0\"><a:solidFill><a:srgbClr val=\"\(theme.muted)\"/></a:solidFill><a:latin typeface=\"\(theme.bodyFont)\"/><a:ea typeface=\"\(theme.bodyFont)\"/></a:rPr><a:t>\(pageIndex) / \(totalPages)</a:t></a:r></a:p></p:txBody></p:sp>"

        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/><p:sp><p:nvSpPr><p:cNvPr id="4" name="顶部色条"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="12192000" cy="76200"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="\(theme.primary)"/></a:solidFill><a:ln><a:noFill/></a:ln></p:spPr><p:txBody><a:bodyPr/><a:lstStyle/><a:p/></p:txBody></p:sp><p:sp><p:nvSpPr><p:cNvPr id="2" name="标题 1"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="838200" y="457200"/><a:ext cx="10515600" cy="1143000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr anchor="b"/><a:lstStyle/><a:p><a:r><a:rPr lang="zh-CN" sz="3200" b="1" dirty="0"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="\(theme.bodyFont)"/><a:ea typeface="\(theme.bodyFont)"/></a:rPr><a:t>\(xmlEscape(title))</a:t></a:r></a:p></p:txBody></p:sp><p:sp><p:nvSpPr><p:cNvPr id="3" name="内容 1"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="838200" y="1825625"/><a:ext cx="10515600" cy="4351338"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr/><a:lstStyle/>\(contentRuns)</p:txBody></p:sp>\(pageFooter)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
        """
    }

    /// 封面页：深蓝底 + 居中大标题 + 日期
    private static func coverSlideXML(theme: DocTheme, title: String, dateLine: String) -> String {
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val="\(theme.primary)"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/><p:sp><p:nvSpPr><p:cNvPr id="2" name="封面标题"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="838200" y="2857500"/><a:ext cx="10515600" cy="1257300"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr anchor="ctr"/><a:lstStyle/><a:p><a:pPr algn="ctr"/><a:r><a:rPr lang="zh-CN" sz="4400" b="1" dirty="0"><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill><a:latin typeface="\(theme.bodyFont)"/><a:ea typeface="\(theme.bodyFont)"/></a:rPr><a:t>\(xmlEscape(title))</a:t></a:r></a:p></p:txBody></p:sp><p:sp><p:nvSpPr><p:cNvPr id="3" name="装饰线"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="5096000" y="2651760"/><a:ext cx="2000000" cy="50800"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="\(theme.secondary)"/></a:solidFill><a:ln><a:noFill/></a:ln></p:spPr><p:txBody><a:bodyPr/><a:lstStyle/><a:p/></p:txBody></p:sp><p:sp><p:nvSpPr><p:cNvPr id="4" name="副标题"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="838200" y="4343400"/><a:ext cx="10515600" cy="457200"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:pPr algn="ctr"/><a:r><a:rPr lang="zh-CN" sz="1600" dirty="0"><a:solidFill><a:srgbClr val="\(theme.light)"/></a:solidFill><a:latin typeface="\(theme.bodyFont)"/><a:ea typeface="\(theme.bodyFont)"/></a:rPr><a:t>Boss AI · \(xmlEscape(dateLine))</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
        """
    }

    /// 结尾页：深蓝底 + 谢幕
    private static func closingSlideXML(theme: DocTheme) -> String {
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val="\(theme.primary)"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/><p:sp><p:nvSpPr><p:cNvPr id="2" name="谢幕"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="838200" y="2926080"/><a:ext cx="10515600" cy="1143000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr anchor="ctr"/><a:lstStyle/><a:p><a:pPr algn="ctr"/><a:r><a:rPr lang="zh-CN" sz="4000" b="1" dirty="0"><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill><a:latin typeface="\(theme.bodyFont)"/><a:ea typeface="\(theme.bodyFont)"/></a:rPr><a:t>谢谢观看</a:t></a:r></a:p></p:txBody></p:sp><p:sp><p:nvSpPr><p:cNvPr id="3" name="副标题"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="838200" y="4229100"/><a:ext cx="10515600" cy="457200"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:pPr algn="ctr"/><a:r><a:rPr lang="zh-CN" sz="1500" dirty="0"><a:solidFill><a:srgbClr val="\(theme.light)"/></a:solidFill><a:latin typeface="\(theme.bodyFont)"/><a:ea typeface="\(theme.bodyFont)"/></a:rPr><a:t>Boss AI · 企业经营者的 AI 顾问矩阵</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
        """
    }

    private static func themeXML(_ theme: DocTheme) -> String { return """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office"><a:themeElements><a:clrScheme name="Office"><a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="\(theme.secondary)"/></a:dk2><a:lt2><a:srgbClr val="E7E6E6"/></a:lt2><a:accent1><a:srgbClr val="2B5CE6"/></a:accent1><a:accent2><a:srgbClr val="ED7D31"/></a:accent2><a:accent3><a:srgbClr val="A5A5A5"/></a:accent3><a:accent4><a:srgbClr val="FFC000"/></a:accent4><a:accent5><a:srgbClr val="5B9BD5"/></a:accent5><a:accent6><a:srgbClr val="70AD47"/></a:accent6><a:hlink><a:srgbClr val="0563C1"/></a:hlink><a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme><a:fontScheme name="Office"><a:majorFont><a:latin typeface="Calibri Light"/><a:ea typeface="微软雅黑"/><a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Calibri"/><a:ea typeface="微软雅黑"/><a:cs typeface=""/></a:minorFont></a:fontScheme><a:fmtScheme name="Office"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="6350" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln><a:ln w="12700" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln><a:ln w="19050" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>
    """
    }

    // MARK: - Excel (.xlsx)

    static func xlsx(title: String, markdown: String, theme: DocTheme) -> Data {
        var rows = MarkdownParser.table(from: markdown)
        if rows.isEmpty {
            rows = MarkdownParser.blocks(from: markdown).map { [$0.text] }
        }

        // F05 修复：各行列数不一致时按最大列数补空列，避免列错位
        // （某行缺了末尾空单元格时，旧版会直接错位到下一列）
        let maxCols = rows.map(\.count).max() ?? 0
        if maxCols > 0 {
            rows = rows.map { row in
                row.count < maxCols ? row + Array(repeating: "", count: maxCols - row.count) : row
            }
        }

        var sheetData = ""
        for (rowIndex, row) in rows.enumerated() {
            var cells = ""
            for (colIndex, value) in row.enumerated() {
                let ref = "\(columnName(colIndex))\(rowIndex + 1)"
                // Keep leading-zero identifiers and currency labels as text; ordinary numbers become numeric cells.
                if let number = Double(value), number.isFinite,
                   !(value.count > 1 && value.hasPrefix("0") && !value.hasPrefix("0.")) {
                    let style = rowIndex == 0 ? " s=\"1\"" : ""
                    cells += "<c r=\"\(ref)\"\(style)><v>\(number)</v></c>"
                } else {
                    let style = rowIndex == 0 ? " s=\"1\"" : ""
                    cells += "<c r=\"\(ref)\" t=\"inlineStr\"\(style)><is><t xml:space=\"preserve\">\(xmlEscape(value))</t></is></c>"
                }
            }
            sheetData += "<row r=\"\(rowIndex + 1)\">\(cells)</row>"
        }

        // 列宽自适应：按每列最大字符宽估算（CJK 记 2），min 10 / max 55
        var cols = ""
        if maxCols > 0 {
            var colDefs = ""
            for col in 0..<maxCols {
                let units = rows.map { row -> Int in
                    guard row.indices.contains(col) else { return 0 }
                    return row[col].unicodeScalars.reduce(0) { $0 + ($1.value > 0x2FFF ? 2 : 1) }
                }.max() ?? 8
                let width = min(55.0, max(10.0, Double(units) * 1.9 + 3))
                colDefs += "<col min=\"\(col + 1)\" max=\"\(col + 1)\" width=\"\(String(format: "%.1f", width))\" customWidth=\"1\"/>"
            }
            cols = "<cols>\(colDefs)</cols>"
        }

        var zip = ZipWriter()
        zip.add("[Content_Types].xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>
        """)
        zip.add("_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """)
        zip.add("xl/workbook.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="\(xmlEscape(MarkdownTableCore.sheetName(title)))" sheetId="1" r:id="rId1"/></sheets></workbook>
        """)
        zip.add("xl/_rels/workbook.xml.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
        """)
        zip.add("xl/styles.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="微软雅黑"/></font><font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="微软雅黑"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF\(theme.primary)"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1" applyAlignment="1"><alignment vertical="center" wrapText="1"/></xf></cellXfs></styleSheet>
        """)
        zip.add("xl/worksheets/sheet1.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>\(cols)<sheetData>\(sheetData)</sheetData></worksheet>
        """)
        return zip.finalize()
    }

    private static func columnName(_ index: Int) -> String {
        var n = index
        var result = ""
        repeat {
            let rem = n % 26
            result = String(UnicodeScalar(UInt8(65 + rem))) + result
            n = n / 26 - 1
        } while n >= 0
        return result
    }

    // MARK: - PDF

    static func pdf(title: String, markdown: String, theme: DocTheme) throws -> Data {
        let pageSize = CGSize(width: 595.2, height: 841.8)
        let margin: CGFloat = 48
        var sections: [NSAttributedString] = []
        var section = NSMutableAttributedString(string: "")
        func append(_ text: String, size: CGFloat, weight: UIFont.Weight = .regular,
                    color: UIColor = .black, indent: CGFloat = 0, italic: Bool = false) {
            guard !text.isEmpty else { return }
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 6; style.paragraphSpacing = 8
            style.headIndent = indent; style.firstLineHeadIndent = indent
            let font = italic ? UIFont.italicSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size, weight: weight)
            section.append(NSAttributedString(string: text + "\n", attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: style
            ]))
        }
        let accent = DocumentBuilder.color(hex: theme.primary)
        append(title, size: 28, weight: .bold, color: accent)
        append(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none), size: 11, color: .gray)
        for block in MarkdownParser.blocks(from: markdown) {
            switch block.kind {
            case .title, .heading1: append(block.text, size: 19, weight: .bold, color: accent)
            case .heading2: append(block.text, size: 16, weight: .semibold)
            case .heading3: append(block.text, size: 13.5, weight: .semibold)
            case .bullet: append("•  " + block.text, size: 12, indent: 16)
            case .numbered: append(block.text, size: 12, indent: 16)
            case .quote: append("“" + block.text + "”", size: 12, color: .darkGray, indent: 16, italic: true)
            case .paragraph: append(block.text, size: 12)
            case .pageBreak:
                if section.length > 0 { sections.append(section.copy() as! NSAttributedString) }
                section = NSMutableAttributedString(string: "")
            }
        }
        if section.length > 0 { sections.append(section.copy() as! NSAttributedString) }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
        let path = CGPath(rect: CGRect(x: margin, y: margin, width: pageSize.width - margin * 2,
                                      height: pageSize.height - margin * 2), transform: nil)
        var layoutError: Error?
        var renderedPageCount = 0
        let result = renderer.pdfData { rendererContext in
            // Advance by the actual visible UTF-16 range. No character-count estimation
            // or recursive substring measurement, and no page can silently lose text.
            for attributed in sections {
                let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
                var position = 0
                while position < attributed.length {
                    if Task.isCancelled { layoutError = CancellationError(); return }
                    let advanced = autoreleasepool { () -> Int in
                        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: position, length: 0), path, nil)
                        let visible = CTFrameGetVisibleStringRange(frame)
                        guard visible.length > 0, visible.location == position else { return 0 }
                        rendererContext.beginPage()
                        renderedPageCount += 1
                        let graphics = rendererContext.cgContext
                        graphics.saveGState()
                        graphics.textMatrix = .identity
                        graphics.translateBy(x: 0, y: pageSize.height)
                        graphics.scaleBy(x: 1, y: -1)
                        CTFrameDraw(frame, graphics)
                        graphics.restoreGState()
                        // 页眉（第 2 页起：文档标题小字）与页脚页码
                        if renderedPageCount > 1 {
                            (title as NSString).draw(at: CGPoint(x: margin, y: 18), withAttributes: [
                                .font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.gray
                            ])
                        }
                        ("第 \(renderedPageCount) 页" as NSString).draw(
                            at: CGPoint(x: pageSize.width - 70, y: pageSize.height - 26),
                            withAttributes: [.font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.gray])
                        return visible.length
                    }
                    guard advanced > 0 else { layoutError = BuildError.pdfLayoutFailed; return }
                    position += advanced
                }
            }
            if sections.isEmpty { rendererContext.beginPage() }
        }
        if let layoutError { throw layoutError }
        return result
    }

    // MARK: - 工具

    /// "1F4E79" → UIColor
    static func color(hex: String) -> UIColor {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255.0,
                       green: CGFloat((value >> 8) & 0xFF) / 255.0,
                       blue: CGFloat(value & 0xFF) / 255.0, alpha: 1)
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// 去掉文件名里的非法字符
    static func safeFilename(_ raw: String, fallback: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : String(cleaned.prefix(60))
    }
}
