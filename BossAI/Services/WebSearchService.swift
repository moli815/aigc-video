import Foundation

/// 联网搜索：App 自带的多引擎融合搜索，不依赖任何模型厂商。
/// 换任何对话模型都能继续联网。
///
/// 实测结论（2026-10，用「抖音最新政策」「增值税小规模纳税人新政」等 3 组查询对比）：
/// - 搜狗：中文平台政策/时效性内容最强（能搜到官方规则中心、抖店公告、公众号新规速递）
/// - 360：时效性好（新闻聚合带"14天前"），结果相关
/// - 百度：相关性尚可，但跳转链接+广告多
/// - Bing RSS：结构化最好（自带摘要+日期），但中文平台政策类偏弱
/// - Google News RSS：被墙不可用；searx.be 有反爬；DuckDuckGo 抓取失败
///
/// 策略：auto 模式下 4 源**并行**请求 → 轮转合并去重，任何一家被反爬/抽风其余自动顶上。
enum WebSearchEngine: String, CaseIterable, Identifiable {
    case auto
    case sogou
    case so360
    case baidu
    case bing
    case tavily
    case bocha
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "自动（多源融合，推荐）"
        case .sogou: return "搜狗"
        case .so360: return "360 搜索"
        case .baidu: return "百度"
        case .bing: return "Bing"
        case .tavily: return "Tavily API"
        case .bocha: return "博查 API"
        }
    }

    var needsKey: Bool { self == .tavily || self == .bocha }
}

struct SearchHit {
    let title: String
    let url: String
    let snippet: String
    /// 发布时间（部分源才有）
    var publishedAt: String = ""
}

enum WebSearchService {
    private static let engineKey = "bossai.search_engine"
    private static let tavilyKeyKey = "bossai.tavily_key"
    private static let bochaKeyKey = "bossai.bocha_key"

    // MARK: - 设置

    static var engine: WebSearchEngine {
        get { WebSearchEngine(rawValue: UserDefaults.standard.string(forKey: engineKey) ?? "") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: engineKey) }
    }

    static var tavilyKey: String {
        get { UserDefaults.standard.string(forKey: tavilyKeyKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: tavilyKeyKey) }
    }

    static var bochaKey: String {
        get { UserDefaults.standard.string(forKey: bochaKeyKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: bochaKeyKey) }
    }

    private static var userAgent: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    }

    // MARK: - 搜索入口

    static func search(query: String, count: Int = 8) async -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        switch engine {
        case .auto:
            if !tavilyKey.isEmpty {
                let hits = await searchTavily(q, count: count)
                if !hits.isEmpty { return hits }
            }
            if !bochaKey.isEmpty {
                let hits = await searchBocha(q, count: count)
                if !hits.isEmpty { return hits }
            }
            return await fusedSearch(q, count: count)
        case .tavily:
            return await withFallback(q, count: count) { await searchTavily(q, count: count) }
        case .bocha:
            return await withFallback(q, count: count) { await searchBocha(q, count: count) }
        case .sogou:
            return await withFallback(q, count: count) { await searchSogou(q, count: count) }
        case .so360:
            return await withFallback(q, count: count) { await search360(q, count: count) }
        case .baidu:
            return await withFallback(q, count: count) { await searchBaidu(q, count: count) }
        case .bing:
            return await withFallback(q, count: count) { await searchBing(q, count: count) }
        }
    }

    /// 单源模式失败时依次回落到融合模式
    private static func withFallback(_ q: String, count: Int,
                                     primary: () async -> [SearchHit]) async -> [SearchHit] {
        let hits = await primary()
        if !hits.isEmpty { return hits }
        return await fusedSearch(q, count: count, skipEngine: engine)
    }

    /// 多源并行 + 轮转合并（融合模式的灵魂：谁挂了都不影响整体）
    private static func fusedSearch(_ q: String, count: Int, skipEngine: WebSearchEngine? = nil) async -> [SearchHit] {
        async let a = (skipEngine == .sogou) ? searchSogou(q, count: 0) : searchSogou(q, count: count)
        async let b = (skipEngine == .so360) ? search360(q, count: 0) : search360(q, count: count)
        async let c = (skipEngine == .baidu) ? searchBaidu(q, count: 0) : searchBaidu(q, count: count)
        async let d = (skipEngine == .bing) ? searchBing(q, count: 0) : searchBing(q, count: count)
        let results = await (a, b, c, d)
        let lists: [[SearchHit]] = [results.0, results.1, results.2, results.3]

        var merged: [SearchHit] = []
        var seen = Set<String>()
        let maxLen = lists.map(\.count).max() ?? 0

        outer: for i in 0..<maxLen {
            for list in lists where i < list.count {
                let hit = list[i]
                let key = hit.title.replacingOccurrences(of: " ", with: "")
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                merged.append(hit)
                if merged.count >= count { break outer }
            }
        }
        return merged
    }

    /// 抓取网页正文（供模型阅读），失败返回空字符串
    static func fetchPageText(url: String, limit: Int = 4000) async -> String {
        guard let target = URL(string: url), target.scheme?.hasPrefix("http") == true else { return "" }
        guard let data = await rawGet(target, timeout: 18) else { return "" }
        guard let html = decodeHTML(data) else { return "" }
        let text = plainText(fromHTML: html)
        guard text.count > 80 else { return "" }
        return String(text.prefix(limit))
    }

    // MARK: - 搜狗

    private static func searchSogou(_ query: String, count: Int) async -> [SearchHit] {
        await searchHTML(engine: .sogou, host: "https://www.sogou.com",
                         path: "/web?query=\(percentEncode(query) ?? "")",
                         count: count)
    }

    // MARK: - 360

    private static func search360(_ query: String, count: Int) async -> [SearchHit] {
        await searchHTML(engine: .so360, host: "https://www.so.com",
                         path: "/s?q=\(percentEncode(query) ?? "")",
                         count: count)
    }

    // MARK: - 百度

    private static func searchBaidu(_ query: String, count: Int) async -> [SearchHit] {
        await searchHTML(engine: .baidu, host: "https://www.baidu.com",
                         path: "/s?wd=\(percentEncode(query) ?? "")&rn=\(max(count, 10))",
                         count: count)
    }

    // MARK: - Bing（RSS 优先，HTML 兜底）

    private static func searchBing(_ query: String, count: Int) async -> [SearchHit] {
        if let hits = await searchBingRSS(query, count: count), !hits.isEmpty {
            return hits
        }
        return await searchHTML(engine: .bing, host: "https://cn.bing.com",
                                path: "/search?q=\(percentEncode(query) ?? "")&setlang=zh-CN&ensearch=0",
                                count: count)
    }

    private static func searchBingRSS(_ query: String, count: Int) async -> [SearchHit]? {
        guard let encoded = percentEncode(query),
              let url = URL(string: "https://www.bing.com/search?q=\(encoded)&format=rss&count=\(max(count, 10))&mkt=zh-CN")
        else { return nil }
        guard let data = await rawGet(url, timeout: 15), let xml = decodeHTML(data) else { return nil }
        guard xml.contains("<item>") || xml.contains("<item ") else { return nil }
        let hits = parseRSS(xml, count: count)
        return hits.isEmpty ? nil : hits
    }

    /// 解析 RSS：<item><title/> <link/> <description/> <pubDate/></item>
    private static func parseRSS(_ xml: String, count: Int) -> [SearchHit] {
        var hits: [SearchHit] = []
        let blocks = xml.components(separatedBy: "<item>")
            .dropFirst()
            .flatMap { $0.components(separatedBy: "<item ") }
        for block in blocks {
            guard hits.count < count else { break }
            guard let end = block.range(of: "</item>") else { continue }
            let chunk = String(block[block.startIndex..<end.lowerBound])
            guard let rawTitle = tagValue("title", in: chunk),
                  let rawLink = tagValue("link", in: chunk),
                  !rawTitle.isEmpty, !rawLink.isEmpty else { continue }
            let rawDesc = tagValue("description", in: chunk) ?? ""
            let date = tagValue("pubDate", in: chunk) ?? ""
            hits.append(SearchHit(title: plainText(fromHTML: stripCDATA(rawTitle)),
                                  url: decodeEntities(stripCDATA(rawLink)),
                                  snippet: plainText(fromHTML: stripCDATA(rawDesc)),
                                  publishedAt: date))
        }
        return hits
    }

    private static func tagValue(_ tag: String, in xml: String) -> String? {
        firstMatch(xml, pattern: "<\(tag)[^>]*>(.*?)</\(tag)>")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripCDATA(_ s: String) -> String {
        s.replacingOccurrences(of: "<![CDATA[", with: "").replacingOccurrences(of: "]]>", with: "")
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    // MARK: - 通用 HTML 结果解析（搜狗 / 360 / 百度 / Bing HTML 共用）
    //
    // 不依赖各家会改版的 class 名，改为通用地提取「指向外部内容的 <a> 标题链接」，
    // 再过滤掉各引擎自身的导航 / 搜索页 / 相关搜索链接。反爬验证码页没有结果链接，
    // 自然解析为空，由其他源兜底。

    private static func searchHTML(engine: WebSearchEngine, host: String, path: String, count: Int) async -> [SearchHit] {
        guard count > 0, let url = URL(string: host + path) else { return [] }
        guard let data = await rawGet(url, timeout: 15), let html = decodeHTML(data) else { return [] }
        return parseLinks(html: html, engine: engine, count: count)
    }

    private static func parseLinks(html: String, engine: WebSearchEngine, count: Int) -> [SearchHit] {
        var hits: [SearchHit] = []
        var seenTitles = Set<String>()

        let pattern = "<a[^>]+href=\\\"([^\\\"]+)\\\"[^>]*>(.*?)</a>"
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in regex.matches(in: html, options: [], range: range) {
            guard hits.count < count else { break }
            guard match.numberOfRanges >= 3,
                  let hrefRange = Range(match.range(at: 1), in: html),
                  let textRange = Range(match.range(at: 2), in: html) else { continue }

            let href = decodeEntities(String(html[hrefRange])).trimmingCharacters(in: .whitespaces)
            let rawTitle = String(html[textRange])
            // 粗筛：原始标题太短的（导航、图标链接）直接跳过，省去无谓的 HTML 清洗
            guard rawTitle.count >= 12 else { continue }

            let title = plainText(fromHTML: rawTitle)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.count >= 10 else { continue }
            guard isResultLink(href, engine: engine) else { continue }
            guard seenTitles.insert(title.replacingOccurrences(of: " ", with: "")).inserted else { continue }

            // 摘要：标题之后的文本片段（宽松提取，拿不到就算了）
            let tail = String(html[textRange.upperBound...].prefix(900))
            let snippet = firstLongLine(plainText(fromHTML: tail))

            hits.append(SearchHit(title: title,
                                  url: absolutize(href, engine: engine),
                                  snippet: snippet,
                                  publishedAt: findDate(in: snippet) ?? findDate(in: title)))
        }
        return hits
    }

    /// 过滤引擎自身的导航 / 搜索页 / 相关搜索链接，只留真实结果
    private static func isResultLink(_ href: String, engine: WebSearchEngine) -> Bool {
        let lower = href.lowercased()
        if lower.hasPrefix("#") || lower.hasPrefix("javascript:") { return false }
        // 通用规则：各引擎的站内搜索页（含相对路径写法）一律排除
        if lower.hasPrefix("/s?") || lower.hasPrefix("/web?") || lower.hasPrefix("/sf/") { return false }

        switch engine {
        case .sogou:
            // 跳转链接 /link?url= 保留；排除站内搜索页、公众号搜索入口等
            if lower.contains("sogou.com") && !lower.contains("/link") { return false }
            if lower.contains("/web?") || lower.contains("weixin.sogou") { return false }
        case .so360:
            // 跳转链接 so.com/link?m= 保留；排除站内搜索页与相关搜索
            if lower.contains("so.com/s?") || lower.contains("/s?q=") { return false }
            if lower.contains("so.com") && !lower.contains("/link") { return false }
            if lower.contains("news.so.com/ns?") { return false }
        case .baidu:
            // 跳转链接 baidu.com/link?url= 保留；排除站内搜索页
            if lower.contains("baidu.com/s?") || lower.contains("/sf/vsearch") { return false }
            if lower.contains("baidu.com") && !lower.contains("/link") { return false }
        case .bing:
            if lower.contains("bing.com/search?") || lower.contains("bing.com/news") { return false }
        default:
            break
        }
        return true
    }

    private static func absolutize(_ href: String, engine: WebSearchEngine) -> String {
        if href.hasPrefix("http") { return href }
        let host: String
        switch engine {
        case .sogou: host = "https://www.sogou.com"
        case .so360: host = "https://www.so.com"
        case .baidu: host = "https://www.baidu.com"
        default: host = "https://cn.bing.com"
        }
        return href.hasPrefix("/") ? host + href : host + "/" + href
    }

    /// 从一段文本里找第一条像"摘要"的长句（≥24 字，含中文，过滤引擎 UI 文案）
    private static func firstLongLine(_ text: String) -> String {
        let bad = ["反馈", "播报", "查看更多", "相关搜索", "下一页", "百度一下", "大家还在搜", "快照"]
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.count >= 24 else { continue }
            guard t.contains(where: \.isCJK) else { continue }
            guard !bad.contains(where: { t.contains($0) }) else { continue }
            return String(t.prefix(160))
        }
        return ""
    }

    /// 宽松日期提取：2026年4月14日 / 2026-04-14 / 14天前 / 3小时前
    private static func findDate(in text: String) -> String? {
        let patterns = [
            #"20\d{2}年\d{1,2}月\d{1,2}日"#,
            #"20\d{2}-\d{1,2}-\d{1,2}"#,
            #"\d+天前"#, #"\d+小时前"#, #"昨天"#, #"今天"#,
        ]
        for p in patterns {
            if let m = firstMatch(text, pattern: p) { return m }
        }
        return nil
    }

    private static func percentEncode(_ s: String) -> String? {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
    }

    // MARK: - Tavily API

    private static func searchTavily(_ query: String, count: Int) async -> [SearchHit] {
        let key = tavilyKey
        guard !key.isEmpty, count > 0 else { return [] }
        guard let url = URL(string: "https://api.tavily.com/search") else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 25
        let body: [String: Any] = [
            "api_key": key, "query": query, "max_results": count,
            "search_depth": "basic", "include_answer": false,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { item in
            guard let title = item["title"] as? String, let url = item["url"] as? String else { return nil }
            return SearchHit(title: title, url: url, snippet: (item["content"] as? String) ?? "")
        }
    }

    // MARK: - 博查 API

    private static func searchBocha(_ query: String, count: Int) async -> [SearchHit] {
        let key = bochaKey
        guard !key.isEmpty, count > 0 else { return [] }
        guard let url = URL(string: "https://api.bochaai.com/v1/web-search") else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 25
        let body: [String: Any] = ["query": query, "count": count, "summary": true]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["data"] as? [String: Any],
              let webPages = payload["webPages"] as? [String: Any],
              let values = webPages["value"] as? [[String: Any]] else { return [] }
        return values.compactMap { item in
            guard let name = item["name"] as? String, let url = item["url"] as? String else { return nil }
            let snippet = (item["summary"] as? String) ?? (item["snippet"] as? String) ?? ""
            return SearchHit(title: name, url: url, snippet: snippet)
        }
    }

    // MARK: - 网络与解析工具

    private static func rawGet(_ url: URL, timeout: TimeInterval) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8",
                         forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return data
    }

    /// 网页编码兜底：多为 UTF-8，部分中文站是 GBK
    private static func decodeHTML(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        let gb18030 = String.Encoding(rawValue: 0x80000632)
        return String(data: data, encoding: gb18030)
    }

    private static func firstMatch(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }

    /// HTML → 纯文本
    static func plainText(fromHTML html: String) -> String {
        var text = html
        for tag in ["script", "style", "noscript", "svg"] {
            text = text.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>",
                                             with: " ",
                                             options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</p>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    /// 把搜索结果格式化成给模型阅读的文本
    static func format(hits: [SearchHit], pages: [(title: String, url: String, text: String)]) -> String {
        var out = ""
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日"
        out += "搜索时间：\(formatter.string(from: Date()))\n"
        out += "结果来源：搜狗 / 360 / 百度 / Bing 多源融合，已去重\n\n"
        out += "【搜索结果】（共 \(hits.count) 条，来自实时联网检索，可直接引用）\n"
        for (index, hit) in hits.enumerated() {
            out += "\(index + 1). \(hit.title)\n"
            if !hit.publishedAt.isEmpty { out += "   发布时间：\(hit.publishedAt)\n" }
            out += "   \(hit.url)\n"
            if !hit.snippet.isEmpty { out += "   摘要：\(hit.snippet)\n" }
        }
        if !pages.isEmpty {
            out += "\n【网页正文摘录】\n"
            for page in pages {
                out += "\n—— \(page.title)（\(page.url)）——\n\(page.text)\n"
            }
        }
        return out
    }
}

private extension Character {
    var isCJK: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        return (0x4E00...0x9FFF).contains(scalar.value)
    }
}
