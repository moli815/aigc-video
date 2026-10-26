import XCTest
@testable import BossAI

final class ImageProviderRequestCompilerTests: XCTestCase {
    func testHostedEnvelopeCarriesAppSemantics() {
        let body = ImageProviderRequestCompiler.hosted(model: "hosted-image", prompt: "scene",
                                                       structured: ["text": [["text": "准确文案"]]],
                                                       requestId: "rid-1", layerDecomposition: false,
                                                       renderIntent: "flat_artwork", aspectRatio: "16:9",
                                                       taskKind: "reference", qualityTier: "high",
                                                       requestedCount: 1, targetSize: nil, textMode: nil)
        XCTAssertEqual(body["task_kind"] as? String, "reference")
        XCTAssertEqual(body["quality_tier"] as? String, "high")
        XCTAssertEqual(body["aspect_ratio"] as? String, "16:9")
        XCTAssertEqual(body["requestId"] as? String, "rid-1")
        XCTAssertNil(body["size"])
    }

    /// overlay = 底图无字；服务端据此不再把精确文案追加回 prompt（否则底图画一遍、排版再画一遍）
    func testHostedEnvelopeCarriesTextModeForOverlay() {
        let body = ImageProviderRequestCompiler.hosted(model: "hosted-image", prompt: "poster scene",
                                                       structured: ["text": [["text": "准确文案"]]],
                                                       requestId: nil, layerDecomposition: false,
                                                       renderIntent: "flat_artwork", aspectRatio: "3:4",
                                                       taskKind: "generate", qualityTier: "high",
                                                       requestedCount: 1, targetSize: nil, textMode: "overlay")
        XCTAssertEqual(body["text_mode"] as? String, "overlay")
    }

    func testSeedreamUsesNativePixelsAndDoesNotLeakHostedEnvelopeFields() throws {
        let body = try ImageProviderRequestCompiler.seedream(model: "seedream", prompt: "red landscape",
                                                             references: [], structured: ["text": [["text": "逐字文案"]]],
                                                             layerDecomposition: false, aspectRatio: "16:9",
                                                             taskKind: "generate",
                                                             requestedCount: 1, targetSize: nil)
        XCTAssertEqual(body["size"] as? String, "2816x1584")
        XCTAssertNil(body["task_kind"])
        XCTAssertNil(body["quality_tier"])
        XCTAssertNil(body["aspect_ratio"])
        XCTAssertTrue((body["prompt"] as? String)?.contains("逐字文案") == true)
    }

    func testDirectProviderRejectsMalformedAspectInsteadOfSilentlyIgnoringIt() {
        XCTAssertThrowsError(try ImageProviderRequestCompiler.zhipu(model: "cogview", prompt: "scene",
                                                                    references: [], structured: nil,
                                                                    layerDecomposition: false,
                                                                    aspectRatio: "bad-ratio",
                                                                    taskKind: "generate",
                                                                    requestedCount: 1, targetSize: nil))
    }

    func testSeedreamLayerDecompositionRequiresExactlyOneInputImage() {
        XCTAssertThrowsError(try ImageProviderRequestCompiler.seedream(model: "seedream", prompt: "split",
                                                                       references: [], structured: nil,
                                                                       layerDecomposition: true, aspectRatio: "1:1", taskKind: "decompose",
                                                                       requestedCount: 1, targetSize: nil))
        XCTAssertThrowsError(try ImageProviderRequestCompiler.seedream(model: "seedream", prompt: "split",
                                                                       references: [Data([1]), Data([2])], structured: nil,
                                                                       layerDecomposition: true, aspectRatio: "1:1", taskKind: "decompose",
                                                                       requestedCount: 1, targetSize: nil))
    }

    func testDirectSeedreamRejectsSeriesBySemanticTaskEvenIfCountWasLost() {
        XCTAssertThrowsError(try ImageProviderRequestCompiler.seedream(model: "seedream", prompt: "series",
                                                                       references: [], structured: nil,
                                                                       layerDecomposition: false, aspectRatio: "1:1",
                                                                       taskKind: "series", requestedCount: nil,
                                                                       targetSize: nil))
    }
}
