import XCTest
@testable import BossAIExpertCore

final class ReliabilityCoreTests: XCTestCase {
    func testSSEWithoutSpace() throws {
        var decoder = SSEDecoder()
        XCTAssertNil(try decoder.consume("data:{\"value\":1}"))
        XCTAssertEqual(try decoder.consume(""), "{\"value\":1}")
    }
    func testSSEMultilineAndComments() throws {
        var decoder = SSEDecoder()
        XCTAssertNil(try decoder.consume(": keep alive"))
        XCTAssertNil(try decoder.consume("event: delta"))
        XCTAssertNil(try decoder.consume("data: first"))
        XCTAssertNil(try decoder.consume("data:second"))
        XCTAssertEqual(try decoder.consume("\r"), "first\nsecond")
        XCTAssertNil(try decoder.consume(""))
    }
    func testSSEOversizedEventRejected() throws {
        var decoder = SSEDecoder()
        XCTAssertThrowsError(try decoder.consume("data:" + String(repeating: "x", count: 1_048_577)))
    }
    func testCitationsStayStableAcrossSearches() {
        var registry = CitationRegistry()
        XCTAssertEqual(registry.register("https://example.com/a?utm_source=search#paragraph"), 1)
        XCTAssertEqual(registry.register("https://example.com/a"), 1)
        XCTAssertEqual(registry.register("https://example.com/b"), 2)
        XCTAssertEqual(registry.register("https://example.com/a"), 1)
        XCTAssertEqual(registry.urls.count, 2)
    }
    func testAllCitationsRemainVisible() {
        var registry = CitationRegistry()
        for index in 1...12 { _ = registry.register("https://example.com/\(index)") }
        XCTAssertTrue(registry.markdown.contains("[12]"))
    }
    func testRecencyWindowUsesUTCDate() {
        let now = Date(timeIntervalSince1970: 1_760_054_400)
        XCTAssertTrue(SearchRecency.week.query("政策", now: now).contains("after:"))
        XCTAssertEqual(SearchRecency.any.query("固定概念", now: now), "固定概念")
        XCTAssertEqual(SearchRecency.inferred(from: "今天新闻"), .day)
        XCTAssertEqual(SearchRecency.inferred(from: "最新动态"), .month)
    }
    func testUnsafeFileLeavesRejected() {
        for leaf in ["../foo", "a/b", "a\\b", ".", "..", "", "C:secret", "x\0y"] { XCTAssertFalse(StorageBoundary.isSafeLeaf(leaf)) }
        XCTAssertTrue(StorageBoundary.isSafeLeaf("正常文件.xlsx"))
    }
    func testMarkdownEscapedPipesAndEmptyColumns() {
        XCTAssertEqual(MarkdownTableCore.cells(#"| A\|B | | `x|y` |"#), ["A|B", "", "`x|y`"])
    }
    func testDashInsideDataIsNotSeparator() {
        XCTAssertFalse(MarkdownTableCore.isSeparator("| A---B | 10 |"))
        XCTAssertTrue(MarkdownTableCore.isSeparator("| :---: | --- |"))
    }
    func testSheetNameIsOfficeCompatible() {
        XCTAssertEqual(MarkdownTableCore.sheetName("[]:*?/\\"), "工作表")
        XCTAssertEqual(MarkdownTableCore.sheetName(String(repeating: "名", count: 50)).count, 31)
    }
    func testRichSharedStringsRetainIndices() {
        let xml = "<sst><si><r><t>第一</t></r><r><t>条</t></r></si><si><t xml:space=\"preserve\">第二条</t></si></sst>"
        XCTAssertEqual(SpreadsheetXMLCore.sharedStrings(xml), ["第一条", "第二条"])
    }
    func testSparseColumnsDoNotShiftAndInlineTextSurvives() {
        let xml = "<worksheet><sheetData><row r=\"1\"><c r=\"A1\" t=\"s\"><v>1</v></c><c r=\"C1\" t=\"inlineStr\"><is><t xml:space=\"preserve\">C</t></is></c></row></sheetData></worksheet>"
        XCTAssertEqual(SpreadsheetXMLCore.rows(xml, shared: ["first", "second"]), ["second |  | C"])
    }
    func testInvalidSharedIndexDoesNotInventValue() {
        let xml = "<worksheet><row><c r=\"A1\" t=\"s\"><v>99</v></c></row></worksheet>"
        XCTAssertEqual(SpreadsheetXMLCore.rows(xml, shared: []), ["[无效共享字符串]"])
    }
    func testMalformedXMLFailsClosed() {
        XCTAssertEqual(SpreadsheetXMLCore.sharedStrings("<sst><si>"), [])
    }
    func testLocalEvidenceToolIsPermitted() throws {
        XCTAssertTrue(ExpertSkillRuntime.permits("search_library", profile: try ExpertCapabilityCatalog.profile("legal")))
    }
    func testSSEBatchPerformance() {
        measure {
            var decoder = SSEDecoder()
            for _ in 0..<10000 { _ = try? decoder.consume("data: short"); _ = try? decoder.consume("") }
        }
    }
}
