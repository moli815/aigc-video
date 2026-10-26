import XCTest
@testable import BossAI

final class ImageReferenceResolverTests: XCTestCase {
    private let first = Data("first-image".utf8)
    private let second = Data("second-image".utf8)
    private let generated = Data("generated-image".utf8)

    func testAttachedSourceUsesExactOneBasedIndex() throws {
        let refs = try ImageReferenceResolver.resolve(source: "attached",
                                                       attachmentIndex: 2,
                                                       attachedImages: [first, second],
                                                       lastGeneratedImage: generated)
        XCTAssertEqual(refs, [second])
    }

    func testBothSourcePreservesBaseThenOverlayOrder() throws {
        let refs = try ImageReferenceResolver.resolve(source: "both",
                                                       attachmentIndex: 1,
                                                       attachedImages: [second],
                                                       lastGeneratedImage: generated)
        XCTAssertEqual(refs, [generated, second])
    }

    func testMissingAttachmentFailsClosedInsteadOfReturningNoReferences() {
        XCTAssertThrowsError(try ImageReferenceResolver.resolve(source: "attached",
                                                                  attachmentIndex: 2,
                                                                  attachedImages: [first],
                                                                  lastGeneratedImage: generated))
    }

    func testUnreadableAttachmentKeepsItsIndexAndFailsClosed() {
        XCTAssertThrowsError(try ImageReferenceResolver.resolve(source: "attached",
                                                                  attachmentIndex: 1,
                                                                  attachedImages: [Data(), second],
                                                                  lastGeneratedImage: generated))
    }

    func testNoneDoesNotAccidentallyReuseLastGeneratedImage() throws {
        let refs = try ImageReferenceResolver.resolve(source: "none",
                                                       attachedImages: [first],
                                                       lastGeneratedImage: generated)
        XCTAssertTrue(refs.isEmpty)
    }

    func testReferenceIntentCanRecoverMissingToolSourceFromUserRequest() {
        XCTAssertTrue(ImageReferenceResolver.userRequestsImageSource("帮我重新设计一下这张海报"))
        XCTAssertTrue(ImageReferenceResolver.userRequestsImageSource("只把这张照片的背景换成海边"))
        XCTAssertFalse(ImageReferenceResolver.userRequestsImageSource("生成一只蓝色的猫"))
        XCTAssertFalse(ImageReferenceResolver.userRequestsImageSource("重新设计一张新的科技海报"),
                       "没有明确指向历史/上传图片时，不应静默选用上一张图")
    }

    func testExplicitUploadedImageRequestOverridesWrongToolSource() {
        XCTAssertEqual(ImageReferenceResolver.sourceOverride(requested: "none",
                                                              userText: "根据我上传的原图重新设计",
                                                              hasAttachedImage: true,
                                                              hasLastGeneratedImage: true), "attached")
        XCTAssertEqual(ImageReferenceResolver.sourceOverride(requested: "last",
                                                              userText: "只把这张照片的背景换成海边",
                                                              hasAttachedImage: true,
                                                              hasLastGeneratedImage: true), "attached")
    }

    func testExplicitLastGeneratedRequestOverridesWrongToolSource() {
        XCTAssertEqual(ImageReferenceResolver.sourceOverride(requested: "attached",
                                                              userText: "修改你刚才生成的那张海报",
                                                              hasAttachedImage: true,
                                                              hasLastGeneratedImage: true), "last")
    }

    func testSourceIsNotOverriddenWhenNoReferenceIsAvailable() {
        XCTAssertNil(ImageReferenceResolver.sourceOverride(requested: "none",
                                                            userText: "根据我上传的原图重新设计",
                                                            hasAttachedImage: false,
                                                            hasLastGeneratedImage: false))
    }

    func testTextlessBackgroundRemovesVisibleCopyFromBothPromptSources() {
        let copy = "中防保全 · 185-6866-4567"
        let context = ImageRequestContext(prompt: "设计海报，显示 \(copy)",
                                          references: [first],
                                          taskKind: "reference",
                                          qualityTier: "high",
                                          requestedCount: nil,
                                          aspectRatio: "16:9",
                                          renderIntent: "flat_artwork",
                                          structured: ["text": copy,
                                                       "subject": "企业品牌中防保全 · 185-6866-4567",
                                                       "composition": "左侧留白，右侧城市夜景"],
                                          layerDecomposition: false)
        let background = context.forTextlessBackground(items: [TextItem(role: .body, key: "text", text: copy)])
        XCTAssertFalse(background.prompt.contains(copy))
        XCTAssertNil(background.structured?["text"])
        XCTAssertFalse((background.structured?["subject"] as? String ?? "").contains("中防保全"))
        XCTAssertFalse((background.structured?["subject"] as? String ?? "").contains("185-6866-4567"))
        XCTAssertEqual(background.structured?["composition"] as? String, "左侧留白，右侧城市夜景")
        XCTAssertEqual(background.references, [first])
        XCTAssertEqual(background.taskKind, "reference")
    }
}
