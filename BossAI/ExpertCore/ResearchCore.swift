import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// 文件职责：研究/检索的核心决策原语——研究模式、回答风格、检索意图识别、
// LLM 查询规划的解析、证据评分（EvidenceRanking）与检索预算（ResearchBudget）。
//
// 在整个 App 中的角色：
//   ChatViewModel 的工具主循环与预检索阶段都依赖本文件：判断"要不要联网"
//   （needsLiveEvidence）、"检索词怎么提炼"（searchSeed）、"结果值不值得给模型"
//   （EvidenceRanking.score）、"这轮还能花多少预算"（ResearchBudget）。
//
// 关键设计决策（P0-20 检索质量主线）：
//   1. 来源过滤：relevance 为 0 的结果在 rankRelevant 里直接被丢弃——
//      搜索引擎常返回无关页面，零匹配候选绝不能送给模型；
//   2. 新鲜度降权：时效查询（recency ≠ any）对无日期结果 -6 分、明确过期 -14 分，
//      mild 惩罚而非清零，避免把合法页面完全踢出；
//   3. 权威加分 / UGC 降权：政府与厂商官网加分，社媒视频站降权（爆料只能当线索）；
//   4. 预算硬约束：单轮检索 ≤5 次、证据 ≤16K 字符（P0-10），防单轮成本失控。
// ─────────────────────────────────────────────────────────────────────────────

/// 研究模式：决定本轮回答的证据策略，同时转成注入给模型的系统指令。
enum ResearchMode: String, CaseIterable, Identifiable {
    case automatic, online, local
    var id: String { rawValue }
    /// 设置页展示名
    var label: String { switch self { case .automatic: return "自动核实"; case .online: return "联网研究"; case .local: return "仅用现有资料" } }
    /// 注入给模型的模式指令（local 模式明确禁止联网并要求标注未核实）
    var prompt: String {
        switch self {
        case .automatic: return "按问题判断是否需要实时证据，时效事实先核实。"
        case .online: return "本任务要求联网核实，证据不足则明确缺失，不能靠记忆填数。"
        case .local: return "本任务禁止联网，只使用用户提供的资料、本地资料库和明确标注的推理；当前实时外部事实未核实。"
        }
    }
}

/// 回答风格：简答（先结论后主表）或详细分析（按主题展开证据与建议），同样转成模型指令。
enum AnswerStyle: String, CaseIterable, Identifiable {
    case concise, detailed
    var id: String { rawValue }
    /// 设置页展示名
    var label: String { self == .concise ? "清晰简答" : "详细分析" }
    /// 注入给模型的输出格式指令（两种风格都要求保留对象/字段/未核实项）
    var prompt: String {
        self == .concise
        ? "先用1至3句话直接回答，再按任务需要给一份主表或要点。省略重复背景、过程自述与自检清单。表格每列只放同一类信息，宽表可拆成主题一致的多张表；不删用户要求的对象和字段。必要的未知和冲突独立说明。"
        : "先给结论，再按主题解释证据、假设、计算和行动建议。每个主题只解释一次，避免重复摘要与重复来源表。保留完整对象、字段和关键限制。"
    }
}

/// 检索意图识别：从用户文本判断是否需要实时证据、提炼检索种子词、
/// 计算查询指纹（去重键）与关键词相关性。
enum ResearchIntent {
    /// 文本是否含时效敏感词（价格/最新/新闻等）——命中则强制走实时证据核实
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

    /// 查询指纹：小写 + 压缩空白 + 时效后缀，用作本轮检索去重键（相同指纹复用缓存证据）
    static func fingerprint(_ query: String, recency: String) -> String {
        query.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") + "|" + recency
    }
    /// 把查询拆成相关性匹配用的关键词：ASCII 词整取，中文取相邻二字组合；
    /// 剔除"最新/价格/参数"这类对匹配无意义的停用词。
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
    /// 相关性打分：命中关键词个数。来源过滤用它做零值过滤（0 分 = 无关，直接丢弃）
    static func relevance(query: String, text: String) -> Int {
        let lower = text.lowercased()
        return keywords(query).filter { lower.contains($0) }.count
    }
}
/// LLM 查询规划的单条查询
struct PlannedQuery: Sendable, Equatable {
    let query: String
    let recency: SearchRecency
}

/// 查询规划结果：意图 + 实体清单 + 可执行查询。
/// 借鉴 anysearch batch_search 的"先拆解再并行"模式：模型先做意图分析，
/// app 端把多条查询并行执行；intent=none 表示本轮无需联网（纯指令/追问）。
struct SearchPlan: Sendable {
    let intent: String
    let entities: [String]
    let queries: [PlannedQuery]

    /// 解析规划器输出：容忍 ```json 围栏与前后缀文本；解析失败返回 nil（调用方回退规则 seed）
    static func parse(_ text: String) -> SearchPlan? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            trimmed = trimmed.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if let fence = trimmed.range(of: "```") { trimmed = String(trimmed[..<fence.lowerBound]) }
        }
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start < end,
              let data = trimmed[start...end].data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let intent = (obj["intent"] as? String)?.lowercased() ?? "single"
        let entities = ((obj["entities"] as? [Any]) ?? [])
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count <= 40 }
        guard intent != "none" else { return SearchPlan(intent: "none", entities: [], queries: []) }
        var queries: [PlannedQuery] = []
        if let list = obj["queries"] as? [Any] {
            for item in list.prefix(4) {
                guard let entry = item as? [String: Any],
                      let q = (entry["q"] as? String)?.trimmingCharacters(in: .whitespaces), q.count >= 2 else { continue }
                let recency = (entry["recency"] as? String).flatMap(SearchRecency.init(rawValue:)) ?? .any
                queries.append(PlannedQuery(query: String(q.prefix(120)), recency: recency))
            }
        }
        guard !queries.isEmpty else { return nil }
        return SearchPlan(intent: intent, entities: Array(entities.prefix(8)), queries: queries)
    }
}

/// 证据评分：融合相关性、权威性、时效与可信度，决定结果注入顺序。
enum EvidenceRanking {
    // Verified official domains, not a claim that every page or region on them is current.
    /// 厂商官方域名（加分项；仅代表域名可信，不代表页面内容新鲜）
    static let manufacturerDomains = ["apple.com", "huawei.com", "mi.com", "samsung.com"]
    /// UGC/视频站点：爆料可作线索，但极少能作为参数核实依据；排序降权而非排除。
    static let lowValueDomains = ["bilibili.com", "b23.tv", "weibo.com", "douyin.com",
                                  "youtube.com", "xiaohongshu.com", "tieba.baidu.com", "zhihu.com"]
    /// UGC/视频站点是否为低价值源（只降权不排除，爆料可作线索）
    static func isLowValue(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        return lowValueDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
    /// 是否权威来源：政府域名或厂商官方域名
    static func isAuthority(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        return host.hasSuffix(".gov.cn") || host.hasSuffix(".gov") || manufacturerDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
    /// 单条结果综合评分（P0-20 排序核心）：
    /// 相关性×8 为主干 + 权威加分 + 摘要加分 + 已核实日期加分；
    /// 时效查询叠加新鲜度降权（无日期 -6、超出窗口 -14）；
    /// 标题含爆料/传闻词 -12，低价值 UGC 源 -10。
    static func score(query: String, title: String, url: String, snippet: String, publishedAt: String, recency: SearchRecency = .any) -> Int {
        let relevance = ResearchIntent.relevance(query: query, text: title + " " + snippet)
        let rumor = ["爆料", "传闻", "预计", "rumor"].contains { title.lowercased().contains($0) }
        var value = relevance * 8 + (relevance > 0 && isAuthority(url) ? 18 : 0) + (snippet.isEmpty ? 0 : 2)
        let verifiedDate = !publishedAt.isEmpty && !publishedAt.contains("抓取") && !publishedAt.contains("未核实")
        value += verifiedDate ? 1 : 0
        // P0 检索质量：时效查询的新鲜度降权。
        // 无日期 ≠ 有罪，但要排在有近期日期的结果后面（ mild 惩罚，避免把合法页面清零）。
        if recency != .any {
            if !verifiedDate { value -= 6 }
            else if let date = WebSearchService.parseDateTokenPublic(publishedAt),
                    let window = recency.days, date < Date().addingTimeInterval(-Double(window) * 86400) {
                value -= 14  // 明确过期的结果：时效查询里几乎不可引用
            }
        }
        return value - (rumor ? 12 : 0) - (isLowValue(url) ? 10 : 0)
    }
}

/// 单轮检索预算：限制检索次数与注入证据总字符数，超限后拒绝新查询并提示模型
/// 标注未核实——防止单轮对话成本失控（P0-10：5 次 / 16K 字符）。
struct ResearchBudget {
    let searchLimit: Int
    let characterLimit: Int
    private(set) var searches = 0
    private(set) var evidenceCharacters = 0
    private var queries = Set<String>()
    // P0-10 成本优化：单轮检索上限 12→5、证据预算 32K→16K（业界推荐区间），防单轮成本失控
    init(searchLimit: Int = 5, characterLimit: Int = 16_000) { self.searchLimit = searchLimit; self.characterLimit = characterLimit }
    /// 申请一次检索额度：同指纹重复查询、次数或字符超限时返回 false（调用方需如实告知模型）
    mutating func reserve(_ key: String) -> Bool {
        guard !queries.contains(key), searches < searchLimit, evidenceCharacters < characterLimit else { return false }
        queries.insert(key); searches += 1; return true
    }
    /// 按剩余预算截断证据文本；被截断时追加提示，防止模型把"没注入"当成"已核实"
    mutating func evidence(_ text: String) -> String {
        let available = max(0, characterLimit - evidenceCharacters)
        let limit = min(12_000, available)
        let value = String(text.prefix(limit)); evidenceCharacters += value.count
        return value + (value.count < text.count ? "\n【证据预算提示】后续文本未注入，不得据此声称已经覆盖所有事实；缺失项必须说明。" : "")
    }
}
