import Foundation

enum ResearchMode: String, CaseIterable, Identifiable {
    case automatic, online, local
    var id: String { rawValue }
    var label: String { switch self { case .automatic: return "自动核实"; case .online: return "联网研究"; case .local: return "仅用现有资料" } }
    var prompt: String {
        switch self {
        case .automatic: return "按问题判断是否需要实时证据，时效事实先核实。"
        case .online: return "本任务要求联网核实，证据不足则明确缺失，不能靠记忆填数。"
        case .local: return "本任务禁止联网，只使用用户提供的资料、本地资料库和明确标注的推理；当前实时外部事实未核实。"
        }
    }
}
enum AnswerStyle: String, CaseIterable, Identifiable {
    case concise, detailed
    var id: String { rawValue }
    var label: String { self == .concise ? "清晰简答" : "详细分析" }
    var prompt: String {
        self == .concise
        ? "先用1至3句话直接回答，再按任务需要给一份主表或要点。省略重复背景、过程自述与自检清单。表格每列只放同一类信息，宽表可拆成主题一致的多张表；不删用户要求的对象和字段。必要的未知和冲突独立说明。"
        : "先给结论，再按主题解释证据、假设、计算和行动建议。每个主题只解释一次，避免重复摘要与重复来源表。保留完整对象、字段和关键限制。"
    }
}
enum ResearchIntent {
    static func needsLiveEvidence(_ text: String) -> Bool {
        ["最新", "今天", "今日", "目前", "现在", "近期", "价格", "售价", "行情", "新闻", "现行", "联网", "发布", "竞品"].contains { text.contains($0) }
    }
    /// A task template should search its subject, not its instructions or desired output fields.
    static func searchSeed(from text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r", with: "")
        if let marker = normalized.range(of: "主题：") ?? normalized.range(of: "主题:") {
            let tail = String(normalized[marker.upperBound...])
            let line = tail.components(separatedBy: .newlines).first ?? tail
            let beforeDate = line.components(separatedBy: "截至日期").first ?? line
            let topic = (beforeDate.components(separatedBy: "需要的字段").first ?? beforeDate)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !topic.isEmpty { return String(topic.prefix(120)) }
        }
        return String(normalized.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
    }

    /// Field-level verification needs an identifiable product/version before retrieving evidence.
    static func needsSpecificTarget(_ text: String) -> Bool {
        let seed = searchSeed(from: text)
        guard seed.count <= 16,
              ["配置", "参数", "售价"].contains(where: seed.contains) else { return false }
        return !seed.unicodeScalars.contains {
            CharacterSet.decimalDigits.contains($0) || ("A"..."Z").contains(String($0).uppercased())
        }
    }

    static func fingerprint(_ query: String, recency: String) -> String {
        query.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") + "|" + recency
    }
    static func keywords(_ query: String) -> [String] {
        let cleaned = query.lowercased().components(separatedBy: " after:").first ?? query
        var result: [String] = []
        for part in cleaned.components(separatedBy: CharacterSet.alphanumerics.inverted) where part.count > 1 {
            let chars = Array(part)
            if chars.allSatisfy({ $0.isASCII }) { result.append(part) }
            else if chars.count > 2 {
                for i in 0..<(chars.count - 1) { result.append(String(chars[i...i+1])) }
            } else { result.append(part) }
        }
        let ignored: Set<String> = ["最新", "目前", "信息", "总结", "整理", "价格", "参数", "发布", "配置", "官方"]
        return Array(Set(result).subtracting(ignored)).sorted()
    }
    static func relevance(query: String, text: String) -> Int {
        let lower = text.lowercased()
        return keywords(query).filter { lower.contains($0) }.count
    }
}
enum EvidenceRanking {
    // Verified official domains, not a claim that every page or region on them is current.
    static let manufacturerDomains = ["apple.com", "huawei.com", "mi.com", "samsung.com"]
    static func isAuthority(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        return host.hasSuffix(".gov.cn") || host.hasSuffix(".gov") || manufacturerDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
    static func score(query: String, title: String, url: String, snippet: String, publishedAt: String) -> Int {
        let relevance = ResearchIntent.relevance(query: query, text: title + " " + snippet)
        let rumor = ["爆料", "传闻", "预计", "rumor"].contains { title.lowercased().contains($0) }
        return relevance * 8 + (relevance > 0 && isAuthority(url) ? 18 : 0) + (snippet.isEmpty ? 0 : 2)
            + (!publishedAt.isEmpty && !publishedAt.contains("抓取") ? 1 : 0) - (rumor ? 12 : 0)
    }
}
struct ResearchBudget {
    let searchLimit: Int
    let characterLimit: Int
    private(set) var searches = 0
    private(set) var evidenceCharacters = 0
    private var queries = Set<String>()
    init(searchLimit: Int = 12, characterLimit: Int = 32_000) { self.searchLimit = searchLimit; self.characterLimit = characterLimit }
    mutating func reserve(_ key: String) -> Bool {
        guard !queries.contains(key), searches < searchLimit, evidenceCharacters < characterLimit else { return false }
        queries.insert(key); searches += 1; return true
    }
    mutating func evidence(_ text: String) -> String {
        let available = max(0, characterLimit - evidenceCharacters)
        let limit = min(12_000, available)
        let value = String(text.prefix(limit)); evidenceCharacters += value.count
        return value + (value.count < text.count ? "\n【证据预算提示】后续文本未注入，不得据此声称已经覆盖所有事实；缺失项必须说明。" : "")
    }
}
