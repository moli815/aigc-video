import XCTest
import Foundation
@testable import BossAI

final class AppPerformanceTests: XCTestCase {
    private func offlineService() -> ChatService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineChatProtocol.self]
        return ChatService(profile: ProviderCatalog.currentChat(), apiKeyProvider: { "test-fixture-key" },
                           session: URLSession(configuration: configuration))
    }
    func testLengthTerminationReportsIncompleteAndRetainsDeltas() async throws {
        OfflineChatProtocol.payload = Data("data: {\"choices\":[{\"delta\":{\"content\":\"ABC\"},\"finish_reason\":null}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n\ndata: [DONE]\n\n".utf8)
        let service = offlineService()
        var text = ""
        do {
            for try await event in service.stream(messages: [], enableTools: false) {
                if case .textDelta(let delta) = event { text += delta }
            }
            XCTFail("length不能判为完整回答")
        } catch let error as ChatService.ChatError {
            if case .incomplete = error {} else { XCTFail("错误种类不正确") }
        }
        XCTAssertEqual(text, "ABC")
    }
    func testEOFWithoutTerminalMarkerReportsIncomplete() async throws {
        OfflineChatProtocol.payload = Data("data: {\"choices\":[{\"delta\":{\"content\":\"ABC\"}}]}\n\n".utf8)
        let service = offlineService()
        do {
            for try await _ in service.stream(messages: [], enableTools: false) {}
            XCTFail("EOF缺完成标记不能判为成功")
        } catch let error as ChatService.ChatError {
            if case .incomplete = error {} else { XCTFail("错误种类不正确") }
        }
    }
    func testStopTerminationCompletes() async throws {
        OfflineChatProtocol.payload = Data("data: {\"choices\":[{\"delta\":{\"content\":\"ABC\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8)
        let service = offlineService()
        var completed = false
        for try await event in service.stream(messages: [], enableTools: false) {
            if case .finished = event { completed = true }
        }
        XCTAssertTrue(completed)
    }
    func testSkillsResourceIsInAppBundle() throws {
        XCTAssertEqual(try ExpertCapabilityCatalog.configuration.get().count, 11)
    }
    func testNativePermissionAndFileStructureGate() throws {
        let p = try ExpertCapabilityCatalog.profile("legal")
        XCTAssertFalse(ExpertSkillRuntime.permits("generate_image", profile: p))
        XCTAssertFalse(try ExpertSkillRuntime.validateDocument("只有标题", format: "word", profile: p).structurePassed)
    }
    @MainActor
    func testWordExportClockAndMemory() {
        let text = (0..<400).map { "| 项目\($0) | 100 | 用户提供 |" }.joined(separator: "\n")
        let markdown = "| 项目 | 数字 | 来源 |\n| --- | --- | --- |\n" + text
        var lastCount = 0
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            lastCount = DocumentBuilder.docx(title: "离线性能样本", markdown: markdown).count
        }
        XCTAssertGreaterThan(lastCount, 0)
    }
    @MainActor
    func testLongPDFClockAndMemory() {
        let markdown = String(repeating: "这是用于测试分页的数据，不是实际经营结论。", count: 2000)
        var lastCount = 0
        var failure: Error?
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            do { lastCount = try DocumentBuilder.pdf(title: "离线分页样本", markdown: markdown).count }
            catch { failure = error }
        }
        XCTAssertNil(failure)
        XCTAssertGreaterThan(lastCount, 0)
    }
    func testTwoHundredMarkdownMessagesParsingPerformance() {
        let sample = "## 样本\n- 第一条\n- 第二条\n\n**结论**与假设。"
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            for _ in 0..<200 { _ = MarkdownView.parse(sample) }
        }
    }
}

/// Intercepts only the explicit dummy test header, never normal App credentials.
private final class OfflineChatProtocol: URLProtocol {
    static var payload = Data()
    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: "Authorization") == "Bearer test-fixture-key"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
