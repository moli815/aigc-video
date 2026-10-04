import Foundation

/// 联网搜索：App 自带的多引擎适配层，不依赖任何模型厂商的搜索能力。
/// 换任何对话模型都能继续联网。
///
/// 引擎优先级：
/// 1. 用户自填 API（Tavily / 博查）—— 最稳，质量最高，需自己申请免费额度
/// 2. Bing 中文（cn.bing.com）—— 免费、无需 Key、国内可直连，结果时效新
/// 3. 百度（www.baidu.com）—— 免费兜底
enum WebSearchEngine: String, CaseIterable, Identifiable {
    case auto, bing, baidu, tavily, bocha
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "自动（推荐）"
        case .bing: return "Bing 中文"
        case .baidu: return "百度"
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

    /// 联网搜索，返回结果列表；失败返回空数组
    static func search(query: String, count: Int = 6) async -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        let preferred = engine
        var order: [WebSearchEngine] = []
        switch preferred {
        case .auto:
            if !tavilyKey.isEmpty { order.append(.tavily) }
            if !bochaKey.isEmpty { order.append(.bocha) }
            order.append(.bing)
            order.append(.baidu)
        case .tavily, .bocha:
            order = [preferred] + [WebSearchEngine.bing, .baidu].filter { $0 != preferred }
        case .bing, .baidu:
            order = [preferred] + [WebSearchEngine.bing, .baidu].filter { $0 != preferred }
        }

        for item in order {
            var hits: [SearchHit] = []
            switch item {
            case .tavily: hits = await searchTavily(q, count: count)
            case .bocha: hits = await searchBocha(q, count: count)
            case .bing: hits = await searchBing(q, count: count)
            case .baidu: hits = await searchBaidu(q, count: count)
            case .auto: continue
            }
            if !hits.isEmpty { return Array(hits.prefix(count)) }
        }
        return []
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

    // MARK: - Tavily API

    private static func searchTavily(_ query: String, count: Int) async -> [SearchHit] {
        let key = tavilyKey
        guard !key.isEmpty else { return [] }
        guard let url = URL(string: "https://api.tavily.com/search") else { return [] }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 25
        let body: [String: Any] = [
            "api_key": key,
            "query": query,
            "max_results": count,
            "search_depth": "basic",
            "include_answer": false,
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
        guard !key.isEmpty else { return [] }
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

    // MARK: - Bing HTML

    private static func searchBing(_ query: String, count: Int) async -> [SearchHit] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://cn.bing.com/search?q=\(encoded)&setlang=zh-CN&ensearch=0")
        else { return [] }
        guard let data = await rawGet(url, timeout: 20), let html = decodeHTML(data) else { return [] }

        var hits: [SearchHit] = []
        let blocks = html.components(separatedBy: "class=\"b_algo\"")
        for block in blocks.dropFirst() {
            guard hits.count < count else { break }
            let chunk = String(block.prefix(6000))
            guard let href = firstMatch(chunk, pattern: "<h2[^>]*>\\s*<a[^>]+href=\"(https?://[^\"]+)\""),
                  let title = firstMatch(chunk, pattern: "<h2[^>]*>\\s*<a[^>]*>(.*?)</a>")
            else { continue }
            let snippet = firstMatch(chunk, pattern: "<p[^>]*>(.*?)</p>") ?? ""
            let cleanTitle = plainText(fromHTML: title)
            let cleanSnippet = plainText(fromHTML: snippet)
            guard !cleanTitle.isEmpty else { continue }
            hits.append(SearchHit(title: cleanTitle, url: href, snippet: cleanSnippet))
        }
        return hits
    }

    // MARK: - 百度 HTML

    private static func searchBaidu(_ query: String, count: Int) async -> [SearchHit] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.baidu.com/s?wd=\(encoded)&rn=\(count)")
        else { return [] }
        guard let data = await rawGet(url, timeout: 20), let html = decodeHTML(data) else { return [] }

        var hits: [SearchHit] = []
        let blocks = html.components(separatedBy: "class=\"result")
        for block in blocks.dropFirst() {
            guard hits.count < count else { break }
            let chunk = String(block.prefix(6000))
            guard let href = firstMatch(chunk, pattern: "<h3[^>]*>\\s*<a[^>]+href=\"([^\"]+)\""),
                  let title = firstMatch(chunk, pattern: "<h3[^>]*>\\s*<a[^>]*>(.*?)</a>")
            else { continue }
            let snippet = firstMatch(chunk, pattern: "class=\"content-right[^\"]*\"[^>]*>(.*?)</span>") ?? ""
            let cleanTitle = plainText(fromHTML: title)
            guard !cleanTitle.isEmpty else { continue }
            hits.append(SearchHit(title: cleanTitle,
                                  url: href.hasPrefix("http") ? href : "https://www.baidu.com\(href)",
                                  snippet: plainText(fromHTML: snippet)))
        }
        return hits
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
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
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
        out += "搜索时间：\(formatter.string(from: Date()))\n\n"
        out += "【搜索结果】\n"
        for (index, hit) in hits.enumerated() {
            out += "\(index + 1). \(hit.title)\n   \(hit.url)\n"
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
