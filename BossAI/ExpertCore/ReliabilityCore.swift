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
struct CitationRegistry {
    private(set) var urls: [String] = []
    mutating func register(_ url: String) -> Int {
        let key = Self.canonical(url)
        if let index = urls.firstIndex(where: { Self.canonical($0) == key }) { return index + 1 }
        urls.append(url)
        return urls.count
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
    var markdown: String {
        urls.enumerated().map { "[\($0.offset + 1)] [查看来源](\($0.element))" }.joined(separator: "\n")
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
        if query.contains("最新") || query.contains("近期") || query.contains("新闻") { return .month }
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
