import XCTest
@testable import BossAI

// ============================================================================
// P0-45 工具调用归一化回归测试 —— 客户截图 bug 的永久防线。
// 背景（2026-10-16 实测抓包）：千问流式分片**每一片都携带 "id":""（空串）**，
//   旧解析 `if let id = ...` 把空串当有效值覆盖首片真实 ID → 终检失败 → 整条回复被丢弃
//   （用户看到"未收到有效回复（工具调用缺少ID或超过安全上限）"）。
// 本测试锁定三个不变量（对应最终修复的实现契约）：
//   ① 空串 id 绝不覆盖首片真实 ID（跨厂商分片格式兼容）；
//   ② 畸形调用只丢弃自身，只要有正文就正常完成（借鉴 DeepSeek Harness 的"管道归一化"原则，
//      工具异常绝不牵连整轮对话）；
//   ③ 既无正文也无有效调用的真正空回复，仍然报错（防呆保留）。
// ============================================================================

final class ToolCallNormalizationTests: XCTestCase {

    private func offlineService() -> ChatService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ToolCallOfflineProtocol.self]
        return ChatService(profile: ProviderCatalog.currentChat(),
                           apiKeyProvider: { "test-fixture-key" },
                           session: URLSession(configuration: configuration))
    }

    /// ① 千问实测格式：首片带真实 id+name，后续所有分片 id 为空串
    /// → 最终调用的 id / name / arguments 必须完整正确（不因空串覆盖而丢失）
    func testQwenEmptyStringIdDoesNotOverwrite() async throws {
        ToolCallOfflineProtocol.payload = Data("""
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_abc123","type":"function","function":{"name":"generate_image","arguments":""}}]},"finish_reason":null}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"","type":"function","function":{"arguments":"{\\"prompt\\":\\"消防海报\\"}"}}]},"finish_reason":null}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"","type":"function","function":{"arguments":""}}]},"finish_reason":"tool_calls"}]}

        data: [DONE]

        """.utf8)
        let service = offlineService()
        var calls: [ChatService.ToolCall] = []
        for try await event in service.stream(messages: [], enableTools: false) {
            if case .toolCalls(let received, _) = event { calls = received }
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.id, "call_abc123",
                       "空串 id 不得覆盖首片真实 ID——这是千问格式的回归锚点（曾导致整条回复丢失）")
        XCTAssertEqual(calls.first?.name, "generate_image")
        XCTAssertTrue(calls.first?.arguments.contains("消防海报") ?? false, "arguments 分片应完整累加")
    }

    /// ② 畸形调用（整个调用缺 id）+ 有正文 → 丢弃畸形调用、正常完成；绝不抛错牵连回复
    func testMalformedCallDroppedNotFatal() async throws {
        ToolCallOfflineProtocol.payload = Data("""
        data: {"choices":[{"delta":{"content":"好的，我来处理。"},"finish_reason":null}]}

        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"type":"function","function":{"arguments":"{}"}}]},"finish_reason":"tool_calls"}]}

        data: [DONE]

        """.utf8)
        let service = offlineService()
        var finished = false
        var text = ""
        for try await event in service.stream(messages: [], enableTools: false) {
            switch event {
            case .textDelta(let delta): text += delta
            case .finished: finished = true
            case .toolCalls: XCTFail("无 id 的畸形调用应被丢弃，不应产生 toolCalls 事件")
            default: break
            }
        }
        XCTAssertTrue(finished, "有正文时必须正常完成（管道归一化），而不是抛错丢弃整条回复")
        XCTAssertEqual(text, "好的，我来处理。")
    }

    /// ③ 真正的空回复（无正文且无有效调用）仍应报错——防呆不能被归一化削弱
    func testEmptyReplyStillFails() async throws {
        ToolCallOfflineProtocol.payload = Data("""
        data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

        data: [DONE]

        """.utf8)
        let service = offlineService()
        do {
            for try await _ in service.stream(messages: [], enableTools: false) {}
            XCTFail("空回复必须报错")
        } catch let error as ChatService.ChatError {
            guard case .incomplete(let reason) = error else {
                XCTFail("错误类型应为 incomplete，实际：\(error)"); return
            }
            XCTAssertFalse(reason.isEmpty)
        }
    }
}

/// 离线 URLProtocol：拦截 URLSession 请求，直接回放预置的 SSE 数据。
/// （独立的私有副本——与 AppPerformanceTests 内的同名设施同款模式，
///   避免跨文件依赖 private 类型。）
private final class ToolCallOfflineProtocol: URLProtocol {
    static var payload = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url ?? URL(string: "https://offline.test")!,
                                       statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
