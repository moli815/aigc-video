import XCTest
@testable import BossAI

final class SeedreamSizeResolverTests: XCTestCase {
    func testDocumentedSeedreamDimensionsByTier() {
        XCTAssertEqual(SeedreamSizeResolver.resolve(aspectRatio: "16:9", tier: "2K"), "2816x1584")
        XCTAssertEqual(SeedreamSizeResolver.resolve(aspectRatio: "1:1", tier: "1.5K"), "1536x1536")
        XCTAssertEqual(SeedreamSizeResolver.resolve(aspectRatio: "21:9", tier: "1K"), "1568x672")
    }

    func testArbitraryAspectRatioProducesBoundedMatchingSize() throws {
        let size = try XCTUnwrap(SeedreamSizeResolver.resolve(aspectRatio: "4:5", tier: "2K"))
        let dimensions = size.split(separator: "x").compactMap { Int($0) }
        XCTAssertEqual(dimensions.count, 2)
        XCTAssertLessThan(abs(Double(dimensions[0]) / Double(dimensions[1]) - 0.8), 0.01)
        XCTAssertLessThanOrEqual(dimensions[0] * dimensions[1], ImageGeometry.maxPixels)
    }

    func testUnrepresentableAspectFailsClosed() {
        XCTAssertNil(SeedreamSizeResolver.resolve(aspectRatio: "1:17", tier: "2K"))
    }

    func testExplicitCanvasSizeIsValidatedAndPreserved() {
        XCTAssertEqual(SeedreamSizeResolver.resolveExplicit("1200x800"), "1200x800")
        XCTAssertNil(SeedreamSizeResolver.resolveExplicit("not-a-size"))
    }
}
