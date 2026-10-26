import XCTest
import UIKit
@testable import BossAI

// ============================================================================
// 底图缓存（BaseImageCache）10-25 并发版：
// 命中 / 未命中 / 会话隔离 / 任务隔离 / 比例 / 过期 / 并发不覆盖 / 成功清理 / 失败保留
//
// 为什么有并发用例：旧实现是单条全局 entry，只有在"全局只跑一个图片任务"时才成立。
// 现在键 = conversationId + taskId + NSLock，本文件把这两条性质都钉死。
// ============================================================================
final class BaseImageCacheTests: XCTestCase {

    private var now: Date { Date(timeIntervalSince1970: 1_800_000_000) }

    override func setUp() {
        super.setUp()
        BaseImageCache.shared.resetForTesting()
    }

    override func tearDown() {
        BaseImageCache.shared.resetForTesting()
        super.tearDown()
    }

    private func img(shade: CGFloat = 0.5) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 900)).image { ctx in
            UIColor(white: shade, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1600, height: 900))
        }
    }

    private func seed(taskId: String = "t1", conversationId: String = "c1", aspect: String = "16:9",
                      now stamp: Date? = nil) {
        BaseImageCache.shared.save(taskId: taskId,
                                   conversationId: conversationId,
                                   baseImage: img(),
                                   aspectRatio: aspect,
                                   now: stamp ?? now)
    }

    // MARK: - 命中/未命中

    func testHitSameConversationSameTask() {
        seed()
        XCTAssertEqual(BaseImageCache.shared.lookup(conversationId: "c1", taskId: "t1", aspectRatio: "16:9", now: now), .hit)
        XCTAssertNotNil(BaseImageCache.shared.entry(conversationId: "c1", taskId: "t1", now: now))
    }

    func testMissWhenEmpty() {
        XCTAssertEqual(BaseImageCache.shared.lookup(conversationId: "c1", taskId: "t1", aspectRatio: "16:9", now: now),
                       .missNoEntry)
    }

    func testNoCrossConversationReuse() {
        seed(conversationId: "c1")
        XCTAssertEqual(BaseImageCache.shared.lookup(conversationId: "c2", taskId: "t1", aspectRatio: "16:9", now: now),
                       .missConversation, "别的会话绝不允许复用底图")
    }

    func testTaskIdMismatch() {
        seed(taskId: "t1")
        XCTAssertEqual(BaseImageCache.shared.lookup(conversationId: "c1", taskId: "t2", aspectRatio: "16:9", now: now),
                       .missTaskId)
    }

    func testAspectMismatch() {
        seed(aspect: "16:9")
        XCTAssertEqual(BaseImageCache.shared.lookup(conversationId: "c1", taskId: "t1", aspectRatio: "3:4", now: now),
                       .missAspect, "比例变了必须重画，不能拉伸复用")
    }

    func testExpiry() {
        seed()
        let later = now.addingTimeInterval(BaseImageCache.shared.ttl + 1)
        XCTAssertEqual(BaseImageCache.shared.lookup(conversationId: "c1", taskId: "t1", aspectRatio: "16:9", now: later),
                       .missExpired)
        XCTAssertEqual(BaseImageCache.shared.count, 0, "过期条目必须被淘汰，不能一直占内存")
    }

    // MARK: - 并发不互相覆盖

    func testTwoConcurrentTasksDoNotOverwrite() {
        // 同一会话的两个任务（例如主图 + 补画）同时在手
        seed(taskId: "tA", conversationId: "c1")
        seed(taskId: "tB", conversationId: "c1")
        XCTAssertEqual(BaseImageCache.shared.count, 2, "两个任务的底图必须同时存在")
        XCTAssertEqual(BaseImageCache.shared.lookup(conversationId: "c1", taskId: "tA", aspectRatio: "16:9", now: now), .hit)
        XCTAssertEqual(BaseImageCache.shared.lookup(conversationId: "c1", taskId: "tB", aspectRatio: "16:9", now: now), .hit)
    }

    func testTwoConversationsKeepTheirOwnImages() {
        seed(taskId: "tA", conversationId: "c1")
        seed(taskId: "tB", conversationId: "c2")
        XCTAssertEqual(BaseImageCache.shared.count, 2)
        XCTAssertEqual(BaseImageCache.shared.lookup(conversationId: "c1", taskId: "tA", aspectRatio: "16:9", now: now), .hit)
        XCTAssertEqual(BaseImageCache.shared.lookup(conversationId: "c2", taskId: "tB", aspectRatio: "16:9", now: now), .hit)
        // 交叉不命中：A 的会话不能用 B 的任务键
        XCTAssertEqual(BaseImageCache.shared.lookup(conversationId: "c1", taskId: "tB", aspectRatio: "16:9", now: now),
                       .missTaskId)
    }

    /// 真实多线程写入：锁缺失时这里会丢写或脏读
    func testConcurrentWritesFromMultipleThreadsAreSafe() {
        let total = 40
        DispatchQueue.concurrentPerform(iterations: total) { index in
            // maxEntries 会淘汰最老的，所以只断言：不崩、条目数不超上限
            BaseImageCache.shared.save(taskId: "task-\(index)",
                                       conversationId: "conv-\(index % 3)",
                                       baseImage: self.img(shade: CGFloat(index % 10) / 10),
                                       aspectRatio: "16:9",
                                       now: now)
            _ = BaseImageCache.shared.lookup(conversationId: "conv-\(index % 3)",
                                             taskId: "task-\(index)", aspectRatio: "16:9")
        }
        XCTAssertGreaterThan(BaseImageCache.shared.count, 0)
        XCTAssertLessThanOrEqual(BaseImageCache.shared.count, BaseImageCache.shared.maxEntries,
                                 "并发写入后条目数必须受上限约束")
    }

    func testCapacityLimitEvictsOldest() {
        for index in 0..<(BaseImageCache.shared.maxEntries + 2) {
            seed(taskId: "t\(index)", conversationId: "c1",
                 now: now.addingTimeInterval(Double(index)))
        }
        XCTAssertEqual(BaseImageCache.shared.count, BaseImageCache.shared.maxEntries, "容量上限必须生效")
        XCTAssertNil(BaseImageCache.shared.entry(conversationId: "c1", taskId: "t0",
                                                 now: now.addingTimeInterval(10)),
                     "最老的必须被淘汰")
    }

    // MARK: - 清理语义

    func testOverlaySuccessKeepsBaseForCopyOnlyEdits() {
        seed(taskId: "tA", conversationId: "c1")
        seed(taskId: "tB", conversationId: "c1")
        BaseImageCache.shared.markOverlayDone(conversationId: "c1", taskId: "tA")
        XCTAssertEqual(BaseImageCache.shared.entry(conversationId: "c1", taskId: "tA", now: now)?.overlayDone, true)
        XCTAssertEqual(BaseImageCache.shared.lookup(conversationId: "c1", taskId: "tA", aspectRatio: "16:9", now: now), .hit,
                       "成功底图必须可复用，改文字不应重新生成")
        XCTAssertNotNil(BaseImageCache.shared.entry(conversationId: "c1", taskId: "tB", now: now),
                        "另一个并发任务的底图不许被误清")
    }

    /// 排版失败 → 底图保留 → 下一次复用同一张底图
    func testOverlayFailureKeepsEntryForReuse() {
        seed(taskId: "t1", conversationId: "c1")
        BaseImageCache.shared.retainAfterOverlayFailure(conversationId: "c1", taskId: "t1")
        XCTAssertNotNil(BaseImageCache.shared.entry(conversationId: "c1", taskId: "t1", now: now),
                        "排版失败不得清掉底图，否则重试仍要重画")
        XCTAssertEqual(BaseImageCache.shared.lookup(conversationId: "c1", taskId: "t1", aspectRatio: "16:9", now: now),
                       .hit)
    }

    func testEvictConversationClearsOnlyItsEntries() {
        seed(taskId: "tA", conversationId: "c1")
        seed(taskId: "tB", conversationId: "c2")
        BaseImageCache.shared.evict(conversationId: "c1")
        XCTAssertNil(BaseImageCache.shared.entry(conversationId: "c1", taskId: "tA", now: now),
                     "会话删除/用户取消必须清掉该会话的底图")
        XCTAssertNotNil(BaseImageCache.shared.entry(conversationId: "c2", taskId: "tB", now: now))
    }

    func testEvictAllClearsEverything() {
        seed(taskId: "tA", conversationId: "c1")
        seed(taskId: "tB", conversationId: "c2")
        BaseImageCache.shared.evictAll()
        XCTAssertEqual(BaseImageCache.shared.count, 0, "App 退出必须全清")
    }

    func testEvictExpiredKeepsFreshEntries() {
        seed(taskId: "old", conversationId: "c1", now: now.addingTimeInterval(-BaseImageCache.shared.ttl - 60))
        seed(taskId: "fresh", conversationId: "c1")
        BaseImageCache.shared.evictExpired(now: now)
        XCTAssertEqual(BaseImageCache.shared.count, 1)
        XCTAssertNotNil(BaseImageCache.shared.entry(conversationId: "c1", taskId: "fresh", now: now))
    }
}
