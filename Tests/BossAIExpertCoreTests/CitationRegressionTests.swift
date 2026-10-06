import XCTest
@testable import BossAIExpertCore

final class CitationRegressionTests: XCTestCase {
    func testTitlesAndDatesSurviveDeduplication() throws {
        var registry = CitationRegistry()
        XCTAssertEqual(registry.register("https://example.com/a?utm_source=x"), 1)
        XCTAssertEqual(registry.register("https://example.com/a", title: "产品规格", publishedAt: "2026-10-01"), 1)
        XCTAssertEqual(registry.sources[0].title, "产品规格")
        XCTAssertTrue(registry.markdown.contains("产品规格"))
        XCTAssertFalse(registry.markdown.contains("查看来源"))
        XCTAssertEqual(try JSONDecoder().decode([CitationSource].self, from: JSONEncoder().encode(registry.sources)), registry.sources)
    }
    func testOnlyCitedSourcesAppearWithoutRenumbering() {
        var registry = CitationRegistry()
        for index in 1...85 { _ = registry.register("https://example.com/\(index)", title: "来源标题\(index)") }
        let cited = CitationPresentation.cited(registry.sources, in: "价格待核实（来源 7、14/16）；发布时间（来源 62）。")
        XCTAssertEqual(cited.map(\.id), [7,14,16,62])
        XCTAssertEqual(registry.sources.count, 85) // Retrieval history remains available.
    }
    func testTableSourceColumnAndRanges() {
        let text = "| 型号 | 来源 |\n| --- | --- |\n| A | 14/16 |\n| B | 25-27 |\n\n价格 4999、发布日期 2026-10-06 不属于来源编号。"
        XCTAssertEqual(CitationPresentation.referencedIDs(in: text), [14,16,25,26,27])
    }
    func testLegacyFooterDoesNotTurnAllSearchResultsIntoCitations() {
        let text = "结论（来源 3）。" + CitationPresentation.legacyMarker + "[1] [查看来源](https://a.test/a)\n[3] [查看来源](https://b.test/b)"
        let projection = CitationPresentation.projection(text: text, json: "")
        XCTAssertEqual(projection.body, "结论（来源 3）。")
        XCTAssertEqual(CitationPresentation.cited(projection.sources, in: projection.body).map(\.id), [3])
        XCTAssertTrue(projection.sources[0].label.contains("标题未记录"))
        XCTAssertEqual(CitationPresentation.projection(text: "正文未含来源尾注", json: "bad json").body, "正文未含来源尾注")
    }
    func testInlineAndFencedCodeDoNotCreateFalseCitations() {
        XCTAssertEqual(CitationPresentation.referencedIDs(in: "`[9]`\n```\n来源 2\n```\n真实事实 [4]"), [4])
    }
    func testPlainLinkSelectsItsActualSource() {
        let sources = [CitationSource(id: 8, url: "https://example.com/a", title: "官方规格")]
        XCTAssertEqual(CitationPresentation.cited(sources, in: "[官方规格](https://example.com/a)").map(\.id), [8])
    }
    func testUnknownDateIsNotPresentedAsSearchTime() {
        let source = CitationSource(id: 1, url: "https://example.com/a")
        XCTAssertEqual(source.dateLabel, "发布时间未核实")
    }
    func testURLPrefixDoesNotSelectAnUnrelatedSource() {
        let sources = [CitationSource(id: 1, url: "https://example.com/1"), CitationSource(id: 10, url: "https://example.com/10?utm_source=test")]
        XCTAssertEqual(CitationPresentation.cited(sources, in: "[官网](https://example.com/10)").map(\.id), [10])
    }
    func testHundredsOfRepeatedSearchHitsBenchmark() {
        measure {
            var registry = CitationRegistry()
            for index in 0..<1000 { _ = registry.register("https://example.com/\(index % 100)?utm_source=x") }
            XCTAssertEqual(registry.sources.count, 100)
        }
    }
}
