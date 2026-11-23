import XCTest
@testable import BossAI

// ============================================================================
// ChatErrorDisplayTests —— 11-03 新增
//
// 来源是一张真机截图：图片/对话任务失败后，聊天气泡下方出现
//
//   输出尚未完成（{ code = "UPSTREAM_ERROR"; message = "\U8fd9\U6b21..." }）。
//
// 这是把服务端流内错误帧整个 `String(describing:)` 之后直接上屏的结果 ——
// 客户看到的是内部错误码 + unicode 转义，既读不懂也无法行动。
//
// 这组用例锁的是「什么可以上屏」这条边界，而不是具体实现：
//   1. 流内错误帧 → 只允许取服务端中文 message，或按 code 映射的固定文案；
//   2. 原始帧、错误码、HTTP 报文一律不得出现在用户可见文案里；
//   3. 排障信息必须留在 diagnostic 里（能查，但看不见）。
// ============================================================================

final class ChatErrorDisplayTests: XCTestCase {

    // MARK: - 流内错误帧解析

    func testStreamFailureUsesServerMessage() throws {
        let env = try XCTUnwrap(APIErrorEnvelope.streamFailure([
            "code": "UPSTREAM_ERROR",
            "message": "这次回复没有接收完整，请再试一次。",
        ]))
        XCTAssertEqual(env.message, "这次回复没有接收完整，请再试一次。")
        XCTAssertEqual(env.code, "UPSTREAM_ERROR", "错误码只用于判断，保留但不上屏")
        XCTAssertTrue(env.actions.contains("retry"), "流断掉必须给一次重试入口")
    }

    func testStreamFailureMapsCodeWhenServerGivesNoCopy() throws {
        let env = try XCTUnwrap(APIErrorEnvelope.streamFailure(["code": "UPSTREAM_ERROR"]))
        XCTAssertEqual(env.message, "模型服务暂时不可用，请稍后重试")
        XCTAssertFalse(env.message.contains("UPSTREAM"), "错误码不能出现在文案里")
    }

    /// 旧服务端形态：error 直接就是错误码字符串
    func testStreamFailureAcceptsLegacyStringFrame() throws {
        let env = try XCTUnwrap(APIErrorEnvelope.streamFailure("UPSTREAM_TIMEOUT"))
        XCTAssertEqual(env.message, "模型服务暂时不可用，请稍后重试")
    }

    /// 空帧不编文案：交给调用方兜底，而不是拼一个"（{ }）"出来
    func testStreamFailureReturnsNilForEmptyFrame() {
        XCTAssertNil(APIErrorEnvelope.streamFailure([:]))
        XCTAssertNil(APIErrorEnvelope.streamFailure(""))
    }

    // MARK: - 文案出口

    func testIncompleteNeverLeaksDiagnostic() {
        // 模拟历史上真正发生的事：内部原因里塞了原始帧
        let raw = #"{ code = "UPSTREAM_ERROR"; message = "\U8fd9\U6b21"; }"#
        let error = ChatService.ChatError.incomplete(raw)

        let shown = error.errorDescription ?? ""
        XCTAssertEqual(shown, "这次回复没有接收完整，请重试一次。")
        XCTAssertFalse(shown.contains("UPSTREAM"), "错误码泄漏到用户文案")
        XCTAssertFalse(shown.contains("\\U"), "unicode 转义泄漏到用户文案")
        XCTAssertFalse(shown.contains("{"), "原始报文泄漏到用户文案")

        XCTAssertTrue(error.diagnostic.contains("UPSTREAM"), "排障标签必须保留，只是不进 UI")
    }

    func testFriendlyErrorPrefersUserFacingMessage() {
        let error = ChatService.ChatError.incomplete("content_filter")
        let shown = FriendlyError.message(for: error, scene: .chat)
        XCTAssertEqual(shown, "这次回复没有接收完整，请重试一次。")
        XCTAssertFalse(shown.contains("content_filter"))
    }

    /// 手动 Key 模式：状态码可以给（用户据此判断 Key 是否有效），报文不行
    func testBadResponseHidesRawBody() {
        let error = ChatService.ChatError.badResponse(401, #"{"error":{"message":"invalid api key"}}"#)
        let shown = error.errorDescription ?? ""
        XCTAssertTrue(shown.contains("401"))
        XCTAssertFalse(shown.contains("{"), "上游原始报文不能上屏")
        XCTAssertFalse(shown.contains("invalid api key"), "英文上游文案不能上屏")
    }

    /// 信封型错误：服务端文案是权威，原样展示，不再二次包装
    func testEnvelopeMessageIsShownVerbatim() {
        let env = APIErrorEnvelope(status: 502, code: "UPSTREAM_ERROR",
                                   message: "服务暂时繁忙，请稍等片刻再试", actions: ["retry"])
        let error = ChatService.ChatError.envelope(env)
        XCTAssertEqual(FriendlyError.message(for: error, scene: .chat), "服务暂时繁忙，请稍等片刻再试")
        XCTAssertEqual(error.envelope?.actions, ["retry"])
    }

    /// 错误码表是单一事实源：登录/额度/上游三条路径必须给同一句话
    func testCodeCopyIsSharedAcrossPaths() {
        XCTAssertEqual(HostedError.server(code: "UPSTREAM_ERROR", status: 502, message: nil).userFacingMessage,
                       FriendlyError.copy(forCode: "UPSTREAM_ERROR"))
        XCTAssertEqual(HostedError.server(code: "ACCOUNT_SUSPENDED", status: 403, message: nil).userFacingMessage,
                       "该账号已停用，请联系客服")
        // 非服务时段要带服务端给的具体时段，不能被通用表覆盖
        XCTAssertEqual(HostedError.server(code: "OUT_OF_SERVICE_HOURS", status: 403, message: "服务时间 9:00-18:00").userFacingMessage,
                       "服务时间 9:00-18:00")
    }
}
