import XCTest
@testable import BossAI

final class ExecutionBoundaryTests: XCTestCase {
    func testMalformedPairsCannotShiftChartValuesToOtherLabels() {
        XCTAssertNil(ChartSpec.parse(#"{"title":"test","labels":["A",null,"C"],"values":[1,2,"bad"]}"#))
        XCTAssertNil(ChartSpec.parse(#"{"title":"test","labels":["A","B"],"values":[1,true]}"#))
        XCTAssertNil(ChartSpec.parse(#"{"title":"test","type":"pie","labels":["A"],"values":[-1]}"#))
        XCTAssertNotNil(ChartSpec.parse(#"{"title":"test","labels":["A","B"],"values":[1,"2"]}"#))
    }

    func testNaturalLanguageImageDoesNotRequireEmptyMetadata() throws {
        let args = try ImageToolArguments.decode(#"{"prompt":"一只在花园的猫"}"#, toolName: "image_generate", userText: "画一只猫")
        XCTAssertEqual(args["prompt"] as? String, "一只在花园的猫")
    }

    func testDispatcherDeniesDisabledSearchAndUnauthorizedDocumentFormat() {
        let policy = EffectiveToolPolicy(canSearch: true, canImage: true, docFormats: ["pdf"],
            disabledToolIDs: ["web_search"], availableToolIDs: ["web_search", "create_document"])
        XCTAssertThrowsError(try ToolDispatcher.validate(.init(id: "search", name: "web_search", arguments: #"{"query":"x"}"#), policy: policy))
        XCTAssertThrowsError(try ToolDispatcher.validate(.init(id: "doc", name: "create_document", arguments: #"{"format":"word"}"#), policy: policy))
        XCTAssertNoThrow(try ToolDispatcher.validate(.init(id: "pdf", name: "create_document", arguments: #"{"format":"pdf"}"#), policy: policy))
    }

    func testManifestSchemasExactlyFollowExecutionPermissions() throws {
        let profile = try ExpertCapabilityCatalog.profile("general")
        let policy = EffectiveToolPolicy(canSearch: false, canImage: true, docFormats: ["pdf"],
            disabledToolIDs: [], availableToolIDs: ["image_generate", "create_document", "web_search"])
        let schemas = ToolManifest.definitions(policy: policy, capability: profile, includeSearch: true)
        let names = schemas.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertEqual(Set(names), ["image_generate", "create_document"])
        XCTAssertEqual(names.count, Set(names).count)
        let document = try XCTUnwrap(schemas.compactMap { $0["function"] as? [String: Any] }.first { $0["name"] as? String == "create_document" })
        let parameters = try XCTUnwrap(document["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        XCTAssertEqual((properties["format"] as? [String: Any])?["enum"] as? [String], ["pdf"])
    }

    func testRequestIdentityLivesWithImmutableIntent() {
        let context = ImageRequestContext(prompt: "scene", references: [Data([1])], taskKind: "edit",
            qualityTier: "high", requestedCount: 1, aspectRatio: "3:1", renderIntent: "", structured: nil,
            layerDecomposition: false, requestId: "stable-request")
        XCTAssertEqual(context.requestId, "stable-request")
        let revised = context.retrying(note: "改变光线")
        XCTAssertNotEqual(revised.requestId, context.requestId, "修改生成意图必须创建新任务，网络重试仍使用原 context")
        XCTAssertEqual(revised.references, context.references)
        XCTAssertEqual(revised.qualityTier, context.qualityTier)
    }
}
