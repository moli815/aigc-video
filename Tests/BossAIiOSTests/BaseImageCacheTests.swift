import XCTest
import UIKit
@testable import BossAI

// 底图缓存单测：命中 / 未命中 / 会话隔离 / taskId / 比例 / 过期 / 成功后清理
final class BaseImageCacheTests: XCTestCase {

    private var now: Date { Date(timeIntervalSince1970: 1_800_000_000) }

    override func setUp() {
        super.setUp()
        BaseImageCache.shared.resetForTesting()
    }

    private func img() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 900)).image { ctx in
            UIColor.darkGray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 1600, height: 900))
        }
    }

    private func seed(taskId: String = "t1", conversationId: String = "c1", aspect: String = "16:9") {
        BaseImageCache.shared.save(taskId: taskId,
                                   conversationId: conversationId,
                                   baseImage: img(),
                                   aspectRatio: aspect,
                                   extractedText: ["phone": "13800000000"],
                                   items: [TextItem(role: .contact, key: "phone", text: "13800000000")],
                                   layout: LayoutSpec(),
                                   canvas: CanvasSpec(size: CGSize(width: 1600, height: 900), expectedAspect: 16.0 / 9.0),
                                   now: now)
    }

    func testHitWhenAllMatch() {
        seed()
        XCTAssertEqual(BaseImageCache.shared.lookup(conversationId: "c1", taskId: "t1", aspectRatio: "16:9", now: now), .hit)
    }

    func testMissWhenEmpty() {
        XCTAssertEqual(BaseImageCache.shared.lookup(conversationId: "c1", taskId: "t1", aspectRatio: "16:9", now: now), .missNoEntry)
    }

    func testNoCrossConversationReuse() {
        seed(conversationId: "c1")
        XCTAssertEqual(BaseImageCache.shared.lookup(conversationId: "c2", taskId: "t1", aspectRatio: "16:9", now: now), .missConversation,
                       "别的会话绝不允许复用底图")
    }

    func testTaskIdMismatch() {
        seed(taskId: "t1")
        XCTAssertEqual(BaseImageCache.shared.lookup(conversationId: "c1", taskId: "t2", aspectRatio: "16:9", now: now), .missTaskId)
    }

    func testAspectMismatch() {
        seed(aspect: "16:9")
        XCTAssertEqual(BaseImageCache.shared.lookup(conversationId: "c1", taskId: "t1", aspectRatio: "3:4", now: now), .missAspect,
                       "比例变了必须重画，不能拉伸复用")
    }

    func testExpiry() {
        seed()
        let later = now.addingTimeInterval(BaseImageCache.shared.ttl + 1)
        XCTAssertEqual(BaseImageCache.shared.lookup(conversationId: "c1", taskId: "t1", aspectRatio: "16:9", now: later), .missExpired)
    }

    func testEvictAfterOverlaySuccess() {
        seed()
        BaseImageCache.shared.markOverlayDoneAndEvict()
        XCTAssertNil(BaseImageCache.shared.entry)
        XCTAssertEqual(BaseImageCache.shared.lookup(conversationId: "c1", taskId: "t1", aspectRatio: "16:9", now: now), .missNoEntry)
    }

    func testOverlayFailureKeepsEntry() {
        seed()
        // 模拟排版失败：不清缓存，重试应命中
        XCTAssertEqual(BaseImageCache.shared.lookup(conversationId: "c1", taskId: "t1", aspectRatio: "16:9", now: now), .hit)
        XCTAssertNotNil(BaseImageCache.shared.entry)
    }
}
