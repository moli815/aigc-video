import XCTest
@testable import BossAI

final class ImageToolArgumentsTests: XCTestCase {
    func testMalformedArgumentsFailBeforeExecution() {
        XCTAssertThrowsError(try ImageToolArguments.decode("not json", toolName: "image_generate", userText: "做张图"))
        XCTAssertThrowsError(try ImageToolArguments.decode("[]", toolName: "image_generate", userText: "做张图"))
        XCTAssertThrowsError(try ImageToolArguments.decode(#"{"prompt":"scene","structured":{"text":"visual instructions"}}"#,
            toolName: "image_generate", userText: "做张图"))
    }

    func testTypedCopyAndSourceIndexAreAccepted() throws {
        let args = try ImageToolArguments.decode(#"{"prompt":"scene","source":"attached","source_index":1,"structured":{"text":[{"role":"title","key":"title","text":"春日来信"}]}}"#,
            toolName: "image_generate", userText: "重新设计")
        XCTAssertEqual(args["source_index"] as? Int, 1)
    }

    func testDuplicateCopyKeysAndWrongSourceAreRejected() {
        XCTAssertThrowsError(try ImageToolArguments.decode(#"{"prompt":"scene","structured":{"text":[{"role":"title","key":"a","text":"甲"},{"role":"body","key":"a","text":"乙"}]}}"#,
            toolName: "image_generate", userText: "做图"))
        XCTAssertThrowsError(try ImageToolArguments.decode(#"{"prompt":"scene","source":"none"}"#,
            toolName: "image_edit", userText: "改图"))
        XCTAssertThrowsError(try ImageToolArguments.decode(#"{"prompt":"scene","source":"attached","source_index":true}"#,
            toolName: "image_edit", userText: "改图"))
    }

    func testSingleToolCannotSpendForMultipleOutputs() {
        XCTAssertThrowsError(try ImageToolArguments.decode(#"{"prompt":"scene","count":3}"#,
            toolName: "generate_image", userText: "做三张"))
        XCTAssertThrowsError(try ImageToolArguments.decode(#"{"prompt":"scene","count":1}"#,
            toolName: "image_series", userText: "做一张"))
    }

    func testNativeShortTitleDoesNotForcePosterOverlay() {
        XCTAssertFalse(TextIntentDecider.needsOverlay(userText: "海报，只有短标题与副标题",
            extractedFieldCount: 2, extractedCharCount: 20))
        XCTAssertTrue(TextIntentDecider.needsOverlay(userText: "完整联系方式必须准确",
            extractedFieldCount: 1, extractedCharCount: 11, accuracyRequired: true))
    }

    func testMatureReferenceLibraryIsBundled() {
        XCTAssertGreaterThanOrEqual(ImageDesignGuidance.references.count, 6)
        XCTAssertEqual(Set(ImageDesignGuidance.references.map(\.id)).count, ImageDesignGuidance.references.count)
        XCTAssertTrue(ImageDesignGuidance.instructions.contains("瑞士网格"))
    }

    func testNonFiniteAspectValuesCannotCrashNormalization() {
        XCTAssertNil(ImageTaskPlanner.normalizeAspect("inf:1"))
        XCTAssertNil(ChatViewModel.aspectRatioValue("nan:1"))
        XCTAssertNotNil(ImageTaskPlanner.normalizeAspect("1e100:1e100"))
    }

    func testHighQualityEditKeepsRatioAtTwoKPixelBudget() {
        let plan = ImageTaskPlanner.plan(userText: "换背景，其余不变", referenceCount: 1,
            sourceSize: (width: 1200, height: 800), userSaid: "换背景，其余不变")
        let parts = (plan.targetSize ?? "").split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return XCTFail("缺少输出画布") }
        XCTAssertGreaterThan(parts[0] * parts[1], 4_000_000)
        XCTAssertEqual(parts[0] / parts[1], 1.5, accuracy: 0.01)
    }

    // MARK: - 2026-10-28 多附件参数

    func testMultiAttachmentPairIsAccepted() throws {
        let args = try ImageToolArguments.decode(
            #"{"prompt":"把图1的人物合成到图2，两人握手","source":"attached","source_indexes":[2,1],"reference_roles":["底图","人物照片"]}"#,
            toolName: "image_edit", userText: "把第一张上的人P到第二张上")
        XCTAssertEqual((args["source_indexes"] as? [NSNumber])?.map(\.intValue), [2, 1])
        XCTAssertEqual(args["reference_roles"] as? [String], ["底图", "人物照片"])
    }

    func testMultiAttachmentRequiresAttachedSourceAndMatchingRoles() {
        // both 是"上次生成图+一张素材"的旧契约，混用会静默丢图
        XCTAssertThrowsError(try ImageToolArguments.decode(
            #"{"prompt":"合成","source":"both","source_indexes":[2,1]}"#,
            toolName: "image_edit", userText: "合成两张图"))
        // 角色数量必须与序号一致，否则服务端会错标"哪张是人物"
        XCTAssertThrowsError(try ImageToolArguments.decode(
            #"{"prompt":"合成","source":"attached","source_indexes":[2,1],"reference_roles":["底图"]}"#,
            toolName: "image_edit", userText: "合成两张图"))
        // source_index 与 source_indexes 不能同时出现
        XCTAssertThrowsError(try ImageToolArguments.decode(
            #"{"prompt":"合成","source":"attached","source_index":1,"source_indexes":[2,1]}"#,
            toolName: "image_edit", userText: "合成两张图"))
        // 重复序号是脏数据
        XCTAssertThrowsError(try ImageToolArguments.decode(
            #"{"prompt":"合成","source":"attached","source_indexes":[1,1]}"#,
            toolName: "image_edit", userText: "合成两张图"))
    }
}
