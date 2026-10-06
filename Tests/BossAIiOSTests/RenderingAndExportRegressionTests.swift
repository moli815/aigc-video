import XCTest
import SwiftData
import PDFKit
import Combine
import UIKit
@testable import BossAI

final class RenderingAndExportRegressionTests: XCTestCase {
    @MainActor
    func testStreamDeltasDoNotInvalidateWholeConversationViewModel() throws {
        let container = try ModelContainer(for: Conversation.self, Message.self, StoredFile.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let vm = ChatViewModel(conversation: nil, expert: ExpertCatalog.find("general"), modelContext: container.mainContext, chatKey: { nil }, imageKey: { nil })
        var wholeConversationUpdates = 0; var activeReplyUpdates = 0
        let whole = vm.objectWillChange.sink { wholeConversationUpdates += 1 }
        let active = vm.replyBuffer.$text.dropFirst().sink { _ in activeReplyUpdates += 1 }
        for _ in 0..<100 { vm.streamingText += "增量" }
        XCTAssertEqual(wholeConversationUpdates, 0)
        XCTAssertEqual(activeReplyUpdates, 100)
        XCTAssertEqual(vm.streamingText.count, 200)
        withExtendedLifetime((whole, active)) {}
    }
    func testParserRetainsAllRowsAndNormalizesExtraColumns() {
        let text = "| A | B |\n| --- | --- |\n| 1 | two | extra |\n" + (2...60).map { "| \($0) | x |" }.joined(separator: "\n")
        guard case .table(let rows) = MarkdownView.parse(text).first else { return XCTFail("应解析为表格") }
        XCTAssertEqual(rows.count, 61); XCTAssertTrue(rows.allSatisfy { $0.count == 3 })
        XCTAssertEqual(rows.last?[0], "60")
    }
    @MainActor
    func testBackgroundPDFKeepsMainActorResponsiveAndRetainsText() async throws {
        let content = String(repeating: "后台导出测试文字，必须保留完整内容。", count: 2000) + "最终导出标记"
        var finished = false; var ticks = 0; var maxGap: TimeInterval = 0
        let heartbeat = Task { @MainActor in
            var previous = ProcessInfo.processInfo.systemUptime
            while !finished {
                try? await Task.sleep(nanoseconds: 20_000_000)
                let now = ProcessInfo.processInfo.systemUptime
                maxGap = max(maxGap, now - previous); previous = now; ticks += 1
            }
        }
        let start = ProcessInfo.processInfo.systemUptime
        let data = try await DocumentBuilder.buildAsync(format: .pdf, title: "后台导出样本", content: content)
        let duration = ProcessInfo.processInfo.systemUptime - start
        finished = true; await heartbeat.value
        print("BOSSAI_BACKGROUND_PDF duration=\(duration) mainActorTicks=\(ticks) maxHeartbeatGap=\(maxGap)")
        XCTAssertGreaterThan(ticks, 5, "生成期间主线程必须能调度其他任务")
        XCTAssertLessThan(maxGap, max(1.0, duration * 0.5), "不得阻塞整个导出期间")
        let doc = try XCTUnwrap(PDFDocument(data: data))
        let text = (0..<doc.pageCount).compactMap { doc.page(at: $0)?.string }.joined()
        XCTAssertTrue(text.contains("最终导出标记")); XCTAssertGreaterThan(doc.pageCount, 1)
    }
    @MainActor
    func testAsyncStorageAndSourcesPersistenceRoundTrip() async throws {
        let container = try ModelContainer(for: Conversation.self, Message.self, StoredFile.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let record = try await FileStore.storeAsync(data: Data("hello".utf8), filename: "async.txt", kind: .generated, context: context)
        XCTAssertEqual(try Data(contentsOf: FileStore.url(for: record)), Data("hello".utf8))
        try FileStore.delete(record, context: context)
        let message = Message(role: "assistant", text: "来源 7")
        message.sourcesJSON = String(data: try JSONEncoder().encode([CitationSource(id: 7, url: "https://example.com/a", title: "官方标题")]), encoding: .utf8)!
        context.insert(message); try context.save()
        let fetched = try XCTUnwrap(context.fetch(FetchDescriptor<Message>()).first)
        XCTAssertEqual(CitationPresentation.projection(text: fetched.text, json: fetched.sourcesJSON).sources.first?.title, "官方标题")
    }
    func testBackupMissingNewSourceFieldStillDecodes() throws {
        let original = BackupService.MessageDTO(id: UUID(), role: "assistant", text: "旧回答", createdAt: Date(), attachmentIds: "", imageEntry: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BackupService.MessageDTO.self, from: data)
        XCTAssertNil(decoded.sourcesJSON)
        var enriched = original; enriched.sourcesJSON = "[]"
        XCTAssertEqual(try JSONDecoder().decode(BackupService.MessageDTO.self, from: JSONEncoder().encode(enriched)).sourcesJSON, "[]")
    }
    @MainActor
    func testGeneratedImageThumbnailIsDownsampledAndInvalidDataFails() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 2000), format: format).image { renderer in
            UIColor.blue.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
        }
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
        let decodedThumbnail = await ImageThumbnailWorker.shared.thumbnail(data)
        let thumbnail = try XCTUnwrap(decodedThumbnail)
        XCTAssertLessThanOrEqual(thumbnail.width, 1260); XCTAssertLessThanOrEqual(thumbnail.height, 1260)
        XCTAssertGreaterThan(thumbnail.width, thumbnail.height)
        let invalid = await ImageThumbnailWorker.shared.thumbnail(Data("invalid image".utf8))
        XCTAssertNil(invalid)
    }
    @MainActor
    func testEncryptedBackupPreservesSourceMetadataThroughRealImport() async throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let source = try ModelContainer(for: Conversation.self, Message.self, StoredFile.self, MemoryItem.self, configurations: configuration)
        let context = source.mainContext
        let conversation = Conversation(expertId: "general", title: "来源备份样本"); context.insert(conversation)
        let message = Message(role: "assistant", text: "结论（来源 7）")
        message.sourcesJSON = String(data: try JSONEncoder().encode([CitationSource(id: 7, url: "https://example.com/a", title: "实际来源标题")]), encoding: .utf8)!
        message.conversation = conversation; context.insert(message); try context.save()
        let url = try await BackupService.export(password: "offline-backup-password", context: context)
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try ModelContainer(for: Conversation.self, Message.self, StoredFile.self, MemoryItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let summary = try await BackupService.importBackup(from: url, password: "offline-backup-password", context: destination.mainContext)
        XCTAssertEqual(summary.messages, 1)
        let messages = try destination.mainContext.fetch(FetchDescriptor<Message>())
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(CitationPresentation.projection(text: messages[0].text, json: messages[0].sourcesJSON).sources.first?.title, "实际来源标题")
    }
    func testCancelledDocumentDoesNotReturnSuccess() async {
        let task = Task { try await DocumentBuilder.buildAsync(format: .word, title: "取消", content: "正文") }
        task.cancel()
        do { _ = try await task.value; XCTFail("取消操作不能显示导出成功") } catch is CancellationError {} catch { XCTFail("取消应返回CancellationError") }
    }
}
