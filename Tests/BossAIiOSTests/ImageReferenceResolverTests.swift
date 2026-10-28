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

    func testMentioningGeneratedPosterDoesNotDropUploadedLogo() {
        XCTAssertNil(ImageReferenceResolver.sourceOverride(requested: "both",
            userText: "把你生成的这张海报中的logo换成我们的logo",
            hasAttachedImage: true, hasLastGeneratedImage: true))
        XCTAssertEqual(ImageReferenceResolver.sourceOverride(requested: "last",
            userText: "把你生成的这张海报中的logo换成我们的logo",
            hasAttachedImage: true, hasLastGeneratedImage: true), "both")
    }

    func testBothSourceDoesNotSilentlyLoseMissingRequiredMaterial() {
        XCTAssertNil(ImageReferenceResolver.sourceOverride(requested: "both",
            userText: "修改你生成的海报中的Logo", hasAttachedImage: false, hasLastGeneratedImage: true))
        XCTAssertThrowsError(try ImageReferenceResolver.resolve(source: "both", attachedImages: [], lastGeneratedImage: generated))
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

    func testExplicitMaterialExclusionOverridesBoth() {
        XCTAssertEqual(ImageReferenceResolver.sourceOverride(requested:"both",userText:"不要用上传的素材，只改生成图",
            hasAttachedImage:true,hasLastGeneratedImage:true),"last")
        XCTAssertEqual(ImageReferenceResolver.sourceOverride(requested:"both",userText:"不要用生成图，只改上传的原图",
            hasAttachedImage:true,hasLastGeneratedImage:true),"attached")
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

    // MARK: - 2026-10-28 多附件合成

    /// 事故回归：用户传「人物照(1) + 底图(2)」要求合成，
    /// Agent 只给 source_index=2，人物照从未离开设备，模型只能按文字编一个陌生人。
    func testMultipleAttachmentsKeepTheGivenOrder() throws {
        let refs = try ImageReferenceResolver.resolve(source: "attached",
                                                      attachmentIndices: [2, 1],
                                                      attachedImages: [first, second],
                                                      lastGeneratedImage: generated)
        XCTAssertEqual(refs, [second, first], "第一位必须是底图，第二位是素材")
    }

    func testDuplicateIndicesAreCollapsedWithoutReordering() throws {
        let refs = try ImageReferenceResolver.resolve(source: "attached",
                                                      attachmentIndices: [2, 2, 1],
                                                      attachedImages: [first, second],
                                                      lastGeneratedImage: generated)
        XCTAssertEqual(refs, [second, first])
    }

    func testOutOfRangeIndexFailsClosedInsteadOfDroppingTheMaterial() {
        XCTAssertThrowsError(try ImageReferenceResolver.resolve(source: "attached",
                                                                attachmentIndices: [1, 3],
                                                                attachedImages: [first, second],
                                                                lastGeneratedImage: generated))
    }

    func testMoreThanSixReferencesIsRejected() {
        let many = (1...7).map { Data("img-\($0)".utf8) }
        XCTAssertThrowsError(try ImageReferenceResolver.resolve(source: "attached",
                                                                attachmentIndices: Array(1...7),
                                                                attachedImages: many,
                                                                lastGeneratedImage: nil))
    }

    /// 旧契约不变：both 仍是「上次生成图 + 一张上传素材」，Logo 替换依赖它
    func testBothStillMeansGeneratedBasePlusOneAttachment() throws {
        let refs = try ImageReferenceResolver.resolve(source: "both",
                                                      attachmentIndices: [1],
                                                      attachedImages: [second],
                                                      lastGeneratedImage: generated)
        XCTAssertEqual(refs, [generated, second])
    }

    /// 双图合成意图识别：只认明确的双图指代，单图编辑不能被误判成双图
    func testCrossAttachmentCompositeIntent() {
        XCTAssertTrue(ImageReferenceResolver.requestsCrossAttachmentComposite(
            "把第一张照片上的人物P在第二张照片上面，让两个人友好握手"))
        XCTAssertTrue(ImageReferenceResolver.requestsCrossAttachmentComposite(
            "把这张图里的人放到另一张上"))
        XCTAssertFalse(ImageReferenceResolver.requestsCrossAttachmentComposite(
            "把这张照片里的女士左边加一个人"))
        XCTAssertFalse(ImageReferenceResolver.requestsCrossAttachmentComposite(
            "把这张图里的天空换成日落"))
    }
}
