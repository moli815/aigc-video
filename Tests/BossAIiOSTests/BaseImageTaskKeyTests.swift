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

    /// 注意参数顺序：Swift 要求实参顺序与形参顺序一致，
    /// 调用点统一按 (prompt, extracted, aspect, renderIntent, references) 写。
    private func context(prompt: String,
                         extracted: [String: String],
                         aspect: String = "16:9",
                         renderIntent: String = "flat_artwork",
                         references: [Data] = []) -> ImageRequestContext {
        ImageRequestContext(prompt: prompt,
                            references: references,
                            taskKind: "generate",
                            qualityTier: "high",
                            requestedCount: nil,
                            aspectRatio: aspect,
                            renderIntent: renderIntent,
                            structured: nil,
                            layerDecomposition: false,
                            textDensity: "high",
                            textAccuracyRequired: true,
                            extractedText: extracted,
                            needsTextOverlay: true)
    }

    private func img() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 900)).image { ctx in
            UIColor.darkGray.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 1600, height: 900))
        }
    }

    func testChangingOnlyTextKeepsSameTaskKey() {
        let first = context(prompt: "做一张简洁名片，电话 13800000000，姓名 张三",
                            extracted: ["phone": "13800000000", "name": "张三"])
        let second = context(prompt: "做一张简洁名片，电话 13911111111，姓名 张三",
                             extracted: ["phone": "13911111111", "name": "张三"])
        XCTAssertEqual(BaseImageTaskKey.make(context: first), BaseImageTaskKey.make(context: second),
                       "只改文字必须落在同一个底图任务上，否则缓存永远命不中")
    }

    func testOverlayItemsAlsoStripText() {
        // extractedText 为空、只有 items 时同样要能抹掉文字（字段解析路径不同）
        let first = context(prompt: "名片 电话 13800000000", extracted: [:])
        let second = context(prompt: "名片 电话 13911111111", extracted: [:])
        let itemsA = [TextItem(role: .contact, key: "phone", text: "13800000000")]
        let itemsB = [TextItem(role: .contact, key: "phone", text: "13911111111")]
        XCTAssertEqual(BaseImageTaskKey.make(context: first, items: itemsA),
                       BaseImageTaskKey.make(context: second, items: itemsB))
    }

    func testAspectChangeChangesTaskKey() {
        let a = context(prompt: "做一张海报，主题：秋季上新", extracted: [:], aspect: "16:9")
        let b = context(prompt: "做一张海报，主题：秋季上新", extracted: [:], aspect: "3:4")
        XCTAssertNotEqual(BaseImageTaskKey.make(context: a), BaseImageTaskKey.make(context: b),
                          "比例变了必须重画底图")
    }

    func testRenderIntentChangeChangesTaskKey() {
        let a = context(prompt: "做一张海报，主题：秋季上新", extracted: [:], renderIntent: "flat_artwork")
        let b = context(prompt: "做一张海报，主题：秋季上新", extracted: [:], renderIntent: "mockup")
        XCTAssertNotEqual(BaseImageTaskKey.make(context: a), BaseImageTaskKey.make(context: b))
    }

    func testReferenceChangeChangesTaskKey() {
        let a = context(prompt: "照这张图做一张新海报", extracted: [:], references: [Data([0x01, 0x02, 0x03])])
        let b = context(prompt: "照这张图做一张新海报", extracted: [:], references: [Data([0x09, 0x08, 0x07])])
        XCTAssertNotEqual(BaseImageTaskKey.make(context: a), BaseImageTaskKey.make(context: b),
                          "换了参考图必须重画，不能拿上一张原图的底图凑")
    }

    func testWhitespaceAndCaseDoNotChangeTaskKey() {
        let a = context(prompt: "秋季上新  海报\n主视觉", extracted: [:])
        let b = context(prompt: "秋季上新 海报 主视觉", extracted: [:])
        XCTAssertEqual(BaseImageTaskKey.make(context: a), BaseImageTaskKey.make(context: b),
                       "同一需求换行/多空格差异不该算成两个任务")
    }

    /// 端到端接线契约：排版失败 → 只改文字重试 → 缓存必须命中（跳过 Pro）
    func testRetryAfterOverlayFailureHitsWithNewText() {
        let first = context(prompt: "做一张名片，电话 13800000000", extracted: ["phone": "13800000000"])
        let second = context(prompt: "做一张名片，电话 13911111111", extracted: ["phone": "13911111111"])
        let keyA = BaseImageTaskKey.make(context: first)
        let keyB = BaseImageTaskKey.make(context: second)

        // 首次：底图成功即缓存（此时还没排版）
        BaseImageCache.shared.save(taskId: keyA,
                                   conversationId: "conv-1",
                                   baseImage: img(),
                                   aspectRatio: "16:9",
                                   extractedText: first.extractedText,
                                   items: [TextItem(role: .contact, key: "phone", text: "13800000000")],
                                   layout: LayoutSpec(),
                                   canvas: CanvasSpec(size: CGSize(width: 1600, height: 900), expectedAspect: 16.0 / 9.0))
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
