import XCTest
import SwiftData
@testable import BossAI

final class ReliabilityIntegrationTests: XCTestCase {
    func testMarkdownTableAndCodeBlocksRemainDistinct() {
        let blocks = MarkdownView.parse("| A | B |\n| --- | --- |\n| 1 | 2 |\n\n```\n| code | x |\n```")
        XCTAssertEqual(blocks.count, 2)
        if case .table(let rows) = blocks[0] { XCTAssertEqual(rows.count, 2) } else { XCTFail("Missing table") }
        if case .code = blocks[1] {} else { XCTFail("Code must not become table") }
    }
    func testLongPPTBulletIsSplitWithoutLosingCharacters() throws {
        let text = String(repeating: "X", count: 1000)
        let archive = DocumentBuilder.pptx(title: "长文本", markdown: "# 长文本\n- " + text)
        let reader = ZipReader(data: archive)
        let slides = reader.entryNames().filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
        XCTAssertGreaterThan(slides.count, 1)
        var xCount = 0
        for slide in slides { xCount += try String(decoding: reader.data(for: slide), as: UTF8.self).filter { $0 == "X" }.count }
        XCTAssertEqual(xCount, 1000)
    }
    func testStoredZIPRoundTripAndCRC() throws {
        var writer = ZipWriter(); writer.add("sample.txt", "经营数据")
        XCTAssertEqual(try ZipReader(data: writer.finalize()).data(for: "sample.txt"), Data("经营数据".utf8))
    }
    func testCompressedZIPRealFixture() throws {
        let archive = try XCTUnwrap(Data(base64Encoded: "UEsDBBQAAAAIAKm+RV0MDSu/JgAAAAgHAAALAAAAZml4dHVyZS50eHR72tf9fM/Kp3snPVu4+NnW7hfrpz4dFRkVGRUZFRkVGRXpGykiAFBLAQIUABQAAAAIAKm+RV0MDSu/JgAAAAgHAAALAAAAAAAAAAAAAACAAQAAAABmaXh0dXJlLnR4dFBLBQYAAAAAAQABADkAAABPAAAAAAA="))
        XCTAssertEqual(try ZipReader(data: archive).data(for: "fixture.txt"), Data(String(repeating: "压缩归档测试", count: 100).utf8))
    }
    func testZIPTruncationAndCRCFailureRejected() throws {
        var writer = ZipWriter(); writer.add("a", "ABC")
        var bytes = writer.finalize(); bytes[31] ^= 1
        XCTAssertThrowsError(try ZipReader(data: bytes).data(for: "a"))
        XCTAssertThrowsError(try ZipReader(data: Data(bytes.dropLast(5))).data(for: "a"))
    }
    func testBackupEncryptionRoundTrip() throws {
        let data = Data("加密备份样本".utf8)
        let encrypted = try BackupService.encrypt(data, password: "offline-fixture-password")
        XCTAssertEqual(try BackupService.decrypt(encrypted, password: "offline-fixture-password"), data)
    }
    func testWrongPasswordAndTamperingRejected() throws {
        let data = Data("合成数据".utf8)
        var encrypted = try BackupService.encrypt(data, password: "offline-password")
        XCTAssertThrowsError(try BackupService.decrypt(encrypted, password: "wrong-password"))
        encrypted[encrypted.count - 1] ^= 1
        XCTAssertThrowsError(try BackupService.decrypt(encrypted, password: "offline-password"))
    }
    func testMalformedPresentManifestArrayIsNotDropped() {
        let data = Data(#"{"version":1,"conversations":"broken"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(BackupService.Manifest.self, from: data))
    }
    func testOldManifestMissingOptionalFieldsStillDecodes() throws {
        let decoded = try JSONDecoder().decode(BackupService.Manifest.self, from: Data(#"{"version":1}"#.utf8))
        XCTAssertTrue(decoded.conversations.isEmpty)
    }
    @MainActor
    func testKnowledgeRetrievalReturnsFileEvidence() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: StoredFile.self, configurations: configuration)
        let context = ModelContext(container)
        let file = StoredFile(name: "合成报销制度", ext: "txt", storedName: "fixture.txt", kind: .uploaded,
                              category: .other, byteCount: 0, sourceConversationId: "", textContent: "报销必须附发票；此内容仅为测试夹具。")
        context.insert(file); try context.save()
        let found = try ExpertKnowledgeService.search("报销", context: context)
        XCTAssertEqual(found.first?.id, file.id)
        XCTAssertTrue(found.first?.excerpt.contains("附发票") == true)
    }
    func testSixThemesHaveSixDifferentLayouts() {
        let layouts = Set(AppTheme.allCases.map { "\($0.cardRadius)/\($0.messageWidth)/\($0.cardPadding)" })
        XCTAssertEqual(layouts.count, 6)
    }
    func testExcelExportsNumericCellsAndSafeSheetName() throws {
        let bytes = DocumentBuilder.xlsx(title: "A/B:*[]", markdown: "| 值 | 编号 |\n| --- | --- |\n| 10.5 | 001 |")
        let reader = ZipReader(data: bytes)
        let xml = String(decoding: try reader.data(for: "xl/worksheets/sheet1.xml"), as: UTF8.self)
        XCTAssertTrue(xml.contains("<v>10.5</v>"))
        XCTAssertTrue(xml.contains(">001</t>"))
        let workbook = String(decoding: try reader.data(for: "xl/workbook.xml"), as: UTF8.self)
        XCTAssertTrue(workbook.contains("name=\"AB\""))
    }
}
