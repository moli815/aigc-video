import XCTest
import SwiftData
@testable import BossAI

final class StreamRegressionTests: XCTestCase {
    private func service(_ payload: String, type: String = "text/event-stream") -> ChatService {
        StreamFixtureProtocol.payload = Data(payload.utf8)
        StreamFixtureProtocol.contentType = type
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamFixtureProtocol.self]
        let profile = ChatProfile(id: "fixture", displayName: "Fixture", baseURL: "https://fixture.invalid/v1",
                                  model: "fixture", memoryModel: "fixture", searchStyle: .none)
        return ChatService(profile: profile, apiKeyProvider: { "stream-regression-fixture" }, session: URLSession(configuration: config))
    }
    private let delta = "data: {\"choices\":[{\"delta\":{\"content\":\"最新手机😀\"}}]}\n\n"
    private let stop = "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}"
    func testActualURLSessionBytesPreserveBlankLinesAndUnicode() async throws {
        let chat = service(delta + stop + "\n\ndata: [DONE]\n\n")
        var text = ""; var finished = false
        for try await event in chat.stream(messages: [], enableTools: false) {
            if case .textDelta(let part) = event { text += part }
            if case .finished = event { finished = true }
        }
        XCTAssertEqual(text, "最新手机😀"); XCTAssertTrue(finished)
    }
    func testFinalStopWithoutDelimiterCompletes() async throws {
        let chat = service(delta + stop)
        var finished = false
        for try await event in chat.stream(messages: [], enableTools: false) { if case .finished = event { finished = true } }
        XCTAssertTrue(finished)
    }
    func testDisconnectKeepsReceivedTextAndFails() async throws {
        let chat = service(delta); var text = ""
        do {
            for try await event in chat.stream(messages: [], enableTools: false) { if case .textDelta(let part) = event { text += part } }
            XCTFail("Disconnect must not succeed")
        } catch { XCTAssertTrue(error.localizedDescription.contains("缺少完成标记")) }
        XCTAssertEqual(text, "最新手机😀")
    }
    func testHTTP200HTMLIsNotAcceptedAsAIStream() async throws {
        let chat = service("<html>proxy page</html>", type: "text/html")
        do { for try await _ in chat.stream(messages: [], enableTools: false) {}; XCTFail("HTML must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("未返回事件流")) }
    }
    func testToolCallsWithoutFinalBlankLine() async throws {
        let chunk = #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_fixture","function":{"name":"web_search","arguments":"{\"query\":\"fixture\"}"}}]},"finish_reason":"tool_calls"}]}"#
        let chat = service("data: " + chunk); var count = 0
        for try await event in chat.stream(messages: [], enableTools: false) {
            if case .toolCalls(let calls, _) = event { count = calls.count; XCTAssertEqual(calls.first?.name, "web_search") }
        }
        XCTAssertEqual(count, 1)
    }
    func testDONEWithNoContentIsReportedAsEmptyReply() async throws {
        let chat = service("data: [DONE]\n\n")
        do { for try await _ in chat.stream(messages: [], enableTools: false) {}; XCTFail("Empty reply must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("空回复")) }
    }
    @MainActor
    func testRetryUsesOneUserMessageAndReplacesFailedAssistant() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Conversation.self, Message.self, StoredFile.self, MemoryItem.self, configurations: config)
        let context = ModelContext(container)
        let chat = service(delta)
        let vm = ChatViewModel(conversation: nil, expert: Expert.general, modelContext: context,
                               chatKey: { "stream-regression-fixture" }, imageKey: { nil }, chatService: chat)
        vm.inputText = "Synthetic question"; vm.send()
        for _ in 0..<200 { if !vm.isStreaming { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(vm.canRetryReply)
        XCTAssertEqual(vm.sortedMessages.filter { $0.role == "user" }.count, 1)
        StreamFixtureProtocol.payload = Data((delta + stop + "\n\ndata: [DONE]\n\n").utf8)
        vm.retryReply()
        for _ in 0..<200 { if !vm.isStreaming { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(vm.isStreaming); XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.sortedMessages.filter { $0.role == "user" }.count, 1)
        XCTAssertEqual(vm.sortedMessages.filter { $0.role == "assistant" }.count, 1)
        XCTAssertEqual(vm.sortedMessages.last?.text, "最新手机😀")
    }
}

/// One-byte callbacks deliberately cut UTF-8 scalars and CR/LF across callbacks.
private final class StreamFixtureProtocol: URLProtocol {
    static var payload = Data()
    static var contentType = "text/event-stream"
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": Self.contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for byte in Self.payload { client?.urlProtocol(self, didLoad: Data([byte])) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
