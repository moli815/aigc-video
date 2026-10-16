import XCTest
@testable import BossAI

// ============================================================================
// P0-52 失败路径测试（CI 必跑）——本轮测试盲区的教训：只测成功路径，导致
// "工具失败却谎报成功"反复发生。这里锁定失败路径的关键判断逻辑：
//   · ImageError.isRetryable：哪些失败该自动重试、哪些不该（重试无意义/有副作用）
//   · 会话失效识别：isSessionFailure 保证 401/停用/到期能触发强制登出
// ============================================================================

final class FailurePathTests: XCTestCase {

    // MARK: - 失败重试判断（isRetryable）

    func testGatewayErrorsAreRetryable() {
        // 5xx 网关/超时类 → 应重试（网络抖动可自动恢复）
        XCTAssertTrue(ImageService.ImageError.badResponse(500, "x").isRetryable)
        XCTAssertTrue(ImageService.ImageError.badResponse(502, "x").isRetryable)
        XCTAssertTrue(ImageService.ImageError.badResponse(504, "x").isRetryable)
        XCTAssertTrue(ImageService.ImageError.hosted(502, "UPSTREAM_ERROR", "x").isRetryable)
    }

    func testClientAndBusinessErrorsAreNotRetryable() {
        // 4xx 参数/额度/权限类 → 不重试（重试无意义，甚至可能重复扣费）
        XCTAssertFalse(ImageService.ImageError.badResponse(400, "x").isRetryable)
        XCTAssertFalse(ImageService.ImageError.badResponse(403, "x").isRetryable)
        XCTAssertFalse(ImageService.ImageError.hosted(400, "BAD_REQUEST", "x").isRetryable)
        XCTAssertFalse(ImageService.ImageError.missingKey.isRetryable)
        XCTAssertFalse(ImageService.ImageError.noImage.isRetryable)
        XCTAssertFalse(ImageService.ImageError.unsupportedEdit.isRetryable)
    }

    // MARK: - 会话失效识别（触发强制登出）

    func testSessionFailuresDetected() {
        XCTAssertTrue(ImageService.ImageError.hosted(401, "UNAUTHORIZED", "x").isSessionFailure)
        XCTAssertTrue(ImageService.ImageError.hosted(403, "ACCOUNT_SUSPENDED", "x").isSessionFailure)
        XCTAssertTrue(ImageService.ImageError.hosted(403, "MEMBERSHIP_EXPIRED", "x").isSessionFailure)
    }

    func testNonSessionErrorsAreNotSessionFailures() {
        XCTAssertFalse(ImageService.ImageError.hosted(502, "UPSTREAM_ERROR", "x").isSessionFailure)
        XCTAssertFalse(ImageService.ImageError.badResponse(500, "x").isSessionFailure)
        XCTAssertFalse(ImageService.ImageError.noImage.isSessionFailure)
    }
}
