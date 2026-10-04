import Foundation
import PDFKit
import Vision
import UIKit

/// 文件文本抽取：让 AI 能"读到"上传的文件。
/// 覆盖 PDF、Word(docx)、Excel(xlsx)、PPT(pptx)、纯文本类；
/// 图片走 Vision OCR（本地识别，中文优先）。
enum FileImportService {

    /// 从磁盘 URL 读入并抽取文本（安全作用域 URL 由调用方处理）
    static func load(url: URL) async -> (data: Data, text: String) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return (Data(), "") }
        let ext = url.pathExtension.lowercased()
        let text = await extractText(data: data, ext: ext)
        return (data, text)
    }

    static func extractText(data: Data, ext: String) async -> String {
        switch ext.lowercased() {
        case "pdf":
            return extractPDF(data: data)
        case "docx", "pptx", "xlsx", "pages", "numbers", "key":
            return extractOOXML(data: data, ext: ext.lowercased())
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

    // MARK: - OOXML（docx / pptx / xlsx）

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
            var shared: [String] = []
            if names.contains("xl/sharedStrings.xml"),
               let xml = String(data: (try? reader.data(for: "xl/sharedStrings.xml")) ?? Data(), encoding: .utf8) {
                shared = extractTagContents(xml, tag: "t")
            }
            let sheets = names.filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }.sorted()
            for (index, name) in sheets.enumerated() {
                guard let xml = String(data: (try? reader.data(for: name)) ?? Data(), encoding: .utf8) else { continue }
                let rows = extractSheetRows(xml: xml, shared: shared)
                if !rows.isEmpty {
                    parts.append("【工作表 \(index + 1)】\n" + rows.joined(separator: "\n"))
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
            if rows.count > 500 { break }
        }
        return rows
    }

    // MARK: - 图片 OCR（本地 Vision，不上传）

    static func ocr(imageData: Data) async -> String {
        guard let cgImage = UIImage(data: imageData)?.cgImage else { return "" }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
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
