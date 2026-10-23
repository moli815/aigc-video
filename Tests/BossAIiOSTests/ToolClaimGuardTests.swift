import XCTest
@testable import BossAI

// ============================================================================
// 10-24 回归：模型"说生成了但没生成"。
//
// 真实现象：用户说"换成科技风"，模型直接回复"已生成"，界面没有图；点重新生成才成功。
// 根因：所有"必须调用工具"的约束只在提示词里，运行时没有任何校验。
// 本文件锁定 ToolClaimGuard 的判定边界，防止误伤普通文本。
// ============================================================================

final class ToolClaimGuardTests: XCTestCase {

    // MARK: - 宣称检测

    func testDetectsCommonSuccessClaims() {
        XCTAssertTrue(ToolClaimGuard.claimsArtifact("已经为你生成了科技风版本"))
        XCTAssertTrue(ToolClaimGuard.claimsArtifact("已生成，请查看"))
        XCTAssertTrue(ToolClaimGuard.claimsArtifact("图片已保存到对话里"))
        XCTAssertTrue(ToolClaimGuard.claimsArtifact("名片已经改好了"))
        XCTAssertTrue(ToolClaimGuard.claimsArtifact("已按科技风重绘完成"))
    }

    func testDoesNotTreatFailureAsClaim() {
        XCTAssertFalse(ToolClaimGuard.claimsArtifact("生成失败了，请重试"))
        XCTAssertFalse(ToolClaimGuard.claimsArtifact("已经尝试生成但失败了"))
        XCTAssertFalse(ToolClaimGuard.claimsArtifact("我没有生成图片，因为缺少参考图"))
        XCTAssertFalse(ToolClaimGuard.claimsArtifact("如果需要，我可以继续帮你调整"))
        XCTAssertFalse(ToolClaimGuard.claimsArtifact(""))
    }

    // MARK: - 拦截条件

    func testInterceptsWhenImageRequestClaimWithoutArtifact() {
        XCTAssertTrue(ToolClaimGuard.shouldIntercept(
            userText: "把刚才那张换成科技风",
            reply: "已经为你生成了科技风版本",
            artifactPersisted: false,
            imageToolAttempted: false))
    }

    func testDoesNotInterceptWhenArtifactExists() {
        XCTAssertFalse(ToolClaimGuard.shouldIntercept(
            userText: "把刚才那张换成科技风",
            reply: "已经为你生成了科技风版本",
            artifactPersisted: true,
            imageToolAttempted: true))
    }

    /// 关键反例：非图片语境下说"已生成一段文案"不能被当成谎报。
    func testDoesNotInterceptForNonImageRequest() {
        XCTAssertFalse(ToolClaimGuard.shouldIntercept(
            userText: "帮我写一段产品介绍",
            reply: "已生成一段文案，供你参考",
            artifactPersisted: false,
            imageToolAttempted: false))
    }

    /// 工具尝试过但失败（artifact 仍为 false）也要拦。
    func testInterceptsWhenToolAttemptedButFailed() {
        XCTAssertTrue(ToolClaimGuard.shouldIntercept(
            userText: "换成科技风",
            reply: "已经改好了",
            artifactPersisted: false,
            imageToolAttempted: true))
    }

    func testImageIntentKeywords() {
        XCTAssertTrue(ToolClaimGuard.isImageRequest("换成科技风"))
        XCTAssertTrue(ToolClaimGuard.isImageRequest("帮我做一张名片"))
        XCTAssertTrue(ToolClaimGuard.isImageRequest("把这个 logo 去掉"))
        XCTAssertFalse(ToolClaimGuard.isImageRequest("帮我写一个周报"))
    }
}
