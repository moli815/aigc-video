import XCTest
import UIKit
@testable import BossAI

// ============================================================================
// 底图任务指纹（BaseImageTaskKey）+ 与 BaseImageCache 的接线契约（10-25）
//
// 这里锁的是**产品承诺**，不是实现细节：
//   1. 用户只把电话 / 姓名改了几个字 → 必须命中同一张底图（不重新调 Pro、不重复扣费）
//   2. 比例 / 渲染意图 / 参考图 / 主题描述变了 → 必须换任务（否则会拿旧底图糊新需求）
// ============================================================================
final class BaseImageTaskKeyTests: XCTestCase {

    override func setUp() {
        super.setUp()
        BaseImageCache.shared.resetForTesting()
    }

    private func context(prompt: String,
                         aspect: String = "16:9",
                         renderIntent: String = "flat_artwork",
                         references: [Data] = [],
                         qualityTier: String = "high",
                         targetSize: String? = nil,
                         structured: [String: Any]? = nil) -> ImageRequestContext {
        ImageRequestContext(prompt: prompt,
                            references: references,
                            taskKind: "generate",
                            qualityTier: qualityTier,
                            requestedCount: nil,
                            aspectRatio: aspect,
                            renderIntent: renderIntent,
                            structured: structured,
                            layerDecomposition: false,
                            targetSize: targetSize)
    }

    private func items(_ values: [String: String]) -> [TextItem] {
        values.sorted { $0.key < $1.key }.map { pair in
            TextItem(role: pair.key == "phone" ? .contact : .body,
                     key: pair.key,
                     text: pair.value)
        }
    }

    private func img() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 900)).image { ctx in
            UIColor.darkGray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 1600, height: 900))
        }
    }

    func testChangingOnlyTextKeepsSameTaskKey() {
        let first = context(prompt: "做一张简洁名片，电话 13800000000，姓名 张三")
        let second = context(prompt: "做一张简洁名片，电话 13911111111，姓名 张三")
        XCTAssertEqual(BaseImageTaskKey.make(context: first, items: items(["phone": "13800000000", "name": "张三"])),
                       BaseImageTaskKey.make(context: second, items: items(["phone": "13911111111", "name": "张三"])),
                       "只改文字必须落在同一个底图任务上，否则缓存永远命不中")
    }

    func testOverlayItemsAlsoStripText() {
        let first = context(prompt: "名片 电话 13800000000")
        let second = context(prompt: "名片 电话 13911111111")
        let itemsA = [TextItem(role: .contact, key: "phone", text: "13800000000")]
        let itemsB = [TextItem(role: .contact, key: "phone", text: "13911111111")]
        XCTAssertEqual(BaseImageTaskKey.make(context: first, items: itemsA),
                       BaseImageTaskKey.make(context: second, items: itemsB))
    }

    func testAspectChangeChangesTaskKey() {
        let a = context(prompt: "做一张海报，主题：秋季上新", aspect: "16:9")
        let b = context(prompt: "做一张海报，主题：秋季上新", aspect: "3:4")
        XCTAssertNotEqual(BaseImageTaskKey.make(context: a), BaseImageTaskKey.make(context: b),
                          "比例变了必须重画底图")
    }

    func testRenderIntentChangeChangesTaskKey() {
        let a = context(prompt: "做一张海报，主题：秋季上新", renderIntent: "flat_artwork")
        let b = context(prompt: "做一张海报，主题：秋季上新", renderIntent: "mockup")
        XCTAssertNotEqual(BaseImageTaskKey.make(context: a), BaseImageTaskKey.make(context: b))
    }

    func testReferenceChangeChangesTaskKey() {
        let a = context(prompt: "照这张图做一张新海报", references: [Data([0x01, 0x02, 0x03])])
        let b = context(prompt: "照这张图做一张新海报", references: [Data([0x09, 0x08, 0x07])])
        XCTAssertNotEqual(BaseImageTaskKey.make(context: a), BaseImageTaskKey.make(context: b),
                          "换了参考图必须重画，不能拿上一张原图的底图凑")
    }

    func testReferenceChangeInMiddleBytesChangesTaskKey() {
        var first = Data(repeating: 0x2a, count: 1024)
        var second = first
        second[512] = 0x2b
        let a = context(prompt: "参考图重设计", references: [first])
        let b = context(prompt: "参考图重设计", references: [second])
        XCTAssertNotEqual(BaseImageTaskKey.make(context: a), BaseImageTaskKey.make(context: b),
                          "参考图指纹必须覆盖完整内容，不能只看 JPEG 头尾")
        first[512] = 0x2c
        XCTAssertNotEqual(BaseImageTaskKey.make(context: a), BaseImageTaskKey.make(context: context(prompt: "参考图重设计", references: [first])))
    }

    func testVisualStructuredFieldsChangeTaskKey() {
        let first = context(prompt: "做一张科技海报", structured: ["composition": "左侧留白", "text": "标题 A"])
        let second = context(prompt: "做一张科技海报", structured: ["composition": "右侧留白", "text": "标题 A"])
        XCTAssertNotEqual(BaseImageTaskKey.make(context: first), BaseImageTaskKey.make(context: second),
                          "视觉构图字段变更不能复用旧底图")
    }

    func testStructuredCopyDoesNotChangeTaskKey() {
        let first = context(prompt: "做一张科技海报，标题 A",
                            structured: ["composition": "左侧留白", "text": "标题 A"])
        let second = context(prompt: "做一张科技海报，标题 B",
                             structured: ["composition": "左侧留白", "text": "标题 B"])
        XCTAssertEqual(BaseImageTaskKey.make(context: first), BaseImageTaskKey.make(context: second),
                       "可见文案变化应复用相同视觉底图")
    }

    func testQualityAndExplicitSizeChangeTaskKey() {
        let base = context(prompt: "做一张海报", qualityTier: "high", targetSize: "1600x900")
        let otherTier = context(prompt: "做一张海报", qualityTier: "fast", targetSize: "1600x900")
        let otherSize = context(prompt: "做一张海报", qualityTier: "high", targetSize: "1200x800")
        XCTAssertNotEqual(BaseImageTaskKey.make(context: base), BaseImageTaskKey.make(context: otherTier))
        XCTAssertNotEqual(BaseImageTaskKey.make(context: base), BaseImageTaskKey.make(context: otherSize))
    }

    func testWhitespaceAndCaseDoNotChangeTaskKey() {
        let a = context(prompt: "秋季上新  海报\n主视觉")
        let b = context(prompt: "秋季上新 海报 主视觉")
        XCTAssertEqual(BaseImageTaskKey.make(context: a), BaseImageTaskKey.make(context: b),
                       "同一需求换行/多空格差异不该算成两个任务")
    }

    /// 端到端接线契约：排版失败 → 只改文字重试 → 缓存必须命中（跳过 Pro）
    func testRetryAfterOverlayFailureHitsWithNewText() {
        let first = context(prompt: "做一张名片，电话 13800000000")
        let second = context(prompt: "做一张名片，电话 13911111111")
        let firstItems = items(["phone": "13800000000"])
        let secondItems = items(["phone": "13911111111"])
        let keyA = BaseImageTaskKey.make(context: first, items: firstItems)
        let keyB = BaseImageTaskKey.make(context: second, items: secondItems)

        // 首次：底图成功即缓存（此时还没排版）
        BaseImageCache.shared.save(taskId: keyA,
                                   conversationId: "conv-1",
                                   baseImage: img(),
                                   aspectRatio: "16:9"
                                   )
        // 排版失败：保留缓存（retainAfterOverlayFailure 不删）
        BaseImageCache.shared.retainAfterOverlayFailure(conversationId: "conv-1", taskId: keyA)
        XCTAssertNotNil(BaseImageCache.shared.entry(conversationId: "conv-1", taskId: keyA),
                        "排版失败不得清掉底图，否则重试仍要重画")

        // 用户改电话后重试：命中，直接排版
        XCTAssertEqual(BaseImageCache.shared.lookup(conversationId: "conv-1", taskId: keyB, aspectRatio: "16:9"), .hit)

        // 排版成功：清缓存
        BaseImageCache.shared.markOverlayDoneAndEvict(conversationId: "conv-1", taskId: keyB)
        XCTAssertNil(BaseImageCache.shared.entry(conversationId: "conv-1", taskId: keyB))
    }

    func testAspectRatioValueParsesPlanString() {
        XCTAssertEqual(ChatViewModel.aspectRatioValue("16:9") ?? 0, 16.0 / 9.0, accuracy: 0.0001)
        XCTAssertEqual(ChatViewModel.aspectRatioValue("3:4") ?? 0, 0.75, accuracy: 0.0001)
        XCTAssertNil(ChatViewModel.aspectRatioValue(""), "空比例不能瞎猜")
        XCTAssertNil(ChatViewModel.aspectRatioValue("16:0"), "非法比例必须返回 nil，不能崩")
        XCTAssertNil(ChatViewModel.aspectRatioValue("auto"))
    }
}
