import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// SpreadsheetXMLCore.swift —— xlsx（OOXML）表格 XML 的安全解析核心。
// 职责：解析共享字符串表（sharedStrings.xml）与工作表 XML（sheet1.xml 等），
//       把单元格还原为按列对齐的文本行（" | " 分隔）。
// 在整个 App 中的角色：专家"表格"能力的读取引擎，模型看不到原始 XML，只看到文本行。
// 安全防呆（处理不可信 XML 的标配三件套）：
// 1) 体积上限 32MiB：防止超大文件耗尽内存。
// 2) 拒绝含 <!DOCTYPE / <!ENTITY 的文档并关闭外部实体解析：
//    阻断 XXE（XML 外部实体注入）攻击路径。
// 3) 行数上限 500、列号上限 16384（Excel 上限 XFD）：越界即中止解析，
//    防止恶意/畸形文件触发指数级资源消耗。
// 其他设计：单元格文本中的 "|" 替换为全角"／"，保证行内分隔符唯一可切分。

/// xlsx XML 解析入口：分别抽取共享字符串与数据行。
enum SpreadsheetXMLCore {
    /// 解析 sharedStrings.xml，返回共享字符串数组；解析失败返回空数组。
    static func sharedStrings(_ xml: String) -> [String] {
        let delegate = SheetXMLDelegate(shared: [], readingShared: true)
        return parse(xml, delegate: delegate) ? delegate.strings : []
    }
    /// 解析工作表 XML 为文本行；触达行数上限时返回已解析部分（stoppedAtLimit 标记）。
    static func rows(_ xml: String, shared: [String]) -> [String] {
        let delegate = SheetXMLDelegate(shared: shared, readingShared: false)
        return parse(xml, delegate: delegate) || delegate.stoppedAtLimit ? delegate.rows : []
    }
    /// 安全校验后交给 SAX 解析器（流式、低内存），委托状态由调用方持有。
    private static func parse(_ xml: String, delegate: SheetXMLDelegate) -> Bool {
        // XXE 防线：直接拒绝 DOCTYPE/ENTITY 文档，并关闭外部实体解析（双保险）。
        guard xml.utf8.count <= 32 * 1024 * 1024, !xml.contains("<!DOCTYPE"), !xml.contains("<!ENTITY") else { return false }
        let parser = XMLParser(data: Data(xml.utf8)); parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        return parser.parse()
    }
}

/// SAX 解析委托：一次遍历中收集 <si>（共享字符串）或 <row>（数据行）。
/// 行与列都有硬上限，触达即 abortParsing，保证解析时间与内存可控。
private final class SheetXMLDelegate: NSObject, XMLParserDelegate {
    let shared: [String]; let readingShared: Bool
    var strings: [String] = []; var rows: [String] = []
    var stoppedAtLimit = false
    private var string = ""; private var cell = ""; private var type = ""
    private var column = 0; private var values: [Int: String] = [:]
    private var capture = false
    init(shared: [String], readingShared: Bool) { self.shared = shared; self.readingShared = readingShared }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "si" { string = "" }
        if name == "row" { values = [:]; column = 0; if rows.count >= 500 { stoppedAtLimit = true; parser.abortParsing() } }
        if name == "c" {
            cell = ""; type = attributes["t"] ?? ""
            // 单元格引用（如 "BC12"）转 0 基列号：26 进制，A=1；超过 16384 视为畸形文件。
            let letters = (attributes["r"] ?? "").prefix { $0.isLetter }
            var index = 0
            for scalar in letters.uppercased().unicodeScalars {
                guard (65...90).contains(scalar.value) else { continue }
                index = index * 26 + Int(scalar.value - 64)
                if index > 16384 { parser.abortParsing(); return }
            }
            if index > 0 { column = index - 1 }
        }
        if name == "t" || (!readingShared && name == "v") { capture = true }
    }
    func parser(_ parser: XMLParser, foundCharacters text: String) {
        guard capture else { return }
        if readingShared { string += text } else { cell += text }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "t" || name == "v" { capture = false }
        if name == "si" { strings.append(string) }
        if name == "c" {
            var text = cell
            // t="s"：值是共享字符串索引，越界索引统一降级为占位符而不是崩溃。
            // t="b"：布尔单元格还原为 TRUE/FALSE。
            // 顺带把文本里的半角 "|" 替换为全角，保证行分隔符唯一可切分。
            if type == "s" { text = Int(cell).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? "[无效共享字符串]" }
            if type == "b" { text = cell == "1" ? "TRUE" : "FALSE" }
            values[column] = text.replacingOccurrences(of: "|", with: "／"); column += 1
        }
        // 稀疏单元格按列号对齐补空：跳过的列补 ""，保证每行列数一致。
        if name == "row", let maximum = values.keys.max(), maximum < 16384 {
            rows.append((0...maximum).map { values[$0] ?? "" }.joined(separator: " | "))
        }
    }
}
