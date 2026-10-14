import Foundation
import PDFKit
import Vision
import UIKit

//
//  FileImportService.swift
//  BossAI（中防AI iPad App）— Services 层
//
//  文件职责：上传文件的文本抽取。把 PDF、Word(docx)、Excel(xlsx)、PPT(pptx)、
//  iWork、纯文本与图片解析成纯文本，供 AI"阅读"上传内容。
//
//  在整个 App 中的角色：资料库入库链路的前置环节。FileImportService 抽出的
//  文本存入 StoredFile.textContent，供资料检索（search_library）与上下文使用。
//
//  关键设计决策：
//  - PDF：先直接取页面文本；取不到（扫描件）的页面渲染成图走本地 Vision OCR，
//    全程不上传，页数限 40 页防超长任务。
//  - OOXML（docx/pptx/xlsx）：按 ZIP 包解析内部 XML，自研轻量 XML 剥标签，
//    不引第三方解析库；xlsx 用共享字符串表还原单元格、限 500 行。
//  - 纯文本编码回退链：UTF-8 → GB18030（兼容 Windows 中文）→ ISO Latin 1。
//  - 重活（OOXML 解压解析、OCR）移出主线程，避免卡 UI。
//
//  防呆/安全冗余理由：
//  - 单文件 ≤32MB 的硬限制，防超大文件耗尽内存。
//  - 加密/损坏的 PDF 直接返回明确错误文案，不静默失败。
//  - OCR 结果标注"可能有误差"、超长内容标注"未读取"，让模型与用户都知道局限。
//
/// 文件文本抽取：让 AI 能"读到"上传的文件。
/// 覆盖 PDF、Word(docx)、Excel(xlsx)、PPT(pptx)、纯文本类；
/// 图片走 Vision OCR（本地识别，中文优先）。
enum FileImportService {

    /// 从磁盘 URL 读入并抽取文本（安全作用域 URL 由调用方处理）。
    /// - Parameter url: 文件地址（若是安全作用域 URL，需调用方已授权）
    /// - Returns: (文件原始数据, 抽取的文本)；超 32MB 或读取失败时 data 为空并附错误文案
    static func load(url: URL) async -> (data: Data, text: String) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // 尺寸前置检查：先查元数据再读盘，避免把超大文件整个读进内存
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32 * 1024 * 1024,
              let data = try? Data(contentsOf: url) else { return (Data(), "读取失败或超过32MB限制") }
        let ext = url.pathExtension.lowercased()
        let text = await extractText(data: data, ext: ext)
        return (data, text)
    }

    /// 按扩展名分发到对应的抽取器。
    /// - Parameters:
    ///   - data: 文件原始字节
    ///   - ext: 小写扩展名
    /// - Returns: 抽取出的纯文本；未知扩展名尝试按 UTF-8 文本读，失败返回空串
    static func extractText(data: Data, ext: String) async -> String {
        switch ext.lowercased() {
        case "pdf":
            // PDF 统一走"文本优先、OCR 兜底"的混合抽取
            return await extractPDFWithOCR(data: data)
        case "docx", "pptx", "xlsx", "pages", "numbers", "key":
            // OOXML 解压+解析较重，放后台线程执行
            let text = await Task.detached(priority: .userInitiated) { extractOOXML(data: data, ext: ext.lowercased()) }.value
            // 空结果给出可操作的提示（扫描件/iWork 的局限），而不是让模型误以为内容为空
            return text.isEmpty ? "未抽取到正文；扫描件可能需要OCR，iWork文件请先导出PDF或Office格式。" : text
        case "txt", "md", "markdown", "csv", "json", "xml", "html", "log":
            return decodePlainText(data)
        case "png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff":
            return await ocr(imageData: data)
        default:
            // 尝试按文本读，失败则返回空
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    /// 纯文本解码：优先 UTF-8，失败再用 GB18030（兼容 Windows 记事本导出的中文文件）
    static func decodePlainText(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text
        }
        let gb18030 = String.Encoding(rawValue: 0x80000632)
        if let text = String(data: data, encoding: gb18030) {
            return text
        }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: - PDF

    /// 直接抽取 PDF 各页文本（不做 OCR），页与页之间用空行分隔。
    /// 失败行为：数据无法构成 PDF 时返回空串
    static func extractPDF(data: Data) -> String {
        guard let doc = PDFDocument(data: data) else { return "" }
        var parts: [String] = []
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i), let text = page.string, !text.isEmpty {
                parts.append(text)
            }
        }
        return parts.joined(separator: "\n\n")
    }

    /// PDF 混合抽取：文本层可用直接取文本，扫描页渲染成图走本地 OCR；
    /// 最多处理 40 页，超出部分标注"未读取"。
    /// 失败行为：PDF 损坏或加密时返回明确错误文案
    static func extractPDFWithOCR(data: Data) async -> String {
        guard let document = PDFDocument(data: data), !document.isLocked else { return "PDF损坏或已加密，无法读取正文。" }
        var parts: [String] = []
        // 页数上限 40：OCR 很慢，超长 PDF 会拖垮导入体验
        for index in 0..<min(document.pageCount, 40) {
            if Task.isCancelled { break }
            guard let page = document.page(at: index) else { continue }
            let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty { parts.append(text) }
            else {
                // 无文本层 → 扫描页：渲染成图走 Vision OCR，并标注可能误差
                let image = page.thumbnail(of: CGSize(width: 1200, height: 1600), for: .mediaBox)
                if let png = image.pngData() { parts.append("【第\(index + 1)页OCR，可能有误差】\n" + (await ocr(imageData: png))) }
            }
        }
        // 明确告知截断，避免模型以为已读完全文
        if document.pageCount > 40 { parts.append("【超过40页，后续正文未读取】") }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - OOXML（docx / pptx / xlsx）

    /// 解析 OOXML 系文件（本质是 ZIP + XML）：docx 抽正文段落、pptx 逐页抽文本、
    /// xlsx 逐表抽行、iWork 尽力抽所有 XML 的纯文本。
    /// 失败行为：ZIP 损坏或条目缺失时返回空串（由调用方给出提示）
    static func extractOOXML(data: Data, ext: String) -> String {
        let reader = ZipReader(data: data)
        let names = reader.entryNames()
        var parts: [String] = []

        switch ext {
        case "docx":
            for name in ["word/document.xml"] where names.contains(name) {
                if let xml = String(data: (try? reader.data(for: name)) ?? Data(), encoding: .utf8) {
                    parts.append(plainText(fromXML: xml, paragraphTags: ["w:p", "w:tr"]))
                }
            }
        case "pptx":
            // 幻灯片按页码数字排序（字符串排序会把 slide10 排在 slide2 前）
            let slides = names.filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
                .sorted { lhs, rhs in
                    let a = Int(lhs.filter(\.isNumber)) ?? 0
                    let b = Int(rhs.filter(\.isNumber)) ?? 0
                    return a < b
                }
            for (index, name) in slides.enumerated() {
                if let xml = String(data: (try? reader.data(for: name)) ?? Data(), encoding: .utf8) {
                    let text = plainText(fromXML: xml, paragraphTags: ["a:p"])
                    if !text.isEmpty {
                        parts.append("【第 \(index + 1) 页】\n\(text)")
                    }
                }
            }
        case "xlsx":
            // 先解析共享字符串表：xlsx 的文本单元格存的是索引，需查表还原
            var shared: [String] = []
            if names.contains("xl/sharedStrings.xml"),
               let xml = String(data: (try? reader.data(for: "xl/sharedStrings.xml")) ?? Data(), encoding: .utf8) {
                shared = SpreadsheetXMLCore.sharedStrings(xml)
            }
            let sheets = names.filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }.sorted { (Int($0.filter(\.isNumber)) ?? 0) < (Int($1.filter(\.isNumber)) ?? 0) }
            for (index, name) in sheets.enumerated() {
                guard let xml = String(data: (try? reader.data(for: name)) ?? Data(), encoding: .utf8) else { continue }
                let rows = SpreadsheetXMLCore.rows(xml, shared: shared)
                if !rows.isEmpty {
                    // 行数上限标注：超出 500 行的部分如实告知未读取
                    parts.append("【工作表 \(index + 1)】\n" + rows.joined(separator: "\n") + (rows.count >= 500 ? "\n【最多读取500行，后续行未读取】" : ""))
                }
            }
        default:
            // pages/numbers/key 是 zip 包，尽力抽纯文本
            for name in names where name.hasSuffix(".xml") {
                if let xml = String(data: (try? reader.data(for: name)) ?? Data(), encoding: .utf8) {
                    let text = plainText(fromXML: xml, paragraphTags: ["w:p", "a:p"])
                    if text.count > 20 { parts.append(text) }
                }
            }
        }
        return parts.joined(separator: "\n\n")
    }

    /// XML → 纯文本：按段落标签断行，再剥标签、还原实体
    private static func plainText(fromXML xml: String, paragraphTags: [String]) -> String {
        var working = xml
        // 先把段落结束/自闭合标签换成换行，再在带属性的段落标签前插换行，
        // 保证剥标签后段落边界不丢失
        for tag in paragraphTags {
            working = working.replacingOccurrences(of: "</\(tag)>", with: "\n")
            working = working.replacingOccurrences(of: "<\(tag)/>", with: "\n")
            working = working.replacingOccurrences(of: "<\(tag) ", with: "\n<\(tag) ")
        }
        working = working.replacingOccurrences(of: "<w:br/>", with: "\n")
        working = working.replacingOccurrences(of: "<w:br />", with: "\n")
        working = working.replacingOccurrences(of: "<a:br/>", with: "\n")
        working = working.replacingOccurrences(of: "<w:tab/>", with: "\t")
        working = stripTags(working)
        return tidy(working)
    }

    /// 逐字符剥掉 XML 标签（不引 XML 解析器，足够应付 OOXML 的简单正文）
    private static func stripTags(_ xml: String) -> String {
        var out = ""
        var inside = false
        for ch in xml {
            if ch == "<" { inside = true; continue }
            if ch == ">" { inside = false; continue }
            if !inside { out.append(ch) }
        }
        return decodeEntities(out)
    }

    /// 还原 XML 中最常见的五个预定义实体（amp/lt/gt/quot/apos）
    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    /// 合并空行、去掉行首尾空白
    private static func tidy(_ s: String) -> String {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [String] = []
        var lastBlank = false
        for line in lines {
            if line.isEmpty {
                if !lastBlank { out.append("") }
                lastBlank = true
            } else {
                out.append(line)
                lastBlank = false
            }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 提取指定标签的所有内容片段（简单的范围扫描实现）
    private static func extractTagContents(_ xml: String, tag: String) -> [String] {
        var result: [String] = []
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        var searchRange = xml.startIndex..<xml.endIndex
        while let o = xml.range(of: open, range: searchRange),
              let c = xml.range(of: close, range: o.upperBound..<xml.endIndex) {
            result.append(decodeEntities(String(xml[o.upperBound..<c.lowerBound])))
            searchRange = c.upperBound..<xml.endIndex
        }
        return result
    }

    /// xlsx 单表：按行取单元格文本（共享字符串用索引还原）
    private static func extractSheetRows(xml: String, shared: [String]) -> [String] {
        var rows: [String] = []
        var searchRange = xml.startIndex..<xml.endIndex
        while let rOpen = xml.range(of: "<row", range: searchRange),
              let rClose = xml.range(of: "</row>", range: rOpen.upperBound..<xml.endIndex) {
            let rowXML = String(xml[rOpen.upperBound..<rClose.lowerBound])
            var cells: [String] = []
            var cellRange = rowXML.startIndex..<rowXML.endIndex
            while let cOpen = rowXML.range(of: "<c ", range: cellRange),
                  let cEnd = rowXML.range(of: "</c>", range: cOpen.upperBound..<rowXML.endIndex) {
                let cellXML = String(rowXML[cOpen.upperBound..<cEnd.lowerBound])
                // 共享字符串单元格（t="s"）存的是索引，需查表还原；否则原样取值
                let isShared = cellXML.contains("t=\"s\"")
                if let value = extractTagContents(cellXML, tag: "v").first {
                    if isShared, let idx = Int(value), idx >= 0, idx < shared.count {
                        cells.append(shared[idx])
                    } else {
                        cells.append(value)
                    }
                } else if let inline = extractTagContents(cellXML, tag: "t").first {
                    cells.append(inline)
                } else {
                    cells.append("")
                }
                cellRange = cEnd.upperBound..<rowXML.endIndex
            }
            let line = cells.joined(separator: " | ")
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                rows.append(line)
            }
            searchRange = rClose.upperBound..<xml.endIndex
            // 行数护栏：超 500 行停止，与上层"未读取"提示配套
            if rows.count > 500 { break }
        }
        return rows
    }

    // MARK: - 图片 OCR（本地 Vision，不上传）

    /// 用 Vision 框架做本地 OCR（中文优先，准确级别）。
    /// - Parameter imageData: 图片字节
    /// - Returns: 按行拼接的识别文本；图片无效或识别失败返回空串
    static func ocr(imageData: Data) async -> String {
        guard let cgImage = UIImage(data: imageData)?.cgImage else { return "" }
        return await withCheckedContinuation { continuation in
            // 识别放全局并发队列：Vision 回调线程与调用方解耦，主线程零阻塞
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                // 准确级别 + 语言纠偏：宁可慢一点也要识别质量
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                // 中文优先：中文用户场景下简体/繁体都覆盖，再兜底英文
                request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
                do {
                    try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
                    let lines = (request.results ?? []).compactMap {
                        $0.topCandidates(1).first?.string
                    }
                    continuation.resume(returning: lines.joined(separator: "\n"))
                } catch {
                    continuation.resume(returning: "")
                }
            }
        }
    }
}
