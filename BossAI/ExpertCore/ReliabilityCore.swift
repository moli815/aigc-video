import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// 文件职责：可靠性基础设施——SSE 流解析、引用来源注册与展示、时效窗口推断、
// 存储路径安全校验、Markdown 表格解析。
//
// 在整个 App 中的角色：
//   ChatService 用 SSEByteDecoder/SSEDecoder 解析流式回复；
//   ChatViewModel 用 CitationRegistry 登记本轮命中的来源（回答末尾的
//   「信息来源」列表）、用 CitationPresentation 从历史回答里识别被引用编号；
//   SearchRecency 为检索提供时效窗口；StorageBoundary / MarkdownTableCore
//   供专家技能运行时做路径与表格解析。
//
// 关键设计决策：
//   1. 引用注册与编号稳定性（register + canonical）：URL 规范化（去 #fragment、
//      域名小写、剔 utm_ 等跟踪参数）后做去重键；同一来源整轮对话只注册一次、
//      编号永不重排——回答里的「（来源 N）」必须能追溯到同一条编号；
//   2. SSE 解析独立于 URLSession 与 UI：按字节消费、精确处理 CR/LF 与空行分帧，
//      传输块边界绝不截断 UTF-8 标量；单行/单事件 1MB 上限防恶意流撑爆内存；
//   3. 防呆冗余：finish() 兼容缺尾分隔符的服务端，但 EOF 本身不算成功，
//      调用方仍要求显式 DONE/stop 标记；历史范围展开上限 500，防畸形超长区间。
// ─────────────────────────────────────────────────────────────────────────────

/// Implements SSE field framing independently of URLSession and the UI.
/// 按行消费 SSE 文本：组装 "data:" 字段，空行触发事件派发（drain），
/// 注释行（冒号开头）忽略；单事件累计超 1MB 抛错（防异常流）。
struct SSEDecoder {
    private var lines: [String] = []
    private var byteCount = 0
    /// 消费一行：返回 nil 表示事件尚未结束；空行返回已组装的完整事件（可能 nil）；
    /// 非 data 字段行与注释行直接忽略；超 1MB 抛 ExpertSkillError。
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
    /// 取出并清空当前累计的事件文本（多行 data 用 \n 连接）；无内容返回 nil
    mutating func drain() -> String? {
        defer { lines.removeAll(keepingCapacity: true); byteCount = 0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// Stable identifiers across all searches in one assistant turn. Never renumber.
/// 单条引用来源：整轮回答内编号稳定（id 从 1 递增，永不重排），
/// 回答中的「（来源 N）」与末尾来源列表靠 id 对应，可逐条追溯。
struct CitationSource: Codable, Equatable, Sendable, Identifiable {
    let id: Int
    let url: String
    var title: String = ""
    var publishedAt: String = ""
    /// 兜底展示域名（URL 解析失败时的占位文案）
    var domain: String { URLComponents(string: url)?.host ?? "域名未记录" }
    /// 列表展示标题；抓取失败时用域名占位并明示"标题未记录"
    var label: String { title.isEmpty ? domain + "（标题未记录）" : title }
    /// 日期展示：无日期必须显式写"发布时间未核实"，防止模型/读者把无日期当最新
    var dateLabel: String { publishedAt.isEmpty ? "发布时间未核实" : "检索返回日期：" + publishedAt + "（原文需核对）" }
}

/// 引用来源注册表：整轮回答共用一份，register 保证同 URL 只登记一次、编号稳定。
struct CitationRegistry {
    private(set) var sources: [CitationSource] = []
    private var indices: [String: Int] = [:]
    var urls: [String] { sources.map(\.url) }
    /// 登记一条来源并返回稳定编号（1 起）；同 canonical 键已存在时复用编号，
    /// 并只补全缺失的标题/日期（不覆盖已有值）。
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
    /// URL 规范化（去重键）：去 fragment、域名小写、剔除 utm_*/spm/fbclid 跟踪参数；
    /// 解析失败时原样返回。
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

/// 引用展示与识别：从回答文本中识别模型实际引用了哪些来源编号/链接，
/// 以及来源列表的 Markdown 渲染与历史消息的来源投影。
enum CitationPresentation {
    /// 旧版 App 在正文尾部拼接来源列表的固定标记（兼容旧数据用）
    static let legacyMarker = "\n\n---\n信息来源（编号在整轮对话中保持一致）：\n"
    private static let numberPattern = try! NSRegularExpression(pattern: #"\d{1,4}"#)
    private static let references = try! NSRegularExpression(pattern: #"(?i)(?:来源|检索结果|source(?:s)?)\s*[:：]?\s*([0-9][0-9/、，,;；\s和与\-–]*[0-9]|[0-9])|\[([0-9][0-9/、，,\s\-–]*[0-9]|[0-9])\]"#)
    /// 识别文本中被引用的来源编号集合：
    /// 匹配「来源 N」「[N]」「来源 3、5」等写法（代码块内的忽略，防误判），
    /// 表格"来源"列里的编号（含 "14/16" 这种斜杠并列）也会收集。
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
    /// 过滤出被回答实际引用的来源（编号命中或正文出现裸链接）
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
    /// 把消息的正文与来源拆开：新数据从 sourcesJSON 解码；旧数据只有尾部来源
    /// 列表时用 legacyMarker 投影拆出。返回 (正文, 来源列表)。
    /// P0-63 剥离 XML 形式工具调用文本（完整块 / 未闭合残片 / 孤立标签行）
    static func stripToolCallXML(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: #"(?s)<tool_call>.*?</tool_call>"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?s)<tool_call>.*$"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"(?m)^\s*</?(tool_call|function|parameter|tool_sep)[^>]*>\s*$"#, with: "", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func projection(text: String, json: String) -> (body: String, sources: [CitationSource]) {
        // P0-63 防护：先剥离模型误输出的 XML 形式工具调用文本，保证用户永远看不到内部调用格式
        // （实机自测发现：原生搜索不可用时，模型会把 <tool_call> 内部格式当正文输出）
        let text = stripToolCallXML(text)
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
    /// 历史消息注入上下文时用：正文 + 该回答实际引用的来源（上限 8000 字符），
    /// 并明确提示编号只对该回答有效——追问最新事实必须重新检索。
    static func historyContext(text: String, json: String) -> String {
        let projected = projection(text: text, json: json)
        let used = cited(projected.sources, in: projected.body)
        guard !used.isEmpty else { return projected.body }
        let notes = markdown(used)
        let bounded = String(notes.prefix(8000))
        return projected.body + "\n\n【该历史回答的来源编号，仅对应该回答；追问最新事实需重新检索】\n" + bounded
            + (notes.count > 8000 ? "\n【历史来源元数据过长，后续未注入；请重新检索核对】" : "")
    }
    /// 来源列表渲染成 Markdown 链接（含域名与日期标注，附加在回答末尾）
    static func markdown(_ sources: [CitationSource]) -> String {
        sources.map { source in
            let title = source.label.replacingOccurrences(of: "[", with: "（").replacingOccurrences(of: "]", with: "）").replacingOccurrences(of: "\n", with: " ")
            return "[\(source.id)] [\(title)](\(source.url)) · \(source.domain) · \(source.dateLabel)"
        }.joined(separator: "\n\n")
    }
}

/// 检索时效窗口：any（不限）/ day / week / month / year。
enum SearchRecency: String, CaseIterable {
    case any, day, week, month, year
    /// 窗口对应的天数（any 为 nil，不加时效过滤）
    var days: Int? {
        switch self { case .any: return nil; case .day: return 1; case .week: return 7; case .month: return 30; case .year: return 365 }
    }
    /// 从查询文本推断时效窗口（今天/本周/本月…）；
    /// 注意"最新在售"是有效状态而非时间戳，推断不出就回落 .any。
    static func inferred(from query: String) -> SearchRecency {
        if query.contains("今天") || query.contains("今日") || query.contains("24小时") { return .day }
        if query.contains("本周") || query.contains("最近一周") { return .week }
        if query.contains("本月") || query.contains("最近一个月") || query.contains("近30天") { return .month }
        // 最新在售是有效状态，不能等同于发布日期在30天内。
        return .any
    }
    /// 给查询追加 "after:yyyy-MM-dd" 后缀（部分引擎支持硬过滤；不支持时仅作提示）
    func query(_ query: String, now: Date = Date()) -> String {
        guard let days else { return query }
        let date = now.addingTimeInterval(-Double(days) * 86400)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
        return query + " after:" + formatter.string(from: date)
    }
}

/// 存储边界校验：文件名是否为"安全叶子名"（防路径穿越 / 非法字符 / 超长名）
enum StorageBoundary {
    /// 合法叶子名：非空、非 . / ..、UTF-8 ≤255 字节、不含路径分隔符与冒号/空字节
    static func isSafeLeaf(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255
        && !name.contains("/") && !name.contains("\\") && !name.contains("\0") && !name.contains(":")
    }
}

/// Preserve escaped separators and code spans; reject only actual separator rows.
/// Markdown 表格核心解析：按 | 切分单元格（保留转义符与代码段内的 |），
/// 供引用列识别与 Excel 导出复用。
enum MarkdownTableCore {
    /// 把一行 Markdown 表格行切成单元格数组；行首尾的包围 | 会被去掉
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
    /// 是否为表格分隔行（形如 |---|:-:---|）
    static func isSeparator(_ line: String) -> Bool {
        let values = cells(line)
        return !values.isEmpty && values.allSatisfy { value in
            let cleaned = value.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            return cleaned.count >= 3 && cleaned.allSatisfy { $0 == "-" }
        }
    }
    /// 把标题清洗成合法 Excel 工作表名（去非法字符，≤31 字符，空则回退"工作表"）
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
            // CRLF：两个字节算一次换行，不能重复触发
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
            // 行尾才解码：传输块边界可能落在多字节汉字中间，按整行解码绝不截断标量
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
