import XCTest
@testable import BossAI

// ============================================================================
// SeriesAndErrorContractTests —— 10-24 新增
//
// 覆盖这一轮"用户能看到什么"的契约，而不是内部实现：
//   1. 服务端错误信封解析：新格式 / 旧格式 / 畸形输入都不能崩、不能编造按钮；
//   2. 动作白名单：未知 action 必须被丢弃（服务端不能指挥客户端执行任意动作）；
//   3. 组图元信息：编码 → 落库（JSON 字符串）→ 解析 → 状态行，数字必须一致；
//   4. 多图持久化：第 1 张进 imageData，其余进 extraImagesJSON，解析后顺序不变。
//
// 这些用例不依赖网络/数据库，跑得快，适合作为回归门禁。
// ============================================================================

final class SeriesAndErrorContractTests: XCTestCase {

    // MARK: - 错误信封

    func testEnvelopeParsesNewFormat() {
        let json: [String: Any] = [
            "ok": false,
            "error": "QUOTA_CHECK_UNAVAILABLE",
            "message": "暂时无法确认额度，请稍后重试。",
            "actions": ["retry", "view_quota"],
            "requestId": "req_abc123",
            "errorDetail": ["category": "billing", "retryable": true, "stage": "quota"],
            "partial": false,
        ]
        let env = APIErrorEnvelope.parse(status: 503, json: json)
        XCTAssertNotNil(env)
        XCTAssertEqual(env?.code, "QUOTA_CHECK_UNAVAILABLE")
        XCTAssertEqual(env?.actions, ["retry", "view_quota"])
        XCTAssertEqual(env?.requestId, "req_abc123")
        XCTAssertTrue(env?.retryable ?? false)
        XCTAssertEqual(env?.category, "billing")
    }

    /// 旧服务端只有 { error, message }：必须仍能解析出文案，且不伪造动作
    func testEnvelopeParsesLegacyFormat() {
        let env = APIErrorEnvelope.parse(status: 400, json: ["error": "BAD_REQUEST", "message": "缺少描述"])
        XCTAssertEqual(env?.message, "缺少描述")
        XCTAssertEqual(env?.actions.count, 0)
        XCTAssertFalse(env?.retryable ?? true)
        XCTAssertFalse(env?.isSessionFailure ?? true)
    }

    /// 空对象不能解析成"有一个没有文案、没有动作的错误卡片"
    func testEnvelopeRejectsEmptyPayload() {
        XCTAssertNil(APIErrorEnvelope.parse(status: 500, json: [:]))
    }

    /// 401 / 停用 / 到期必须识别为会话失效（否则账号到期了不登出）
    func testSessionFailureDetection() {
        XCTAssertTrue(APIErrorEnvelope(status: 401, code: "UNAUTHORIZED", message: "x").isSessionFailure)
        XCTAssertTrue(APIErrorEnvelope(status: 403, code: "ACCOUNT_SUSPENDED", message: "x").isSessionFailure)
        XCTAssertTrue(APIErrorEnvelope(status: 403, code: "MEMBERSHIP_EXPIRED", message: "x").isSessionFailure)
        XCTAssertFalse(APIErrorEnvelope(status: 429, code: "POOL_EXHAUSTED", message: "x").isSessionFailure)
    }

    /// 组图失败的序号要能从信封里读出来（用于"重试剩余"）
    func testFailedIndicesParsing() {
        let env = APIErrorEnvelope.parse(status: 200, json: [
            "error": "SERIES_PARTIAL",
            "message": "已完成 3/4",
            "failedIndices": [4],
            "partial": true,
        ])
        XCTAssertEqual(env?.failedIndices, [4])
        XCTAssertTrue(env?.partial ?? false)
    }

    /// 对话类错误也要能带信封（否则对话失败只显示一句话，没有可点的下一步）
    func testChatErrorCarriesEnvelope() {
        let env = APIErrorEnvelope(status: 429, code: "POOL_EXHAUSTED",
                                   message: "本月额度已用完", actions: ["renew"], retryable: false)
        let err = ChatService.ChatError.envelope(env)
        XCTAssertEqual(err.envelope?.actions, ["renew"])
        XCTAssertEqual(err.errorDescription, "本月额度已用完")
        XCTAssertFalse(err.isSessionFailure)
    }

    // MARK: - 动作白名单

    func testActionWhitelistDropsUnknown() {
        let actions = FriendlyError.actions(from: ["retry", "delete_everything", "renew", "retry"])
        XCTAssertEqual(actions.map { $0.id }, ["retry", "renew"], "未知动作必须丢弃，重复动作必须去重")
        XCTAssertEqual(actions.first?.title, "再试一次")
    }

    func testActionWhitelistEmptyInput() {
        XCTAssertTrue(FriendlyError.actions(from: []).isEmpty)
        XCTAssertTrue(FriendlyError.actions(from: nil).isEmpty)
    }

    // MARK: - 组图元信息

    func testSeriesMetaRoundTrip() throws {
        var meta = SeriesMeta()
        meta.requestId = "req_1"
        meta.requested = 4
        meta.succeeded = 3
        meta.failedIndices = [4]
        meta.downloadFailedIndices = [2]
        meta.pricedCny = 1.35
        meta.committedCny = 0.9
        meta.pendingCostCount = 1
        meta.partial = true
        meta.size = "1.5K"

        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(SeriesMeta.self, from: data)

        XCTAssertEqual(decoded.requested, 4)
        XCTAssertEqual(decoded.succeeded, 3)
        XCTAssertEqual(decoded.failedIndices, [4])
        XCTAssertEqual(decoded.downloadFailedIndices, [2])
        XCTAssertEqual(decoded.committedCny, 0.9, accuracy: 0.0001)
        XCTAssertTrue(decoded.canRetryFailed)
    }

    func testSeriesMetaStatusLineReportsRealNumbers() {
        var meta = SeriesMeta()
        meta.requested = 4
        meta.succeeded = 3
        meta.failedIndices = [4]
        XCTAssertEqual(meta.statusLine, "已完成 3/4 张 · 失败 #4")

        meta.failedIndices = []
        XCTAssertEqual(meta.statusLine, "已完成 3/4 张")

        // 没有请求数时不编造"0/0"
        XCTAssertEqual(SeriesMeta().statusLine, "")
    }

    // MARK: - 多图持久化

    func testMessageStoresAllImagesInOrder() {
        let first = Data([0xFF, 0xD8, 0x01])
        let second = Data([0x89, 0x50, 0x02])
        let third = Data([0x47, 0x49, 0x03])

        let msg = Message(role: "assistant", text: "组图", imageData: first)
        msg.extraImagesJSON = try? JSONEncoder().encode([second, third])
        msg.seriesMetaJSON = (try? JSONEncoder().encode(SeriesMeta())) .flatMap { String(data: $0, encoding: .utf8) } ?? ""

        XCTAssertEqual(msg.allImages.count, 3)
        XCTAssertEqual(msg.allImages[0], first)
        XCTAssertEqual(msg.allImages[1], second)
        XCTAssertEqual(msg.allImages[2], third)
        XCTAssertNotNil(msg.seriesMeta)
    }

    /// 旧消息（没有组图字段）不能被解析成"有 0 张图的组图消息"
    func testLegacyMessageHasNoSeriesMeta() {
        let msg = Message(role: "assistant", text: "普通回复", imageData: Data([0x01]))
        XCTAssertNil(msg.seriesMeta)
        XCTAssertTrue(msg.extraImages.isEmpty)
        XCTAssertEqual(msg.allImages.count, 1)
    }
}
