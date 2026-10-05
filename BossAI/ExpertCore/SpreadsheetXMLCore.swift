import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

enum SpreadsheetXMLCore {
    static func sharedStrings(_ xml: String) -> [String] {
        let delegate = SheetXMLDelegate(shared: [], readingShared: true)
        return parse(xml, delegate: delegate) ? delegate.strings : []
    }
    static func rows(_ xml: String, shared: [String]) -> [String] {
        let delegate = SheetXMLDelegate(shared: shared, readingShared: false)
        return parse(xml, delegate: delegate) || delegate.stoppedAtLimit ? delegate.rows : []
    }
    private static func parse(_ xml: String, delegate: SheetXMLDelegate) -> Bool {
        guard xml.utf8.count <= 32 * 1024 * 1024, !xml.contains("<!DOCTYPE"), !xml.contains("<!ENTITY") else { return false }
        let parser = XMLParser(data: Data(xml.utf8)); parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        return parser.parse()
    }
}

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
            if type == "s" { text = Int(cell).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? "[无效共享字符串]" }
            if type == "b" { text = cell == "1" ? "TRUE" : "FALSE" }
            values[column] = text.replacingOccurrences(of: "|", with: "／"); column += 1
        }
        if name == "row", let maximum = values.keys.max(), maximum < 16384 {
            rows.append((0...maximum).map { values[$0] ?? "" }.joined(separator: " | "))
        }
    }
}
