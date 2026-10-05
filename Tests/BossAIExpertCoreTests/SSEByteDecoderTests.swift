import XCTest
@testable import BossAIExpertCore

final class SSEByteDecoderTests: XCTestCase {
    private func decode(_ value: String) throws -> [String] {
        var decoder = SSEByteDecoder(); var result: [String] = []
        for byte in value.utf8 { if let event = try decoder.consume(byte) { result.append(event) } }
        if let last = try decoder.finish() { result.append(last) }
        return result
    }
    func testLFBlankLinesPreserved() throws {
        XCTAssertEqual(try decode("data: one\n\ndata: two\n\ndata: [DONE]\n\n"), ["one", "two", "[DONE]"])
    }
    func testCRLFAndCR() throws {
        XCTAssertEqual(try decode("data: one\r\rdata: two\r\n\r\n"), ["one", "two"])
    }
    func testUTF8AcrossIndividualBytes() throws {
        XCTAssertEqual(try decode("data: 最新旗舰手机😀\n\n"), ["最新旗舰手机😀"])
    }
    func testMultilineAndComment() throws {
        XCTAssertEqual(try decode(": heartbeat\n\ndata: first\ndata: second\n\n"), ["first\nsecond"])
    }
    func testProviderFinalMarkerWithoutBlankLine() throws {
        XCTAssertEqual(try decode("data: [DONE]"), ["[DONE]"])
    }
    func testTruncatedJSONIsNotInventedOrDropped() throws {
        XCTAssertEqual(try decode("data: {\"unfinished\":"), ["{\"unfinished\":"])
    }
    func testInvalidUTF8IsRejected() throws {
        var decoder = SSEByteDecoder()
        _ = try decoder.consume(255)
        XCTAssertThrowsError(try decoder.consume(10))
    }
    func testOversizedUnterminatedLineIsRejected() throws {
        var decoder = SSEByteDecoder()
        for _ in 0..<1_048_576 { _ = try decoder.consume(65) }
        XCTAssertThrowsError(try decoder.consume(65))
    }
}
