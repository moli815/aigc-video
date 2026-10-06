import XCTest
import SwiftData
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
    private func chat(_ responses: [Data], provider: String = "fixture") -> ChatService {
        ResearchChatProtocol.configure(responses)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ResearchChatProtocol.self]
        let profile = ChatProfile(id: provider, displayName: "Synthetic provider", baseURL: "https://research-fixture.invalid/v1", model: "replaceable-model", memoryModel: "replaceable-model", searchStyle: .none)
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
    func testMITNoticeIsIncludedInApplicationBundle() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("SwiftSoup 2.13.9")); XCTAssertTrue(text.contains("The MIT License"))
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
    private static var bodies: [[String: Any]] = []
    static var requests: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return bodies }
    static func configure(_ data: [Data]) { lock.lock(); defer { lock.unlock() }; responses = data; bodies = [] }
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
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
