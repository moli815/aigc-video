import Foundation

/// Implements SSE field framing independently of URLSession and the UI.
struct SSEDecoder {
    private var lines: [String] = []
    private var byteCount = 0
    mutating func consume(_ raw: String) throws -> String? {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        if line.isEmpty { return drain() }
        if line.hasPrefix(":") { return nil }
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.first == "data" else { return nil }
        var value = parts.count > 1 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        byteCount += value.utf8.count
        guard byteCount <= 1_048_576 else { throw ExpertSkillError.invalidInput("流事件超过1MB") }
        lines.append(value)
        return nil
    }
    mutating func drain() -> String? {
        defer { lines.removeAll(keepingCapacity: true); byteCount = 0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// Stable identifiers across all searches in one assistant turn. Never renumber.
struct CitationSource: Codable, Equatable, Sendable, Identifiable {
    let id: Int
    let url: String
    var title: String = ""
    var publishedAt: String = ""
    var domain: String { URLComponents(string: url)?.host ?? "域名未记录" }
    var label: String { title.isEmpty ? domain + "（标题未记录）" : title }
    var dateLabel: String { publishedAt.isEmpty ? "发布时间未核实" : "检索返回日期：" + publishedAt + "（原文需核对）" }
}

struct CitationRegistry {
    private(set) var sources: [CitationSource] = []
    private var indices: [String: Int] = [:]
    var urls: [String] { sources.map(\.url) }
    mutating func register(_ url: String, title: String = "", publishedAt: String = "") -> Int {
        let key = Self.canonical(url)
        if let index = indices[key] {
            if sources[index].title.isEmpty { sources[index].title = title }
            if sources[index].publishedAt.isEmpty { sources[index].publishedAt = publishedAt }
            return sources[index].id
        }
        indices[key] = sources.count
        sources.append(CitationSource(id: sources.count + 1, url: url, title: title, publishedAt: publishedAt))
        return sources.count
    }
    static func canonical(_ raw: String) -> String {
        guard var parts = URLComponents(string: raw) else { return raw }
        parts.fragment = nil
        parts.host = parts.host?.lowercased()
        parts.queryItems = parts.queryItems?.filter {
            !$0.name.lowercased().hasPrefix("utm_") && !["spm", "fbclid"].contains($0.name.lowercased())
        }
        if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
        return parts.string ?? raw
    }
    var markdown: String { CitationPresentation.markdown(sources) }
}

enum CitationPresentation {
    static let legacyMarker = "\n\n---\n信息来源（编号在整轮对话中保持一致）：\n"
    private static let numberPattern = try! NSRegularExpression(pattern: #"\d{1,4}"#)
    private static let references = try! NSRegularExpression(pattern: #"(?i)(?:来源|检索结果|source(?:s)?)\s*[:：]?\s*([0-9][0-9/、，,;；\s和与\-–]*[0-9]|[0-9])|\[([0-9][0-9/、，,\s\-–]*[0-9]|[0-9])\]"#)
    static func referencedIDs(in text: String) -> Set<Int> {
        let body = text.components(separatedBy: legacyMarker).first ?? text
        let clean = body.replacingOccurrences(of: #"```[\s\S]*?```|`[^`\n]*`"#, with: "", options: .regularExpression)
        var result: Set<Int> = []
        func collect(_ value: String) {
            let ns = value as NSString
            for match in numberPattern.matches(in: value, range: NSRange(location: 0, length: ns.length)) {
                if let number = Int(ns.substring(with: match.range)) { result.insert(number) }
            }
            // Explicit source ranges, bounded to avoid expanding malformed enormous ranges.
            let rangePattern = #"(\d{1,4})\s*[-–]\s*(\d{1,4})"#
            if let pattern = try? NSRegularExpression(pattern: rangePattern) {
                for match in pattern.matches(in: value, range: NSRange(location: 0, length: ns.length)) {
                    if let lower = Int(ns.substring(with: match.range(at: 1))), let upper = Int(ns.substring(with: match.range(at: 2))), upper >= lower, upper - lower < 500 {
                        result.formUnion(lower...upper)
                    }
                }
            }
        }
        let ns = clean as NSString
        for match in references.matches(in: clean, range: NSRange(location: 0, length: ns.length)) { collect(ns.substring(with: match.range)) }
        // Source columns also support model-generated plain IDs such as "14/16".
        var sourceColumns: [Int] = []
        for line in clean.components(separatedBy: .newlines) {
            guard line.contains("|") else { sourceColumns = []; continue }
            let cells = MarkdownTableCore.cells(line)
            let columns = cells.indices.filter { ["来源", "引用", "出处", "source"].contains(cells[$0].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "* "))) }
            if !columns.isEmpty { sourceColumns = columns; continue }
            if MarkdownTableCore.isSeparator(line) { continue }
            for index in sourceColumns where cells.indices.contains(index) { collect(cells[index]) }
        }
        return result
    }
    static func cited(_ sources: [CitationSource], in text: String) -> [CitationSource] {
        let ids = referencedIDs(in: text)
        let body = text.components(separatedBy: legacyMarker).first ?? text
        let pattern = try! NSRegularExpression(pattern: #"https?://[^\s<>\]\)]+"#)
        let ns = body as NSString
        let links = Set(pattern.matches(in: body, range: NSRange(location: 0, length: ns.length)).map {
            CitationRegistry.canonical(ns.substring(with: $0.range).trimmingCharacters(in: CharacterSet(charactersIn: "。，；、\"")))
        })
        return sources.filter { ids.contains($0.id) || links.contains(CitationRegistry.canonical($0.url)) }
    }
    static func projection(text: String, json: String) -> (body: String, sources: [CitationSource]) {
        if let data = json.data(using: .utf8), let sources = try? JSONDecoder().decode([CitationSource].self, from: data) {
            return (text, sources)
        }
        // Old conversations keep their original data; only the known App footer is projected.
        guard let marker = text.range(of: legacyMarker) else { return (text, []) }
        let body = String(text[..<marker.lowerBound])
        let footer = String(text[marker.upperBound...])
        let pattern = try! NSRegularExpression(pattern: #"\[(\d+)\] \[查看来源\]\((https?://[^\s)]+)\)"#)
        let ns = footer as NSString
        var sources: [CitationSource] = []
        for match in pattern.matches(in: footer, range: NSRange(location: 0, length: ns.length)) {
            if let id = Int(ns.substring(with: match.range(at: 1))) {
                sources.append(CitationSource(id: id, url: ns.substring(with: match.range(at: 2))))
            }
        }
        return sources.isEmpty ? (text, []) : (body, sources)
    }
    static func historyContext(text: String, json: String) -> String {
        let projected = projection(text: text, json: json)
        let used = cited(projected.sources, in: projected.body)
        guard !used.isEmpty else { return projected.body }
        let notes = markdown(used)
        let bounded = String(notes.prefix(8000))
        return projected.body + "\n\n【该历史回答的来源编号，仅对应该回答；追问最新事实需重新检索】\n" + bounded
            + (notes.count > 8000 ? "\n【历史来源元数据过长，后续未注入；请重新检索核对】" : "")
    }
    static func markdown(_ sources: [CitationSource]) -> String {
        sources.map { source in
            let title = source.label.replacingOccurrences(of: "[", with: "（").replacingOccurrences(of: "]", with: "）").replacingOccurrences(of: "\n", with: " ")
            return "[\(source.id)] [\(title)](\(source.url)) · \(source.domain) · \(source.dateLabel)"
        }.joined(separator: "\n\n")
    }
}

enum SearchRecency: String, CaseIterable {
    case any, day, week, month, year
    var days: Int? {
        switch self { case .any: return nil; case .day: return 1; case .week: return 7; case .month: return 30; case .year: return 365 }
    }
    static func inferred(from query: String) -> SearchRecency {
        if query.contains("今天") || query.contains("今日") || query.contains("24小时") { return .day }
        if query.contains("本周") || query.contains("最近一周") { return .week }
        if query.contains("本月") || query.contains("最近一个月") || query.contains("近30天") { return .month }
        // 最新在售是有效状态，不能等同于发布日期在30天内。
        return .any
    }
    func query(_ query: String, now: Date = Date()) -> String {
        guard let days else { return query }
        let date = now.addingTimeInterval(-Double(days) * 86400)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
        return query + " after:" + formatter.string(from: date)
    }
}

enum StorageBoundary {
    static func isSafeLeaf(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255
        && !name.contains("/") && !name.contains("\\") && !name.contains("\0") && !name.contains(":")
    }
}

/// Preserve escaped separators and code spans; reject only actual separator rows.
enum MarkdownTableCore {
    static func cells(_ line: String) -> [String] {
        var cells: [String] = []; var cell = ""; var escaped = false; var code = false
        for char in line {
            if escaped { cell.append(char); escaped = false; continue }
            if char == "\\" { escaped = true; continue }
            if char == "`" { code.toggle(); cell.append(char); continue }
            if char == "|" && !code { cells.append(cell.trimmingCharacters(in: .whitespaces)); cell = "" }
            else { cell.append(char) }
        }
        if escaped { cell.append("\\") }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") { cells.removeFirst() }
        if line.trimmingCharacters(in: .whitespaces).hasSuffix("|") && !cells.isEmpty { cells.removeLast() }
        return cells
    }
    static func isSeparator(_ line: String) -> Bool {
        let values = cells(line)
        return !values.isEmpty && values.allSatisfy { value in
            let cleaned = value.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            return cleaned.count >= 3 && cleaned.allSatisfy { $0 == "-" }
        }
    }
    static func sheetName(_ title: String) -> String {
        let cleaned = title.filter { !"[]:*?/\\".contains($0) && !$0.isNewline }
            .trimmingCharacters(in: CharacterSet(charactersIn: "' "))
        return cleaned.isEmpty ? "工作表" : String(cleaned.prefix(31))
    }
}


/// Reads network bytes directly: SSE requires empty lines and exact CR/LF framing.
/// Never decode a partial UTF-8 scalar at a transport chunk boundary.
struct SSEByteDecoder {
    private var line: [UInt8] = []
    private var previousCR = false
    private var events = SSEDecoder()
    mutating func consume(_ byte: UInt8) throws -> String? {
        if previousCR {
            previousCR = false
            if byte == 10 { return nil }
        }
        if byte == 13 || byte == 10 {
            previousCR = byte == 13
            return try finishLine()
        }
        guard line.count < 1_048_576 else { throw ExpertSkillError.invalidInput("流数据行超过1MB") }
        line.append(byte)
        return nil
    }
    private mutating func finishLine() throws -> String? {
        guard let decoded = String(bytes: line, encoding: .utf8) else {
            throw ExpertSkillError.invalidInput("流数据不是有效UTF-8")
        }
        line.removeAll(keepingCapacity: true)
        return try events.consume(decoded)
    }
    /// Compatibility with providers omitting the last delimiter. The caller still
    /// requires an explicit DONE/stop/tool_calls marker; EOF alone is not success.
    mutating func finish() throws -> String? {
        if !line.isEmpty { _ = try finishLine() }
        return events.drain()
    }
}
