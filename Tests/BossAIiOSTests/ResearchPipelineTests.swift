import XCTest
import SwiftData
import UIKit
@testable import BossAI

final class ResearchPipelineTests: XCTestCase {
    private func stream(_ delta: [String: Any], finish: String) throws -> Data {
        let frame: [String: Any] = ["choices": [["delta": delta, "finish_reason": finish]]]
        return Data(("data: " + String(decoding: try JSONSerialization.data(withJSONObject: frame), as: UTF8.self) + "\n\ndata: [DONE]\n\n").utf8)
    }
    private func toolFrame(query: String, duplicate: Bool = false) throws -> Data {
        let args = String(decoding: try JSONSerialization.data(withJSONObject: ["query": query]), as: UTF8.self)
        let calls = (0..<(duplicate ? 2 : 1)).map { i in
            ["index": i, "id": "tool-\(i)", "function": ["name": "web_search", "arguments": args]] as [String: Any]
        }
        return try stream(["content": "这是检索过程，不是最终回答", "reasoning_content": "private synthetic reasoning", "tool_calls": calls], finish: "tool_calls")
    }
    private func chat(_ responses: [Data], provider: String = "fixture", searchStyle: SearchStyle = .none, statuses: [Int] = []) -> ChatService {
        ResearchChatProtocol.configure(responses, statuses: statuses)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ResearchChatProtocol.self]
        let profile = ChatProfile(id: provider, displayName: "Synthetic provider", baseURL: "https://research-fixture.invalid/v1", model: "replaceable-model", memoryModel: "replaceable-model", searchStyle: searchStyle)
        return ChatService(profile: profile, apiKeyProvider: { "offline-research-fixture" }, session: URLSession(configuration: config))
    }
    @MainActor private func vm(chat: ChatService, search: FakeResearchSearch) throws -> ChatViewModel {
        let container = try ModelContainer(for: Conversation.self, Message.self, StoredFile.self, MemoryItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ChatViewModel(conversation: nil, expert: ExpertCatalog.general, modelContext: ModelContext(container), chatKey: { "offline-research-fixture" }, imageKey: { nil }, chatService: chat, researchService: search)
    }
    @MainActor private func finish(_ vm: ChatViewModel) async throws {
        for _ in 0..<500 { if !vm.isStreaming { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(vm.isStreaming, "native synthetic turn exceeded 5s")
        XCTAssertNil(vm.errorMessage)
    }
    @MainActor func testToolRoundNotesAndReasoningAreNotSavedAsAnswerAndDuplicateQueriesRunOnce() async throws {
        let search = FakeResearchSearch()
        let service = chat([try toolFrame(query: "iPhone battery", duplicate: true), try stream(["content": "最终结论（来源 1）"], finish: "stop")])
        let model = try vm(chat: service, search: search)
        model.inputText = "Compare handset"; model.send(); try await finish(model)
        XCTAssertEqual(model.sortedMessages.filter { $0.role == "assistant" }.map(\.text), ["最终结论（来源 1）"])
        let count = await search.searchCount; XCTAssertEqual(count, 1)
        let requests = ResearchChatProtocol.requests
        XCTAssertEqual(requests.count, 2)
        let history = try XCTUnwrap(requests.last?["messages"] as? [[String: Any]])
        let continuation = try XCTUnwrap(history.first { $0["tool_calls"] != nil })
        XCTAssertEqual(continuation["reasoning_content"] as? String, "private synthetic reasoning")
        let tools = history.filter { $0["role"] as? String == "tool" }
        XCTAssertEqual(tools.count, 2); XCTAssertEqual(tools.last?["tool_call_id"] as? String, "tool-1")
        XCTAssertTrue((tools.last?["content"] as? String ?? "").contains("复用"))
    }
    @MainActor func testForcedOnlineResearchRunsBeforeModelWithoutModelToolChoice() async throws {
        let search = FakeResearchSearch()
        let model = try vm(chat: chat([try stream(["content": "已核对本轮证据（来源 1）"], finish: "stop")]), search: search)
        model.researchMode = .online; model.inputText = "iPhone battery"; model.send(); try await finish(model)
        let count = await search.searchCount; XCTAssertEqual(count, 1)
        let messages = try XCTUnwrap(ResearchChatProtocol.requests.first?["messages"] as? [[String: Any]])
        XCTAssertTrue(messages.contains { ($0["content"] as? String ?? "").contains("App 提供的外部证据") })
        XCTAssertTrue(model.researchSummary?.contains("1 个主题") == true)
    }
    @MainActor func testLocalModeDoesNotExposeOrExecuteWebSearchEvenIfModelCallsIt() async throws {
        let search = FakeResearchSearch()
        let model = try vm(chat: chat([try toolFrame(query: "iPhone battery"), try stream(["content": "外部事实未核实"], finish: "stop")], provider: "qwen"), search: search)
        model.researchMode = .local; model.inputText = "今天价格"; model.send(); try await finish(model)
        let count = await search.searchCount; XCTAssertEqual(count, 0)
        let requests = ResearchChatProtocol.requests
        let tools = requests.first?["tools"] as? [[String: Any]] ?? []
        XCTAssertFalse(tools.contains { ($0["function"] as? [String: Any])?["name"] as? String == "web_search" })
        XCTAssertNil(requests.first?["enable_search"])
        let messages = requests.last?["messages"] as? [[String: Any]] ?? []
        XCTAssertTrue(messages.contains { ($0["content"] as? String ?? "").contains("联网搜索未执行") })
    }
    @MainActor func testSameResearchContractWorksAfterChangingProviderAndModel() async throws {
        for provider in ["deepseek", "kimi"] {
            let search = FakeResearchSearch()
            let model = try vm(chat: chat([try stream(["content": "统一证据流程（来源 1）"], finish: "stop")], provider: provider), search: search)
            model.researchMode = .online; model.inputText = "iPhone battery"; model.send(); try await finish(model)
            let count = await search.searchCount; XCTAssertEqual(count, 1)
            XCTAssertEqual(model.sortedMessages.last?.text, "统一证据流程（来源 1）")
            XCTAssertEqual(ResearchChatProtocol.requests.first?["model"] as? String, "replaceable-model")
            let thinking = ResearchChatProtocol.requests.first?["thinking"] as? [String: String]
            if provider == "deepseek" { XCTAssertEqual(thinking?["type"], "disabled") }
            else { XCTAssertNil(thinking) }
        }
    }
    @MainActor func testNativeSearchTakesPriorityWithoutDuplicateAppPreflight() async throws {
        let old = AppConfig.preferProviderSearch
        AppConfig.setPreferProviderSearch(true)
        defer { AppConfig.setPreferProviderSearch(old) }
        let search = FakeResearchSearch()
        let service = chat([try stream(["content": "已核对：https://evidence.invalid/spec"], finish: "stop")], provider: "qwen", searchStyle: .dashscopeParam)
        let model = try vm(chat: service, search: search)
        model.researchMode = .online; model.inputText = "今天价格"; model.send(); try await finish(model)
        let count = await search.searchCount
        XCTAssertEqual(count, 0)
        let request = try XCTUnwrap(ResearchChatProtocol.requests.first)
        XCTAssertEqual(request["enable_search"] as? Bool, true)
        let tools = request["tools"] as? [[String: Any]] ?? []
        XCTAssertFalse(tools.contains { ($0["function"] as? [String: Any])?["name"] as? String == "web_search" })
    }

    @MainActor func testNativeAnswerWithoutLinksFallsBackToAppEvidence() async throws {
        let old = AppConfig.preferProviderSearch
        AppConfig.setPreferProviderSearch(true)
        defer { AppConfig.setPreferProviderSearch(old) }
        let search = FakeResearchSearch()
        let service = chat([
            try stream(["content": "已经联网查到，但没给来源"], finish: "stop"),
            try stream(["content": "按补查证据回答（来源 1）"], finish: "stop"),
        ], provider: "qwen", searchStyle: .dashscopeParam)
        let model = try vm(chat: service, search: search)
        model.researchMode = .online; model.inputText = "今天价格"; model.send(); try await finish(model)
        let count = await search.searchCount
        XCTAssertEqual(count, 1)
        let requests = ResearchChatProtocol.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?["enable_search"] as? Bool, true)
        XCTAssertNil(requests.last?["enable_search"])
        let messages = requests.last?["messages"] as? [[String: Any]] ?? []
        XCTAssertTrue(messages.contains { ($0["content"] as? String ?? "").contains("App 提供的外部证据") })
        XCTAssertEqual(model.sortedMessages.last?.text, "按补查证据回答（来源 1）")
    }

    @MainActor func testRejectedNativeSearchRetriesWithAppToolAndEvidence() async throws {
        let old = AppConfig.preferProviderSearch
        AppConfig.setPreferProviderSearch(true)
        defer { AppConfig.setPreferProviderSearch(old) }
        let search = FakeResearchSearch()
        let service = chat([
            Data("unsupported native tool".utf8),
            try stream(["content": "暂时没有检索结果"], finish: "stop"),
            try stream(["content": "补查后回答（来源 1）"], finish: "stop"),
        ], provider: "qwen", searchStyle: .dashscopeParam, statuses: [400, 200, 200])
        let model = try vm(chat: service, search: search)
        model.researchMode = .online; model.inputText = "今天价格"; model.send(); try await finish(model)
        let count = await search.searchCount
        XCTAssertEqual(count, 1)
        let requests = ResearchChatProtocol.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.first?["enable_search"] as? Bool, true)
        XCTAssertNil(requests[1]["enable_search"])
        XCTAssertNil(requests[2]["enable_search"])
        XCTAssertEqual(model.sortedMessages.last?.text, "补查后回答（来源 1）")
    }

    func testDOMResultsDoNotStealOtherResultSnippetsAndSupportSingleQuotes() {
        let html = "<nav><a href='https://noise.example'>导航</a></nav><div class='result'><h3><a href='https://example.com/a'>第一项标题</a></h3><p>第一项摘要独有</p></div><div class='result'><h3><a href='https://example.com/b'>第二项标题</a></h3><p>第二项摘要独有</p></div>"
        let links = WebEvidenceExtractor.links(html: html)
        XCTAssertEqual(links.count, 2); XCTAssertEqual(links[0].href, "https://example.com/a")
        XCTAssertTrue(links[0].snippet.contains("第一项摘要独有")); XCTAssertFalse(links[0].snippet.contains("第二项摘要独有"))
    }
    func testDOMMainContentRetainsTablesAndRemovesNavigationAndScripts() {
        let article = String(repeating: "可核对的正文内容", count: 40)
        let html = "<header>导航污染标记</header><main>\(article)<table><tr><td>项目</td><td>数值</td></tr><tr><td>电池</td><td>测试值</td></tr></table></main><script>假数据污染标记</script><footer>版权污染标记</footer>"
        let content = WebEvidenceExtractor.contentHTML(html)
        XCTAssertTrue(content.contains("测试值")); XCTAssertTrue(content.contains("<table>"))
        XCTAssertFalse(content.contains("污染标记"))
    }
    func testDOMFallbackDoesNotInventSnippet() {
        let links = WebEvidenceExtractor.links(html: "<a href='https://example.com/a'>实际标题</a><p>其他项目摘要</p>")
        XCTAssertEqual(links.first?.snippet, "")
    }
    func testProviderWireParametersStayInAdapterAndDoNotLeak() {
        for id in ["deepseek", "kimi", "qwen", "custom-compatible"] {
            let profile = ChatProfile(id: id, displayName: id, baseURL: "https://fixture.invalid/v1", model: "custom", memoryModel: "custom", searchStyle: .none)
            var body: [String: Any] = ["model": "custom"]
            ModelRequestAdapter.apply(to: &body, profile: profile, purpose: .memory)
            XCTAssertEqual(body["model"] as? String, "custom")
            if id == "deepseek" { XCTAssertEqual(body["max_tokens"] as? Int, 2048) }
            else { XCTAssertNil(body["thinking"]); XCTAssertNil(body["max_tokens"]) }
        }
    }
    func test360ListContainerUsesOriginalURLAndKeepsItsOwnSnippet() {
        let html = "<li class='res-list'><h3><a href='https://www.so.com/link?m=x' data-mdurl='https://support.apple.com/spec'>iPhone 技术规格</a></h3><p>苹果官方摘要</p></li>"
        let hit = WebEvidenceExtractor.links(html: html).first
        XCTAssertEqual(hit?.href, "https://support.apple.com/spec")
        XCTAssertTrue(hit?.snippet.contains("苹果官方摘要") == true)
    }
    func testInvalidOriginalURLDoesNotReplaceActualLink() {
        let html = "<div class='result'><h3><a href='https://example.com/a' data-mdurl='javascript:bad'>实际标题</a></h3><p>有效摘要</p></div>"
        XCTAssertEqual(WebEvidenceExtractor.links(html: html).first?.href, "https://example.com/a")
    }
    func testKnownHTTPRelayUsesHTTPSWithoutChangingQueryOrRelaxingOtherHosts() {
        XCTAssertEqual(WebSearchService.secureSearchLink("http://www.baidu.com/link?url=a%2Fb&wd=x"), "https://www.baidu.com/link?url=a%2Fb&wd=x")
        XCTAssertEqual(WebSearchService.secureSearchLink("http://www.so.com:80/link?m=x"), "https://www.so.com/link?m=x")
        for url in ["http://www.baidu.com.evil.invalid/link?url=x", "http://example.com/article", "http://www.sogou.com/antispider", "https://www.baidu.com/link?url=x"] {
            XCTAssertEqual(WebSearchService.secureSearchLink(url), url)
        }
    }
    func testDOMEvidenceExtractionBenchmarkWithOneHundredResults() {
        let html = (0..<100).map { "<li class='res-list'><h3><a href='https://example.com/\($0)'>测试标题\($0)</a></h3><p>" + String(repeating: "同一条结果的完整摘要", count: 100) + "</p></li>" }.joined()
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            XCTAssertEqual(WebEvidenceExtractor.links(html: html).count, 100)
        }
    }
    func testCaptureRealNativeSearchDiagnosticsAndVerifyReturnedLinkContract() async throws {
        // Live diagnostic, not an assertion that the current facts or publication dates are correct.
        let originalEngine = WebSearchService.engine; WebSearchService.engine = .auto
        defer { WebSearchService.engine = originalEngine }
        var rows: [[String: Any]] = []
        for query in ["iPhone 官方 技术规格 site:apple.com", "华为 官方 手机 参数 site:huawei.com", "小米 官方 手机 参数 site:mi.com"] {
            let started = ProcessInfo.processInfo.systemUptime
            let hits = await WebSearchService.search(query: query, count: 6, recency: .any)
            let searchSeconds = ProcessInfo.processInfo.systemUptime - started
            XCTAssertLessThanOrEqual(hits.count, 6)
            for hit in hits { XCTAssertTrue(["https", "http"].contains(URL(string: hit.url)?.scheme ?? "")) }
            let pageStarted = ProcessInfo.processInfo.systemUptime
            var page = ""
            if let first = hits.first { page = await WebSearchService.fetchPageText(url: first.url, limit: 3500) }
            rows.append(["query": query, "search_seconds": searchSeconds, "first_page_seconds": ProcessInfo.processInfo.systemUptime - pageStarted,
                         "candidate_count": hits.count, "authority_candidates": hits.filter { EvidenceRanking.isAuthority($0.url) }.count,
                         "first_page_characters": page.count, "first_page_excerpt": String(page.prefix(180)),
                         "hits": hits.map { ["title": $0.title, "url": $0.url, "date_unverified": $0.publishedAt] }])
        }
        let report: [String: Any] = ["scope": "Actual App search and DOM code on iPad simulator; 3 single samples; facts and dates need human review", "samples": rows]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); attachment.name = "native-live-search-audit"; attachment.lifetime = .keepAlways; add(attachment)
        print("BOSSAI_NATIVE_SEARCH_AUDIT " + String(decoding: data, as: UTF8.self))
    }
    func testMITNoticeIsIncludedInApplicationBundle() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("SwiftSoup 2.13.9")); XCTAssertTrue(text.contains("The MIT License"))
    }
    func testWhiteExpertBannerLabelsHaveReadableContrastInEveryTheme() {
        for theme in AppTheme.allCases {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            XCTAssertTrue(UIColor(theme.accent).getRed(&red, green: &green, blue: &blue, alpha: &alpha))
            func linear(_ value: CGFloat) -> Double { let x = Double(value); return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
            let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
            XCTAssertGreaterThanOrEqual(1.05 / (luminance + 0.05), 4.5, theme.rawValue)
        }
    }
}
private actor FakeResearchSearch: ResearchSearching {
    var searchCount = 0
    func search(query: String, count: Int, recency: SearchRecency) async -> [SearchHit] {
        searchCount += 1
        return [SearchHit(title: "iPhone battery synthetic fixture", url: "https://evidence.invalid/spec", snippet: "Synthetic test evidence only", publishedAt: "2026-10-06")]
    }
    func page(url: String, limit: Int) async -> String { String(repeating: "iPhone battery synthetic data for deterministic tests. ", count: 10) }
}
private final class ResearchChatProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var responses: [Data] = []
    private static var statuses: [Int] = []
    private static var bodies: [[String: Any]] = []
    static var requests: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return bodies }
    static func configure(_ data: [Data], statuses: [Int] = []) { lock.lock(); defer { lock.unlock() }; responses = data; self.statuses = statuses; bodies = [] }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "research-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; bytes.append(contentsOf: buffer.prefix(n)) }
        }
        Self.lock.lock()
        Self.bodies.append((try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] ?? [:])
        let data = Self.responses.isEmpty ? Data("data: [DONE]\n\n".utf8) : Self.responses.removeFirst()
        let status = Self.statuses.isEmpty ? 200 : Self.statuses.removeFirst()
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": status == 200 ? "text/event-stream" : "text/plain"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
