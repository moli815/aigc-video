import XCTest
@testable import BossAI

// ============================================================================
// 10-23 回归：首包 watchdog / 活动事件 / 出图尺寸配置。
//
// 背景缺陷（真机截图）：模型只返回 tool_calls、没有正文 delta 时，45s 首包 watchdog
// 仍会在"生图执行阶段"触发，出现「图片已生成并落库，界面还弹 模型首包响应超时」。
// 修复要点：
//   1) ChatService 在首个合法 SSE 帧就发 .activity，不再等正文；
//   2) watchdog 被收窄到模型流阶段，流结束立即取消；
//   3) 产物已落库时后续说明失败降级为"部分成功"。
// 本文件锁定 1) 与尺寸配置，2)/3) 的行为边界由 PosterContextRegressionTests 的超时用例覆盖。
// ============================================================================

final class StreamActivityTests: XCTestCase {

    override func tearDown() {
        ActivityFixtureProtocol.payload = Data()
        super.tearDown()
    }

    /// 只有工具调用、没有任何正文时，也必须先收到 .activity——否则首包 watchdog 会误杀。
    func testToolOnlyStreamEmitsActivityBeforeToolCalls() async throws {
        ActivityFixtureProtocol.payload = Data(Self.toolOnlySSE.utf8)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ActivityFixtureProtocol.self]
        let chat = ChatService(profile: ChatProfile(id: "fixture",
                                                    displayName: "Fixture",
                                                    baseURL: "https://activity.invalid/v1",
                                                    model: "fixture",
                                                    memoryModel: "fixture",
                                                    searchStyle: .none),
                               apiKeyProvider: { "fixture" },
                               session: URLSession(configuration: config))

        var sawActivity = false
        var sawToolCalls = false
        for try await event in chat.stream(messages: [["role": "user", "content": "做一张名片"]],
                                           enableTools: true) {
            switch event {
            case .activity:
                XCTAssertFalse(sawToolCalls, "activity 必须早于 toolCalls")
                sawActivity = true
            case .toolCalls:
                XCTAssertTrue(sawActivity, "收到 toolCalls 前必须先收到 activity")
                sawToolCalls = true
            default:
                break
            }
        }
        XCTAssertTrue(sawActivity, "纯工具调用流必须发出 activity，否则首包 watchdog 会误判超时")
        XCTAssertTrue(sawToolCalls, "夹具应能解析出工具调用")
    }

    private static let toolOnlySSE = """
    data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"image_generate","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}

    data: [DONE]

    """
}

// MARK: - 桩

/// 只回一条 tool_calls delta + [DONE]，模拟"模型只调工具、不出正文"。
private final class ActivityFixtureProtocol: URLProtocol {
    nonisolated(unsafe) static var payload = Data()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "activity.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "text/event-stream"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !Self.payload.isEmpty { client?.urlProtocol(self, didLoad: Self.payload) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
